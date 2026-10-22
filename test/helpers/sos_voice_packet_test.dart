import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/sos_voice_packet.dart';

/// [count] distinct byte-aligned frames whose unused low bits are zero, as
/// Codec2 produces them.
List<Uint8List> fakeFrames(int count, SosVoiceQuality quality) {
  final bytes = (quality.bitsPerFrame + 7) ~/ 8;
  final spare = bytes * 8 - quality.bitsPerFrame;
  return [
    for (var f = 0; f < count; f++)
      Uint8List.fromList([
        for (var b = 0; b < bytes; b++)
          b == bytes - 1
              ? ((f * 37 + b) & 0xFF) & (0xFF << spare)
              : (f * 7 + b * 13) & 0xFF,
      ]),
  ];
}

final Uint8List prefix = Uint8List.fromList([1, 2, 3, 4, 5, 6]);

void main() {
  test('bit packing round-trips both qualities', () {
    for (final q in SosVoiceQuality.values) {
      final frames = fakeFrames(17, q);
      final packed = packFrames(frames, q.bitsPerFrame);
      expect(packed.length, (17 * q.bitsPerFrame + 7) ~/ 8);
      expect(unpackFrames(packed, 17, q.bitsPerFrame), frames);
    }
  });

  test('a clip splits into chunks that fit and decode back', () {
    for (final q in SosVoiceQuality.values) {
      final frames = fakeFrames(q.maxFrames + 40, q);
      final packets = SosVoicePacket.split(
        frames: frames,
        quality: q,
        sosId: 'a1b2',
        senderPrefix: prefix,
        clipId: 0xBEEF,
      );
      expect(packets.length, lessThanOrEqualTo(SosVoicePacket.maxChunks));
      final back = <Uint8List>[];
      for (final p in packets) {
        final blob = p.encode();
        expect(blob.length, lessThanOrEqualTo(SosVoicePacket.maxBlobBytes));
        final decoded = SosVoicePacket.decode(blob)!;
        expect(decoded.sosId, 'a1b2');
        expect(decoded.clipId, 0xBEEF);
        expect(decoded.senderPrefix, prefix);
        expect(decoded.total, packets.length);
        back.addAll(decoded.frames);
      }
      // Frames past the quality's limit are dropped.
      expect(back, frames.take(q.maxFrames).toList());
    }
  });

  test('chunk capacity and clip limits', () {
    expect(SosVoiceQuality.low.framesPerChunk, 42);
    expect(SosVoiceQuality.clear.framesPerChunk, 22);
    expect(SosVoiceQuality.low.maxFrames, 500);
    expect(SosVoiceQuality.clear.maxFrames, 250);
  });

  test('rejects malformed packets', () {
    final good = SosVoicePacket.split(
      frames: fakeFrames(5, SosVoiceQuality.low),
      quality: SosVoiceQuality.low,
      sosId: '0001',
      senderPrefix: prefix,
      clipId: 1,
    ).single.encode();
    expect(SosVoicePacket.decode(good), isNotNull);
    expect(SosVoicePacket.decode(good.sublist(0, good.length - 1)), isNull);
    expect(
      SosVoicePacket.decode(Uint8List.fromList([2, ...good.skip(1)])),
      isNull,
    );
    final badQuality = Uint8List.fromList(good)..[1] = 9;
    expect(SosVoicePacket.decode(badQuality), isNull);
    final badIndex = Uint8List.fromList(good)..[12] = 1;
    expect(SosVoicePacket.decode(badIndex), isNull);
  });

  group('assembler', () {
    late DateTime now;
    late SosVoiceAssembler assembler;
    late List<SosVoicePacket> packets;

    setUp(() {
      now = DateTime(2026, 10, 22, 12);
      assembler = SosVoiceAssembler(now: () => now);
      packets = SosVoicePacket.split(
        frames: fakeFrames(200, SosVoiceQuality.low),
        quality: SosVoiceQuality.low,
        sosId: 'a1b2',
        senderPrefix: prefix,
        clipId: 7,
      );
      expect(packets, hasLength(5));
    });

    test('completes when every chunk arrives, in any order', () {
      for (final p in packets.skip(1).toList().reversed) {
        expect(assembler.add(p), isNull);
      }
      final clip = assembler.add(packets.first)!;
      expect(clip.isComplete, isTrue);
      expect(clip.frames, hasLength(200));
      expect(assembler.hasPending, isFalse);
    });

    test('plays a clip with a lost middle chunk after the timeout', () {
      for (final p in packets) {
        if (p.index != 2) assembler.add(p);
      }
      expect(assembler.takeStale(), isEmpty);
      now = now.add(const Duration(seconds: 9));
      final clip = assembler.takeStale().single;
      expect(clip.isComplete, isFalse);
      expect(clip.received, 4);
      final frames = clip.frames;
      expect(frames, hasLength(200));
      expect(frames.sublist(84, 126).every((f) => f == null), isTrue);
    });

    test('drops a clip missing its last chunk', () {
      for (final p in packets.take(4)) {
        assembler.add(p);
      }
      now = now.add(const Duration(seconds: 9));
      expect(assembler.takeStale(), isEmpty);
      expect(assembler.hasPending, isFalse);
    });
  });
}
