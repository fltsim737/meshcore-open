import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/app_localizations.dart';
import '../l10n/l10n.dart';
import '../models/sos_history.dart';
import '../services/sos_service.dart';

String sosHistoryOutcomeLabel(AppLocalizations l10n, SosHistoryRecord r) =>
    switch (r.outcome) {
      SosHistoryOutcome.ongoing => l10n.sos_historyOngoing,
      SosHistoryOutcome.cancelledBySender => l10n.sos_historyCancelledBySender,
      SosHistoryOutcome.cancelledByMe => l10n.sos_historyCancelledByMe,
      SosHistoryOutcome.dismissed => l10n.sos_historyDismissed,
      SosHistoryOutcome.expired => l10n.sos_historyExpired,
      SosHistoryOutcome.leftNetwork => l10n.sos_historyLeftNetwork,
    };

String _dateTime(BuildContext context, DateTime t) {
  final local = t.toLocal();
  final date = MaterialLocalizations.of(context).formatShortDate(local);
  return '$date ${TimeOfDay.fromDateTime(local).format(context)}';
}

Future<void> _share(BuildContext context, SosHistoryRecord record) async {
  final box = context.findRenderObject() as RenderBox?;
  await SharePlus.instance.share(
    ShareParams(
      text: record.toReport(),
      subject: context.l10n.sos_historySubject(record.id),
      sharePositionOrigin: box == null
          ? null
          : box.localToGlobal(Offset.zero) & box.size,
    ),
  );
}

/// Every SOS this phone received or sent, kept until the user deletes it.
class SosHistoryScreen extends StatelessWidget {
  const SosHistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final sos = context.watch<SosService>();
    final records = sos.history;
    final finished = records.where((r) => !r.isOngoing).length;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.sos_historyTitle),
        actions: [
          if (finished > 0)
            IconButton(
              tooltip: l10n.sos_historyDeleteAll,
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: () async {
                final ok = await _confirm(
                  context,
                  l10n.sos_historyDeleteAllTitle(finished),
                  l10n.sos_historyDeleteAllMessage,
                );
                if (ok) await sos.deleteFinishedHistory();
              },
            ),
        ],
      ),
      body: records.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(l10n.sos_historyEmpty, textAlign: TextAlign.center),
              ),
            )
          : ListView.separated(
              itemCount: records.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) => _RecordTile(record: records[i]),
            ),
    );
  }
}

class _RecordTile extends StatelessWidget {
  final SosHistoryRecord record;

  const _RecordTile({required this.record});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final received = record.direction == SosHistoryDirection.received;
    final status = [
      received ? l10n.sos_historyReceived : l10n.sos_historySent,
      if (received && record.ackSentAt != null) l10n.sos_historyAcknowledged,
      sosHistoryOutcomeLabel(l10n, record),
    ].join(' · ');
    return ListTile(
      leading: Icon(
        received ? Icons.call_received : Icons.call_made,
        color: record.isOngoing ? Colors.red.shade700 : null,
      ),
      title: Text(
        '${record.senderName.isEmpty ? l10n.sos_unknownSender : record.senderName}'
        '  #${record.id}',
      ),
      subtitle: Text(
        [
          _dateTime(context, record.startedAt),
          if (record.info != null) l10n.sos_alertInfo(record.info!),
          status,
        ].join('\n'),
      ),
      isThreeLine: true,
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => _RecordScreen(record: record)),
      ),
    );
  }
}

class _RecordScreen extends StatelessWidget {
  final SosHistoryRecord record;

  const _RecordScreen({required this.record});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // rebuilt as repeats of a live alert come in
    context.watch<SosService>();
    return Scaffold(
      appBar: AppBar(
        title: Text('SOS #${record.id}'),
        actions: [
          Builder(
            builder: (context) => IconButton(
              tooltip: l10n.common_share,
              icon: const Icon(Icons.share),
              onPressed: () => _share(context, record),
            ),
          ),
          IconButton(
            tooltip: l10n.common_delete,
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              final ok = await _confirm(
                context,
                l10n.sos_historyDeleteTitle,
                l10n.sos_historyDeleteMessage,
              );
              if (!ok || !context.mounted) return;
              await context.read<SosService>().deleteHistory(record);
              if (context.mounted) Navigator.pop(context);
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: SelectableText(
          record.toReport(),
          style: const TextStyle(fontFamily: 'monospace', height: 1.4),
        ),
      ),
    );
  }
}

Future<bool> _confirm(
  BuildContext context,
  String title,
  String message,
) async {
  final l10n = context.l10n;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(l10n.common_cancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(l10n.common_delete),
        ),
      ],
    ),
  );
  return ok ?? false;
}
