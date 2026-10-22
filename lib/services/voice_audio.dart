import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:record/record.dart';

import '../helpers/sos_voice_packet.dart';

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
/// needing GStreamer.
class DeviceVoiceAudio implements VoiceAudio {
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer? _player = Platform.isLinux ? null : AudioPlayer();
  StreamController<Int16List>? _frames;
  StreamSubscription<Uint8List>? _micSub;
  Completer<void>? _playing;
  StreamSubscription<void>? _completeSub;
  Process? _linuxPlayer;

  DeviceVoiceAudio() {
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

  @override
  Future<Stream<Int16List>> startMic() async {
    await stopMic();
    final controller = StreamController<Int16List>();
    _frames = controller;
    final pending = BytesBuilder(copy: false);
    final raw = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: SosVoicePacket.sampleRate,
        numChannels: 1,
        autoGain: true,
        echoCancel: true,
        noiseSuppress: true,
        androidConfig: AndroidRecordConfig(
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
      for (final bin in const ['paplay', 'pw-play']) {
        try {
          final process = await Process.start(bin, [file.path]);
          _linuxPlayer = process;
          await process.exitCode;
          break;
        } on ProcessException {
          continue;
        }
      }
    } finally {
      _linuxPlayer = null;
      await dir.delete(recursive: true);
      _donePlaying();
    }
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
