import 'dart:convert';
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

  /// Longest clip, which keeps it within [SosVoicePacket.maxChunks], sealed
  /// or not.
  final Duration maxClip;

  const SosVoiceQuality(this.code, this.bitsPerFrame, this.maxClip);

  static SosVoiceQuality? fromCode(int code) =>
      values.where((q) => q.code == code).firstOrNull;

  /// Frames that fit in one chunk.
  int get framesPerChunk => SosVoicePacket.maxBodyBytes * 8 ~/ bitsPerFrame;

  /// Frames that fit in one chunk sealed on an SOS2 network, which leaves
  /// [SosVoicePacket.sealOverhead] bytes less for audio.
  int get sealedFramesPerChunk =>
      (SosVoicePacket.maxBodyBytes - SosVoicePacket.sealOverhead) *
      8 ~/
      bitsPerFrame;

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
///
/// On an SOS2 network each chunk is sealed with its SOS's keys (see
/// `SosSeal`): `[2][quality][sos id u16][ref x4][nonce x6]`, then the rest
/// of the chunk after its first 4 bytes, encrypted, and an 8-byte tag. Only
/// the sender and the network's responders can play it.
///
/// Push-to-talk clips (10.0.0), outside an SOS, use the same layout with
/// version [pttVersion] and the SOS id 0: on the public Voice channel as
/// channel data, or in a direct message as text ([toDirectText]).
class SosVoicePacket {
  static const int version = 1;

  /// A push-to-talk chunk.
  static const int pttVersion = 3;

  /// A push-to-talk clip in a direct message takes more, smaller chunks.
  static const int maxPttChunks = 24;

  /// What starts a direct message holding a push-to-talk chunk.
  static const String directPrefix = '~ptt1:';

  /// Direct message text the companion firmware takes, with room to spare.
  static const int maxDirectText = 150;

  /// Audio bytes in a direct-message chunk, after base64 and the header.
  static const int directBodyBytes =
      (maxDirectText - directPrefix.length) * 3 ~/ 4 - headerBytes;
  static const int keyPrefixSize = 6;
  static const int headerBytes = 15;

  /// Largest blob the companion firmware accepts as channel data.
  static const int maxBlobBytes = 163;
  static const int maxBodyBytes = maxBlobBytes - headerBytes;

  /// What sealing adds: the ref, nonce and tag, less the 4 bytes the sealed
  /// header repeats.
  static const int sealOverhead = 18;

  /// 12 chunks hold the longest clip unsealed, 14 sealed.
  static const int maxChunks = 14;

  /// Codec2 frames are 40 ms of 8 kHz audio.
  static const int frameMs = 40;
  static const int sampleRate = 8000;
  static const int samplesPerFrame = sampleRate * frameMs ~/ 1000;

  final SosVoiceQuality quality;
  final String sosId;
  final bool ptt;
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
    this.ptt = false,
  });

  /// The same chunk filed under another conversation (a push-to-talk chunk
  /// carries no SOS id).
  SosVoicePacket withSosId(String id) => SosVoicePacket(
    quality: quality,
    sosId: id,
    senderPrefix: senderPrefix,
    clipId: clipId,
    index: index,
    total: total,
    frames: frames,
    ptt: ptt,
  );

  /// Frames in one direct-message chunk at [quality].
  static int directFramesPerChunk(SosVoiceQuality quality) =>
      directBodyBytes * 8 ~/ quality.bitsPerFrame;

  /// This chunk as the text of a direct message.
  String toDirectText() => '$directPrefix${base64Encode(encode())}';

  /// A push-to-talk chunk from a direct message's text; null if it isn't one.
  static SosVoicePacket? fromDirectText(String text) {
    if (!text.startsWith(directPrefix)) return null;
    try {
      final packet = decode(base64Decode(text.substring(directPrefix.length)));
      return packet != null && packet.ptt ? packet : null;
    } on FormatException {
      return null;
    }
  }

  Uint8List encode() {
    final id = ptt ? 0 : int.parse(sosId, radix: 16);
    final out = BytesBuilder()
      ..addByte(ptt ? pttVersion : version)
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
    if (data.length < headerBytes) return null;
    final ptt = data[0] == pttVersion;
    if (data[0] != version && !ptt) return null;
    final quality = SosVoiceQuality.fromCode(data[1]);
    if (quality == null) return null;
    final index = data[12];
    final total = data[13];
    final count = data[14];
    final most = ptt ? maxPttChunks : maxChunks;
    if (total == 0 || total > most || index >= total) return null;
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
      ptt: ptt,
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
    bool sealed = false,
    bool ptt = false,
    int? framesPerChunk,
  }) {
    final kept = frames.take(quality.maxFrames).toList();
    if (kept.isEmpty) return const [];
    final per =
        framesPerChunk ??
        (sealed ? quality.sealedFramesPerChunk : quality.framesPerChunk);
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
          ptt: ptt,
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

  /// The frames in order, with null for each frame of a missing chunk (as
  /// many as the largest chunk that arrived holds).
  List<Uint8List?> get frames {
    final per = chunks.whereType<List<Uint8List>>().fold<int>(
      0,
      (most, c) => max(most, c.length),
    );
    final gap = per == 0 ? quality.framesPerChunk : per;
    return [
      for (final chunk in chunks)
        if (chunk == null) ...List<Uint8List?>.filled(gap, null) else ...chunk,
    ];
  }

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
