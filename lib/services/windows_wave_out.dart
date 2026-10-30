import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:win32/win32.dart';

/// The format and samples of a PCM WAV file.
@immutable
class WavPcm {
  final int sampleRate;
  final int channels;
  final int bitsPerSample;
  final Uint8List samples;

  const WavPcm(
    this.sampleRate,
    this.channels,
    this.bitsPerSample,
    this.samples,
  );

  /// Reads a PCM WAV file; null if it isn't one.
  static WavPcm? parse(Uint8List wav) {
    if (wav.length < 12) return null;
    final data = ByteData.sublistView(wav);
    String tag(int at) => String.fromCharCodes(wav.sublist(at, at + 4));
    if (tag(0) != 'RIFF' || tag(8) != 'WAVE') return null;
    int? rate, channels, bits;
    var at = 12;
    while (at + 8 <= wav.length) {
      final id = tag(at);
      final size = data.getUint32(at + 4, Endian.little);
      final body = at + 8;
      if (id == 'fmt ' && body + 16 <= wav.length) {
        if (data.getUint16(body, Endian.little) != 1) return null; // not PCM
        channels = data.getUint16(body + 2, Endian.little);
        rate = data.getUint32(body + 4, Endian.little);
        bits = data.getUint16(body + 14, Endian.little);
      } else if (id == 'data' && rate != null) {
        final end = (body + size).clamp(body, wav.length);
        return WavPcm(rate, channels!, bits!, wav.sublist(body, end));
      }
      at = body + size + (size & 1); // chunks are padded to even sizes
    }
    return null;
  }
}

/// Windows: plays sound on a chosen speaker with the system's waveOut API,
/// so only this app's sound goes there and Windows' default stays as it is.
class WindowsWaveOut {
  static const _waveMapper = 0xFFFFFFFF; // the default speaker
  static const _whdrDone = 0x00000001;

  Pointer<Pointer>? _handle;
  Pointer<WAVEHDR>? _header;
  Pointer<Uint8>? _buffer;
  Pointer<WAVEFORMATEX>? _format;
  Timer? _poll;
  Completer<void>? _done;

  /// The speakers' names, in the system's order.
  static List<String> deviceNames() {
    final names = <String>[];
    final caps = calloc<WAVEOUTCAPS>();
    try {
      final count = waveOutGetNumDevs();
      for (var i = 0; i < count; i++) {
        if (waveOutGetDevCaps(i, caps, sizeOf<WAVEOUTCAPS>()) ==
            MMSYSERR_NOERROR) {
          names.add(caps.ref.szPname);
        }
      }
    } finally {
      calloc.free(caps);
    }
    return names;
  }

  /// Plays [wav] (16-bit PCM) on the speaker named [device], or the default
  /// if it's null or not found. Completes when it has played or [stop] ran;
  /// false if it couldn't play at all.
  Future<bool> play(Uint8List wav, {String? device}) async {
    stop();
    final pcm = WavPcm.parse(wav);
    if (pcm == null || pcm.samples.isEmpty) return false;
    final index = device == null ? -1 : deviceNames().indexOf(device);
    final id = index < 0 ? _waveMapper : index;

    final format = calloc<WAVEFORMATEX>();
    format.ref
      ..wFormatTag = WAVE_FORMAT_PCM
      ..nChannels = pcm.channels
      ..nSamplesPerSec = pcm.sampleRate
      ..wBitsPerSample = pcm.bitsPerSample
      ..nBlockAlign = pcm.channels * pcm.bitsPerSample ~/ 8
      ..nAvgBytesPerSec = pcm.sampleRate * pcm.channels * pcm.bitsPerSample ~/ 8
      ..cbSize = 0;
    final handle = calloc<Pointer>();
    _format = format;
    _handle = handle;
    if (waveOutOpen(handle, id, format, null, null, CALLBACK_NULL) !=
        MMSYSERR_NOERROR) {
      _free();
      return false;
    }

    final buffer = calloc<Uint8>(pcm.samples.length);
    buffer.asTypedList(pcm.samples.length).setAll(0, pcm.samples);
    final header = calloc<WAVEHDR>();
    header.ref
      ..lpData = PSTR(buffer.cast<Utf8>())
      ..dwBufferLength = pcm.samples.length;
    _buffer = buffer;
    _header = header;
    final out = HWAVEOUT(handle.value);
    if (waveOutPrepareHeader(out, header, sizeOf<WAVEHDR>()) !=
            MMSYSERR_NOERROR ||
        waveOutWrite(out, header, sizeOf<WAVEHDR>()) != MMSYSERR_NOERROR) {
      _close();
      return false;
    }

    final done = Completer<void>();
    _done = done;
    _poll = Timer.periodic(const Duration(milliseconds: 40), (_) {
      if (header.ref.dwFlags & _whdrDone != 0) _close();
    });
    await done.future;
    return true;
  }

  /// Stops what's playing.
  void stop() {
    final handle = _handle;
    if (handle != null && handle.value != nullptr) {
      waveOutReset(HWAVEOUT(handle.value));
    }
    _close();
  }

  void _close() {
    _poll?.cancel();
    _poll = null;
    final handle = _handle;
    final header = _header;
    if (handle != null && handle.value != nullptr) {
      final out = HWAVEOUT(handle.value);
      if (header != null) {
        waveOutUnprepareHeader(out, header, sizeOf<WAVEHDR>());
      }
      waveOutClose(out);
    }
    _free();
    final done = _done;
    _done = null;
    if (done != null && !done.isCompleted) done.complete();
  }

  void _free() {
    for (final p in [_header, _buffer, _format, _handle]) {
      if (p != null) calloc.free(p);
    }
    _header = null;
    _buffer = null;
    _format = null;
    _handle = null;
  }
}
