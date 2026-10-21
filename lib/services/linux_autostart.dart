import 'dart:io';

import 'login_autostart.dart';

/// Starts the app hidden in the tray when the user logs in, through a
/// freedesktop autostart entry (`~/.config/autostart`). The entry's presence
/// is the setting, so turning it off in the desktop's own startup settings
/// turns it off here too.
class LinuxAutostart implements LoginAutostart {
  static const String hiddenArgument = LoginAutostart.hiddenArgument;
  static const String _fileName = 'meshcore-open.desktop';

  final String _configHome;
  final String _launchPath;

  LinuxAutostart({String? configHome, String? launchPath})
    : _configHome = configHome ?? _defaultConfigHome(),
      _launchPath = launchPath ?? _defaultLaunchPath();

  static String _defaultConfigHome() {
    final xdg = Platform.environment['XDG_CONFIG_HOME'];
    if (xdg != null && xdg.isNotEmpty) return xdg;
    return '${Platform.environment['HOME']}/.config';
  }

  /// The AppImage when running from one (its runtime sets APPIMAGE), else
  /// the executable itself.
  static String _defaultLaunchPath() {
    final appImage = Platform.environment['APPIMAGE'];
    if (appImage != null && appImage.isNotEmpty) return appImage;
    return Platform.resolvedExecutable;
  }

  File get _file => File('$_configHome/autostart/$_fileName');

  bool get isEnabled => _file.existsSync();

  @override
  Future<bool> enabled() async => isEnabled;

  @override
  Future<void> setEnabled(bool on) async {
    if (on) {
      await _file.parent.create(recursive: true);
      await _file.writeAsString(desktopEntry);
    } else if (_file.existsSync()) {
      await _file.delete();
    }
  }

  /// Points an existing entry at where the app runs from now, in case the
  /// AppImage was moved or replaced under another name.
  @override
  Future<void> refresh() async {
    if (!isEnabled) return;
    if (await _file.readAsString() != desktopEntry) {
      await _file.writeAsString(desktopEntry);
    }
  }

  String get desktopEntry =>
      '''
[Desktop Entry]
Type=Application
Name=MeshCore Open
Comment=Listens for messages and SOS alerts
TryExec=${_launchPath.replaceAll('\\', '\\\\')}
Exec=${_quote(_launchPath)} $hiddenArgument
Terminal=false
X-GNOME-Autostart-enabled=true
''';

  /// Quotes a path for an Exec line, per the desktop entry spec: escape
  /// for the quoted argument, then backslashes again for the string value,
  /// and double `%` (field codes).
  static String _quote(String path) {
    final quoted = path.replaceAllMapped(
      RegExp(r'["`$\\]'),
      (m) => '\\${m[0]}',
    );
    return '"$quoted"'.replaceAll('\\', '\\\\').replaceAll('%', '%%');
  }
}
