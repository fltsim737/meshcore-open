import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'sound_devices.dart';

/// Plays notification sounds on Linux. Many notification daemons, Cinnamon's
/// included, ignore a notification's sound hint, so the app plays the
/// freedesktop theme sounds itself.
class LinuxSoundPlayer {
  static const String _systemSoundDir = '/usr/share/sounds/freedesktop/stereo';

  /// How often an SOS alarm sounds again until it is cleared (set to suit the
  /// chosen alarm before it starts).
  Duration alarmRepeat;

  /// The SOS alarm: a theme sound by name, or a file path (the Morse SOS,
  /// once the app has copied it out).
  String alarmSound = themeAlarm;

  /// The desktop theme's alarm: the classic SOS alarm on Linux.
  static const String themeAlarm = 'alarm-clock-elapsed';

  /// Plays a theme sound by name; replaced in tests.
  final Future<void> Function(String name) _play;

  LinuxSoundPlayer({
    this.alarmRepeat = const Duration(
      milliseconds: 3600,
    ), // the Morse SOS, with its gap
    Future<void> Function(String name)? play,
  }) : _play = play ?? _playThemeSound;

  final Set<int> _alarms = {};
  Timer? _alarmTimer;

  void playMessage() => unawaited(_play('message-new-instant'));

  void playEvent() => unawaited(_play('complete'));

  /// A warning (the radio's battery is low): not the SOS alarm.
  void playWarning() => unawaited(_play('dialog-warning'));

  /// Sounds the alarm for [id] now and every [alarmRepeat] until
  /// [stopAlarm], like Android's insistent SOS notification.
  void startAlarm(int id) {
    _alarms.add(id);
    unawaited(_play(alarmSound));
    _alarmTimer ??= Timer.periodic(
      alarmRepeat,
      (_) => unawaited(_play(alarmSound)),
    );
  }

  void stopAlarm(int id) {
    _alarms.remove(id);
    if (_alarms.isNotEmpty) return;
    _alarmTimer?.cancel();
    _alarmTimer = null;
  }

  void stopAll() {
    _alarms.clear();
    _alarmTimer?.cancel();
    _alarmTimer = null;
  }

  /// PulseAudio's player first (PipeWire provides it too), then PipeWire's.
  static Future<void> _playThemeSound(
    String name, {
    SoundRole role = SoundRole.alerts,
  }) async {
    // The AppImage bundles the sounds and points here at them.
    final bundled = Platform.environment['MESHCORE_SOUND_DIR'];
    var file = '$_systemSoundDir/$name.oga';
    if (name.startsWith('/')) {
      file = name; // a file of our own
    } else if (bundled != null && File('$bundled/$name.oga').existsSync()) {
      file = '$bundled/$name.oga';
    }
    try {
      // On the speaker chosen in the app's settings, else the default. It
      // waits for the player to exit so it is reaped; a detached start left a
      // zombie process behind for every sound.
      await SoundDevices.playOnLinux(file, role: role);
    } catch (e) {
      debugPrint('Playing $name failed: $e');
    }
  }

  /// Plays a short sound, to try the speaker chosen for [role].
  static Future<void> playTest(SoundRole role) =>
      _playThemeSound('complete', role: role);
}
