import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../screens/emergency_screen.dart' show sosCoordinates, sosSourceLabel;
import '../services/sos_service.dart';

/// Full-screen warning shown above every route while any incoming SOS is
/// open. Driven by [SosService] state rather than a pushed route, so no
/// navigation can hide it: only Send ACK or Dismiss does.
class SosWarningOverlay extends StatelessWidget {
  const SosWarningOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    final service = context.watch<SosService>();
    final open = service.openIncoming;
    if (open.isEmpty) return const SizedBox.shrink();

    // Oldest first, so the first alert heard is the first answered.
    final alert = open.last;
    final l10n = context.l10n;
    final textTheme = Theme.of(context).textTheme;
    const white = Colors.white;
    final fix = alert.fix;
    final others = alert.ackedBy.join(', ');
    String time(DateTime t) => TimeOfDay.fromDateTime(t).format(context);

    return Positioned.fill(
      child: Material(
        color: Colors.red.shade800,
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: constraints.maxHeight - 48,
                ),
                child: DefaultTextStyle.merge(
                  style: const TextStyle(color: white),
                  textAlign: TextAlign.center,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.sos, color: white, size: 96),
                      const SizedBox(height: 8),
                      Text(
                        l10n.sos_warningTitle,
                        style: textTheme.headlineMedium?.copyWith(
                          color: white,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 2,
                        ),
                      ),
                      if (open.length > 1)
                        Text(l10n.sos_warningMore(open.length - 1)),
                      const SizedBox(height: 16),
                      Text(
                        alert.senderName.isEmpty
                            ? l10n.sos_unknownSender
                            : alert.senderName,
                        style: textTheme.headlineSmall?.copyWith(
                          color: white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (alert.info != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            l10n.sos_alertInfo(alert.info!),
                            style: textTheme.titleLarge?.copyWith(
                              color: white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      const SizedBox(height: 16),
                      Text(
                        fix.hasPosition
                            ? sosCoordinates(fix)
                            : l10n.sos_noPosition,
                        style: textTheme.titleLarge?.copyWith(
                          color: white,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      Text(
                        l10n.sos_locationSource(
                          sosSourceLabel(l10n, fix.source),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        l10n.sos_heardSummary(
                          time(alert.firstSeen),
                          time(alert.lastSeen),
                          alert.receivedCount,
                        ),
                      ),
                      if (others.isNotEmpty)
                        Text(l10n.sos_ackedByOthers(others)),
                      const SizedBox(height: 32),
                      SizedBox(
                        width: double.infinity,
                        height: 64,
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: white,
                            foregroundColor: Colors.red.shade900,
                            textStyle: textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          icon: const Icon(Icons.check, size: 32),
                          label: Text(l10n.sos_sendAck),
                          onPressed: service.isConnected
                              ? () => service.acknowledge(alert)
                              : null,
                        ),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: white,
                            side: const BorderSide(color: white, width: 2),
                          ),
                          onPressed: () => service.dismiss(alert),
                          child: Text(l10n.sos_dismiss),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
