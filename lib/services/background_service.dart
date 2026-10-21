import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../l10n/app_localizations.dart';
import '../storage/prefs_manager.dart';
import '../utils/platform_info.dart';

/// Keeps the app running on Android for as long as it is open, connected or
/// not, until the user taps Stop on its notification (or force-stops it).
class BackgroundService {
  static const String _stopButtonId = 'stop';
  static const String _stopMessage = 'stop';
  static const String _batteryPromptedKey = 'background_battery_prompted';

  bool _initialized = false;
  String? Function()? _languageOverrideProvider;

  /// Runs when the user taps Stop on the service notification.
  Future<void> Function()? onStopRequested;

  /// Allows the app to expose its current language override (e.g. from
  /// AppSettingsService) so the foreground notification matches the app UI
  /// language instead of only the system locale.
  void setLanguageOverrideProvider(String? Function()? provider) {
    _languageOverrideProvider = provider;
  }

  Future<void> initialize() async {
    if (!PlatformInfo.isAndroid || _initialized) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'meshcore_background',
        channelName: 'MeshCore Background',
        channelDescription: 'Keeps MeshCore running in the background.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(5000),
        autoRunOnBoot: false,
        allowWifiLock: false,
      ),
    );
    FlutterForegroundTask.initCommunicationPort();
    FlutterForegroundTask.addTaskDataCallback(_onTaskData);
    _initialized = true;
  }

  void _onTaskData(Object data) {
    if (data == _stopMessage) onStopRequested?.call();
  }

  Future<void> start() async {
    if (!PlatformInfo.isAndroid) return;
    if (!_initialized) {
      await initialize();
    }
    final running = await FlutterForegroundTask.isRunningService;
    if (running) return;
    final l10n = await _loadLocalizations();
    await FlutterForegroundTask.startService(
      notificationTitle: l10n.background_serviceTitle,
      notificationText: l10n.background_serviceRunningText,
      notificationButtons: [
        NotificationButton(id: _stopButtonId, text: l10n.background_stop),
      ],
      callback: startCallback,
    );
  }

  /// Asks once to be exempt from battery optimisation, which otherwise lets
  /// Android (and some phone makers far sooner) stop the app in the
  /// background. The app settings keep a shortcut for later.
  Future<void> requestBatteryExemptionOnce() async {
    if (!PlatformInfo.isAndroid) return;
    final prefs = PrefsManager.instance;
    if (prefs.getBool(_batteryPromptedKey) ?? false) return;
    if (await FlutterForegroundTask.isIgnoringBatteryOptimizations) return;
    await prefs.setBool(_batteryPromptedKey, true);
    await FlutterForegroundTask.requestIgnoreBatteryOptimization();
  }

  Future<AppLocalizations> _loadLocalizations() async {
    final supported = AppLocalizations.supportedLocales;
    final override = _languageOverrideProvider?.call();
    if (override != null && override.isNotEmpty) {
      final overrideLocale = Locale(override);
      final isSupported = supported.any(
        (l) => l.languageCode == overrideLocale.languageCode,
      );
      if (isSupported) {
        return AppLocalizations.delegate.load(overrideLocale);
      }
    }
    final preferred = WidgetsBinding.instance.platformDispatcher.locales;
    final match = basicLocaleListResolution(preferred, supported);
    return AppLocalizations.delegate.load(match);
  }

  static Future<void> openBatteryOptimizationSettings() async {
    if (!PlatformInfo.isAndroid) return;
    await FlutterForegroundTask.openIgnoreBatteryOptimizationSettings();
  }

  Future<void> stop() async {
    if (!PlatformInfo.isAndroid) return;
    final running = await FlutterForegroundTask.isRunningService;
    if (!running) return;
    await FlutterForegroundTask.stopService();
  }
}

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(_MeshCoreTaskHandler());
}

class _MeshCoreTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  @override
  void onNotificationButtonPressed(String id) {
    if (id != BackgroundService._stopButtonId) return;
    // The app disconnects and exits; stop here too in case it is gone.
    FlutterForegroundTask.sendDataToMain(BackgroundService._stopMessage);
    FlutterForegroundTask.stopService();
  }

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp('/');
  }
}
