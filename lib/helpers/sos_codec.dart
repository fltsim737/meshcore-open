import 'dart:convert';
import 'dart:math';

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

  const SosPayload({required this.id, required this.fix, this.node});
}

/// Plain-text SOS and ACK messages carried in ordinary MeshCore text frames.
///
/// ```
/// *** EMERGENCY SOS *** #a1b2
/// Node: <node>          (direct messages only)
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
    int? maxBytes,
  }) {
    String build(String? nodeName) => [
      '$header #$id',
      if (nodeName != null && nodeName.isNotEmpty) 'Node: $nodeName',
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
    return SosPayload(
      id: match.group(1)!,
      node: fields['node'],
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
