import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../connector/meshcore_protocol.dart' show utf8BoundaryLength;

/// Where the position in an SOS came from, in priority order.
enum SosLocationSource {
  phoneGps('Phone GPS'),
  radio('Radio location'),
  stored('Stored location'),
  none('None');

  /// Fixed English label sent on the wire so every client can read it.
  final String wireLabel;
  const SosLocationSource(this.wireLabel);

  static SosLocationSource fromWireLabel(String label) {
    final wanted = label.trim().toLowerCase();
    for (final source in values) {
      if (source.wireLabel.toLowerCase() == wanted) return source;
    }
    return SosLocationSource.none;
  }
}

class SosFix {
  final double? latitude;
  final double? longitude;
  final SosLocationSource source;

  const SosFix({this.latitude, this.longitude, required this.source});

  const SosFix.none()
    : latitude = null,
      longitude = null,
      source = SosLocationSource.none;

  bool get hasPosition => latitude != null && longitude != null;
}

class SosPayload {
  final String id;
  final String? node;
  final SosFix fix;

  /// The sender's line of text, such as a short address (`Info:` line).
  final String? info;

  const SosPayload({required this.id, required this.fix, this.node, this.info});
}

/// Plain-text SOS and ACK messages carried in ordinary MeshCore text frames.
///
/// ```
/// *** EMERGENCY SOS *** #a1b2
/// Node: <node>          (direct messages only)
/// Info: <text>          (optional, e.g. a short address)
/// Time: 10-21 14:32Z
/// Source: Phone GPS
/// Lat: -45.12345
/// Lon: -122.54321
/// Reply ACK #a1b2
/// ```
///
/// Cancelling sends `*** SOS CANCELLED *** #a1b2`, the time, and a line
/// saying the sender cancelled it.
class SosCodec {
  static const String header = '*** EMERGENCY SOS ***';
  static const String cancelHeader = '*** SOS CANCELLED ***';
  static final RegExp _cancelLine = RegExp(
    r'^\*\*\* SOS CANCELLED \*\*\* #([0-9a-f]{4})$',
  );
  static final RegExp _headerLine = RegExp(
    r'^\*\*\* EMERGENCY SOS \*\*\* #([0-9a-f]{4})$',
  );
  static final RegExp _ack = RegExp(
    r'^ACK #([0-9a-f]{4})$',
    caseSensitive: false,
  );

  static String newId([Random? random]) => (random ?? Random.secure())
      .nextInt(0x10000)
      .toRadixString(16)
      .padLeft(4, '0');

  /// True for text that must be sent byte-for-byte (no Smaz or Cyr2Lat).
  static bool isStructured(String text) {
    final trimmed = text.trim();
    return trimmed.startsWith(header) ||
        trimmed.startsWith(cancelHeader) ||
        _ack.hasMatch(trimmed);
  }

  /// [node] is included for direct messages; on a channel the radio already
  /// prefixes the sender name. A [node] too long for [maxBytes] is shortened.
  static String encodeSos({
    required String id,
    required DateTime time,
    required SosFix fix,
    String? node,
    String? info,
    int? maxBytes,
  }) {
    String build(String? nodeName) => [
      '$header #$id',
      if (nodeName != null && nodeName.isNotEmpty) 'Node: $nodeName',
      if (info != null && info.isNotEmpty) 'Info: $info',
      'Time: ${formatTime(time)}',
      'Source: ${fix.source.wireLabel}',
      if (fix.hasPosition) 'Lat: ${fix.latitude!.toStringAsFixed(5)}',
      if (fix.hasPosition) 'Lon: ${fix.longitude!.toStringAsFixed(5)}',
      'Reply ACK #$id',
    ].join('\n');

    var name = node;
    var text = build(name);
    while (maxBytes != null &&
        name != null &&
        name.isNotEmpty &&
        utf8.encode(text).length > maxBytes) {
      name = name.substring(0, name.length - 1);
      text = build(name);
    }
    return text;
  }

  static String formatTime(DateTime time) {
    final utc = time.toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(utc.month)}-${two(utc.day)} '
        '${two(utc.hour)}:${two(utc.minute)}Z';
  }

  static SosPayload? parseSos(String text) {
    final lines = const LineSplitter()
        .convert(text.trim())
        .map((line) => line.trim())
        .toList();
    if (lines.isEmpty) return null;
    final match = _headerLine.firstMatch(lines.first);
    if (match == null) return null;

    final fields = <String, String>{};
    for (final line in lines.skip(1)) {
      final colon = line.indexOf(':');
      if (colon <= 0) continue;
      fields[line.substring(0, colon).trim().toLowerCase()] = line
          .substring(colon + 1)
          .trim();
    }
    final lat = double.tryParse(fields['lat'] ?? '');
    final lon = double.tryParse(fields['lon'] ?? '');
    final valid =
        lat != null && lon != null && lat.abs() <= 90 && lon.abs() <= 180;
    final info = fields['info'];
    return SosPayload(
      id: match.group(1)!,
      node: fields['node'],
      info: info == null || info.isEmpty ? null : info,
      fix: valid
          ? SosFix(
              latitude: lat,
              longitude: lon,
              source: SosLocationSource.fromWireLabel(fields['source'] ?? ''),
            )
          : const SosFix.none(),
    );
  }

  static String encodeAck(String id) => 'ACK #$id';

  static String? parseAck(String text) =>
      _ack.firstMatch(text.trim())?.group(1)?.toLowerCase();

  static String encodeCancel(String id, DateTime time) => [
    '$cancelHeader #$id',
    'Time: ${formatTime(time)}',
    'The sender cancelled this SOS.',
  ].join('\n');

  static String? parseCancel(String text) {
    final firstLine = const LineSplitter().convert(text.trim()).firstOrNull;
    return firstLine == null
        ? null
        : _cancelLine.firstMatch(firstLine.trim())?.group(1);
  }
}

/// GRP_DATA type for SOS packets ("SP"). Clients that do not know it drop
/// the packet, so an SOS on a channel never lands in any chat history.
const int dataTypeSos = 0x5053;

enum SosPacketKind {
  sos(1),
  ack(2),
  cancel(3),

  /// A responder asks the SOS sender to send [beacon]s, to home in on it.
  locate(4),

  /// Sent zero hop by the SOS sender while someone is locating it: only radios
  /// in direct range hear one, so its signal strength says how near it is.
  beacon(5);

  final int code;
  const SosPacketKind(this.code);
}

/// A binary SOS, ACK or cancellation sent as channel data.
///
/// Layout (little-endian):
/// `[version=1][kind][id u16][sender key prefix x6][name len][name...]`
/// then for an SOS `[time u32][source][has position][lat i32][lon i32]`
/// (degrees x 1e6), or for a cancellation `[time u32]`.
///
/// An SOS may carry, after the full key, `[info len][info...]`: a line of
/// text such as a short address, sent by the MeshCore SOS button firmware.
///
/// A locate request is just the header up to the name; a beacon adds
/// `[seq]`. Builds before 9.5.3 don't know these kinds and ignore them.
class SosPacket {
  static const int version = 1;
  static const int keyPrefixSize = 6;
  static const int publicKeySize = 32;
  static const int maxNameBytes = 31;
  static const int maxInfoBytes = 32;

  final SosPacketKind kind;
  final String id;
  final Uint8List senderPrefix;
  final String senderName;
  final DateTime? time;
  final SosFix fix;

  /// The sender's full public key, so SOS and ACK let each side add the
  /// other as a contact. Appended after the fields older builds read, which
  /// ignore it.
  final Uint8List? senderKey;

  /// The sender's line of text, if any. Only sent with an SOS that also
  /// carries [senderKey]; older builds stop reading before it.
  final String? info;

  /// A beacon's number, counting up from 0; null for other kinds.
  final int? seq;

  const SosPacket({
    required this.kind,
    required this.id,
    required this.senderPrefix,
    required this.senderName,
    this.time,
    this.fix = const SosFix.none(),
    this.senderKey,
    this.info,
    this.seq,
  });

  bool get _carriesKey =>
      kind != SosPacketKind.cancel && senderKey?.length == publicKeySize;

  Uint8List encode() {
    final out = BytesBuilder()
      ..addByte(version)
      ..addByte(kind.code);
    final idValue = int.parse(id, radix: 16);
    out
      ..addByte(idValue & 0xFF)
      ..addByte((idValue >> 8) & 0xFF)
      ..add(_prefix(senderPrefix));
    var name = utf8.encode(senderName);
    if (name.length > maxNameBytes) name = name.sublist(0, maxNameBytes);
    out
      ..addByte(name.length)
      ..add(name);
    if (kind == SosPacketKind.locate) return out.toBytes();
    if (kind == SosPacketKind.beacon) {
      out.addByte((seq ?? 0) & 0xFF);
      return out.toBytes();
    }
    if (kind == SosPacketKind.ack) {
      if (_carriesKey) out.add(senderKey!);
      return out.toBytes();
    }
    final seconds = (time ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    out.add(_u32(seconds));
    if (kind == SosPacketKind.cancel) return out.toBytes();
    out
      ..addByte(fix.source.index)
      ..addByte(fix.hasPosition ? 1 : 0)
      ..add(_i32(((fix.latitude ?? 0) * 1e6).round()))
      ..add(_i32(((fix.longitude ?? 0) * 1e6).round()));
    if (_carriesKey) {
      out.add(senderKey!);
      var infoBytes = utf8.encode(info ?? '');
      if (infoBytes.length > maxInfoBytes) {
        infoBytes = infoBytes.sublist(
          0,
          utf8BoundaryLength(infoBytes, maxInfoBytes),
        );
      }
      if (infoBytes.isNotEmpty) {
        out
          ..addByte(infoBytes.length)
          ..add(infoBytes);
      }
    }
    return out.toBytes();
  }

  static SosPacket? decode(Uint8List data) {
    try {
      if (data.length < 11 || data[0] != version) return null;
      final kind = SosPacketKind.values
          .where((k) => k.code == data[1])
          .firstOrNull;
      if (kind == null) return null;
      final id = (data[2] | (data[3] << 8)).toRadixString(16).padLeft(4, '0');
      final prefix = Uint8List.fromList(data.sublist(4, 4 + keyPrefixSize));
      final nameLength = data[10];
      var offset = 11;
      if (data.length < offset + nameLength) return null;
      final name = utf8.decode(
        data.sublist(offset, offset + nameLength),
        allowMalformed: true,
      );
      offset += nameLength;
      if (kind == SosPacketKind.locate || kind == SosPacketKind.beacon) {
        return SosPacket(
          kind: kind,
          id: id,
          senderPrefix: prefix,
          senderName: name,
          seq: kind == SosPacketKind.beacon && data.length > offset
              ? data[offset]
              : null,
        );
      }
      if (kind == SosPacketKind.ack) {
        return SosPacket(
          kind: kind,
          id: id,
          senderPrefix: prefix,
          senderName: name,
          senderKey: _readKey(data, offset, prefix),
        );
      }
      if (data.length < offset + 4) return null;
      final time = DateTime.fromMillisecondsSinceEpoch(
        _readU32(data, offset) * 1000,
      );
      offset += 4;
      if (kind == SosPacketKind.cancel) {
        return SosPacket(
          kind: kind,
          id: id,
          senderPrefix: prefix,
          senderName: name,
          time: time,
        );
      }
      if (data.length < offset + 10) return null;
      final sourceIndex = data[offset];
      final hasPosition = data[offset + 1] == 1;
      final lat = _readI32(data, offset + 2) / 1e6;
      final lon = _readI32(data, offset + 6) / 1e6;
      final valid = hasPosition && lat.abs() <= 90 && lon.abs() <= 180;
      final senderKey = _readKey(data, offset + 10, prefix);
      return SosPacket(
        kind: kind,
        id: id,
        senderPrefix: prefix,
        senderName: name,
        time: time,
        senderKey: senderKey,
        info: senderKey == null
            ? null
            : _readInfo(data, offset + 10 + publicKeySize),
        fix: valid
            ? SosFix(
                latitude: lat,
                longitude: lon,
                source: sourceIndex < SosLocationSource.values.length
                    ? SosLocationSource.values[sourceIndex]
                    : SosLocationSource.none,
              )
            : const SosFix.none(),
      );
    } catch (_) {
      return null;
    }
  }

  /// The optional full key at [offset]; null unless it matches [prefix].
  static Uint8List? _readKey(Uint8List data, int offset, Uint8List prefix) {
    if (data.length < offset + publicKeySize) return null;
    final key = Uint8List.fromList(
      data.sublist(offset, offset + publicKeySize),
    );
    for (var i = 0; i < keyPrefixSize; i++) {
      if (key[i] != prefix[i]) return null;
    }
    return key;
  }

  /// The optional `[len][text]` at [offset]; null if absent or malformed.
  static String? _readInfo(Uint8List data, int offset) {
    if (data.length <= offset) return null;
    final length = data[offset];
    if (length == 0 ||
        length > maxInfoBytes ||
        data.length < offset + 1 + length) {
      return null;
    }
    final text = utf8
        .decode(
          data.sublist(offset + 1, offset + 1 + length),
          allowMalformed: true,
        )
        .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ')
        .trim();
    return text.isEmpty ? null : text;
  }

  static Uint8List _prefix(Uint8List key) {
    final out = Uint8List(keyPrefixSize);
    out.setRange(0, min(keyPrefixSize, key.length), key);
    return out;
  }

  static List<int> _u32(int v) => [
    v & 0xFF,
    (v >> 8) & 0xFF,
    (v >> 16) & 0xFF,
    (v >> 24) & 0xFF,
  ];

  static List<int> _i32(int v) => _u32(v & 0xFFFFFFFF);

  static int _readU32(Uint8List d, int o) =>
      d[o] | (d[o + 1] << 8) | (d[o + 2] << 16) | (d[o + 3] << 24);

  static int _readI32(Uint8List d, int o) {
    final v = _readU32(d, o);
    return v >= 0x80000000 ? v - 0x100000000 : v;
  }
}

/// How a packet was heard: its signal-to-noise ratio, whether it came straight
/// from the sender's radio (no repeater between), and its received signal
/// strength when the radio's raw packet log gave it.
class SosSignal {
  final double snrDb;
  final bool direct;
  final int? rssiDbm;

  const SosSignal({required this.snrDb, required this.direct, this.rssiDbm});

  static const unknown = SosSignal(snrDb: 0, direct: false);
}
