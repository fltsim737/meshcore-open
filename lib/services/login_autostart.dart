import 'dart:io';

import '../utils/platform_info.dart';
import 'linux_autostart.dart';

/// Starts the app hidden in the tray when the user logs in (desktop only).
abstract class LoginAutostart {
  /// Launch argument that keeps the window hidden in the tray.
  static const String hiddenArgument = '--hidden';

  /// The implementation for this platform, or null where there is none.
  static LoginAutostart? forPlatform() {
    if (PlatformInfo.isLinux) return LinuxAutostart();
    if (PlatformInfo.isWindows) return WindowsAutostart();
    return null;
  }

  Future<bool> enabled();

  Future<void> setEnabled(bool on);

  /// Points an existing entry at where the app runs from now.
  Future<void> refresh();
}

/// Runs a command; replaced in tests.
typedef CommandRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

/// Windows: a value under the user's Run key, the list Task Manager shows as
/// startup apps (and where turning it off there takes effect here too).
class WindowsAutostart implements LoginAutostart {
  static const String _runKey =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const String valueName = 'MeshCore Open SOS Voice';

  final String _executable;
  final CommandRunner _run;

  WindowsAutostart({String? executable, CommandRunner? run})
    : _executable = executable ?? Platform.resolvedExecutable,
      _run = run ?? Process.run;

  /// The command line stored in the Run value.
  String get command => '"$_executable" ${LoginAutostart.hiddenArgument}';

  Future<String?> _current() async {
    final result = await _run('reg', ['query', _runKey, '/v', valueName]);
    if (result.exitCode != 0) return null;
    for (final line in '${result.stdout}'.split('\n')) {
      final at = line.indexOf('REG_SZ');
      if (line.trimLeft().startsWith(valueName) && at >= 0) {
        return line.substring(at + 'REG_SZ'.length).trim();
      }
    }
    return null;
  }

  @override
  Future<bool> enabled() async => await _current() != null;

  @override
  Future<void> setEnabled(bool on) async {
    if (on) {
      await _run('reg', [
        'add',
        _runKey,
        '/v',
        valueName,
        '/t',
        'REG_SZ',
        '/d',
        command,
        '/f',
      ]);
    } else if (await enabled()) {
      await _run('reg', ['delete', _runKey, '/v', valueName, '/f']);
    }
  }

  @override
  Future<void> refresh() async {
    final current = await _current();
    if (current != null && current != command) await setEnabled(true);
  }
}
