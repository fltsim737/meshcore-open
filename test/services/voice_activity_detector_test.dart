import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/voice_activity_detector.dart';

Int16List tone(double amplitude, [int seed = 0]) {
  final r = Random(seed);
  return Int16List.fromList([
    for (var i = 0; i < 320; i++)
      (amplitude * 32767 * sin(i * 0.3) + r.nextInt(40) - 20).round(),
  ]);
}

Int16List quiet([int seed = 0]) {
  final r = Random(seed);
  return Int16List.fromList([for (var i = 0; i < 320; i++) r.nextInt(40) - 20]);
}

void main() {
  late List<List<Int16List>> clips;
  late List<bool> speaking;
  late VoiceActivityDetector vad;

  setUp(() {
    clips = [];
    speaking = [];
    vad = VoiceActivityDetector(
      maxFrames: 100,
      onClip: clips.add,
      onSpeakingChanged: speaking.add,
    );
  });

  void feed(Int16List Function(int i) frame, int count) {
    for (var i = 0; i < count; i++) {
      vad.addFrame(frame(i));
    }
  }

  test('silence never makes a clip', () {
    feed(quiet, 300);
    expect(clips, isEmpty);
    expect(speaking, isEmpty);
  });

  test('speech makes one clip with pre-roll and a short tail', () {
    feed(quiet, 50);
    feed((i) => tone(0.3, i), 40);
    feed(quiet, 40);
    expect(speaking, [true, false]);
    final clip = clips.single;
    // 8 pre-roll + 3 start frames, the rest of the speech, 6 tail frames.
    expect(clip.length, 8 + 40 + 6);
    expect(VoiceActivityDetector.levelDb(clip.first), lessThan(-50));
  });

  test('a short noise is ignored', () {
    feed(quiet, 50);
    feed((i) => tone(0.3, i), 5);
    feed(quiet, 40);
    expect(clips, isEmpty);
  });

  test('long speech goes out in pieces at the limit', () {
    feed(quiet, 50);
    feed((i) => tone(0.3, i), 230);
    expect(clips, hasLength(2));
    expect(clips.every((c) => c.length == 100), isTrue);
    expect(vad.isSpeaking, isTrue);
  });

  test('flush sends a clip in progress; reset drops it', () {
    feed(quiet, 50);
    feed((i) => tone(0.3, i), 30);
    vad.flush();
    expect(clips, hasLength(1));
    feed((i) => tone(0.3, i), 30);
    vad.reset();
    expect(clips, hasLength(1));
    expect(vad.isSpeaking, isFalse);
  });
}
