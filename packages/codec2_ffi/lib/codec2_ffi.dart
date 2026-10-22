import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Codec2 speech modes used for voice clips.
enum Codec2Mode {
  /// 700 bit/s: 28 bits per 40 ms frame.
  mode700c(8),

  /// 1300 bit/s: 52 bits per 40 ms frame.
  mode1300(4);

  /// The mode number codec2_create takes.
  final int native;
  const Codec2Mode(this.native);
}

typedef _CreateNative = Pointer<Void> Function(Int32 mode);
typedef _Create = Pointer<Void> Function(int mode);
typedef _DestroyNative = Void Function(Pointer<Void> state);
typedef _Destroy = void Function(Pointer<Void> state);
typedef _PerFrameNative = Int32 Function(Pointer<Void> state);
typedef _PerFrame = int Function(Pointer<Void> state);
typedef _EncodeNative = Void Function(
  Pointer<Void> state,
  Pointer<Uint8> bits,
  Pointer<Int16> pcm,
);
typedef _Encode = void Function(
  Pointer<Void> state,
  Pointer<Uint8> bits,
  Pointer<Int16> pcm,
);
typedef _DecodeNative = Void Function(
  Pointer<Void> state,
  Pointer<Int16> pcm,
  Pointer<Uint8> bits,
);
typedef _Decode = void Function(
  Pointer<Void> state,
  Pointer<Int16> pcm,
  Pointer<Uint8> bits,
);

class _Bindings {
  final _Create create;
  final _Destroy destroy;
  final _PerFrame bitsPerFrame;
  final _PerFrame bytesPerFrame;
  final _PerFrame samplesPerFrame;
  final _Encode encode;
  final _Decode decode;

  _Bindings(DynamicLibrary lib)
    : create = lib.lookupFunction<_CreateNative, _Create>('codec2_create'),
      destroy = lib.lookupFunction<_DestroyNative, _Destroy>('codec2_destroy'),
      bitsPerFrame = lib.lookupFunction<_PerFrameNative, _PerFrame>(
        'codec2_bits_per_frame',
      ),
      bytesPerFrame = lib.lookupFunction<_PerFrameNative, _PerFrame>(
        'codec2_bytes_per_frame',
      ),
      samplesPerFrame = lib.lookupFunction<_PerFrameNative, _PerFrame>(
        'codec2_samples_per_frame',
      ),
      encode = lib.lookupFunction<_EncodeNative, _Encode>('codec2_encode'),
      decode = lib.lookupFunction<_DecodeNative, _Decode>('codec2_decode');
}

_Bindings? _bindings;

/// Overrides where the library is loaded from, for tests on the host.
String? codec2LibraryPath;

_Bindings _load() => _bindings ??= _Bindings(
  DynamicLibrary.open(
    codec2LibraryPath ??
        (Platform.isAndroid || Platform.isLinux
            ? 'libcodec2_ffi.so'
            : throw UnsupportedError('Codec2 is not built for this platform')),
  ),
);

/// One Codec2 encoder/decoder. Frames are 40 ms of 8 kHz mono 16-bit audio;
/// encoded frames are returned byte-aligned as Codec2 packs them. Call
/// [dispose] when done.
class Codec2 {
  final Codec2Mode mode;
  final _Bindings _b;
  Pointer<Void> _state;
  late final int bitsPerFrame = _b.bitsPerFrame(_state);
  late final int bytesPerFrame = _b.bytesPerFrame(_state);
  late final int samplesPerFrame = _b.samplesPerFrame(_state);

  Codec2._(this.mode, this._b, this._state);

  factory Codec2(Codec2Mode mode) {
    final b = _load();
    final state = b.create(mode.native);
    if (state == nullptr) {
      throw StateError('codec2_create failed for $mode');
    }
    return Codec2._(mode, b, state);
  }

  /// Encodes one frame of [samplesPerFrame] samples.
  Uint8List encodeFrame(Int16List pcm) {
    if (pcm.length != samplesPerFrame) {
      throw ArgumentError.value(pcm.length, 'pcm', 'need $samplesPerFrame');
    }
    return using((arena) {
      final inPtr = arena<Int16>(samplesPerFrame);
      final outPtr = arena<Uint8>(bytesPerFrame);
      inPtr.asTypedList(samplesPerFrame).setAll(0, pcm);
      _b.encode(_state, outPtr, inPtr);
      return Uint8List.fromList(outPtr.asTypedList(bytesPerFrame));
    });
  }

  /// Decodes one frame of [bytesPerFrame] bytes.
  Int16List decodeFrame(Uint8List bits) {
    if (bits.length != bytesPerFrame) {
      throw ArgumentError.value(bits.length, 'bits', 'need $bytesPerFrame');
    }
    return using((arena) {
      final inPtr = arena<Uint8>(bytesPerFrame);
      final outPtr = arena<Int16>(samplesPerFrame);
      inPtr.asTypedList(bytesPerFrame).setAll(0, bits);
      _b.decode(_state, outPtr, inPtr);
      return Int16List.fromList(outPtr.asTypedList(samplesPerFrame));
    });
  }

  void dispose() {
    if (_state == nullptr) return;
    _b.destroy(_state);
    _state = nullptr;
  }
}
