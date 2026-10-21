import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../helpers/snack_bar_builder.dart';
import '../helpers/sos_codec.dart';
import '../l10n/app_localizations.dart';
import '../l10n/l10n.dart';
import '../models/contact.dart';
import '../models/sos_alert.dart';
import '../services/sos_service.dart';
import '../utils/disconnect_navigation_mixin.dart';
import '../utils/route_transitions.dart';
import '../widgets/mesh_ui.dart';
import '../widgets/quick_switch_bar.dart';
import 'channels_screen.dart';
import 'contacts_screen.dart';
import 'map_screen.dart';

String sosSourceLabel(AppLocalizations l10n, SosLocationSource source) =>
    switch (source) {
      SosLocationSource.phoneGps => l10n.sos_sourcePhoneGps,
      SosLocationSource.radio => l10n.sos_sourceRadio,
      SosLocationSource.stored => l10n.sos_sourceStored,
      SosLocationSource.none => l10n.sos_sourceNone,
    };

String sosCoordinates(SosFix fix) =>
    '${fix.latitude!.toStringAsFixed(5)}, ${fix.longitude!.toStringAsFixed(5)}';

String _time(BuildContext context, DateTime time) =>
    TimeOfDay.fromDateTime(time).format(context);

class EmergencyScreen extends StatefulWidget {
  final bool hideBackButton;

  const EmergencyScreen({super.key, this.hideBackButton = false});

  @override
  State<EmergencyScreen> createState() => _EmergencyScreenState();
}

class _EmergencyScreenState extends State<EmergencyScreen>
    with DisconnectNavigationMixin {
  @override
  void initState() {
    super.initState();
    // Ask now, while nothing is urgent, so the SOS itself never waits on a
    // permission dialog.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<SosService>().phoneLocation?.requestPermission();
    });
  }

  @override
  Widget build(BuildContext context) {
    final connector = context.watch<MeshCoreConnector>();
    final sos = context.watch<SosService>();
    final l10n = context.l10n;
    if (!checkConnectionAndNavigate(connector)) {
      return const Scaffold(body: SizedBox.shrink());
    }
    final active = sos.active;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.sos_title),
        centerTitle: true,
        automaticallyImplyLeading: !widget.hideBackButton,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 24),
        children: [
          if (active == null)
            _SosHoldButton(onActivated: sos.activate)
          else
            _ActiveSosCard(sos: active, service: sos),
          SectionHeader(l10n.sos_incomingHeader),
          if (sos.incoming.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(l10n.sos_incomingEmpty),
            )
          else
            for (final alert in sos.incoming)
              _IncomingSosCard(alert: alert, service: sos),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: QuickSwitchBar(
          selectedIndex: 3,
          onDestinationSelected: (index) => _handleQuickSwitch(index, context),
          contactsUnreadCount: connector.getTotalContactsUnreadCount(),
          channelsUnreadCount: connector.getTotalChannelsUnreadCount(),
        ),
      ),
    );
  }

  void _handleQuickSwitch(int index, BuildContext context) {
    if (index == 3) return;
    switch (index) {
      case 0:
        Navigator.pushReplacement(
          context,
          buildQuickSwitchRoute(const ContactsScreen(hideBackButton: true)),
        );
        break;
      case 1:
        Navigator.pushReplacement(
          context,
          buildQuickSwitchRoute(const ChannelsScreen(hideBackButton: true)),
        );
        break;
      case 2:
        Navigator.pushReplacement(
          context,
          buildQuickSwitchRoute(const MapScreen(hideBackButton: true)),
        );
        break;
    }
  }
}

/// A large red button that must be held for two seconds, so a pocket or a
/// stray tap cannot raise an alarm across the mesh.
class _SosHoldButton extends StatefulWidget {
  final Future<void> Function() onActivated;

  const _SosHoldButton({required this.onActivated});

  @override
  State<_SosHoldButton> createState() => _SosHoldButtonState();
}

class _SosHoldButtonState extends State<_SosHoldButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _hold = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  )..addStatusListener(_onHoldStatus);

  void _onHoldStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    HapticFeedback.heavyImpact();
    _hold.reset();
    widget.onActivated();
  }

  @override
  void dispose() {
    _hold.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Column(
        children: [
          // Screen readers cannot time a two-second hold; their long-press
          // gesture (double-tap and hold) activates directly instead.
          Semantics(
            button: true,
            label: l10n.sos_holdToSend,
            onLongPress: widget.onActivated,
            excludeSemantics: true,
            child: GestureDetector(
              onTapDown: (_) => _hold.forward(),
              onTapUp: (_) => _hold.reverse(),
              onTapCancel: _hold.reverse,
              child: SizedBox.square(
                dimension: 220,
                child: AnimatedBuilder(
                  animation: _hold,
                  builder: (context, _) => Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox.expand(
                        child: CircularProgressIndicator(
                          value: _hold.value,
                          strokeWidth: 10,
                          color: scheme.onSurface,
                          backgroundColor: Colors.transparent,
                        ),
                      ),
                      Container(
                        width: 196,
                        height: 196,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: Colors.red.shade700,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.red.withValues(alpha: 0.4),
                              blurRadius: 24,
                            ),
                          ],
                        ),
                        child: Text(
                          l10n.sos_buttonLabel,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 64,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            l10n.sos_holdToSend,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ],
      ),
    );
  }
}

class _ActiveSosCard extends StatelessWidget {
  final OutgoingSos sos;
  final SosService service;

  const _ActiveSosCard({required this.sos, required this.service});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final textTheme = Theme.of(context).textTheme;
    final lastBroadcast = sos.lastBroadcastAt;
    final nextBroadcast = service.nextBroadcastAt;
    final fix = sos.lastFix;
    final contacts = service.emergencyContacts;
    const onRed = TextStyle(color: Colors.white);

    return Card(
      color: Colors.red.shade700,
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: DefaultTextStyle.merge(
          style: onRed,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.sos, color: Colors.white, size: 32),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '${l10n.sos_active}  #${sos.id}',
                      style: textTheme.titleLarge
                          ?.merge(onRed)
                          .copyWith(fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                lastBroadcast == null
                    ? l10n.sos_notSentYet
                    : l10n.sos_broadcastCount(
                        sos.broadcastCount,
                        _time(context, lastBroadcast),
                      ),
              ),
              if (lastBroadcast != null && nextBroadcast != null)
                Text(l10n.sos_nextBroadcast(_time(context, nextBroadcast))),
              const SizedBox(height: 4),
              Text(l10n.sos_locationSource(sosSourceLabel(l10n, fix.source))),
              if (fix.hasPosition) Text(sosCoordinates(fix)),
              const SizedBox(height: 12),
              Text(
                sos.acks.isEmpty ? l10n.sos_acksNone : l10n.sos_acksHeader,
                style: textTheme.titleSmall?.merge(onRed),
              ),
              for (final ack in sos.acks)
                Text(
                  '• ${ack.senderName.isEmpty ? l10n.sos_unknownSender : ack.senderName}'
                  '  ${_time(context, ack.receivedAt)}',
                ),
              if (contacts.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  l10n.sos_dmHeader,
                  style: textTheme.titleSmall?.merge(onRed),
                ),
                for (final contact in contacts)
                  Text('• ${contact.name}  ${_dmStatus(l10n, contact)}'),
              ],
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white),
                  ),
                  icon: const Icon(Icons.close),
                  label: Text(l10n.sos_cancel),
                  onPressed: () => _confirmCancel(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _dmStatus(AppLocalizations l10n, Contact contact) {
    final key = contact.publicKeyHex;
    if (sos.acks.any(
      (ack) => ack.senderKeyHex == key || ack.senderName == contact.name,
    )) {
      return l10n.sos_contactAcked;
    }
    if (sos.deliveredContactKeys.contains(key)) {
      return l10n.sos_contactDelivered;
    }
    return l10n.sos_contactWaiting;
  }

  Future<void> _confirmCancel(BuildContext context) async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.sos_cancelConfirmTitle),
        content: Text(l10n.sos_cancelConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.sos_keepActive),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.sos_cancel),
          ),
        ],
      ),
    );
    if (confirmed == true) await service.cancel();
  }
}

class _IncomingSosCard extends StatelessWidget {
  final IncomingSos alert;
  final SosService service;

  const _IncomingSosCard({required this.alert, required this.service});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final fix = alert.fix;
    final open = alert.isOpen;
    final others = alert.ackedBy.join(', ');
    final emphasis = open ? Colors.red.shade900 : null;

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      color: open ? Colors.red.shade50 : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: open ? Colors.red.shade700 : scheme.outlineVariant,
          width: open ? 3 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: DefaultTextStyle.merge(
          style: open ? const TextStyle(color: Colors.black87) : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.sos, color: Colors.red.shade700, size: 28),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      alert.senderName.isEmpty
                          ? l10n.sos_unknownSender
                          : alert.senderName,
                      style: textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: emphasis,
                      ),
                    ),
                  ),
                  Text('#${alert.id}'),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                fix.hasPosition ? sosCoordinates(fix) : l10n.sos_noPosition,
                style: textTheme.titleMedium?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: open ? Colors.black87 : null,
                ),
              ),
              Text(l10n.sos_locationSource(sosSourceLabel(l10n, fix.source))),
              Text(
                l10n.sos_heardSummary(
                  _time(context, alert.firstSeen),
                  _time(context, alert.lastSeen),
                  alert.receivedCount,
                ),
              ),
              if (others.isNotEmpty) Text(l10n.sos_ackedByOthers(others)),
              if (!open)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    alert.ackSent ? l10n.sos_ackSent : l10n.sos_dismissed,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  if (!alert.ackSent)
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.red.shade700,
                        foregroundColor: Colors.white,
                      ),
                      icon: const Icon(Icons.check),
                      label: Text(l10n.sos_sendAck),
                      onPressed: service.isConnected
                          ? () => service.acknowledge(alert)
                          : null,
                    ),
                  if (open)
                    OutlinedButton(
                      onPressed: () => service.dismiss(alert),
                      child: Text(l10n.sos_dismiss),
                    ),
                  if (fix.hasPosition) ...[
                    OutlinedButton.icon(
                      icon: const Icon(Icons.map_outlined),
                      label: Text(l10n.nav_map),
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => MapScreen(
                            highlightPosition: LatLng(
                              fix.latitude!,
                              fix.longitude!,
                            ),
                            highlightLabel: alert.senderName,
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: l10n.sos_copyCoordinates,
                      icon: const Icon(Icons.copy),
                      onPressed: () async {
                        await Clipboard.setData(
                          ClipboardData(text: sosCoordinates(fix)),
                        );
                        if (!context.mounted) return;
                        showDismissibleSnackBar(
                          context,
                          content: Text(l10n.sos_coordinatesCopied),
                        );
                      },
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
