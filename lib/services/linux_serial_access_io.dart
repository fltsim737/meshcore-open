import 'dart:io';

import '../utils/app_logger.dart';
import 'linux_serial_access_types.dart';

export 'linux_serial_access_types.dart';

/// Works out why a USB serial radio wouldn't open on Linux, and can let the
/// person at the desktop use USB radios, with one password prompt.
class LinuxSerialAccess {
  static const String rulePath =
      '/etc/udev/rules.d/70-meshcore-open-serial.rules';

  /// `uaccess` gives whoever is logged in at the desktop access to the device
  /// (no logout needed, unlike joining `dialout`); it must sort before
  /// 73-seat-late.rules. ModemManager is kept off the USB-serial chips radios
  /// use, as its probing garbles the first frames. It still sees modems.
  static const String rule = '''
# Installed by MeshCore Open SOS Voice: lets the person at the desktop use USB serial
# radios, and keeps ModemManager from probing common radio USB chips.
SUBSYSTEM=="tty", KERNEL=="ttyUSB[0-9]*|ttyACM[0-9]*", TAG+="uaccess"
SUBSYSTEM=="tty", ATTRS{idVendor}=="10c4|1a86|303a|239a|1915|2886|0403", ENV{ID_MM_DEVICE_IGNORE}="1"
''';

  static Future<SerialOpenProblem> diagnose(String port) async {
    if (!Platform.isLinux || !port.startsWith('/dev/')) {
      return SerialOpenProblem.unknown;
    }
    if (!await File(port).exists()) return SerialOpenProblem.missing;
    try {
      // access(2), so ACLs and group membership both count
      final result = await Process.run('test', ['-r', port, '-a', '-w', port]);
      if (result.exitCode != 0) return SerialOpenProblem.permission;
    } catch (e) {
      appLogger.warn('Checking access to $port failed: $e', tag: 'USB Serial');
    }
    return SerialOpenProblem.unknown;
  }

  static Future<String?> _pkexec() async {
    for (final path in const ['/usr/bin/pkexec', '/bin/pkexec']) {
      if (await File(path).exists()) return path;
    }
    return null;
  }

  static Future<bool> canGrantAccess() async =>
      Platform.isLinux && await _pkexec() != null;

  /// Installs [rule] as root through the desktop's own password prompt, then
  /// applies it to devices already plugged in.
  static Future<SerialAccessGrant> grantAccess() async {
    final pkexec = await _pkexec();
    if (pkexec == null) return SerialAccessGrant.unavailable;
    // Stops at the first failure, so a rule that wasn't written is never
    // reported as access granted.
    final script =
        'set -e\n'
        "mkdir -p '${File(rulePath).parent.path}'\n"
        "cat > '$rulePath' <<'RULE'\n${rule}RULE\n"
        'udevadm control --reload-rules\n'
        'udevadm trigger --subsystem-match=tty --action=change\n'
        'udevadm settle --timeout=5 || true\n';
    try {
      final result = await Process.run(pkexec, ['/bin/sh', '-c', script]);
      appLogger.info(
        'Serial access rule install: exit ${result.exitCode} ${result.stderr}',
        tag: 'USB Serial',
      );
      // pkexec: 126 = not authorised or dialog dismissed, 127 = no agent
      if (result.exitCode == 0) return SerialAccessGrant.granted;
      if (result.exitCode == 126) return SerialAccessGrant.cancelled;
      return SerialAccessGrant.failed;
    } catch (e) {
      appLogger.warn(
        'Serial access rule install failed: $e',
        tag: 'USB Serial',
      );
      return SerialAccessGrant.failed;
    }
  }
}
