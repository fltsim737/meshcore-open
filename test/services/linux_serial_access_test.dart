import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/linux_serial_access_io.dart';

void main() {
  test('tells a missing port from one the user may not open', () async {
    expect(
      await LinuxSerialAccess.diagnose('/dev/ttyMESHCORE_NONE'),
      SerialOpenProblem.missing,
    );
    // root-only device file
    expect(
      await LinuxSerialAccess.diagnose('/dev/mem'),
      SerialOpenProblem.permission,
    );
    // there and usable: something else must have it
    expect(
      await LinuxSerialAccess.diagnose('/dev/null'),
      SerialOpenProblem.unknown,
    );
  }, skip: !Platform.isLinux || Platform.environment['USER'] == 'root');

  test('the udev rule tags serial ports for the desktop user', () {
    expect(LinuxSerialAccess.rulePath, startsWith('/etc/udev/rules.d/70-'));
    expect(LinuxSerialAccess.rule, contains('TAG+="uaccess"'));
    expect(LinuxSerialAccess.rule, contains('ttyUSB[0-9]*|ttyACM[0-9]*'));
    expect(LinuxSerialAccess.rule, contains('ID_MM_DEVICE_IGNORE'));
  });
}
