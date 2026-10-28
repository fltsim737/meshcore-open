import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../theme/mesh_theme.dart';

/// Small warning shown next to a message time when the sender's clock is
/// clearly wrong, ahead (#584) or far behind; the time shown is then when the
/// message arrived, and messages are ordered by that.
class FutureTimestampIndicator extends StatelessWidget {
  final double size;

  const FutureTimestampIndicator({super.key, this.size = 16});

  @override
  Widget build(BuildContext context) {
    final label = context.l10n.chat_futureTimestampWarning;
    return Tooltip(
      message: label,
      triggerMode: TooltipTriggerMode.tap,
      child: Semantics(
        label: label,
        child: Icon(Icons.update, size: size, color: MeshPalette.warn),
      ),
    );
  }
}
