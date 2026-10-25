import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// The SOS alarm as Morse code (· · · – – – · · ·), so responders can't
/// mistake it for the alert tones of other emergency apps. Android plays it
/// from res/raw/sos_alarm_morse.wav; the desktops from this asset, copied to
/// a file their players can open.
const String sosMorseAsset = 'assets/sounds/sos_morse.wav';

/// Copies the Morse alarm to the temporary folder once; null if that fails.
Future<String?> extractSosMorseSound() async {
  try {
    final data = await rootBundle.load(sosMorseAsset);
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/meshcore_sos_morse.wav');
    if (!await file.exists() || await file.length() != data.lengthInBytes) {
      await file.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
    }
    return file.path;
  } catch (e) {
    debugPrint('Extracting the SOS Morse sound failed: $e');
    return null;
  }
}

/// Windows: loops the Morse alarm while any SOS is open, through PowerShell's
/// SoundPlayer (no audio package needed). A toast can only loop Windows' own
/// alarm sounds, so the toast stays silent and this plays instead.
class WindowsMorseAlarm {
  final String file;
  final Set<int> _alarms = {};
  Process? _player;

  WindowsMorseAlarm(this.file);

  void start(int id) {
    _alarms.add(id);
    if (_player != null) return;
    final path = file.replaceAll("'", "''");
    unawaited(
      Process.start('powershell', [
        '-NoProfile',
        '-WindowStyle',
        'Hidden',
        '-Command',
        "(New-Object Media.SoundPlayer '$path').PlayLooping(); Start-Sleep -Seconds 86400",
      ]).then((p) {
        if (_alarms.isEmpty) {
          p.kill();
        } else {
          _player = p;
        }
      }).catchError((Object e) {
        debugPrint('Playing the SOS alarm failed: $e');
      }),
    );
  }

  void stop(int id) {
    _alarms.remove(id);
    if (_alarms.isEmpty) stopAll();
  }

  void stopAll() {
    _alarms.clear();
    _player?.kill();
    _player = null;
  }
}
