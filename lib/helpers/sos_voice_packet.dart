import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

/// GRP_DATA type for SOS voice chunks ("SV"). Like [dataTypeSos], clients
/// that do not know it drop the packet, so voice never lands in chat history.
const int dataTypeSosVoice = 0x5356;

/// Codec2 quality for a voice clip.
enum SosVoiceQuality {
  /// Codec2 700C: 28 bits per 40 ms frame, about 88 bytes a second.
  low(0, 28, Duration(seconds: 20)),

  /// Codec2 1300: 52 bits per 40 ms frame, about 163 bytes a second.
  clear(1, 52, Duration(seconds: 10));

  final int code;
  final int bitsPerFrame;

  /// Longest clip, which keeps it within [SosVoicePacket.maxChunks].
  final Duration maxClip;

  const SosVoiceQuality(this.code, this.bitsPerFrame, this.maxClip);

  static SosVoiceQuality? fromCode(int code) =>
      values.where((q) => q.code == code).firstOrNull;

  /// Frames that fit in one chunk.
  int get framesPerChunk => SosVoicePacket.maxBodyBytes * 8 ~/ bitsPerFrame;

  int get maxFrames => maxClip.inMilliseconds ~/ SosVoicePacket.frameMs;
}

/// One chunk of a voice clip, sent as channel data during an SOS.
///
/// Layout (little-endian):
/// `[version=1][quality][sos id u16][sender key prefix x6][clip id u16]`
/// `[index][total][frame count][Codec2 frames, bit-packed MSB first]`
///
/// Every chunk holds whole frames, so a clip with a lost chunk still plays,
/// with a gap where the chunk was.
class SosVoicePacket {
  static const int version = 1;
  static const int keyPrefixSize = 6;
  static const int headerBytes = 15;

  /// Largest blob the companion firmware accepts as channel data.
  static const int maxBlobBytes = 163;
  static const int maxBodyBytes = maxBlobBytes - headerBytes;
  static const int maxChunks = 12;

  /// Codec2 frames are 40 ms of 8 kHz audio.
  static const int frameMs = 40;
  static const int sampleRate = 8000;
  static const int samplesPerFrame = sampleRate * frameMs ~/ 1000;

  final SosVoiceQuality quality;
  final String sosId;
  final Uint8List senderPrefix;
  final int clipId;
  final int index;
  final int total;

  /// Codec2 frames as the codec produces them, byte-aligned.
  final List<Uint8List> frames;

  SosVoicePacket({
    required this.quality,
    required this.sosId,
    required this.senderPrefix,
    required this.clipId,
    required this.index,
    required this.total,
    required this.frames,
  });

  Uint8List encode() {
    final id = int.parse(sosId, radix: 16);
    final out = BytesBuilder()
      ..addByte(version)
      ..addByte(quality.code)
      ..addByte(id & 0xFF)
      ..addByte((id >> 8) & 0xFF)
      ..add(senderPrefix.sublist(0, keyPrefixSize))
      ..addByte(clipId & 0xFF)
      ..addByte((clipId >> 8) & 0xFF)
      ..addByte(index)
      ..addByte(total)
      ..addByte(frames.length)
      ..add(packFrames(frames, quality.bitsPerFrame));
    return out.toBytes();
  }

  static SosVoicePacket? decode(Uint8List data) {
    if (data.length < headerBytes || data[0] != version) return null;
    final quality = SosVoiceQuality.fromCode(data[1]);
    if (quality == null) return null;
    final index = data[12];
    final total = data[13];
    final count = data[14];
    if (total == 0 || total > maxChunks || index >= total) return null;
    if (count == 0 || count > quality.framesPerChunk) return null;
    final bodyBytes = (count * quality.bitsPerFrame + 7) ~/ 8;
    if (data.length < headerBytes + bodyBytes) return null;
    final id = data[2] | (data[3] << 8);
    return SosVoicePacket(
      quality: quality,
      sosId: id.toRadixString(16).padLeft(4, '0'),
      senderPrefix: Uint8List.fromList(data.sublist(4, 4 + keyPrefixSize)),
      clipId: data[10] | (data[11] << 8),
      index: index,
      total: total,
      frames: unpackFrames(
        Uint8List.sublistView(data, headerBytes),
        count,
        quality.bitsPerFrame,
      ),
    );
  }

  /// Splits a clip's frames into chunk packets, dropping frames past the
  /// quality's limit.
  static List<SosVoicePacket> split({
    required List<Uint8List> frames,
    required SosVoiceQuality quality,
    required String sosId,
    required Uint8List senderPrefix,
    required int clipId,
  }) {
    final kept = frames.take(quality.maxFrames).toList();
    if (kept.isEmpty) return const [];
    final per = quality.framesPerChunk;
    final total = (kept.length + per - 1) ~/ per;
    return [
      for (var i = 0; i < total; i++)
        SosVoicePacket(
          quality: quality,
          sosId: sosId,
          senderPrefix: senderPrefix,
          clipId: clipId,
          index: i,
          total: total,
          frames: kept.sublist(i * per, min((i + 1) * per, kept.length)),
        ),
    ];
  }
}

/// Packs the first [bitsPerFrame] bits of each frame into one bitstream.
/// Codec2 fills its byte-aligned frames most significant bit first.
@visibleForTesting
Uint8List packFrames(List<Uint8List> frames, int bitsPerFrame) {
  final out = Uint8List((frames.length * bitsPerFrame + 7) ~/ 8);
  var bit = 0;
  for (final frame in frames) {
    for (var i = 0; i < bitsPerFrame; i++) {
      if ((frame[i >> 3] >> (7 - (i & 7))) & 1 == 1) {
        out[bit >> 3] |= 0x80 >> (bit & 7);
      }
      bit++;
    }
  }
  return out;
}

/// Reverses [packFrames], returning byte-aligned frames.
@visibleForTesting
List<Uint8List> unpackFrames(Uint8List data, int count, int bitsPerFrame) {
  final bytesPerFrame = (bitsPerFrame + 7) ~/ 8;
  var bit = 0;
  return [
    for (var f = 0; f < count; f++)
      () {
        final frame = Uint8List(bytesPerFrame);
        for (var i = 0; i < bitsPerFrame; i++) {
          if ((data[bit >> 3] >> (7 - (bit & 7))) & 1 == 1) {
            frame[i >> 3] |= 0x80 >> (i & 7);
          }
          bit++;
        }
        return frame;
      }(),
  ];
}

/// A clip put back together from its chunks. Missing chunks are null.
class SosVoiceClipFrames {
  final SosVoiceQuality quality;
  final String sosId;
  final Uint8List senderPrefix;
  final int clipId;

  /// One entry per chunk; null where a chunk never arrived.
  final List<List<Uint8List>?> chunks;

  SosVoiceClipFrames({
    required this.quality,
    required this.sosId,
    required this.senderPrefix,
    required this.clipId,
    required this.chunks,
  });

  int get received => chunks.whereType<List<Uint8List>>().length;
  bool get isComplete => received == chunks.length;

  /// The frames in order, with null for each frame of a missing chunk.
  List<Uint8List?> get frames => [
    for (final chunk in chunks)
      if (chunk == null)
        ...List<Uint8List?>.filled(quality.framesPerChunk, null)
      else
        ...chunk,
  ];

  Duration get duration =>
      Duration(milliseconds: frames.length * SosVoicePacket.frameMs);
}

/// Collects chunks into clips. A clip is done when every chunk has arrived,
/// or [idleTimeout] after its last chunk; a clip missing its last chunk, or
/// more than half its chunks, is dropped.
class SosVoiceAssembler {
  final Duration idleTimeout;
  final DateTime Function() _now;
  final Map<String, _PendingClip> _pending = {};

  SosVoiceAssembler({
    this.idleTimeout = const Duration(seconds: 8),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  static String _key(SosVoicePacket p) =>
      '${p.senderPrefix.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}'
      ':${p.clipId}';

  /// Adds a chunk; returns the clip if this chunk completed it.
  SosVoiceClipFrames? add(SosVoicePacket packet) {
    final key = _key(packet);
    final pending = _pending[key];
    if (pending != null &&
        (pending.clip.chunks.length != packet.total ||
            pending.clip.quality != packet.quality)) {
      _pending.remove(key); // A different clip reusing the ID.
    }
    final entry = _pending.putIfAbsent(
      key,
      () => _PendingClip(
        SosVoiceClipFrames(
          quality: packet.quality,
          sosId: packet.sosId,
          senderPrefix: packet.senderPrefix,
          clipId: packet.clipId,
          chunks: List<List<Uint8List>?>.filled(packet.total, null),
        ),
      ),
    );
    entry.clip.chunks[packet.index] ??= packet.frames;
    entry.lastChunk = _now();
    if (!entry.clip.isComplete) return null;
    _pending.remove(key);
    return entry.clip;
  }

  /// Clips that stopped receiving chunks and are worth playing.
  List<SosVoiceClipFrames> takeStale() {
    final cutoff = _now().subtract(idleTimeout);
    final stale = _pending.entries
        .where((e) => e.value.lastChunk.isBefore(cutoff))
        .toList();
    for (final e in stale) {
      _pending.remove(e.key);
    }
    return [
      for (final e in stale)
        if (e.value.clip.chunks.last != null &&
            e.value.clip.received * 2 >= e.value.clip.chunks.length)
          e.value.clip,
    ];
  }

  bool get hasPending => _pending.isNotEmpty;
}

class _PendingClip {
  final SosVoiceClipFrames clip;
  late DateTime lastChunk;

  _PendingClip(this.clip);
}
