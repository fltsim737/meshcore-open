import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Plays notification sounds on Linux. Many notification daemons, Cinnamon's
/// included, ignore a notification's sound hint, so the app plays the
/// freedesktop theme sounds itself.
class LinuxSoundPlayer {
  static const String _soundDir = '/usr/share/sounds/freedesktop/stereo';

  /// How often an SOS alarm sounds again until it is cleared.
  final Duration alarmRepeat;

  /// Plays a theme sound by name; replaced in tests.
  final Future<void> Function(String name) _play;

  LinuxSoundPlayer({
    this.alarmRepeat = const Duration(seconds: 4),
    Future<void> Function(String name)? play,
  }) : _play = play ?? _playThemeSound;

  final Set<int> _alarms = {};
  Timer? _alarmTimer;

  void playMessage() => unawaited(_play('message-new-instant'));

  void playEvent() => unawaited(_play('complete'));

  /// Sounds the alarm for [id] now and every [alarmRepeat] until
  /// [stopAlarm], like Android's insistent SOS notification.
  void startAlarm(int id) {
    _alarms.add(id);
    unawaited(_play('alarm-clock-elapsed'));
    _alarmTimer ??= Timer.periodic(
      alarmRepeat,
      (_) => unawaited(_play('alarm-clock-elapsed')),
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
  static Future<void> _playThemeSound(String name) async {
    final file = '$_soundDir/$name.oga';
    for (final player in const ['paplay', 'pw-play']) {
      try {
        await Process.start(player, [file], mode: ProcessStartMode.detached);
        return;
      } on ProcessException {
        continue;
      } catch (e) {
        debugPrint('Playing $name with $player failed: $e');
        return;
      }
    }
  }
}
