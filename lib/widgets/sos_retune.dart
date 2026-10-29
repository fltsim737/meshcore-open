import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../helpers/snack_bar_builder.dart';
import '../l10n/l10n.dart';
import '../models/sos_alert.dart';
import '../services/sos_service.dart';

/// Asks before moving this radio to [alert]'s sender's settings, then does it
/// (telling the other responders first). Retuning is always the responder's
/// own choice: they know when they're within coverage on the far side.
Future<void> confirmAndRetune(
  BuildContext context,
  SosService service,
  IncomingSos alert,
) async {
  final l10n = context.l10n;
  final radio = alert.senderRadio;
  if (radio == null) return;
  final go = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.sos_retuneConfirmTitle(alert.senderName)),
      content: Text(l10n.sos_retuneConfirmBody(radio.label)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text(
            MaterialLocalizations.of(dialogContext).cancelButtonLabel,
          ),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(l10n.sos_retuneAction),
        ),
      ],
    ),
  );
  if (go != true || !context.mounted) return;
  showDismissibleSnackBar(context, content: Text(l10n.sos_retuning));
  final ok = await service.retuneTo(alert);
  if (!ok && context.mounted) {
    showDismissibleSnackBar(
      context,
      content: Text(l10n.sos_retuneFailed),
      backgroundColor: Theme.of(context).colorScheme.error,
    );
  }
}

/// While this radio is retuned to an SOS sender's settings: says so, and
/// takes it back. Never hidden while retuned.
class SosRetunedBanner extends StatelessWidget {
  const SosRetunedBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final service = context.watch<SosService>();
    final retune = service.retune;
    if (retune == null) return const SizedBox.shrink();
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      color: scheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.swap_horiz, color: scheme.onTertiaryContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.sos_retunedBannerTitle,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: scheme.onTertiaryContainer,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              l10n.sos_retunedBanner(
                retune.senderName,
                retune.to.label,
                retune.from.frequencyLabel,
              ),
              style: TextStyle(color: scheme.onTertiaryContainer),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              icon: const Icon(Icons.undo),
              label: Text(l10n.sos_retuneBack(retune.from.frequencyLabel)),
              onPressed: service.isConnected
                  ? () async {
                      final ok = await service.retuneBack();
                      if (!ok && context.mounted) {
                        showDismissibleSnackBar(
                          context,
                          content: Text(l10n.sos_retuneBackFailed),
                          backgroundColor: scheme.error,
                        );
                      }
                    }
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}
