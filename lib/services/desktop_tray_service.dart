import 'dart:io' show exit;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../l10n/app_localizations.dart';
import '../utils/platform_info.dart';

/// Linux and Windows: a tray icon, and closing the window hides it there
/// instead of quitting, so the radio connection, messages and SOS alarms
/// carry on. Only Quit in the tray menu ends the app.
class DesktopTrayService with TrayListener, WindowListener {
  // Windows tray icons must be .ico.
  static String get _iconAsset => PlatformInfo.isWindows
      ? 'assets/icons/tray_icon.ico'
      : 'assets/icons/tray_icon.png';
  static const String _showKey = 'show';
  static const String _quitKey = 'quit';

  bool _enabled = false;
  Future<void> Function()? _onQuit;

  /// Sets up the window and tray. [onQuit] runs before the app exits.
  /// [startedHidden]: launched at login, so the window starts in the tray.
  Future<void> initialize({
    required Future<void> Function() onQuit,
    String? languageOverride,
    bool startedHidden = false,
  }) async {
    if (!PlatformInfo.isLinux && !PlatformInfo.isWindows) return;
    _onQuit = onQuit;
    try {
      await windowManager.ensureInitialized();
      await windowManager.setPreventClose(true);
      windowManager.addListener(this);

      final l10n = await _loadLocalizations(languageOverride);
      await trayManager.setIcon(_iconAsset);
      try {
        await trayManager.setToolTip(l10n.background_serviceRunningText);
      } on MissingPluginException {
        // Not every tray host supports tooltips (AppIndicator does not).
      }
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: _showKey, label: l10n.tray_show),
            MenuItem.separator(),
            MenuItem(key: _quitKey, label: l10n.tray_quit),
          ],
        ),
      );
      trayManager.addListener(this);
      _enabled = true;
    } catch (e) {
      // No tray host: closing the window quits as before.
      debugPrint('Tray icon unavailable: $e');
      await windowManager.setPreventClose(false);
      // Nowhere to open a hidden window from, so show it.
      if (startedHidden) await windowManager.show();
    }
  }

  /// Brings the window back, e.g. for an incoming SOS.
  Future<void> showWindow() async {
    if (!_enabled) return;
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _quit() async {
    try {
      await _onQuit?.call();
    } finally {
      await trayManager.destroy();
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
      exit(0);
    }
  }

  @override
  void onWindowClose() {
    if (_enabled) windowManager.hide();
  }

  @override
  void onTrayIconMouseDown() => showWindow();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case _showKey:
        showWindow();
      case _quitKey:
        _quit();
    }
  }

  Future<AppLocalizations> _loadLocalizations(String? override) {
    const supported = AppLocalizations.supportedLocales;
    if (override != null && override.isNotEmpty) {
      final locale = Locale(override);
      if (supported.any((l) => l.languageCode == locale.languageCode)) {
        return AppLocalizations.delegate.load(locale);
      }
    }
    final preferred = WidgetsBinding.instance.platformDispatcher.locales;
    return AppLocalizations.delegate.load(
      basicLocaleListResolution(preferred, supported),
    );
  }
}
