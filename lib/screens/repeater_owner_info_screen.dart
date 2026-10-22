import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../helpers/repeater_owner_info.dart';
import '../helpers/snack_bar_builder.dart';
import '../helpers/sos_network_code.dart';
import '../l10n/l10n.dart';
import '../models/contact.dart';
import '../models/path_selection.dart';
import '../services/sos_service.dart';
import '../theme/mesh_theme.dart';
import '../widgets/empty_state.dart';
import '../widgets/mesh_ui.dart';
import 'sos_network_screen.dart';

/// The operator's public notes for a repeater, readable with a guest login.
///
/// An emergency network code in the notes, such as the member code for the
/// area, is offered for joining.
class RepeaterOwnerInfoScreen extends StatefulWidget {
  final Contact repeater;

  const RepeaterOwnerInfoScreen({super.key, required this.repeater});

  @override
  State<RepeaterOwnerInfoScreen> createState() =>
      _RepeaterOwnerInfoScreenState();
}

class _RepeaterOwnerInfoScreenState extends State<RepeaterOwnerInfoScreen> {
  Uint8List _tagData = Uint8List(4);
  bool _awaitingSent = false;
  bool _isLoading = false;
  bool _timedOut = false;
  RepeaterOwnerInfo? _info;
  Timer? _timeout;
  StreamSubscription<Uint8List>? _frameSubscription;
  PathSelection? _pendingSelection;

  Contact _resolveRepeater(MeshCoreConnector connector) =>
      connector.contacts
          .where((c) => c.publicKeyHex == widget.repeater.publicKeyHex)
          .firstOrNull ??
      widget.repeater;

  @override
  void initState() {
    super.initState();
    final connector = context.read<MeshCoreConnector>();
    _frameSubscription = connector.receivedFrames.listen((frame) {
      if (frame.isEmpty) return;
      if (frame[0] == respCodeSent && _awaitingSent && frame.length >= 6) {
        _awaitingSent = false;
        _tagData = frame.sublist(2, 6);
      }
      if (frame[0] == pushCodeBinaryResponse &&
          frame.length >= 6 &&
          listEquals(frame.sublist(2, 6), _tagData)) {
        _handleResponse(frame.sublist(6));
      }
    });
    _load();
  }

  void _handleResponse(Uint8List data) {
    final info = RepeaterOwnerInfo.parse(data);
    if (info == null || !mounted) return;
    _tagData = Uint8List(4);
    _timeout?.cancel();
    _recordResult(true);
    setState(() {
      _info = info;
      _isLoading = false;
      _timedOut = false;
    });
  }

  Future<void> _load() async {
    final connector = context.read<MeshCoreConnector>();
    setState(() {
      _isLoading = true;
      _timedOut = false;
    });
    try {
      final repeater = _resolveRepeater(connector);
      final selection = await connector.preparePathForContactSend(repeater);
      _pendingSelection = selection;
      final frame = buildSendBinaryReq(
        repeater.publicKey,
        payload: Uint8List.fromList([reqTypeGetOwnerInfo]),
      );
      _awaitingSent = true;
      await connector.sendFrame(frame);
      // The reply carries up to 120 bytes of text plus version and name.
      final timeoutMs = connector.calculateTimeout(
        pathLength: selection.useFlood ? -1 : selection.hopCount,
        messageBytes: 180,
      );
      _timeout?.cancel();
      _timeout = Timer(Duration(milliseconds: timeoutMs), () {
        if (!mounted) return;
        setState(() {
          _isLoading = false;
          _timedOut = true;
        });
        _recordResult(false);
      });
    } catch (e) {
      _awaitingSent = false;
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _timedOut = true;
      });
    }
  }

  void _recordResult(bool success) {
    final selection = _pendingSelection;
    if (selection == null) return;
    final connector = context.read<MeshCoreConnector>();
    connector.recordRepeaterPathResult(
      _resolveRepeater(connector),
      selection,
      success,
      null,
    );
    _pendingSelection = null;
  }

  @override
  void dispose() {
    _frameSubscription?.cancel();
    _timeout?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final connector = context.watch<MeshCoreConnector>();
    final repeater = _resolveRepeater(connector);
    final info = _info;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l10n.repeater_ownerInfo,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              repeater.name,
              style: const TextStyle(fontSize: 14),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: _isLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            onPressed: _isLoading ? null : _load,
            tooltip: l10n.repeater_refreshOwnerInfo,
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              if (info == null && _isLoading)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 64),
                  child: Column(
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 16),
                      Text(
                        l10n.common_loading,
                        style: const TextStyle(fontSize: 16),
                      ),
                    ],
                  ),
                )
              else if (info == null && _timedOut)
                EmptyState(
                  icon: Icons.portable_wifi_off,
                  title: l10n.ownerInfo_timedOut,
                )
              else if (info != null)
                ..._buildInfo(info),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildInfo(RepeaterOwnerInfo info) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final codes = SosNetworkCode.findIn(info.ownerInfo);
    return [
      for (final code in codes) _SosCodeCard(code: code),
      SectionHeader(
        l10n.repeater_ownerInfo,
        padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
      ),
      MeshCard(
        margin: EdgeInsets.zero,
        child: info.ownerInfo.isEmpty
            ? Text(
                l10n.ownerInfo_empty,
                style: TextStyle(color: scheme.onSurfaceVariant),
              )
            : SelectableText(
                info.ownerInfo,
                style: const TextStyle(fontSize: 16, height: 1.4),
              ),
      ),
      if (info.firmwareVersion.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
          child: Text(
            l10n.ownerInfo_firmware(info.firmwareVersion),
            style: MeshTheme.mono(fontSize: 13, color: scheme.onSurfaceVariant),
          ),
        ),
    ];
  }
}

class _SosCodeCard extends StatelessWidget {
  final SosNetworkCode code;

  const _SosCodeCard({required this.code});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final joined = listEquals(
      context.watch<SosService>().network?.key,
      code.key,
    );
    return MeshCard(
      margin: const EdgeInsets.only(top: 8),
      borderColor: MeshPalette.alert,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.sos, color: MeshPalette.alert),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  l10n.ownerInfo_sosCodeTitle,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              StatusChip(
                label: sosRoleLabel(l10n, code.role),
                color: MeshPalette.alert,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(l10n.ownerInfo_sosCodeBody),
          const SizedBox(height: 10),
          SelectableText(
            code.text,
            style: MeshTheme.mono(fontSize: 15, color: scheme.onSurface),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: joined
                    ? FilledButton.tonalIcon(
                        icon: const Icon(Icons.check),
                        label: Text(l10n.ownerInfo_sosJoined),
                        onPressed: null,
                      )
                    : FilledButton.icon(
                        icon: const Icon(Icons.group_add),
                        label: Text(l10n.sos_networkJoinAction),
                        onPressed: () => confirmJoinSosNetwork(context, code),
                      ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.copy),
                tooltip: l10n.common_copy,
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
        ],
      ),
    );
  }
}
