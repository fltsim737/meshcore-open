import 'package:flutter/material.dart';

import '../connector/meshcore_connector.dart';
import '../helpers/snack_bar_builder.dart';
import '../l10n/l10n.dart';

/// Asks before blocking a radio (10.2.4): by its key ([keyHex]) when known,
/// otherwise a channel sender by [name] alone.
Future<void> confirmBlockRadio(
  BuildContext context,
  MeshCoreConnector connector, {
  String? keyHex,
  required String name,
}) async {
  final l10n = context.l10n;
  final yes = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(l10n.block_title(name)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(keyHex == null ? l10n.block_bodyNameOnly : l10n.block_body),
          if (keyHex != null && connector.radioCanBlock) ...[
            const SizedBox(height: 8),
            Text(l10n.block_bodyRadio),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(l10n.common_cancel),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(ctx).colorScheme.error,
            foregroundColor: Theme.of(ctx).colorScheme.onError,
          ),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(l10n.block_confirm),
        ),
      ],
    ),
  );
  if (yes != true) return;
  final ok = await connector.blockRadio(keyHex: keyHex, name: name);
  if (!ok || !context.mounted) return;
  showDismissibleSnackBar(context, content: Text(l10n.block_blocked(name)));
}
