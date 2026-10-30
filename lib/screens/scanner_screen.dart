import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../utils/platform_info.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../l10n/l10n.dart';
import '../services/app_settings_service.dart';
import '../services/linux_ble_error_classifier.dart';
import '../utils/usb_port_labels.dart';
import '../theme/mesh_theme.dart';
import '../utils/app_logger.dart';
import '../widgets/adaptive_app_bar_title.dart';
import '../widgets/device_tile.dart';
import '../widgets/empty_state.dart';
import '../widgets/get_node_banner.dart';
import '../widgets/mesh_ui.dart';
import '../helpers/snack_bar_builder.dart';
import '../review_mode/review_mode_entry.dart';
import 'channels_screen.dart';
import 'tcp_screen.dart';
import 'usb_screen.dart';
import 'setup_wizard_screen.dart';

/// Screen for scanning and connecting to MeshCore devices
class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key});

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
  // Connecting to the last radio by itself happens once per app start, not
  // each time this screen comes back after a disconnect.
  static bool _autoConnectTried = false;
  String? _autoConnectName; // shown while connecting to the last radio
  bool _autoConnectCancelled = false;
  bool _autoUsb = false; // USB from here: this screen moves on, not UsbScreen
  bool _changedNavigation = false;
  String? _connectingDeviceId;
  late final MeshCoreConnector _connector;
  late final VoidCallback _connectionListener;
  BluetoothAdapterState _bluetoothState = BluetoothAdapterState.unknown;
  late StreamSubscription<BluetoothAdapterState> _bluetoothStateSubscription;

  @override
  void initState() {
    super.initState();
    _connector = Provider.of<MeshCoreConnector>(context, listen: false);

    // A new install: the first-time setup, once.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) SetupWizardScreen.showIfFirstRun(context);
    });

    _connectionListener = () {
      // ModalRoute.of needs a live element, so bail out before touching it.
      if (!mounted) return;
      final isCurrentRoute = ModalRoute.of(context)?.isCurrent ?? true;
      if (_connector.state == MeshCoreConnectionState.disconnected) {
        _changedNavigation = false;
      } else if (_connector.state == MeshCoreConnectionState.connected &&
          // TCP lands here after an auto-reconnect: a dropped link popped
          // back to this screen, and the TCP screen is no longer on the stack.
          (_connector.activeTransport == MeshCoreTransportType.bluetooth ||
              _connector.activeTransport == MeshCoreTransportType.tcp ||
              (_autoUsb &&
                  _connector.activeTransport == MeshCoreTransportType.usb)) &&
          isCurrentRoute &&
          !_changedNavigation) {
        _changedNavigation = true;
        Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (context) => const ChannelsScreen()));
      }
    };

    _connector.addListener(_connectionListener);
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoConnect());

    _bluetoothStateSubscription = FlutterBluePlus.adapterState.listen(
      (state) {
        if (mounted) {
          setState(() {
            _bluetoothState = state;
          });
          // Cancel scan if Bluetooth turns off while scanning
          if (state != BluetoothAdapterState.on) {
            unawaited(_connector.stopScan());
          }
        }
      },
      onError: (Object e) {
        appLogger.warn('Adapter state stream error: $e', tag: 'ScannerScreen');
      },
    );
  }

  @override
  void dispose() {
    _connector.removeListener(_connectionListener);
    unawaited(_bluetoothStateSubscription.cancel());
    if (!_changedNavigation) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_connector.disconnect(manual: true));
      });
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canPop = Navigator.of(context).canPop();
    return Scaffold(
      appBar: AppBar(
        leading: canPop
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () {
                  appLogger.info('Back button pressed', tag: 'ScannerScreen');
                  Navigator.of(context).maybePop();
                },
              )
            : null,
        title: ReviewModeLongPress(
          child: AdaptiveAppBarTitle(context.l10n.scanner_title),
        ),
        centerTitle: true,
        automaticallyImplyLeading: false,
        actions: [
          if (PlatformInfo.supportsUsbSerial)
            IconButton(
              icon: const Icon(Icons.usb),
              tooltip: context.l10n.connectionChoiceUsbLabel,
              onPressed: () {
                appLogger.info(
                  'USB selected, opening UsbScreen',
                  tag: 'ScannerScreen',
                );
                Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const UsbScreen()));
              },
            ),
          if (!PlatformInfo.isWeb)
            IconButton(
              icon: const Icon(Icons.lan),
              tooltip: context.l10n.connectionChoiceTcpLabel,
              onPressed: () {
                Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const TcpScreen()));
              },
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Consumer<MeshCoreConnector>(
          builder: (context, connector, child) {
            return Column(
              children: [
                // Bluetooth off warning — slides in/out with AnimatedSize
                AnimatedSize(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeInOut,
                  child: _bluetoothState == BluetoothAdapterState.off
                      ? _BluetoothOffBanner(
                          onEnable: PlatformInfo.isAndroid
                              ? () => FlutterBluePlus.turnOn()
                              : null,
                        )
                      : const SizedBox.shrink(),
                ),

                // Connecting to the last radio by itself, with a way out
                if (_autoConnectName != null)
                  MaterialBanner(
                    leading: const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    content: Text(
                      context.l10n.scanner_autoConnecting(_autoConnectName!),
                    ),
                    actions: [
                      TextButton(
                        onPressed: _cancelAutoConnect,
                        child: Text(context.l10n.common_cancel),
                      ),
                    ],
                  ),

                // Connection status header
                _ConnectionStatusHeader(connector: connector),

                // Device list
                Expanded(child: _buildDeviceList(context, connector)),
              ],
            );
          },
        ),
      ),
      bottomNavigationBar: const GetNodeBanner(),
      floatingActionButton: Consumer<MeshCoreConnector>(
        builder: (context, connector, child) {
          final isScanning =
              connector.state == MeshCoreConnectionState.scanning;
          final isBluetoothOff = _bluetoothState == BluetoothAdapterState.off;

          return FloatingActionButton.extended(
            heroTag: 'scanner_ble_action',
            onPressed: isBluetoothOff
                ? null
                : () {
                    HapticFeedback.lightImpact();
                    _toggleScan(connector);
                  },
            icon: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              transitionBuilder: (child, anim) =>
                  ScaleTransition(scale: anim, child: child),
              child: isScanning
                  ? SizedBox(
                      key: const ValueKey('scanning'),
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Theme.of(context).colorScheme.onPrimary,
                      ),
                    )
                  : const Icon(
                      Icons.bluetooth_searching,
                      key: ValueKey('idle'),
                    ),
            ),
            label: Text(
              isScanning
                  ? context.l10n.scanner_stop
                  : context.l10n.scanner_scan,
            ),
          );
        },
      ),
    );
  }

  void _toggleScan(MeshCoreConnector connector) {
    if (PlatformInfo.isWeb) {
      // flutter_blue_plus has no web backend, so a BLE scan silently no-ops in
      // the browser. Tell the user instead of leaving them staring at a button.
      showDismissibleSnackBar(
        context,
        content: Text(context.l10n.scanner_bluetoothWebUnsupported),
      );
      return;
    }
    if (connector.state == MeshCoreConnectionState.scanning) {
      connector.stopScan();
    } else {
      unawaited(
        connector.startScan().catchError((e) {
          appLogger.warn('startScan error: $e', tag: 'ScannerScreen');
        }),
      );
    }
  }

  Widget _buildDeviceList(BuildContext context, MeshCoreConnector connector) {
    if (connector.scanResults.isEmpty) {
      final isBluetoothOff = _bluetoothState == BluetoothAdapterState.off;
      final isScanning = connector.state == MeshCoreConnectionState.scanning;
      return EmptyState(
        icon: isBluetoothOff ? Icons.bluetooth_disabled : Icons.bluetooth,
        title: isBluetoothOff
            ? context.l10n.scanner_bluetoothOff
            : isScanning
            ? context.l10n.scanner_searchingDevices
            : context.l10n.scanner_tapToScan,
        subtitle: isBluetoothOff
            ? context.l10n.scanner_bluetoothOffMessage
            : null,
        action: (isBluetoothOff || isScanning)
            ? null
            : FilledButton.icon(
                onPressed: () {
                  HapticFeedback.lightImpact();
                  _toggleScan(connector);
                },
                icon: const Icon(Icons.bluetooth_searching),
                label: Text(context.l10n.scanner_scan),
              ),
      );
    }

    final isConnecting = connector.state == MeshCoreConnectionState.connecting;
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 96),
      itemCount: connector.scanResults.length,
      itemBuilder: (context, index) {
        final result = connector.scanResults[index];
        final deviceId = result.device.remoteId.toString();
        return ListEntrance(
          index: index,
          child: DeviceTile(
            scanResult: result,
            isConnecting: isConnecting && _connectingDeviceId == deviceId,
            onTap: isConnecting
                ? null
                : () => _connectToDevice(context, connector, result),
          ),
        );
      },
    );
  }

  Future<void> _connectToDevice(
    BuildContext context,
    MeshCoreConnector connector,
    ScanResult result,
  ) async {
    final name = result.device.platformName.isNotEmpty
        ? result.device.platformName
        : result.advertisementData.advName;
    setState(() {
      _connectingDeviceId = result.device.remoteId.toString();
    });
    try {
      await connector.connect(
        result.device,
        displayName: name,
        linuxPairingPinProvider: PlatformInfo.isLinux
            ? () async {
                if (!context.mounted) return null;
                return _promptLinuxPairingPin(context, name);
              }
            : null,
      );
    } catch (e) {
      final errorText = e.toString();
      final suppressTransientLinuxConnectError =
          PlatformInfo.isLinux &&
          connector.isAutoReconnectScheduled &&
          isLinuxBleConnectFailureText(errorText);
      if (suppressTransientLinuxConnectError) {
        appLogger.info(
          'Suppressing transient Linux connect error while auto-reconnect is active: $e',
          tag: 'ScannerScreen',
        );
        return;
      }
      if (context.mounted) {
        showDismissibleSnackBar(
          context,
          content: Text(context.l10n.scanner_connectionFailed(e.toString())),
          backgroundColor: Theme.of(context).colorScheme.error,
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _connectingDeviceId = null;
        });
      }
    }
  }

  /// When the app starts, connect to the radio it was last connected to, the
  /// same way (Bluetooth, USB or network), unless turned off in App Settings.
  Future<void> _autoConnect() async {
    if (_autoConnectTried || !mounted) return;
    _autoConnectTried = true;
    if (!AppSettingsService.autoConnectOnLaunchSaved) return;
    final saved = MeshCoreConnector.savedConnection;
    if (saved == null ||
        _connector.state != MeshCoreConnectionState.disconnected) {
      return;
    }
    final type = saved['type'];
    final name = (saved['name'] as String?)?.trim();
    setState(() {
      _autoConnectName = (name == null || name.isEmpty)
          ? context.l10n.scanner_autoConnectLastRadio
          : name;
      _autoConnectCancelled = false;
    });
    appLogger.info('Connecting to the last radio ($type)', tag: 'AutoConnect');
    try {
      if (type == 'tcp' && saved['host'] is String && saved['port'] is int) {
        await _connector.connectTcp(
          host: saved['host'] as String,
          port: saved['port'] as int,
        );
      } else if (type == 'usb' &&
          saved['port'] is String &&
          PlatformInfo.supportsUsbSerial) {
        final want = saved['port'] as String;
        final ports = await _connector.listUsbPorts();
        final port = ports
            .map(normalizeUsbPortName)
            .where((p) => p == want)
            .firstOrNull;
        if (port != null && !_autoConnectCancelled) {
          _autoUsb = true;
          await _connector.connectUsb(portName: port);
        }
      } else if (type == 'ble' &&
          saved['id'] is String &&
          !PlatformInfo.isWeb &&
          _bluetoothState != BluetoothAdapterState.off) {
        await _autoConnectBle(saved['id'] as String);
      }
    } catch (e) {
      // Not there, or it failed: the list is still here to choose from.
      appLogger.info('Auto-connect failed: $e', tag: 'AutoConnect');
    } finally {
      if (mounted) setState(() => _autoConnectName = null);
    }
  }

  /// Scans for up to 15 s for the remembered radio, then connects as a tap
  /// on it would (so Linux can still ask for its pairing PIN).
  Future<void> _autoConnectBle(String id) async {
    unawaited(
      _connector
          .startScan(timeout: const Duration(seconds: 15))
          .catchError((Object _) {}),
    );
    final until = DateTime.now().add(const Duration(seconds: 15));
    while (mounted &&
        !_autoConnectCancelled &&
        DateTime.now().isBefore(until)) {
      final found = _connector.scanResults
          .where((r) => r.device.remoteId.toString() == id)
          .firstOrNull;
      if (found != null) {
        await _connector.stopScan();
        if (!mounted || _autoConnectCancelled) return;
        await _connectToDevice(context, _connector, found);
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }

  void _cancelAutoConnect() {
    setState(() {
      _autoConnectCancelled = true;
      _autoConnectName = null;
    });
    unawaited(_connector.stopScan());
    if (_connector.state == MeshCoreConnectionState.connecting) {
      unawaited(_connector.disconnect(manual: true));
    }
  }

  Future<String?> _promptLinuxPairingPin(
    BuildContext context,
    String deviceName,
  ) async {
    final l10n = context.l10n;
    var pinValue = '';
    var obscure = true;
    appLogger.info(
      'Showing Linux BLE pairing PIN prompt for $deviceName',
      tag: 'ScannerScreen',
    );
    final pin = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            return AlertDialog(
              title: Text(l10n.scanner_linuxPairingPinTitle),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.scanner_linuxPairingPinPrompt(deviceName)),
                    const SizedBox(height: 12),
                    TextField(
                      autofocus: true,
                      keyboardType: TextInputType.number,
                      textInputAction: TextInputAction.done,
                      obscureText: obscure,
                      enableSuggestions: false,
                      autocorrect: false,
                      onChanged: (value) {
                        pinValue = value.trim();
                      },
                      onSubmitted: (value) {
                        Navigator.of(dialogContext).pop(value.trim());
                      },
                      decoration: InputDecoration(
                        suffixIcon: IconButton(
                          onPressed: () {
                            setDialogState(() {
                              obscure = !obscure;
                            });
                          },
                          icon: Icon(
                            obscure ? Icons.visibility : Icons.visibility_off,
                          ),
                          tooltip: obscure
                              ? l10n.scanner_linuxPairingShowPin
                              : l10n.scanner_linuxPairingHidePin,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(null),
                  child: Text(l10n.common_cancel),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(pinValue),
                  child: Text(l10n.common_connect),
                ),
              ],
            );
          },
        );
      },
    );
    if (pin == null) {
      appLogger.info(
        'Linux BLE pairing PIN prompt cancelled for $deviceName',
        tag: 'ScannerScreen',
      );
      return null;
    }
    appLogger.info(
      'Linux BLE pairing PIN prompt completed for $deviceName',
      tag: 'ScannerScreen',
    );
    return pin;
  }
}

// ── Private sub-widgets ────────────────────────────────────────────────────

/// Bluetooth-off warning banner — styled as an alert MeshCard.
class _BluetoothOffBanner extends StatelessWidget {
  final VoidCallback? onEnable;

  const _BluetoothOffBanner({this.onEnable});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MeshCard(
      color: scheme.error.withValues(alpha: 0.08),
      borderColor: scheme.error.withValues(alpha: 0.35),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Icon(Icons.bluetooth_disabled, size: 20, color: scheme.error),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  context.l10n.scanner_bluetoothOff,
                  style: TextStyle(
                    color: scheme.error,
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  context.l10n.scanner_bluetoothOffMessage,
                  style: TextStyle(color: scheme.error, fontSize: 14),
                ),
              ],
            ),
          ),
          if (onEnable != null) ...[
            const SizedBox(width: 8),
            TextButton(
              onPressed: onEnable,
              child: Text(context.l10n.scanner_enableBluetooth),
            ),
          ],
        ],
      ),
    );
  }
}

/// Connection status header with AnimatedSwitcher between states.
class _ConnectionStatusHeader extends StatelessWidget {
  final MeshCoreConnector connector;

  const _ConnectionStatusHeader({required this.connector});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;

    final (String label, Color color, bool pulse) = switch (connector.state) {
      MeshCoreConnectionState.scanning => (
        l10n.scanner_scanning,
        MeshPalette.blue,
        true,
      ),
      MeshCoreConnectionState.connecting => (
        l10n.scanner_connecting,
        MeshPalette.warn,
        true,
      ),
      MeshCoreConnectionState.connected => (
        l10n.scanner_connectedTo(connector.deviceDisplayName),
        MeshPalette.signal,
        false,
      ),
      MeshCoreConnectionState.disconnecting => (
        l10n.scanner_disconnecting,
        MeshPalette.warn,
        true,
      ),
      MeshCoreConnectionState.disconnected => (
        l10n.scanner_notConnected,
        scheme.onSurfaceVariant,
        false,
      ),
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        child: Align(
          key: ValueKey(connector.state),
          alignment: Alignment.centerLeft,
          child: StatusChip(label: label, color: color, pulse: pulse),
        ),
      ),
    );
  }
}
