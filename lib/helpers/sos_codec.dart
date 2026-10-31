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
  beacon(5),

  /// A searcher sharing what they hear: their own position and the beacon's
  /// strength there, so every searcher's map can combine them (9.8.0).
  report(6),

  /// A responder retuning their radio to an SOS sender's settings, for
  /// instance to cross a bridge to the sender's frequency, and so maybe out of
  /// reach on this one; or back again (9.8.3).
  retune(7),

  /// A searcher left the Locate screen (9.8.4, radio firmware 1.8.2): just the
  /// header. When the last one has stopped, the SOS sender's beacons stop and
  /// go back to full power, so a later search starts at full power.
  stopLocate(8);

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
/// text such as a short address, sent by a MeshCore SOS radio.
///
/// A locate request is just the header up to the name; a beacon adds
/// `[seq]`. Builds before 9.5.3 don't know these kinds and ignore them.
///
/// A coordinated search (9.8.0, MeshCore SOS firmware 1.6.1): a locate
/// request may add `[power i8]`, the dBm any searcher asks the beacons to go
/// at ([powerFull]: the radio's own); a beacon then adds `[power i8][flags,
/// bit 0 full power][set-by len][set-by]`. A [SosPacketKind.report] is the
/// header plus `[lat i32][lon i32][rssi i8][snr i8, 1/4 dB][beacon power i8]
/// [age secs u8]`. Older builds skip the bytes they don't know.
///
/// Radio settings (9.8.3, MeshCore SOS firmware 1.7.0): an SOS may end, after
/// the full key and an info length byte (written as 0 when there is no info,
/// so older builds read no info), with the sender's radio settings
/// ([SosRadio], 5 bytes). A [SosPacketKind.retune] is the header plus
/// `[flags, bit 0 back][radio settings]`: the settings the responder is
/// moving to, or (back) returning to.
class SosPacket {
  static const int version = 1;
  static const int keyPrefixSize = 6;
  static const int publicKeySize = 32;
  static const int maxNameBytes = 31;
  static const int maxInfoBytes = 32;
  static const int maxSetByBytes = 16;

  /// In a locate request: back to the radio's own TX power.
  static const int powerFull = 127;

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

  /// A locate request: the beacon power asked for (dBm, or [powerFull]); null
  /// asks for no change. A beacon: the power it was sent at, null when the
  /// sender doesn't say (a phone app's, or an older radio's).
  final int? power;

  /// A beacon sent at the radio's own power (nobody has turned it down).
  final bool fullPower;

  /// A beacon: who last set its power; empty when nobody has.
  final String setBy;

  /// A [SosPacketKind.report]'s reading.
  final SosReading? reading;

  /// An SOS: the sender's radio settings, when it says. A retune: the
  /// settings the responder is moving to, or returning to when [back].
  final SosRadio? radio;

  /// A retune: back on their own settings.
  final bool back;

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
    this.power,
    this.fullPower = false,
    this.setBy = '',
    this.reading,
    this.radio,
    this.back = false,
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
    if (kind == SosPacketKind.locate) {
      if (power != null) out.addByte(power! & 0xFF);
      return out.toBytes();
    }
    if (kind == SosPacketKind.stopLocate) return out.toBytes();
    if (kind == SosPacketKind.retune) {
      out
        ..addByte(back ? 1 : 0)
        ..add(radio!.encode());
      return out.toBytes();
    }
    if (kind == SosPacketKind.beacon) {
      out.addByte((seq ?? 0) & 0xFF);
      if (power != null) {
        var by = utf8.encode(setBy);
        if (by.length > maxSetByBytes) {
          by = by.sublist(0, utf8BoundaryLength(by, maxSetByBytes));
        }
        out
          ..addByte(power! & 0xFF)
          ..addByte(fullPower ? 1 : 0)
          ..addByte(by.length)
          ..add(by);
      }
      return out.toBytes();
    }
    if (kind == SosPacketKind.report) {
      final r = reading!;
      out
        ..add(_i32((r.latitude * 1e6).round()))
        ..add(_i32((r.longitude * 1e6).round()))
        ..addByte(r.rssiDbm.clamp(-128, 127) & 0xFF)
        ..addByte((r.snrDb * 4).round().clamp(-128, 127) & 0xFF)
        ..addByte(r.beaconPower.clamp(-128, 127) & 0xFF)
        ..addByte(r.ageSeconds.clamp(0, 255));
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
      // The radio settings take their room from the info, so the largest
      // SOS is no bigger than before (it must still fit one channel packet).
      final radioBytes = radio?.encode();
      final infoMax = radioBytes == null
          ? maxInfoBytes
          : maxInfoBytes - SosRadio.size;
      var infoBytes = utf8.encode(info ?? '');
      if (infoBytes.length > infoMax) {
        infoBytes = infoBytes.sublist(
          0,
          utf8BoundaryLength(infoBytes, infoMax),
        );
      }
      if (infoBytes.isNotEmpty || radioBytes != null) {
        out
          ..addByte(infoBytes.length)
          ..add(infoBytes);
      }
      if (radioBytes != null) out.add(radioBytes);
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
        if (kind == SosPacketKind.locate) {
          return SosPacket(
            kind: kind,
            id: id,
            senderPrefix: prefix,
            senderName: name,
            power: data.length > offset ? _i8(data[offset]) : null,
          );
        }
        int? seq;
        int? power;
        var full = false;
        var setBy = '';
        if (data.length > offset) seq = data[offset++];
        if (data.length >= offset + 2) {
          power = _i8(data[offset]);
          full = data[offset + 1] & 1 == 1;
          offset += 2;
          if (data.length > offset) {
            final n = data[offset++];
            if (n <= maxSetByBytes && data.length >= offset + n) {
              setBy = utf8.decode(
                data.sublist(offset, offset + n),
                allowMalformed: true,
              );
            }
          }
        }
        return SosPacket(
          kind: kind,
          id: id,
          senderPrefix: prefix,
          senderName: name,
          seq: seq,
          power: power,
          fullPower: full,
          setBy: setBy,
        );
      }
      if (kind == SosPacketKind.stopLocate) {
        return SosPacket(
          kind: kind,
          id: id,
          senderPrefix: prefix,
          senderName: name,
        );
      }
      if (kind == SosPacketKind.retune) {
        if (data.length <= offset) return null;
        final radio = SosRadio.decode(data, offset + 1);
        if (radio == null) return null;
        return SosPacket(
          kind: kind,
          id: id,
          senderPrefix: prefix,
          senderName: name,
          radio: radio,
          back: data[offset] & 1 == 1,
        );
      }
      if (kind == SosPacketKind.report) {
        if (data.length < offset + 12) return null;
        final lat = _readI32(data, offset) / 1e6;
        final lon = _readI32(data, offset + 4) / 1e6;
        if (lat.abs() > 90 || lon.abs() > 180) return null;
        return SosPacket(
          kind: kind,
          id: id,
          senderPrefix: prefix,
          senderName: name,
          reading: SosReading(
            latitude: lat,
            longitude: lon,
            rssiDbm: _i8(data[offset + 8]),
            snrDb: _i8(data[offset + 9]) / 4,
            beaconPower: _i8(data[offset + 10]),
            ageSeconds: data[offset + 11],
          ),
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
        radio: senderKey == null
            ? null
            : _readRadioAfterInfo(data, offset + 10 + publicKeySize),
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

  /// The radio settings after the `[len][text]` info at [offset], if any.
  static SosRadio? _readRadioAfterInfo(Uint8List data, int offset) {
    if (data.length <= offset) return null;
    final length = data[offset];
    if (length > maxInfoBytes) return null;
    return SosRadio.decode(data, offset + 1 + length);
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

  static int _i8(int b) => b >= 0x80 ? b - 0x100 : b;
}

/// What a searcher heard, and where: their own position, the beacon's
/// strength there, and the power that beacon was sent at.
class SosReading {
  final double latitude;
  final double longitude;
  final int rssiDbm;
  final double snrDb;
  final int beaconPower;
  final int ageSeconds; // how old the beacon heard was when this was sent

  const SosReading({
    required this.latitude,
    required this.longitude,
    required this.rssiDbm,
    required this.snrDb,
    required this.beaconPower,
    this.ageSeconds = 0,
  });
}

/// LoRa radio settings, as an SOS or a retune carries them: 5 bytes,
/// `[freq kHz u24][bandwidth code][sf << 4 | (cr - 4)]`. Bandwidth codes index
/// [bandwidthsHz], the LoRa bandwidths MeshCore radios use.
class SosRadio {
  /// kHz, as MeshCore's SELF_INFO and SET_RADIO_PARAMS give it.
  final int freqKhz;
  final int bwHz;
  final int sf;

  /// Coding rate denominator, 5 to 8 (4/5 to 4/8).
  final int cr;

  const SosRadio({
    required this.freqKhz,
    required this.bwHz,
    required this.sf,
    required this.cr,
  });

  static const int size = 5;
  static const List<int> bandwidthsHz = [
    7800,
    10400,
    15600,
    20800,
    31250,
    41700,
    62500,
    125000,
    250000,
    500000,
  ];

  /// Null for settings that can't be carried (unknown, an unlisted
  /// bandwidth, or values out of range).
  static SosRadio? fromRadio({
    required int? freqKhz,
    required int? bwHz,
    required int? sf,
    required int? cr,
  }) {
    if (freqKhz == null || bwHz == null || sf == null || cr == null) {
      return null;
    }
    final radio = SosRadio(
      freqKhz: freqKhz,
      bwHz: bwHz,
      sf: sf,
      cr: cr <= 4 ? cr + 4 : cr,
    );
    return radio._valid ? radio : null;
  }

  int get _bwCode {
    for (var i = 0; i < bandwidthsHz.length; i++) {
      if ((bandwidthsHz[i] - bwHz).abs() <= 100) return i;
    }
    return -1;
  }

  bool get _valid =>
      freqKhz > 0 &&
      freqKhz <= 0xFFFFFF &&
      _bwCode >= 0 &&
      sf >= 5 &&
      sf <= 12 &&
      cr >= 5 &&
      cr <= 8;

  Uint8List encode() => Uint8List.fromList([
    freqKhz & 0xFF,
    (freqKhz >> 8) & 0xFF,
    (freqKhz >> 16) & 0xFF,
    _bwCode,
    (sf << 4) | (cr - 4),
  ]);

  static SosRadio? decode(Uint8List data, int offset) {
    if (data.length < offset + size) return null;
    final code = data[offset + 3];
    if (code >= bandwidthsHz.length) return null;
    final radio = SosRadio(
      freqKhz:
          data[offset] | (data[offset + 1] << 8) | (data[offset + 2] << 16),
      bwHz: bandwidthsHz[code],
      sf: data[offset + 4] >> 4,
      cr: (data[offset + 4] & 0x0F) + 4,
    );
    return radio._valid ? radio : null;
  }

  /// Radios hear each other only on the same frequency, bandwidth and
  /// spreading factor; the coding rate doesn't matter for that.
  bool canHear(SosRadio other) =>
      freqKhz == other.freqKhz && _bwCode == other._bwCode && sf == other.sf;

  /// e.g. 915.075 MHz
  String get frequencyLabel => '${(freqKhz / 1000).toStringAsFixed(3)} MHz';

  /// e.g. 915.075 MHz · BW 125 · SF9 · CR 4/5
  String get label {
    final bw = bwHz / 1000;
    final bwText = bw == bw.roundToDouble()
        ? bw.toStringAsFixed(0)
        : bw.toString();
    return '$frequencyLabel · BW $bwText · SF$sf · CR 4/$cr';
  }

  Map<String, dynamic> toJson() => {
    'freq_khz': freqKhz,
    'bw_hz': bwHz,
    'sf': sf,
    'cr': cr,
  };

  static SosRadio? fromJson(Object? json) {
    if (json is! Map) return null;
    return SosRadio.fromRadio(
      freqKhz: (json['freq_khz'] as num?)?.toInt(),
      bwHz: (json['bw_hz'] as num?)?.toInt(),
      sf: (json['sf'] as num?)?.toInt(),
      cr: (json['cr'] as num?)?.toInt(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SosRadio &&
      other.freqKhz == freqKhz &&
      other.bwHz == bwHz &&
      other.sf == sf &&
      other.cr == cr;

  @override
  int get hashCode => Object.hash(freqKhz, bwHz, sf, cr);
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
