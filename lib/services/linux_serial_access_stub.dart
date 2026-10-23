import 'linux_serial_access_types.dart';

export 'linux_serial_access_types.dart';

/// No serial device files to check off Linux desktop builds.
class LinuxSerialAccess {
  static Future<SerialOpenProblem> diagnose(String port) async =>
      SerialOpenProblem.unknown;

  static Future<bool> canGrantAccess() async => false;

  static Future<SerialAccessGrant> grantAccess() async =>
      SerialAccessGrant.unavailable;
}
