import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../services/sos_service.dart';

/// The connected radio doesn't have the emergency network's channel: asks
/// before putting it on, rather than adding it to whatever radio connects
/// (a test radio, someone else's, or one meant for another network).
class SosRadioApprovalCard extends StatelessWidget {
  const SosRadioApprovalCard({super.key});

  @override
  Widget build(BuildContext context) {
    final sos = context.watch<SosService>();
    final network = sos.network;
    if (network == null ||
        sos.networkStatus != SosNetworkStatus.needsApproval ||
        sos.radioDeclined) {
      return const SizedBox.shrink();
    }
    final l10n = context.l10n;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.sos_radioApprovalTitle(network.name),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(l10n.sos_radioApprovalBody),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: sos.declineRadio,
                  child: Text(l10n.sos_radioNotThis),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: sos.addNetworkToRadio,
                  child: Text(l10n.sos_radioAdd),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
