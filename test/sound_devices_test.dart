import 'dart:math';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:meshcore_open/services/sound_devices.dart';
import 'package:meshcore_open/services/windows_wave_out.dart';

void main() {
  group('levelVoice', () {
    Int16List tone(int amplitude) => Int16List.fromList([
      for (var i = 0; i < 800; i++)
        (amplitude * sin(2 * pi * 440 * i / 8000)).round(),
    ]);
    int peak(Int16List pcm) => pcm.fold(0, (m, s) => max(m, s.abs()));

    test('a quiet clip is brought up to 90% of full scale', () {
      final out = SoundDevices.levelVoice(tone(4000), 1.0);
      expect(peak(out) / 32767, closeTo(0.7 + 0.3 * 0.53, 0.05));
      expect(peak(out), greaterThan(peak(tone(4000)) * 5));
    });

    test('hiss is raised by at most 8 times', () {
      final out = SoundDevices.levelVoice(tone(100), 1.0);
      expect(peak(out), lessThanOrEqualTo(810));
    });

    test('turned up, it gets louder but never clips', () {
      final out = SoundDevices.levelVoice(tone(20000), 3.0);
      expect(peak(out), lessThanOrEqualTo(32767));
      expect(
        peak(out),
        greaterThan(peak(SoundDevices.levelVoice(tone(20000), 1.0))),
      );
    });

    test('turned down, it gets quieter', () {
      final out = SoundDevices.levelVoice(tone(20000), 0.25);
      expect(peak(out) / 32767, closeTo(0.225, 0.01));
    });

    test('silence stays silent', () {
      final silence = Int16List(800);
      expect(SoundDevices.levelVoice(silence, 2.0), same(silence));
    });
  });

  test('voice volume is kept between 25% and 300%', () async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    expect(SoundDevices.voiceVolume, 1.0);
    await SoundDevices.setVoiceVolume(5);
    expect(SoundDevices.voiceVolume, 3.0);
    await SoundDevices.setVoiceVolume(0.1);
    expect(SoundDevices.voiceVolume, 0.25);
  });

  group('speakers for voice and for alerts', () {
    Future<void> prefs(Map<String, Object> values) async {
      SharedPreferences.setMockInitialValues(values);
      PrefsManager.reset();
      await PrefsManager.initialize();
    }

    test('are chosen separately; nothing chosen is the default', () async {
      await prefs({});
      expect(SoundDevices.voiceOutputId, isNull);
      expect(SoundDevices.alertOutputId, isNull);
      await SoundDevices.setFor(
        SoundRole.voice,
        const SoundDevice('headset', 'USB headset'),
      );
      expect(SoundDevices.voiceOutputId, 'headset');
      expect(SoundDevices.labelFor(SoundRole.voice), 'USB headset');
      expect(SoundDevices.alertOutputId, isNull); // alerts stay on default
      expect(SoundDevices.inputId, isNull);
      await SoundDevices.setFor(SoundRole.voice, null);
      expect(SoundDevices.voiceOutputId, isNull);
    });

    test(
      'the single speaker of earlier 9.8.6 builds becomes the voice one',
      () async {
        await prefs({
          'sound_output_device': 'headset',
          'sound_output_label': 'USB headset',
        });
        expect(SoundDevices.alertOutputId, isNull);
        expect(SoundDevices.voiceOutputId, 'headset');
        expect(SoundDevices.labelFor(SoundRole.voice), 'USB headset');
        await Future<void>.delayed(Duration.zero);
        expect(PrefsManager.instance.getString('sound_output_device'), isNull);
      },
    );
  });

  group('parsePactlList', () {
    test('lists sinks by name and description', () {
      const out = '''Sink #51
\tState: SUSPENDED
\tName: alsa_output.usb-GeneralPlus_USB_Audio_Device-00.analog-stereo
\tDescription: USB Audio Device Analog Stereo
\tProperties:
\t\tnode.name = "alsa_output.usb-GeneralPlus_USB_Audio_Device-00.analog-stereo"
\t\tdevice.description = "Something: with a colon"

Sink #53
\tName: alsa_output.pci-0000_00_1f.3.analog-stereo
\tDescription: Built-in Audio Analog Stereo: Speakers
''';
      final devices = SoundDevices.parsePactlList(out);
      expect(devices.map((d) => d.id), [
        'alsa_output.usb-GeneralPlus_USB_Audio_Device-00.analog-stereo',
        'alsa_output.pci-0000_00_1f.3.analog-stereo',
      ]);
      expect(devices.map((d) => d.label), [
        'USB Audio Device Analog Stereo',
        'Built-in Audio Analog Stereo: Speakers',
      ]);
    });

    test('leaves out monitors of speakers', () {
      const out = '''Source #51
\tName: alsa_output.usb-X.analog-stereo.monitor
\tDescription: Monitor of USB Audio Device Analog Stereo
Source #52
\tName: alsa_input.usb-X.mono-fallback
\tDescription: USB Audio Device Mono
''';
      final devices = SoundDevices.parsePactlList(out);
      expect(devices, hasLength(1));
      expect(devices.single.id, 'alsa_input.usb-X.mono-fallback');
    });

    test('nothing listed gives nothing', () {
      expect(SoundDevices.parsePactlList(''), isEmpty);
    });
  });

  group('WavPcm', () {
    test('reads the alarm files, skipping extra chunks', () {
      for (final f in [
        'assets/sounds/sos_morse.wav',
        'assets/sounds/sos_classic.wav',
      ]) {
        final wav = WavPcm.parse(File(f).readAsBytesSync());
        expect(wav, isNotNull, reason: f);
        expect(wav!.bitsPerSample, 16, reason: f);
        expect(wav.samples, isNotEmpty, reason: f);
      }
    });

    test('rejects what is not a PCM WAV', () {
      expect(WavPcm.parse(Uint8List.fromList(List.filled(40, 7))), isNull);
      expect(WavPcm.parse(Uint8List(0)), isNull);
    });
  });
}
