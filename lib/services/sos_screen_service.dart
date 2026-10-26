import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../utils/app_logger.dart';
import '../utils/platform_info.dart';

/// What lets an incoming SOS fill the screen on Android.
enum SosScreenAccess {
  /// Locked or not: the alert opens over the lock screen, and the app opens
  /// itself when the phone is in use.
  full,

  /// Only while the phone is locked: "Display over other apps" is off.
  lockedOnly,

  /// Never: only a notification (Android 14+ took full-screen alerts away).
  none,
}

/// Android: puts an incoming SOS on the screen when the app isn't open
/// (MainActivity and SosScreenFunctions do the native side). Elsewhere the
/// calls do nothing.
class SosScreenService {
  static const MethodChannel _channel = MethodChannel(
    'meshcore_open/sos_screen',
  );

  static Future<SosScreenAccess?> access() async {
    if (!PlatformInfo.isAndroid) return null;
    try {
      final fullScreen =
          await _channel.invokeMethod<bool>('canUseFullScreen') ?? false;
      final overApps =
          await _channel.invokeMethod<bool>('canShowOverApps') ?? false;
      if (!fullScreen) return SosScreenAccess.none;
      return overApps ? SosScreenAccess.full : SosScreenAccess.lockedOnly;
    } catch (e) {
      appLogger.warn('SOS screen access check failed: $e', tag: 'SOS');
      return null;
    }
  }

  /// Opens the system page for the permission that is still missing.
  static Future<void> openSetting(SosScreenAccess access) async {
    try {
      await _channel.invokeMethod<bool>(
        access == SosScreenAccess.none
            ? 'openFullScreenSetting'
            : 'openShowOverAppsSetting',
      );
    } catch (e) {
      appLogger.warn('Opening the SOS screen setting failed: $e', tag: 'SOS');
    }
  }

  /// Brings the app to the front on the alert when it isn't on screen.
  /// The notification's full-screen alert covers the locked phone; this
  /// covers the phone in use, where Android only shows a banner.
  static Future<void> showAlert(String payload) async {
    if (!PlatformInfo.isAndroid) return;
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      return; // already on screen: the app shows the alert itself
    }
    try {
      final opened =
          await _channel.invokeMethod<bool>('showSosAlert', {
            'payload': payload,
          }) ??
          false;
      if (!opened) {
        appLogger.info(
          'SOS alert left as a notification: "Display over other apps" is off',
          tag: 'SOS',
        );
      }
    } catch (e) {
      appLogger.warn('Opening the SOS alert failed: $e', tag: 'SOS');
    }
  }
}
