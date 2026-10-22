import 'dart:typed_data';

import 'package:codec2_ffi/codec2_ffi.dart';

import '../helpers/sos_voice_packet.dart';

/// Turns 40 ms frames of audio into Codec2 frames and back.
abstract class VoiceCodec {
  List<Uint8List> encode(List<Int16List> frames, SosVoiceQuality quality);

  /// Decodes a clip; null frames (from lost chunks) become silence.
  Int16List decode(List<Uint8List?> frames, SosVoiceQuality quality);
}

class Codec2VoiceCodec implements VoiceCodec {
  static Codec2Mode _mode(SosVoiceQuality quality) => switch (quality) {
    SosVoiceQuality.low => Codec2Mode.mode700c,
    SosVoiceQuality.clear => Codec2Mode.mode1300,
  };

  @override
  List<Uint8List> encode(List<Int16List> frames, SosVoiceQuality quality) {
    final codec = Codec2(_mode(quality));
    try {
      return [for (final frame in frames) codec.encodeFrame(frame)];
    } finally {
      codec.dispose();
    }
  }

  @override
  Int16List decode(List<Uint8List?> frames, SosVoiceQuality quality) {
    const n = SosVoicePacket.samplesPerFrame;
    final out = Int16List(frames.length * n);
    final codec = Codec2(_mode(quality));
    try {
      for (var i = 0; i < frames.length; i++) {
        final frame = frames[i];
        if (frame != null) out.setAll(i * n, codec.decodeFrame(frame));
      }
    } finally {
      codec.dispose();
    }
    return out;
  }
}
