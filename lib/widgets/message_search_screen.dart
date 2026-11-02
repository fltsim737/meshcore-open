import 'dart:async';

import 'package:flutter/material.dart';

import '../helpers/message_search.dart';
import '../l10n/l10n.dart';
import 'chat_day_separator.dart';
import 'empty_state.dart';

/// Searches one chat's whole history (10.2.6). [load] gives every message
/// once; the list then filters as you type, newest first. Tapping a result
/// closes the screen with that message's id, for the chat to jump to.
class MessageSearchScreen extends StatefulWidget {
  final String title;
  final Future<List<MessageSearchHit>> Function() load;

  const MessageSearchScreen({
    super.key,
    required this.title,
    required this.load,
  });

  /// Opens the search; the id of the message picked, or null.
  static Future<String?> open(
    BuildContext context, {
    required String title,
    required Future<List<MessageSearchHit>> Function() load,
  }) => Navigator.push<String>(
    context,
    MaterialPageRoute(
      builder: (_) => MessageSearchScreen(title: title, load: load),
    ),
  );

  @override
  State<MessageSearchScreen> createState() => _MessageSearchScreenState();
}

class _MessageSearchScreenState extends State<MessageSearchScreen> {
  final _controller = TextEditingController();
  List<MessageSearchHit>? _all;
  List<MessageSearchHit> _hits = const [];
  String _query = '';
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    widget.load().then((all) {
      if (!mounted) return;
      setState(() {
        _all = all;
        _hits = MessageSearch.filter(all, _query);
      });
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), () {
      if (!mounted) return;
      setState(() {
        _query = value;
        _hits = _all == null ? const [] : MessageSearch.filter(_all!, value);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final terms = MessageSearch.terms(_query);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          controller: _controller,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: l10n.chat_searchHint,
            border: InputBorder.none,
            suffixIcon: _controller.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear),
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).deleteButtonTooltip,
                    onPressed: () {
                      _controller.clear();
                      _onChanged('');
                      setState(() {});
                    },
                  ),
          ),
          onChanged: (v) {
            setState(() {}); // the clear button
            _onChanged(v);
          },
        ),
      ),
      body: _all == null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 12),
                  Text(l10n.chat_searchLoading),
                ],
              ),
            )
          : terms.isEmpty
          ? EmptyState(
              icon: Icons.search,
              title: widget.title,
              subtitle: l10n.chat_searchStart,
            )
          : _hits.isEmpty
          ? EmptyState(icon: Icons.search_off, title: l10n.chat_searchNone)
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      l10n.chat_searchCount(_hits.length),
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ),
                ),
                Expanded(
                  child: ListView.separated(
                    itemCount: _hits.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final h = _hits[i];
                      final hl = TextStyle(
                        fontWeight: FontWeight.w700,
                        backgroundColor: scheme.primaryContainer,
                        color: scheme.onPrimaryContainer,
                      );
                      return ListTile(
                        title: Row(
                          children: [
                            Expanded(
                              child: Text.rich(
                                TextSpan(
                                  children: MessageSearch.highlight(
                                    h.sender,
                                    terms,
                                    hl,
                                  ),
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '${formatChatDayLabel(context, h.time)} '
                              '${formatChatTime(context, h.time)}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                        subtitle: Text.rich(
                          TextSpan(
                            children: MessageSearch.highlight(
                              h.text,
                              terms,
                              hl,
                            ),
                          ),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => Navigator.pop(context, h.messageId),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}
