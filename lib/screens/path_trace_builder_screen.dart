import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../helpers/path_helper.dart';
import '../helpers/path_hop_resolver.dart';
import '../l10n/contact_localization.dart';
import '../l10n/l10n.dart';
import '../models/contact.dart';
import 'path_trace_map.dart';

/// Path Trace (10.2.7): one page. The hex path is at the top and can be typed
/// or pasted; below it the same path is built by tapping repeaters. Both stay
/// in step. Two buttons run the trace there and back, or one way.
class PathTraceBuilderScreen extends StatefulWidget {
  const PathTraceBuilderScreen({super.key, this.contactsForTest});

  /// Repeaters to list instead of the connector's, for widget tests.
  @visibleForTesting
  final List<Contact>? contactsForTest;

  /// The last path traced, so reopening the page starts from it.
  static List<int> _lastPath = const [];

  @override
  State<PathTraceBuilderScreen> createState() => _PathTraceBuilderScreenState();
}

class _PathTraceBuilderScreenState extends State<PathTraceBuilderScreen> {
  static const int _maxHops = 64;

  final List<Uint8List> _hops = [];
  final _hexController = TextEditingController();
  final _searchController = TextEditingController();
  String? _hexError;
  String _search = '';

  int get _width => context
      .read<MeshCoreConnector>()
      .pathHashByteWidth
      .clamp(1, pubKeySize)
      .toInt();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _hops.addAll(
          PathHelper.splitPathBytes(PathTraceBuilderScreen._lastPath, _width),
        );
        _syncHex();
      });
    });
  }

  @override
  void dispose() {
    _hexController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Uint8List get _pathBytes {
    final bytes = <int>[];
    for (final hop in _hops) {
      bytes.addAll(hop);
    }
    return Uint8List.fromList(bytes);
  }

  void _syncHex() {
    _hexController.text = _hops.map(PathHelper.formatHopHex).join(',');
    _hexError = null;
  }

  void _onHexChanged(String text) {
    final l10n = context.l10n;
    final width = _width;
    final tokens = text
        .split(RegExp(r'[,\s]+'))
        .where((t) => t.isNotEmpty)
        .toList();
    final invalid = tokens
        .where(
          (t) => t.length != width * 2 || int.tryParse(t, radix: 16) == null,
        )
        .toList();
    setState(() {
      if (invalid.isNotEmpty) {
        _hexError = l10n.pathEditor_invalidTokens(invalid.join(', '));
        return;
      }
      if (tokens.length > _maxHops) {
        _hexError = l10n.pathEditor_tooManyHops;
        return;
      }
      _hexError = null;
      _hops
        ..clear()
        ..addAll(
          tokens.map((t) {
            final bytes = <int>[];
            for (var i = 0; i < t.length; i += 2) {
              bytes.add(int.parse(t.substring(i, i + 2), radix: 16));
            }
            return Uint8List.fromList(bytes);
          }),
        );
    });
  }

  void _addHop(Contact contact) {
    if (_hops.length >= _maxHops) return;
    final width = _width.clamp(1, contact.publicKey.length).toInt();
    setState(() {
      _hops.add(Uint8List.fromList(contact.publicKey.sublist(0, width)));
      _syncHex();
    });
  }

  void _removeHop(int index) {
    setState(() {
      _hops.removeAt(index);
      _syncHex();
    });
  }

  void _reorderHop(int oldIndex, int newIndex) {
    setState(() {
      final hop = _hops.removeAt(oldIndex);
      _hops.insert(newIndex, hop);
      _syncHex();
    });
  }

  void _clear() {
    setState(() {
      _hops.clear();
      _syncHex();
    });
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty || !mounted) return;
    _hexController.text = text.toUpperCase();
    _onHexChanged(_hexController.text);
  }

  void _run({required bool thereAndBack}) {
    if (_hops.isEmpty || _hexError != null) return;
    final connector = context.read<MeshCoreConnector>();
    final path = _pathBytes;
    PathTraceBuilderScreen._lastPath = path;
    final resolved = PathHopResolver.resolve(
      pathBytes: path,
      contacts: widget.contactsForTest ?? connector.contacts,
      pathHashByteWidth: _width,
    );
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => PathTraceMapScreen(
          title: context.l10n.contacts_pathTrace,
          path: path,
          flipPathAround: thereAndBack,
          pathHashByteWidth: _width,
          pathContacts: resolved.whereType<Contact>().toList(),
        ),
      ),
    );
  }

  List<Contact> _repeaters(List<Contact> contacts) {
    final query = _search.trim().toLowerCase();
    return contacts
        .where((c) => c.type == advTypeRepeater || c.type == advTypeRoom)
        .where((c) => c.publicKey.isNotEmpty)
        .where(
          (c) =>
              query.isEmpty ||
              c.name.toLowerCase().contains(query) ||
              PathHelper.formatHopHex(
                c.publicKey,
              ).toLowerCase().startsWith(query),
        )
        .toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  String? _hopName(List<Contact> contacts, Uint8List hop) {
    final names = contacts
        .where((c) => c.type == advTypeRepeater || c.type == advTypeRoom)
        .where((c) => c.publicKey.length >= hop.length)
        .where((c) {
          for (var i = 0; i < hop.length; i++) {
            if (c.publicKey[i] != hop[i]) return false;
          }
          return true;
        })
        .map((c) => c.name)
        .toList();
    if (names.isEmpty) return null;
    return names.join(' | ');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final connector = context.watch<MeshCoreConnector>();
    final contacts = widget.contactsForTest ?? connector.contacts;
    final repeaters = _repeaters(contacts);
    final width = _width;
    final canRun = _hops.isNotEmpty && _hexError == null;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.contacts_pathTrace),
        actions: [
          if (_hops.isNotEmpty)
            TextButton(onPressed: _clear, child: Text(l10n.common_clear)),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        children: [
          TextField(
            controller: _hexController,
            onChanged: _onHexChanged,
            textCapitalization: TextCapitalization.characters,
            autocorrect: false,
            enableSuggestions: false,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
            decoration: InputDecoration(
              labelText: l10n.pathTrace_hexLabel,
              hintText: List.filled(3, 'A1' * width).join(','),
              helperText: _hexError == null
                  ? l10n.pathTrace_hexHelper(width * 2)
                  : null,
              helperMaxLines: 3,
              errorText: _hexError,
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: const Icon(Icons.content_paste),
                tooltip: l10n.pathTrace_paste,
                onPressed: _paste,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            l10n.pathEditor_hopCounter(_hops.length),
            style: theme.textTheme.titleSmall,
          ),
          if (_hops.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                l10n.pathTrace_noHops,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            )
          else
            ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              itemCount: _hops.length,
              onReorderItem: _reorderHop,
              itemBuilder: (context, index) {
                final hop = _hops[index];
                return ListTile(
                  key: ObjectKey(hop),
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                    radius: 14,
                    backgroundColor: scheme.primaryContainer,
                    child: Text(
                      '${index + 1}',
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                  title: Text(
                    _hopName(contacts, hop) ?? l10n.pathEditor_unknownHop,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(PathHelper.formatHopHex(hop)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.remove_circle_outline),
                        tooltip: l10n.pathEditor_removeHop,
                        onPressed: () => _removeHop(index),
                      ),
                      ReorderableDragStartListener(
                        index: index,
                        child: const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 12,
                          ),
                          child: Icon(Icons.drag_handle),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          const Divider(height: 24),
          Text(l10n.pathTrace_buildBelow, style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          TextField(
            controller: _searchController,
            onChanged: (value) => setState(() => _search = value),
            decoration: InputDecoration(
              labelText: l10n.pathEditor_searchRepeaters,
              prefixIcon: const Icon(Icons.search),
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 4),
          if (repeaters.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                l10n.path_noRepeatersFound,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            )
          else
            ...repeaters.map((c) {
              final isRepeater = c.type == advTypeRepeater;
              final full = _hops.length >= _maxHops;
              return ListTile(
                contentPadding: EdgeInsets.zero,
                enabled: !full,
                leading: Icon(isRepeater ? Icons.router : Icons.meeting_room),
                title: Text(
                  c.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${c.typeLabel(l10n)} • ${PathHelper.formatHopHex(c.publicKey.sublist(0, width.clamp(1, c.publicKey.length).toInt()))}',
                ),
                trailing: const Icon(Icons.add_circle_outline),
                onTap: full ? null : () => _addHop(c),
              );
            }),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                      ),
                      onPressed: canRun
                          ? () => _run(thereAndBack: false)
                          : null,
                      child: Text(l10n.pathTrace_oneWay),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                      ),
                      onPressed: canRun ? () => _run(thereAndBack: true) : null,
                      icon: const Icon(Icons.radar),
                      label: Text(l10n.pathTrace_thereAndBack),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                l10n.pathTrace_oneWayNote,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
