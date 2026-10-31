import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../storage/prefs_manager.dart';
import 'windows_wave_out.dart';

/// A speaker or microphone, as the system names it.
@immutable
class SoundDevice {
  /// What the system opens it by: a PulseAudio/PipeWire name on Linux, the
  /// device's name (speakers) or endpoint ID (microphones) on Windows.
  final String id;

  /// What the user sees.
  final String label;

  const SoundDevice(this.id, this.label);

  @override
  bool operator ==(Object other) => other is SoundDevice && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// What a chosen sound device is for.
enum SoundRole {
  /// Voice clips, SOS and push-to-talk (SOS Voice): a headset, say.
  voice('sound_voice_output'),

  /// The SOS alarm, message chimes and warnings.
  alerts('sound_alert_output'),

  /// Recording voice clips (SOS Voice).
  microphone('sound_input_device');

  final String _key;
  const SoundRole(this._key);

  String get _labelKey => '${_key}_label';
}

/// The speakers and microphone this app uses on Linux and Windows, chosen in
/// its settings: one speaker for voice, another for alerts, so a headset can
/// carry the talking while the alarm still sounds out loud. Only the app's
/// own sound goes there: the computer's default devices, and every other
/// program, are left as they are. Nothing chosen means the system default,
/// and so does a chosen device that has gone.
class SoundDevices {
  SoundDevices._();

  /// 9.8.6 test builds had one speaker for everything; it was chosen for
  /// voice, so it becomes the voice speaker and alerts go back to the default.
  static const _oldOutputKey = 'sound_output_device';
  static const _oldOutputLabelKey = 'sound_output_label';

  /// The desktops choose; Android follows the phone's own routing.
  static bool get supported => Platform.isLinux || Platform.isWindows;

  /// Lists the microphones, where the app records (SOS Voice sets this).
  static Future<List<SoundDevice>> Function()? inputLister;

  /// The app plays voice clips (SOS Voice sets this, on every platform).
  static bool playsVoice = false;

  static const _voiceVolumeKey = 'voice_volume';
  static const double minVoiceVolume = 0.25;
  static const double maxVoiceVolume = 3.0;

  /// How loud voice clips play, after each is levelled ([levelVoice]): 1.0
  /// as levelled, more for louder (softly limited, so it doesn't distort).
  static double get voiceVolume {
    try {
      final v = PrefsManager.instance.getDouble(_voiceVolumeKey);
      return (v ?? 1.0).clamp(minVoiceVolume, maxVoiceVolume).toDouble();
    } catch (_) {
      return 1.0;
    }
  }

  static Future<void> setVoiceVolume(double value) =>
      PrefsManager.instance.setDouble(
        _voiceVolumeKey,
        value.clamp(minVoiceVolume, maxVoiceVolume).toDouble(),
      );

  /// A voice clip brought to a steady loudness, then [volume] applied.
  ///
  /// Codec2 clips often come out quiet (a quiet microphone stays quiet), and
  /// turning the computer's volume up barely helps. So each clip's peak is
  /// raised to 90% of full scale (by up to 8 times: silence and hiss aren't
  /// blown up), then multiplied by [volume]; anything above 70% of full
  /// scale is rounded off smoothly towards full scale instead of clipping.
  static Int16List levelVoice(Int16List pcm, double volume) {
    var peak = 0;
    for (final s in pcm) {
      final a = s.abs();
      if (a > peak) peak = a;
    }
    if (peak == 0) return pcm;
    final gain = min(0.9 * 32767 / peak, 8.0) * volume;
    final out = Int16List(pcm.length);
    for (var i = 0; i < pcm.length; i++) {
      final v = pcm[i] * gain / 32767;
      final a = v.abs();
      final shaped = a <= 0.7 ? a : 0.7 + 0.3 * _tanh((a - 0.7) / 0.3);
      out[i] = (shaped * v.sign * 32767).round().clamp(-32768, 32767);
    }
    return out;
  }

  static double _tanh(double x) {
    final e = exp(2 * x);
    return (e - 1) / (e + 1);
  }

  /// The app has voice (SOS Voice): a voice speaker and a microphone to
  /// choose, besides the alerts speaker.
  static bool get hasVoice => inputLister != null;

  static String? _read(String key) {
    try {
      final prefs = PrefsManager.instance;
      final old = prefs.getString(_oldOutputKey);
      if (old != null) {
        final label = prefs.getString(_oldOutputLabelKey);
        unawaited(prefs.setString(SoundRole.voice._key, old));
        if (label != null) {
          unawaited(prefs.setString(SoundRole.voice._labelKey, label));
        }
        unawaited(prefs.remove(_oldOutputKey));
        unawaited(prefs.remove(_oldOutputLabelKey));
        if (key == SoundRole.voice._key) return old;
        if (key == SoundRole.voice._labelKey) return label;
      }
      final value = prefs.getString(key);
      return value == null || value.isEmpty ? null : value;
    } catch (_) {
      return null; // no settings store (as in tests): the system default
    }
  }

  /// The device chosen for [role], or null for the system default.
  static String? idFor(SoundRole role) => supported ? _read(role._key) : null;
  static String? labelFor(SoundRole role) => _read(role._labelKey);

  static String? get voiceOutputId => idFor(SoundRole.voice);
  static String? get alertOutputId => idFor(SoundRole.alerts);
  static String? get inputId => idFor(SoundRole.microphone);

  static Future<void> setFor(SoundRole role, SoundDevice? device) async {
    final prefs = PrefsManager.instance;
    if (device == null) {
      await prefs.remove(role._key);
      await prefs.remove(role._labelKey);
    } else {
      await prefs.setString(role._key, device.id);
      await prefs.setString(role._labelKey, device.label);
    }
  }

  /// The speakers to choose from; empty if they can't be listed.
  static Future<List<SoundDevice>> outputs() async {
    try {
      if (Platform.isLinux) return await _pactl('sinks');
      if (Platform.isWindows) {
        return [
          for (final name in WindowsWaveOut.deviceNames())
            SoundDevice(name, name),
        ];
      }
    } catch (e) {
      debugPrint('Listing speakers failed: $e');
    }
    return const [];
  }

  /// The microphones to choose from; empty if they can't be listed.
  static Future<List<SoundDevice>> inputs() async {
    try {
      return await inputLister?.call() ?? const [];
    } catch (e) {
      debugPrint('Listing microphones failed: $e');
      return const [];
    }
  }

  /// Linux: the microphones, from PulseAudio or PipeWire.
  static Future<List<SoundDevice>> linuxInputs() => _pactl('sources');

  static Future<List<SoundDevice>> _pactl(String kind) async {
    final result = await Process.run(
      'pactl',
      ['list', kind],
      environment: const {'LC_ALL': 'C'},
    );
    if (result.exitCode != 0) return const [];
    return parsePactlList(result.stdout as String);
  }

  /// The devices in `pactl list sinks` or `pactl list sources` output, by
  /// name and description. Monitors (a speaker's output, offered as a
  /// microphone) are left out.
  @visibleForTesting
  static List<SoundDevice> parsePactlList(String output) {
    final devices = <SoundDevice>[];
    String? name;
    String? description;
    void flush() {
      if (name != null && !name!.endsWith('.monitor')) {
        devices.add(SoundDevice(name!, description ?? name!));
      }
      name = null;
      description = null;
    }

    for (final raw in output.split('\n')) {
      final line = raw.trim();
      if (raw.startsWith('Sink #') || raw.startsWith('Source #')) {
        flush();
      } else if (line.startsWith('Name:') && name == null) {
        name = line.substring(5).trim();
      } else if (line.startsWith('Description:') && description == null) {
        description = line.substring(12).trim();
      }
    }
    flush();
    return devices;
  }

  /// Linux: plays [file] on the speaker chosen for [role] (the default if
  /// none is chosen, or if it has gone), with PulseAudio's player, or
  /// PipeWire's. [started] gets the player, so it can be stopped.
  static Future<void> playOnLinux(
    String file, {
    required SoundRole role,
    void Function(Process player)? started,
  }) async {
    final sink = idFor(role);
    for (final device in [?sink, null]) {
      for (final bin in const ['paplay', 'pw-play']) {
        final Process player;
        try {
          player = await Process.start(bin, [
            if (device != null)
              bin == 'paplay' ? '--device=$device' : '--target=$device',
            file,
          ]);
        } on ProcessException {
          continue; // not installed: the other player
        }
        started?.call(player);
        unawaited(player.stdout.drain<void>());
        unawaited(player.stderr.drain<void>());
        final code = await player.exitCode;
        // played, stopped, or already on the default: done. Otherwise the
        // chosen speaker failed, so once more on the default.
        if (code == 0 || code < 0 || device == null) return;
        break;
      }
    }
  }
}
