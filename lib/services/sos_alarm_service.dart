import 'package:flutter/services.dart';

import '../utils/app_logger.dart';
import '../utils/platform_info.dart';

/// Android: the incoming SOS alarm, played by the app (SosAlarmFunctions does
/// the native side) so that it sounds through silent mode, other apps' audio
/// and, with access, Do Not Disturb. One alarm for every open alert: it starts
/// with the first and stops with the last. Elsewhere the calls do nothing.
class SosAlarmService {
  static const MethodChannel _channel = MethodChannel(
    'meshcore_open/sos_alarm',
  );
  static final Set<int> _alerts = {};

  /// Starts the alarm for alert [id]. False when it couldn't play, so the
  /// notification has to make the sound instead.
  static Future<bool> start(int id, {required bool classic}) async {
    if (!PlatformInfo.isAndroid) return false;
    try {
      final playing =
          await _channel.invokeMethod<bool>('start', {
            'sound': classic ? 'sos_alarm_classic' : 'sos_alarm_morse',
          }) ??
          false;
      if (playing) _alerts.add(id);
      return playing;
    } catch (e) {
      appLogger.warn('SOS alarm failed to start: $e', tag: 'SOS');
      return false;
    }
  }

  /// Alert [id] is dealt with: the alarm stops once no alert is left.
  static Future<void> stop(int id) async {
    if (!PlatformInfo.isAndroid) return;
    _alerts.remove(id);
    if (_alerts.isNotEmpty) return;
    try {
      await _channel.invokeMethod<bool>('stop');
    } catch (e) {
      appLogger.warn('SOS alarm failed to stop: $e', tag: 'SOS');
    }
  }

  /// Whether the app may sound an SOS through Do Not Disturb. Null off Android.
  static Future<bool?> hasDndAccess() async {
    if (!PlatformInfo.isAndroid) return null;
    try {
      return await _channel.invokeMethod<bool>('hasDndAccess');
    } catch (e) {
      appLogger.warn('Do Not Disturb access check failed: $e', tag: 'SOS');
      return null;
    }
  }

  /// Opens Android's Do Not Disturb access page.
  static Future<void> openDndSetting() async {
    try {
      await _channel.invokeMethod<bool>('openDndSetting');
    } catch (e) {
      appLogger.warn('Opening Do Not Disturb access failed: $e', tag: 'SOS');
    }
  }
}
