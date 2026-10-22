import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:codec2_ffi/codec2_ffi.dart';
import 'package:flutter_test/flutter_test.dart';

/// Needs a host build of the library, which Flutter does not make for tests:
///
///   cmake -S src -B build/host && cmake --build build/host
///   CODEC2_LIB=$PWD/build/host/libcodec2_ffi.so flutter test
void main() {
  final lib = Platform.environment['CODEC2_LIB'];

  setUpAll(() => codec2LibraryPath = lib);

  test('frame sizes', () {
    final low = Codec2(Codec2Mode.mode700c);
    final clear = Codec2(Codec2Mode.mode1300);
    expect(low.bitsPerFrame, 28);
    expect(low.bytesPerFrame, 4);
    expect(clear.bitsPerFrame, 52);
    expect(clear.bytesPerFrame, 7);
    expect(low.samplesPerFrame, 320);
    expect(clear.samplesPerFrame, 320);
    low.dispose();
    clear.dispose();
  }, skip: lib == null ? 'set CODEC2_LIB' : false);

  test('a tone comes back as sound', () {
    for (final mode in Codec2Mode.values) {
      final codec = Codec2(mode);
      var inEnergy = 0.0, outEnergy = 0.0;
      for (var f = 0; f < 50; f++) {
        // A buzzy 150 Hz tone, roughly like a voice.
        final pcm = Int16List.fromList([
          for (var i = 0; i < 320; i++)
            (6000 * sin(2 * pi * 150 * (f * 320 + i) / 8000) +
                    2000 * sin(2 * pi * 450 * (f * 320 + i) / 8000))
                .round(),
        ]);
        final bits = codec.encodeFrame(pcm);
        expect(bits, hasLength(codec.bytesPerFrame));
        final out = codec.decodeFrame(bits);
        if (f >= 10) {
          for (var i = 0; i < 320; i++) {
            inEnergy += pcm[i] * pcm[i].toDouble();
            outEnergy += out[i] * out[i].toDouble();
          }
        }
      }
      codec.dispose();
      // Codec2 is tuned for speech and resynthesises it, so a test tone
      // only has to come back as sound, not as the same waveform or level.
      // (On Codec2's own speech sample, encoding matches c2enc bit for bit.)
      expect(outEnergy / inEnergy, greaterThan(0.001), reason: '$mode');
    }
  }, skip: lib == null ? 'set CODEC2_LIB' : false);
}
