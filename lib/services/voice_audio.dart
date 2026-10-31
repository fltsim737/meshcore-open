import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

import '../helpers/sos_voice_packet.dart';
import 'sound_devices.dart';
import 'windows_wave_out.dart';

/// Microphone and speaker for voice clips: 8 kHz mono 16-bit audio in
/// 40 ms frames.
abstract class VoiceAudio {
  /// Asks for microphone permission if needed; true once granted.
  Future<bool> ensureMicPermission();

  /// Starts the microphone; frames are [SosVoicePacket.samplesPerFrame] long.
  Future<Stream<Int16List>> startMic();
  Future<void> stopMic();

  /// Plays [pcm] and completes when it has finished or [stopPlayback] ran.
  Future<void> play(Int16List pcm);
  Future<void> stopPlayback();

  Future<void> dispose();
}

/// For platforms without voice: nothing records or plays.
class UnavailableVoiceAudio implements VoiceAudio {
  const UnavailableVoiceAudio();

  @override
  Future<bool> ensureMicPermission() async => false;
  @override
  Future<Stream<Int16List>> startMic() async => const Stream.empty();
  @override
  Future<void> stopMic() async {}
  @override
  Future<void> play(Int16List pcm) async {}
  @override
  Future<void> stopPlayback() async {}
  @override
  Future<void> dispose() async {}
}

/// [VoiceAudio] using the record plugin for the microphone. Android plays
/// clips with the audioplayers plugin; Linux pipes them to PulseAudio's or
/// PipeWire's player, as it does for notification sounds, which avoids
/// needing GStreamer. On Linux and Windows the microphone and speaker are the
/// ones chosen in the app's settings ([SoundDevices]).
class DeviceVoiceAudio implements VoiceAudio {
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer? _player = Platform.isLinux ? null : AudioPlayer();
  StreamController<Int16List>? _frames;
  StreamSubscription<Uint8List>? _micSub;
  Completer<void>? _playing;
  StreamSubscription<void>? _completeSub;
  Process? _linuxPlayer;
  WindowsWaveOut? _windowsOut;

  DeviceVoiceAudio() {
    SoundDevices.playsVoice = true;
    if (Platform.isLinux) {
      SoundDevices.inputLister = SoundDevices.linuxInputs;
    } else if (Platform.isWindows) {
      SoundDevices.inputLister = () async => [
        for (final d in await _recorder.listInputDevices())
          SoundDevice(d.id, d.label),
      ];
    }
    final player = _player;
    if (player == null) return;
    _completeSub = player.onPlayerComplete.listen((_) => _donePlaying());
    unawaited(
      player.setAudioContext(
        AudioContextConfig(focus: AudioContextConfigFocus.duckOthers).build(),
      ),
    );
  }

  @override
  Future<bool> ensureMicPermission() => _recorder.hasPermission();

  /// The chosen microphone, if it's still there; null for the default.
  Future<InputDevice?> _chosenMic() async {
    final id = SoundDevices.inputId;
    if (id == null) return null;
    final present = await SoundDevices.inputs();
    for (final d in present) {
      if (d.id == id) return InputDevice(id: d.id, label: d.label);
    }
    return null; // unplugged: the default instead
  }

  @override
  Future<Stream<Int16List>> startMic() async {
    await stopMic();
    final mic = await _chosenMic();
    final controller = StreamController<Int16List>();
    _frames = controller;
    final pending = BytesBuilder(copy: false);
    final raw = await _recorder.startStream(
      RecordConfig(
        device: mic,
        encoder: AudioEncoder.pcm16bits,
        sampleRate: SosVoicePacket.sampleRate,
        numChannels: 1,
        autoGain: true,
        echoCancel: true,
        noiseSuppress: true,
        androidConfig: const AndroidRecordConfig(
          audioSource: AndroidAudioSource.voiceCommunication,
        ),
      ),
    );
    const frameBytes = SosVoicePacket.samplesPerFrame * 2;
    _micSub = raw.listen((bytes) {
      pending.add(bytes);
      if (pending.length < frameBytes) return;
      final all = pending.takeBytes();
      var offset = 0;
      while (all.length - offset >= frameBytes) {
        final frame = Int16List(SosVoicePacket.samplesPerFrame);
        final data = ByteData.sublistView(all, offset, offset + frameBytes);
        for (var i = 0; i < frame.length; i++) {
          frame[i] = data.getInt16(i * 2, Endian.little);
        }
        controller.add(frame);
        offset += frameBytes;
      }
      if (offset < all.length) pending.add(all.sublist(offset));
    });
    return controller.stream;
  }

  @override
  Future<void> stopMic() async {
    await _micSub?.cancel();
    _micSub = null;
    if (await _recorder.isRecording()) await _recorder.stop();
    await _frames?.close();
    _frames = null;
  }

  @override
  Future<void> play(Int16List pcm) async {
    await stopPlayback();
    final done = Completer<void>();
    _playing = done;
    final player = _player;
    if (player == null) {
      unawaited(_playOnLinux(pcm));
    } else if (Platform.isWindows && SoundDevices.voiceOutputId != null) {
      unawaited(_playOnWindows(pcm));
    } else {
      await player.play(BytesSource(wavBytes(pcm), mimeType: 'audio/wav'));
    }
    return done.future;
  }

  Future<void> _playOnLinux(Int16List pcm) async {
    final dir = await Directory.systemTemp.createTemp('meshcore_voice');
    final file = File('${dir.path}/clip.wav');
    try {
      await file.writeAsBytes(wavBytes(pcm));
      await SoundDevices.playOnLinux(
        file.path,
        role: SoundRole.voice,
        started: (player) => _linuxPlayer = player,
      );
    } finally {
      _linuxPlayer = null;
      await dir.delete(recursive: true);
      _donePlaying();
    }
  }

  /// Windows, on the chosen speaker; the default player if that fails.
  Future<void> _playOnWindows(Int16List pcm) async {
    final out = _windowsOut ??= WindowsWaveOut();
    final wav = wavBytes(pcm);
    var played = false;
    try {
      played = await out.play(wav, device: SoundDevices.voiceOutputId);
    } catch (e) {
      debugPrint('Playing on the chosen speaker failed: $e');
    }
    if (!played && _playing != null) {
      await _player?.play(BytesSource(wav, mimeType: 'audio/wav'));
      return; // completes through onPlayerComplete
    }
    _donePlaying();
  }

  void _donePlaying() {
    final done = _playing;
    _playing = null;
    if (done != null && !done.isCompleted) done.complete();
  }

  @override
  Future<void> stopPlayback() async {
    if (_playing == null) return;
    _linuxPlayer?.kill();
    _windowsOut?.stop();
    await _player?.stop();
    _donePlaying();
  }

  @override
  Future<void> dispose() async {
    await stopMic();
    await stopPlayback();
    await _completeSub?.cancel();
    await _player?.dispose();
    await _recorder.dispose();
  }
}

/// A WAV file holding [pcm] as 8 kHz mono 16-bit audio.
Uint8List wavBytes(Int16List pcm) {
  const rate = SosVoicePacket.sampleRate;
  final dataBytes = pcm.length * 2;
  final out = ByteData(44 + dataBytes);
  void tag(int offset, String s) {
    for (var i = 0; i < 4; i++) {
      out.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  out.setUint32(4, 36 + dataBytes, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  out.setUint32(16, 16, Endian.little);
  out.setUint16(20, 1, Endian.little); // PCM
  out.setUint16(22, 1, Endian.little); // mono
  out.setUint32(24, rate, Endian.little);
  out.setUint32(28, rate * 2, Endian.little);
  out.setUint16(32, 2, Endian.little);
  out.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  out.setUint32(40, dataBytes, Endian.little);
  for (var i = 0; i < pcm.length; i++) {
    out.setInt16(44 + i * 2, pcm[i], Endian.little);
  }
  return out.buffer.asUint8List();
}
