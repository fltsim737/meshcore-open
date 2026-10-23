/// Why a serial port that is listed could not be opened.
enum SerialOpenProblem {
  /// The device file has gone: unplugged, or the board restarted.
  missing,

  /// The user may not read and write it: on Ubuntu-based systems only the
  /// `dialout` group may, and a new desktop user isn't in it.
  permission,

  /// It is there and accessible, so most likely another program has it open.
  unknown,
}

enum SerialAccessGrant { granted, cancelled, failed, unavailable }
