import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'sound_devices.dart';
import 'windows_wave_out.dart';

/// The SOS alarm as Morse code (· · · – – – · · ·), so responders can't
/// mistake it for the alert tones of other emergency apps. Android plays it
/// from res/raw/sos_alarm_morse.wav; the desktops from this asset, copied to
/// a file their players can open.
const String sosMorseAsset = 'assets/sounds/sos_morse.wav';

/// The classic two-tone alarm, for Windows when it plays on a chosen speaker
/// (otherwise Windows' own alarm sound plays).
const String sosClassicAsset = 'assets/sounds/sos_classic.wav';

/// Copies the Morse alarm to the temporary folder once; null if that fails.
Future<String?> extractSosMorseSound() =>
    extractSoundAsset(sosMorseAsset, 'meshcore_sos_morse.wav');

/// Copies a sound asset to the temporary folder once, as [name]; null if
/// that fails.
Future<String?> extractSoundAsset(String asset, String name) async {
  try {
    final data = await rootBundle.load(asset);
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$name');
    if (!await file.exists() || await file.length() != data.lengthInBytes) {
      await file.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
    }
    return file.path;
  } catch (e) {
    debugPrint('Extracting $asset failed: $e');
    return null;
  }
}

/// Windows: loops an alarm file while any SOS is open. On the speaker chosen
/// in the app's settings it plays through waveOut ([WindowsWaveOut]); on the
/// default speaker, or if that fails, through PowerShell's SoundPlayer (no
/// audio package needed). A toast can only loop Windows' own alarm sounds, so
/// the toast stays silent and this plays instead.
class WindowsLoopingAlarm {
  final String file;
  final Set<int> _alarms = {};
  Process? _player;
  WindowsWaveOut? _waveOut;

  WindowsLoopingAlarm(this.file);

  void start(int id) {
    _alarms.add(id);
    if (_player != null || _waveOut != null) return;
    final device = SoundDevices.alertOutputId;
    if (device != null) {
      unawaited(_loopOn(device));
    } else {
      _startPowerShell();
    }
  }

  Future<void> _loopOn(String device) async {
    final out = _waveOut = WindowsWaveOut();
    try {
      final wav = await File(file).readAsBytes();
      while (_alarms.isNotEmpty && identical(_waveOut, out)) {
        if (!await out.play(wav, device: device)) break;
      }
    } catch (e) {
      debugPrint('Playing the SOS alarm on the chosen speaker failed: $e');
    }
    if (!identical(_waveOut, out)) return; // stopped
    _waveOut = null;
    if (_alarms.isNotEmpty) _startPowerShell(); // couldn't: the default
  }

  void _startPowerShell() {
    final path = file.replaceAll("'", "''");
    unawaited(
      Process.start('powershell', [
            '-NoProfile',
            '-WindowStyle',
            'Hidden',
            '-Command',
            "(New-Object Media.SoundPlayer '$path').PlayLooping(); Start-Sleep -Seconds 86400",
          ])
          .then((p) {
            if (_alarms.isEmpty) {
              p.kill();
            } else {
              _player = p;
            }
          })
          .catchError((Object e) {
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
    final out = _waveOut;
    _waveOut = null;
    out?.stop();
  }
}

/// Windows: plays the start of the Morse alarm on the speaker chosen for
/// [role], to try it.
Future<void> playWindowsSpeakerTest(SoundRole role) async {
  final data = await rootBundle.load(sosMorseAsset);
  final wav = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  final pcm = WavPcm.parse(wav);
  if (pcm == null) return;
  // "· · ·": the first second or so
  final bytes = (pcm.sampleRate * pcm.channels * pcm.bitsPerSample ~/ 8 * 1.1)
      .floor()
      .clamp(0, pcm.samples.length);
  final clip = _wav(pcm, pcm.samples.sublist(0, bytes & ~1));
  await WindowsWaveOut().play(clip, device: SoundDevices.idFor(role));
}

Uint8List _wav(WavPcm pcm, Uint8List samples) {
  final out = ByteData(44 + samples.length);
  void tag(int at, String s) {
    for (var i = 0; i < 4; i++) {
      out.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  final block = pcm.channels * pcm.bitsPerSample ~/ 8;
  tag(0, 'RIFF');
  out.setUint32(4, 36 + samples.length, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  out.setUint32(16, 16, Endian.little);
  out.setUint16(20, 1, Endian.little);
  out.setUint16(22, pcm.channels, Endian.little);
  out.setUint32(24, pcm.sampleRate, Endian.little);
  out.setUint32(28, pcm.sampleRate * block, Endian.little);
  out.setUint16(32, block, Endian.little);
  out.setUint16(34, pcm.bitsPerSample, Endian.little);
  tag(36, 'data');
  out.setUint32(40, samples.length, Endian.little);
  final bytes = out.buffer.asUint8List();
  bytes.setAll(44, samples);
  return bytes;
}
