import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../services/sos_screen_service.dart';

/// Android: whether an incoming SOS fills the screen, and a tap to open the
/// system page that allows it. Checked again whenever the app comes back,
/// as the person returns from that page. With [onlyWhenMissing] it shows
/// nothing once everything is allowed (the Emergency tab's warning card).
class SosScreenAccessTile extends StatefulWidget {
  final bool onlyWhenMissing;

  const SosScreenAccessTile({super.key, this.onlyWhenMissing = false});

  @override
  State<SosScreenAccessTile> createState() => _SosScreenAccessTileState();
}

class _SosScreenAccessTileState extends State<SosScreenAccessTile>
    with WidgetsBindingObserver {
  SosScreenAccess? _access;

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
    final access = await SosScreenService.access();
    if (mounted) setState(() => _access = access);
  }

  @override
  Widget build(BuildContext context) {
    final access = _access;
    if (access == null) return const SizedBox.shrink();
    if (widget.onlyWhenMissing && access == SosScreenAccess.full) {
      return const SizedBox.shrink();
    }
    final l10n = context.l10n;
    final missing = access != SosScreenAccess.full;
    final subtitle = switch (access) {
      SosScreenAccess.full => l10n.sos_fullScreenOn,
      SosScreenAccess.lockedOnly => l10n.sos_fullScreenLockedOnly,
      SosScreenAccess.none => l10n.sos_fullScreenOff,
    };
    final tile = ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Icon(
        missing ? Icons.warning_amber_rounded : Icons.fullscreen,
        size: 24,
        color: missing ? Colors.red.shade700 : null,
      ),
      title: Text(l10n.sos_fullScreen),
      // Samsung especially: the system pages can hide a newly installed app, or not keep a
      // setting, until the phone has restarted
      subtitle: Text(
        missing ? '$subtitle\n${l10n.sos_fullScreenRestartTip}' : subtitle,
      ),
      trailing: missing ? Text(l10n.sos_fullScreenAllow) : null,
      onTap: missing ? () => SosScreenService.openSetting(access) : null,
    );
    if (!widget.onlyWhenMissing) return tile;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      color: Colors.red.shade50,
      child: tile,
    );
  }
}
