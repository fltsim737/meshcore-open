import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../helpers/snack_bar_builder.dart';
import '../helpers/sos_network_code.dart';
import '../l10n/app_localizations.dart';
import '../l10n/l10n.dart';
import '../services/sos_service.dart';
import '../widgets/mesh_ui.dart';
import '../widgets/qr_code_display.dart';
import '../widgets/qr_scanner_widget.dart';

String sosRoleLabel(AppLocalizations l10n, SosNetworkRole role) =>
    switch (role) {
      SosNetworkRole.member => l10n.sos_roleMember,
      SosNetworkRole.responder => l10n.sos_roleResponder,
    };

String sosNetworkStatusLabel(AppLocalizations l10n, SosNetworkStatus status) =>
    switch (status) {
      SosNetworkStatus.none => l10n.sos_networkNoneSubtitle,
      SosNetworkStatus.disconnected => l10n.sos_networkStatusDisconnected,
      SosNetworkStatus.needsFirmware => l10n.sos_channelNeedsFirmware,
      SosNetworkStatus.installing => l10n.sos_networkStatusInstalling,
      SosNetworkStatus.noFreeSlot => l10n.sos_networkStatusNoFreeSlot,
      SosNetworkStatus.ready => l10n.sos_networkStatusReady,
    };

/// Set up, join, share or leave the emergency network.
class SosNetworkScreen extends StatelessWidget {
  const SosNetworkScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final sos = context.watch<SosService>();
    final network = sos.network;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.sos_network), centerTitle: true),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(0, 8, 0, 24),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text(l10n.sos_networkIntro),
            ),
            if (network == null)
              _NotJoined(sos: sos)
            else
              _Joined(sos: sos, network: network),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Text(
                l10n.sos_networkSecurityNote,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NotJoined extends StatelessWidget {
  final SosService sos;

  const _NotJoined({required this.sos});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton.icon(
            icon: const Icon(Icons.add),
            label: Text(l10n.sos_networkCreate),
            onPressed: () => _create(context),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            icon: const Icon(Icons.vpn_key_outlined),
            label: Text(l10n.sos_networkJoin),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SosNetworkJoinScreen()),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _create(BuildContext context) async {
    final l10n = context.l10n;
    final controller = TextEditingController(text: SosNetworkCode.defaultName);
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.sos_networkCreate),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 31,
          decoration: InputDecoration(labelText: l10n.sos_networkNameLabel),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: Text(l10n.sos_networkCreateAction),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null) return;
    await sos.createNetwork(name);
  }
}

class _Joined extends StatelessWidget {
  final SosService sos;
  final SosNetworkCode network;

  const _Joined({required this.sos, required this.network});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MeshCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(network.name, style: textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(l10n.sos_networkRoleLabel(sosRoleLabel(l10n, network.role))),
              const SizedBox(height: 4),
              Text(sosNetworkStatusLabel(l10n, sos.networkStatus)),
            ],
          ),
        ),
        if (sos.isCoordinator) ...[
          SectionHeader(l10n.sos_networkCodesTitle),
          _CodeCard(
            title: l10n.sos_networkMemberCode,
            help: l10n.sos_networkMemberCodeHelp,
            code: network.withRole(SosNetworkRole.member),
          ),
          _CodeCard(
            title: l10n.sos_networkResponderCode,
            help: l10n.sos_networkResponderCodeHelp,
            code: network.withRole(SosNetworkRole.responder),
          ),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            icon: const Icon(Icons.logout),
            label: Text(l10n.sos_networkLeave),
            onPressed: () => _leave(context),
          ),
        ),
      ],
    );
  }

  Future<void> _leave(BuildContext context) async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.sos_networkLeave),
        content: Text(l10n.sos_networkLeaveConfirm(network.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.sos_networkLeave),
          ),
        ],
      ),
    );
    if (confirmed == true) await sos.leaveNetwork();
  }
}

class _CodeCard extends StatelessWidget {
  final String title;
  final String help;
  final SosNetworkCode code;

  const _CodeCard({
    required this.title,
    required this.help,
    required this.code,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final textTheme = Theme.of(context).textTheme;
    return MeshCard(
      child: Column(
        children: [
          Text(title, style: textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(help, textAlign: TextAlign.center, style: textTheme.bodySmall),
          QrCodeDisplay(data: code.qrData, size: 200),
          SelectableText(
            code.text,
            textAlign: TextAlign.center,
            style: textTheme.titleSmall?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
              letterSpacing: 1,
            ),
          ),
          TextButton.icon(
            icon: const Icon(Icons.copy),
            label: Text(l10n.sos_copyCode),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: code.text));
              if (!context.mounted) return;
              showDismissibleSnackBar(
                context,
                content: Text(l10n.sos_networkCodeCopied),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// Type or scan a network code, confirm the network and role, then join.
class SosNetworkJoinScreen extends StatefulWidget {
  const SosNetworkJoinScreen({super.key});

  @override
  State<SosNetworkJoinScreen> createState() => _SosNetworkJoinScreenState();
}

class _SosNetworkJoinScreenState extends State<SosNetworkJoinScreen> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final data = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const _SosNetworkScanScreen()),
    );
    if (data == null || !mounted) return;
    await _join(data);
  }

  Future<void> _join(String input) async {
    final l10n = context.l10n;
    final code = SosNetworkCode.parse(input);
    if (code == null) {
      setState(() => _error = l10n.sos_networkInvalidCode);
      return;
    }
    setState(() => _error = null);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.sos_networkJoin),
        content: Text(
          l10n.sos_networkJoinConfirm(code.name, sosRoleLabel(l10n, code.role)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.sos_networkJoinAction),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await context.read<SosService>().joinNetwork(code);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.sos_networkJoin), centerTitle: true),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            FilledButton.icon(
              icon: const Icon(Icons.qr_code_scanner),
              label: Text(l10n.sos_networkScan),
              onPressed: _scan,
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _controller,
              textCapitalization: TextCapitalization.characters,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: l10n.sos_networkCodeLabel,
                hintText: 'SOS1-R-XXXX-XXXX-…',
                errorText: _error,
              ),
              onSubmitted: _join,
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () => _join(_controller.text),
              child: Text(l10n.sos_networkJoinAction),
            ),
          ],
        ),
      ),
    );
  }
}

class _SosNetworkScanScreen extends StatelessWidget {
  const _SosNetworkScanScreen();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.sos_networkScan), centerTitle: true),
      body: QrScannerWidget(
        onScanned: (data) => Navigator.pop(context, data),
        validator: (data) => SosNetworkCode.parse(data) != null,
        onValidationFailed: (_) => showDismissibleSnackBar(
          context,
          content: Text(l10n.sos_networkInvalidCode),
        ),
        instructions: l10n.sos_networkScanInstructions,
        themed: true,
      ),
    );
  }
}
