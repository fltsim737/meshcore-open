import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../services/sos_alarm_service.dart';

/// Android: whether an incoming SOS sounds through Do Not Disturb, and a tap
/// to open the system page that allows it. Checked again whenever the app
/// comes back, as the person returns from that page. With [onlyWhenMissing]
/// it shows nothing once allowed (the Emergency tab's warning card).
class SosDndAccessTile extends StatefulWidget {
  final bool onlyWhenMissing;

  const SosDndAccessTile({super.key, this.onlyWhenMissing = false});

  @override
  State<SosDndAccessTile> createState() => _SosDndAccessTileState();
}

class _SosDndAccessTileState extends State<SosDndAccessTile>
    with WidgetsBindingObserver {
  bool? _allowed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    final allowed = await SosAlarmService.hasDndAccess();
    if (mounted) setState(() => _allowed = allowed);
  }

  @override
  Widget build(BuildContext context) {
    final allowed = _allowed;
    if (allowed == null) return const SizedBox.shrink();
    if (widget.onlyWhenMissing && allowed) return const SizedBox.shrink();
    final l10n = context.l10n;
    final tile = ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Icon(
        allowed ? Icons.do_not_disturb_off : Icons.warning_amber_rounded,
        size: 24,
        color: allowed ? null : Colors.red.shade700,
      ),
      title: Text(l10n.sos_dndAccess),
      subtitle: Text(allowed ? l10n.sos_dndAccessOn : l10n.sos_dndAccessOff),
      trailing: allowed ? null : Text(l10n.sos_fullScreenAllow),
      onTap: allowed ? null : SosAlarmService.openDndSetting,
    );
    if (!widget.onlyWhenMissing) return tile;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      color: Colors.red.shade50,
      child: tile,
    );
  }
}
