import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../helpers/snack_bar_builder.dart';
import '../l10n/l10n.dart';
import '../widgets/empty_state.dart';

Future<void> pushBlockedRadiosScreen(BuildContext context) {
  return Navigator.push(
    context,
    MaterialPageRoute<void>(builder: (context) => const BlockedRadiosScreen()),
  );
}

/// The radios the user blocked (10.2.4), to unblock.
class BlockedRadiosScreen extends StatelessWidget {
  const BlockedRadiosScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final connector = context.watch<MeshCoreConnector>();
    final blocked = connector.blockedRadios;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.block_screenTitle)),
      body: blocked.isEmpty
          ? EmptyState(
              icon: Icons.block,
              title: l10n.block_screenTitle,
              subtitle: l10n.block_empty,
            )
          : ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(
                    connector.radioCanBlock
                        ? '${l10n.block_about} ${l10n.block_radioToo}'
                        : l10n.block_about,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                for (final b in blocked)
                  ListTile(
                    leading: const Icon(Icons.block),
                    title: Text(b.name.isEmpty ? (b.keyHex ?? '') : b.name),
                    subtitle: Text(
                      b.keyHex == null
                          ? l10n.block_nameOnly
                          : b.keyHex!.substring(0, 12),
                      style: b.keyHex == null
                          ? null
                          : const TextStyle(fontFamily: 'monospace'),
                    ),
                    trailing: TextButton(
                      onPressed: () async {
                        await connector.unblockRadio(b.id);
                        if (!context.mounted) return;
                        showDismissibleSnackBar(
                          context,
                          content: Text(
                            l10n.block_unblocked(
                              b.name.isEmpty ? (b.keyHex ?? '') : b.name,
                            ),
                          ),
                        );
                      },
                      child: Text(l10n.block_unblock),
                    ),
                  ),
              ],
            ),
    );
  }
}
