import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/helpers/sos_codec.dart';

void main() {
  final time = DateTime.utc(2026, 10, 21, 14, 32);

  test('round-trips a channel SOS with a position', () {
    final text = SosCodec.encodeSos(
      id: 'a1b2',
      time: time,
      fix: const SosFix(
        latitude: -45.123456,
        longitude: -122.543211,
        source: SosLocationSource.phoneGps,
      ),
    );
    expect(
      text,
      '*** EMERGENCY SOS *** #a1b2\n'
      'Time: 10-21 14:32Z\n'
      'Source: Phone GPS\n'
      'Lat: -45.12346\n'
      'Lon: -122.54321\n'
      'Reply ACK #a1b2',
    );
    final parsed = SosCodec.parseSos(text)!;
    expect(parsed.id, 'a1b2');
    expect(parsed.node, isNull);
    expect(parsed.fix.source, SosLocationSource.phoneGps);
    expect(parsed.fix.latitude, closeTo(-45.12346, 1e-9));
    expect(parsed.fix.longitude, closeTo(-122.54321, 1e-9));
  });

  test('omits coordinates when there is no position', () {
    final text = SosCodec.encodeSos(
      id: '00ff',
      time: time,
      fix: const SosFix.none(),
    );
    expect(text, isNot(contains('Lat:')));
    expect(SosCodec.parseSos(text)!.fix.hasPosition, isFalse);
  });

  test('fits every budget with a maximum-length node name', () {
    final longName = 'N' * (maxNameSize - 1);
    for (final source in SosLocationSource.values) {
      final fix = source == SosLocationSource.none
          ? const SosFix.none()
          : SosFix(latitude: -89.99999, longitude: -179.99999, source: source);
      final channel = SosCodec.encodeSos(id: 'ffff', time: time, fix: fix);
      expect(
        utf8.encode(channel).length,
        lessThanOrEqualTo(maxChannelMessageBytes(longName)),
        reason: source.name,
      );
      final dm = SosCodec.encodeSos(
        id: 'ffff',
        time: time,
        fix: fix,
        node: longName,
        maxBytes: maxTextPayloadBytesAfterFullLengthAttempts,
      );
      expect(
        utf8.encode(dm).length,
        lessThanOrEqualTo(maxTextPayloadBytesAfterFullLengthAttempts),
        reason: source.name,
      );
      expect(SosCodec.parseSos(dm)!.fix.source, fix.source);
    }
  });

  test('keeps the DM node line when it fits', () {
    final dm = SosCodec.encodeSos(
      id: 'a1b2',
      time: time,
      fix: const SosFix.none(),
      node: 'Farmhouse',
      maxBytes: maxTextPayloadBytesAfterFullLengthAttempts,
    );
    expect(SosCodec.parseSos(dm)!.node, 'Farmhouse');
  });

  test('rejects ordinary text and out-of-range positions', () {
    expect(SosCodec.parseSos('help me'), isNull);
    expect(SosCodec.parseSos('*** EMERGENCY SOS ***'), isNull);
    final bad = SosCodec.parseSos(
      '*** EMERGENCY SOS *** #a1b2\nSource: Phone GPS\nLat: 95\nLon: 10',
    )!;
    expect(bad.fix.hasPosition, isFalse);
  });

  test('parses ACK messages', () {
    expect(SosCodec.encodeAck('a1b2'), 'ACK #a1b2');
    expect(SosCodec.parseAck('ACK #a1b2'), 'a1b2');
    expect(SosCodec.parseAck(' ack #A1B2 '), 'a1b2');
    expect(SosCodec.parseAck('ACK'), isNull);
    expect(SosCodec.parseAck('ACK #a1b2 thanks'), isNull);
  });

  test('round-trips a cancellation', () {
    final text = SosCodec.encodeCancel('a1b2', time);
    expect(
      text,
      '*** SOS CANCELLED *** #a1b2\n'
      'Time: 10-21 14:32Z\n'
      'The sender cancelled this SOS.',
    );
    expect(SosCodec.parseCancel(text), 'a1b2');
    expect(SosCodec.parseSos(text), isNull);
    expect(SosCodec.parseCancel('SOS CANCELLED #a1b2'), isNull);
    expect(SosCodec.isStructured(text), isTrue);
  });

  test('marks SOS and ACK text as structured', () {
    expect(SosCodec.isStructured('*** EMERGENCY SOS *** #a1b2\n'), isTrue);
    expect(SosCodec.isStructured('ACK #a1b2'), isTrue);
    expect(SosCodec.isStructured('ACK received'), isFalse);
  });
}
