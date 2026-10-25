import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';

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

  group('SosPacket', () {
    final prefix = Uint8List.fromList([1, 2, 3, 4, 5, 6]);

    test('round-trips an SOS with a southern, western position', () {
      final packet = SosPacket(
        kind: SosPacketKind.sos,
        id: 'a1b2',
        senderPrefix: prefix,
        senderName: 'Farmhouse',
        time: time,
        fix: const SosFix(
          latitude: -45.123456,
          longitude: -122.543211,
          source: SosLocationSource.radio,
        ),
      );
      final bytes = packet.encode();
      expect(bytes.length, lessThan(64));
      final decoded = SosPacket.decode(bytes)!;
      expect(decoded.kind, SosPacketKind.sos);
      expect(decoded.id, 'a1b2');
      expect(decoded.senderPrefix, prefix);
      expect(decoded.senderName, 'Farmhouse');
      expect(decoded.time!.isAtSameMomentAs(time), isTrue);
      expect(decoded.fix.source, SosLocationSource.radio);
      expect(decoded.fix.latitude, closeTo(-45.123456, 1e-6));
      expect(decoded.fix.longitude, closeTo(-122.543211, 1e-6));
    });

    test('round-trips ACK and cancel, and an SOS without a position', () {
      for (final kind in SosPacketKind.values) {
        final decoded = SosPacket.decode(
          SosPacket(
            kind: kind,
            id: '00ff',
            senderPrefix: prefix,
            senderName: 'Ridge',
            time: time,
          ).encode(),
        )!;
        expect(decoded.kind, kind);
        expect(decoded.id, '00ff');
        expect(decoded.senderName, 'Ridge');
        expect(decoded.fix.hasPosition, isFalse);
      }
    });

    test('SOS and ACK carry the full key; older packets have none', () {
      final key = Uint8List.fromList([...prefix, ...List.filled(26, 7)]);
      for (final kind in [SosPacketKind.sos, SosPacketKind.ack]) {
        final withKey = SosPacket(
          kind: kind,
          id: 'a1b2',
          senderPrefix: key,
          senderName: 'Ridge',
          time: time,
          fix: const SosFix(
            latitude: -41,
            longitude: 174,
            source: SosLocationSource.phoneGps,
          ),
          senderKey: key,
        ).encode();
        final decoded = SosPacket.decode(withKey)!;
        expect(decoded.senderKey, key);
        expect(decoded.senderName, 'Ridge');
        if (kind == SosPacketKind.sos) {
          expect(decoded.fix.latitude, closeTo(-41, 1e-6));
        }
        // Without the trailing key, as older builds send it.
        final older = SosPacket.decode(
          Uint8List.sublistView(withKey, 0, withKey.length - 32),
        )!;
        expect(older.senderKey, isNull);
        expect(older.senderName, 'Ridge');
      }
      // A key that does not match the prefix is not trusted.
      final mismatched = SosPacket(
        kind: SosPacketKind.ack,
        id: 'a1b2',
        senderPrefix: prefix,
        senderName: 'Ridge',
        senderKey: Uint8List.fromList(List.filled(32, 9)),
      ).encode();
      expect(SosPacket.decode(mismatched)!.senderKey, isNull);
    });

    test('shortens long names and rejects junk', () {
      final decoded = SosPacket.decode(
        SosPacket(
          kind: SosPacketKind.ack,
          id: 'ffff',
          senderPrefix: prefix,
          senderName: 'N' * 60,
        ).encode(),
      )!;
      expect(decoded.senderName.length, SosPacket.maxNameBytes);
      expect(SosPacket.decode(Uint8List.fromList([1, 2, 3])), isNull);
      expect(SosPacket.decode(Uint8List.fromList(List.filled(20, 9))), isNull);
    });
  });

  group('info line from the MeshCore SOS button', () {
    // made by the button firmware (examples/sos_button/SosCodec.cpp)
    final buttonPacket = Uint8List.fromList(
      hex.decode(
        '0101b2a1a0a1a2a3a4a51f4e616e277320706c6163652c203134204c6f6e6720'
        '47756c6c7920526f6164b03cfa6802019602bffd0c0a5cf7a0a1a2a3a4a5a6a7'
        'a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebf204c6f7420313420'
        '4c6f6e672047756c6c792052642c20576f6d62617420466c61',
      ),
    );

    test('reads the info after the full key', () {
      final packet = SosPacket.decode(buttonPacket)!;
      expect(packet.kind, SosPacketKind.sos);
      expect(packet.senderName, "Nan's place, 14 Long Gully Road");
      expect(packet.senderKey, isNotNull);
      expect(packet.fix.latitude, closeTo(-37.81361, 1e-6));
      expect(packet.info, 'Lot 14 Long Gully Rd, Wombat Fla');
    });

    test('reads the Info line of the DM', () {
      final payload = SosCodec.parseSos(
        '*** EMERGENCY SOS *** #a1b2\n'
        'Info: Lot 14 Long Gully Rd, Wombat Fla\n'
        'Time: 10-23 14:33Z\n'
        'Source: Stored location\n'
        'Lat: -37.81361\n'
        'Lon: -144.96306\n'
        'Reply ACK #a1b2',
      )!;
      expect(payload.info, 'Lot 14 Long Gully Rd, Wombat Fla');
      expect(payload.node, isNull);
      expect(payload.fix.longitude, closeTo(-144.96306, 1e-6));
    });

    test('round-trips info, and leaves it out when there is none', () {
      SosPacket sos({String? info}) => SosPacket(
        kind: SosPacketKind.sos,
        id: 'a1b2',
        senderPrefix: Uint8List.fromList(List.filled(6, 3)),
        senderName: 'Hut',
        senderKey: Uint8List.fromList(List.filled(32, 3)),
        time: time,
        info: info,
      );
      final plain = sos().encode();
      expect(SosPacket.decode(plain)!.info, isNull);
      final withInfo = sos(info: 'Gate 2').encode();
      expect(withInfo.length, plain.length + 7);
      expect(SosPacket.decode(withInfo)!.info, 'Gate 2');
      expect(
        SosPacket.decode(sos(info: 'x' * 50).encode())!.info!.length,
        SosPacket.maxInfoBytes,
      );
      expect(
        SosCodec.encodeSos(
          id: 'a1b2',
          time: time,
          fix: const SosFix.none(),
          info: 'Gate 2',
        ),
        contains('\nInfo: Gate 2\n'),
      );
    });

    test('ignores a malformed info field', () {
      final cut = Uint8List.fromList([
        ...buttonPacket.sublist(0, buttonPacket.length - 5),
      ]);
      final packet = SosPacket.decode(cut)!;
      expect(packet.info, isNull);
      expect(packet.senderKey, isNotNull);
    });
  });

  test('marks SOS and ACK text as structured', () {
    expect(SosCodec.isStructured('*** EMERGENCY SOS *** #a1b2\n'), isTrue);
    expect(SosCodec.isStructured('ACK #a1b2'), isTrue);
    expect(SosCodec.isStructured('ACK received'), isFalse);
  });

  test('locate and beacon round trip, and match the firmware bytes', () {
    final prefix = Uint8List.fromList(List.generate(6, (i) => 0x10 + i));
    final locate = SosPacket(
      kind: SosPacketKind.locate,
      id: 'a1b2',
      senderPrefix: prefix,
      senderName: 'Pat',
    ).encode();
    // [1][4][b2 a1][prefix x6][3]"Pat", as SosCodec::encodeLocator writes it
    expect(locate, [1, 4, 0xb2, 0xa1, ...prefix, 3, 0x50, 0x61, 0x74]);
    final back = SosPacket.decode(locate)!;
    expect(back.kind, SosPacketKind.locate);
    expect(back.senderName, 'Pat');

    final beacon = SosPacket(
      kind: SosPacketKind.beacon,
      id: 'a1b2',
      senderPrefix: prefix,
      senderName: 'Nan',
      seq: 7,
    ).encode();
    expect(beacon.length, 11 + 3 + 1);
    expect(beacon.last, 7);
    expect(SosPacket.decode(beacon)!.seq, 7);
  });
}
