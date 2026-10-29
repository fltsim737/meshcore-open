import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:meshcore_open/utils/app_logger.dart';
import 'package:provider/provider.dart';
import '../l10n/l10n.dart';
import '../models/contact.dart';
import '../models/path_selection.dart';
import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../services/repeater_command_service.dart';
import '../theme/mesh_theme.dart';
import '../widgets/empty_state.dart';
import '../widgets/mesh_ui.dart';
import '../widgets/routing_sheet.dart';
import '../helpers/snack_bar_builder.dart';
import '../l10n/app_localizations.dart';
import '../widgets/repeater_login_dialog.dart';
import 'repeater_hub_screen.dart';

class NeighborsScreen extends StatefulWidget {
  final Contact repeater;
  final String password;

  const NeighborsScreen({
    super.key,
    required this.repeater,
    required this.password,
  });

  @override
  State<NeighborsScreen> createState() => _NeighborsScreenState();
}

class _NeighborsScreenState extends State<NeighborsScreen> {
  static const int _reqNeighborsKeyLen = 4;
  // Firmware packs results into a 130-byte buffer (simple_repeater/MyMesh.cpp).
  static const int _reqNeighborsPageSize = 130 ~/ (_reqNeighborsKeyLen + 5);
  static const int _pageAttempts = 3;
  // Tags of every request sent for the page being loaded: a late reply to an
  // earlier attempt still counts.
  final Set<String> _pageTags = {};
  bool _awaitingSent = false;
  Completer<({int total, List<Map<String, dynamic>> page})>? _pageReply;
  int _neighborCount = 0;

  bool _isLoading = false;
  bool _isLoaded = false;
  bool _hasData = false;
  StreamSubscription<Uint8List>? _frameSubscription;
  RepeaterCommandService? _commandService;
  PathSelection? _pendingStatusSelection;
  List<Map<String, dynamic>>? _parsedNeighbors;

  int _resolveRepeaterIndex = -1;

  Contact _resolveRepeater(MeshCoreConnector connector) {
    if (_resolveRepeaterIndex >= 0 &&
        _resolveRepeaterIndex < connector.contacts.length &&
        connector.contacts[_resolveRepeaterIndex].publicKeyHex ==
            widget.repeater.publicKeyHex) {
      return connector.contacts[_resolveRepeaterIndex];
    }
    _resolveRepeaterIndex = connector.contacts.indexWhere(
      (c) => c.publicKeyHex == widget.repeater.publicKeyHex,
    );
    if (_resolveRepeaterIndex == -1) {
      return widget.repeater;
    }
    return connector.contacts[_resolveRepeaterIndex];
  }

  @override
  void initState() {
    super.initState();
    final connector = Provider.of<MeshCoreConnector>(context, listen: false);
    _commandService = RepeaterCommandService(connector);
    _setupMessageListener();
    _loadNeighbors();
    _hasData = false;
  }

  void _setupMessageListener() {
    final connector = Provider.of<MeshCoreConnector>(context, listen: false);

    // Listen for incoming text messages from the repeater
    _frameSubscription = connector.receivedFrames.listen((frame) {
      if (frame.isEmpty) return;

      if (frame[0] == respCodeSent && _awaitingSent && frame.length >= 6) {
        _awaitingSent = false;
        _pageTags.add(pubKeyToHex(frame.sublist(2, 6)));
      }

      // Check if it's a binary response
      if (frame[0] == pushCodeBinaryResponse &&
          frame.length >= 6 &&
          _pageTags.contains(pubKeyToHex(frame.sublist(2, 6)))) {
        _handleNeighborsResponse(frame.sublist(6));
      }
    });
  }

  static String fmtDuration(AppLocalizations l10n, double seconds) {
    if (seconds < 60) {
      return l10n.neighbors_durationSeconds(seconds.toStringAsFixed(1));
    }

    final int m = (seconds ~/ 60).toInt();
    final double s = seconds - (60 * m);

    if (m < 60) {
      return l10n.neighbors_durationMinutes(m, s.toStringAsFixed(0));
    }

    final int h = m ~/ 60;
    final int m2 = m % 60;

    return l10n.neighbors_durationHours(h, m2);
  }

  static List<Map<String, dynamic>> parseNeighborsData(
    BufferReader buffer,
    int resultsCount,
  ) {
    final Map<int, Map<String, dynamic>> neighbors = {};
    try {
      for (var i = 0; i < resultsCount; i++) {
        final neighborData = neighbors.putIfAbsent(
          i,
          () => {
            'contact': null,
            'publicKey': <Uint8List>{},
            'lastHeard': <int>{},
            'snr': <double>{},
          },
        );
        neighborData['publicKey'] = buffer.readBytes(_reqNeighborsKeyLen);
        neighborData['lastHeard'] = buffer.readUInt32LE();
        neighborData['snr'] = buffer.readInt8() / 4.0;
      }

      return neighbors.values.toList();
    } catch (e) {
      appLogger.error(
        'Error parsing neighbors data: $e',
        tag: 'NeighborsScreen',
      );
      return [];
    }
  }

  void _handleNeighborsResponse(Uint8List frame) {
    final reply = _pageReply;
    if (reply == null || reply.isCompleted) return;
    final buffer = BufferReader(frame);
    try {
      final total = buffer.readUInt16LE();
      final page = parseNeighborsData(buffer, buffer.readUInt16LE());
      reply.complete((total: total, page: page));
    } catch (e) {
      appLogger.error('Error handling neighbors response: $e');
    }
  }

  /// Links neighbours to known repeater contacts by key prefix.
  void _linkContacts(
    MeshCoreConnector connector,
    List<Map<String, dynamic>> neighbors,
  ) {
    final repeaters = connector.allContactsUnfiltered.where(
      (c) => c.type == advTypeRepeater,
    );
    for (final repeater in repeaters) {
      for (final neighborData in neighbors) {
        if (listEquals(
          repeater.publicKey.sublist(0, _reqNeighborsKeyLen),
          neighborData['publicKey'],
        )) {
          neighborData['contact'] = repeater;
        }
      }
    }
  }

  /// Requests one page, up to [_pageAttempts] times. Null if none answered.
  Future<({int total, List<Map<String, dynamic>> page})?> _requestPage(
    MeshCoreConnector connector,
    Contact repeater,
    int offset,
    Object load,
  ) async {
    final reply = Completer<({int total, List<Map<String, dynamic>> page})>();
    _pageReply = reply;
    _pageTags.clear();
    PathSelection? first;
    for (var attempt = 0; attempt < _pageAttempts; attempt++) {
      final selection = await connector.preparePathForRepeaterAttempt(
        repeater,
        attempt: attempt,
        attempts: _pageAttempts,
        first: first,
      );
      first ??= selection;
      if (!mounted || !identical(_currentLoad, load)) return null;
      _pendingStatusSelection = selection;

      //[version][number of requested neighbors][offset_16bit][order by][len of public key]
      final frame = buildSendBinaryReq(
        repeater.publicKey,
        payload: Uint8List.fromList([
          reqTypeGetNeighbors,
          0x00,
          _reqNeighborsPageSize,
          offset & 0xFF,
          (offset >> 8) & 0xFF,
          0x00,
          _reqNeighborsKeyLen,
        ]),
      );
      _awaitingSent = true;
      await connector.sendFrame(frame);
      try {
        final result = await reply.future.timeout(
          Duration(milliseconds: connector.repeaterReplyTimeout(selection)),
        );
        _recordStatusResult(true);
        return result;
      } on TimeoutException {
        if (!mounted || !identical(_currentLoad, load)) return null;
        _recordStatusResult(false);
      }
    }
    return null;
  }

  /// Identifies the running load, so a refresh abandons the previous one.
  Object? _currentLoad;

  Future<void> _loadNeighbors() async {
    if (_commandService == null) return;
    final load = Object();
    _currentLoad = load;

    setState(() {
      _isLoading = true;
      _isLoaded = false;
    });
    try {
      final connector = Provider.of<MeshCoreConnector>(context, listen: false);
      final repeater = _resolveRepeater(connector);
      final neighbors = <Map<String, dynamic>>[];
      var total = 0;
      while (true) {
        final result = await _requestPage(
          connector,
          repeater,
          neighbors.length,
          load,
        );
        if (!mounted || !identical(_currentLoad, load)) return;
        if (result == null) {
          setState(() {
            _isLoading = false;
            _isLoaded = false;
          });
          showDismissibleSnackBar(
            context,
            content: Text(context.l10n.neighbors_requestTimedOut),
            backgroundColor: Theme.of(context).colorScheme.error,
          );
          return;
        }
        total = result.total;
        neighbors.addAll(result.page);
        _linkContacts(connector, neighbors);
        setState(() {
          _parsedNeighbors = List.of(neighbors);
          _neighborCount = total;
        });
        if (result.page.isEmpty || neighbors.length >= total) break;
      }
      setState(() {
        _isLoading = false;
        _isLoaded = true;
        _hasData = true;
      });
    } catch (e) {
      _awaitingSent = false;
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isLoaded = false;
        });

        showDismissibleSnackBar(
          context,
          content: Text(context.l10n.neighbors_errorLoading(e.toString())),
          backgroundColor: Theme.of(context).colorScheme.error,
        );
      }
    }
  }

  void _recordStatusResult(bool success) {
    final selection = _pendingStatusSelection;
    if (selection == null) return;
    final connector = Provider.of<MeshCoreConnector>(context, listen: false);
    final repeater = _resolveRepeater(connector);
    connector.recordRepeaterPathResult(repeater, selection, success, null);
    _pendingStatusSelection = null;
  }

  @override
  void dispose() {
    _frameSubscription?.cancel();
    _commandService?.dispose();
    _currentLoad = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final connector = context.watch<MeshCoreConnector>();
    final repeater = _resolveRepeater(connector);
    final isFloodMode = repeater.pathOverride == -1;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l10n.neighbors_repeatersNeighbors,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              repeater.name,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.normal,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: Icon(isFloodMode ? Icons.waves : Icons.route),
            tooltip: l10n.repeater_routingMode,
            onPressed: () =>
                ContactRoutingSheet.show(context, contact: repeater),
          ),
          IconButton(
            icon: _isLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            onPressed: _isLoading ? null : _loadNeighbors,
            tooltip: l10n.repeater_refresh,
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: RefreshIndicator(
          onRefresh: _loadNeighbors,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              // First request still in flight: show progress, not "no data".
              if (_isLoading && _parsedNeighbors == null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 64),
                  child: Column(
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 16),
                      Text(
                        l10n.common_loading,
                        style: const TextStyle(fontSize: 16),
                      ),
                    ],
                  ),
                )
              else if (!_isLoaded &&
                  !_hasData &&
                  (_parsedNeighbors == null || _parsedNeighbors!.isEmpty))
                EmptyState(icon: Icons.wifi_find, title: l10n.neighbors_noData),
              if (_isLoaded ||
                  _hasData &&
                      !(_parsedNeighbors == null || _parsedNeighbors!.isEmpty))
                _buildNeighborsList(connector),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNeighborsList(MeshCoreConnector connector) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          '${l10n.repeater_neighbors} — $_neighborCount',
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 10),
        ),
        for (var i = 0; i < _parsedNeighbors!.length; i++)
          ListEntrance(
            index: i,
            child: _buildNeighborRow(_parsedNeighbors![i], connector.currentSf),
          ),
      ],
    );
  }

  Widget _buildNeighborRow(Map<String, dynamic> data, int? spreadingFactor) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final Contact? contact = data['contact'] as Contact?;
    final double snr = data['snr'] as double;
    final int lastHeardSeconds = data['lastHeard'] as int;

    final name = contact != null
        ? contact.name
        : l10n.neighbors_unknownContact(
            '<${pubKeyToHex(data['publicKey'] as Uint8List)}>',
          );

    final snrColor = MeshTheme.snrColor(snr, blocked: false);
    final heardLabel = l10n.neighbors_heardAgo(
      fmtDuration(l10n, lastHeardSeconds + 0.0),
    );
    // Only repeaters saved on the radio can be logged into.
    final canOpen = contact != null && contact.isActive;

    return MeshCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      margin: const EdgeInsets.symmetric(vertical: 4),
      onTap: canOpen ? () => _openNeighbor(contact) : null,
      child: Row(
        children: [
          AvatarCircle(
            name: name,
            size: 40,
            color: contact != null ? MeshPalette.warn : scheme.onSurfaceVariant,
            icon: contact != null ? Icons.cell_tower : Icons.device_unknown,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w500,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  heardLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              SignalBars(snr: snr, height: 16),
              const SizedBox(height: 4),
              Text(
                '${snr.toStringAsFixed(1)} dB',
                style: MeshTheme.mono(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: snrColor,
                ),
              ),
            ],
          ),
          if (canOpen) ...[
            const SizedBox(width: 4),
            Icon(Icons.chevron_right, size: 24, color: scheme.onSurfaceVariant),
          ],
        ],
      ),
    );
  }

  /// Opens a resolved neighbor the same way the contacts list does:
  /// repeaters go through the login dialog to the repeater hub.
  void _openNeighbor(Contact contact) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => RepeaterLoginDialog(
        repeater: contact,
        onLogin: (password, isAdmin) {
          if (!mounted) return;
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => RepeaterHubScreen(
                repeater: contact,
                password: password,
                isAdmin: isAdmin,
              ),
            ),
          );
        },
      ),
    );
  }
}
