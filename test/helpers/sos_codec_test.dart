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
      // (a report always carries a reading: see 'coordinated search'; a
      // retune its radio settings: see 'radio settings and retune')
      for (final kind in SosPacketKind.values.where(
        (k) => k != SosPacketKind.report && k != SosPacketKind.retune,
      )) {
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
    // a packet as a MeshCore SOS radio sends it
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

  group('coordinated search', () {
    final prefix = Uint8List.fromList([1, 2, 3, 4, 5, 6]);

    test('a locate request carries the power asked for, or none', () {
      final asks = SosPacket(
        kind: SosPacketKind.locate,
        id: 'a1b2',
        senderPrefix: prefix,
        senderName: 'Mike',
        power: -9,
      );
      final bytes = asks.encode();
      expect(bytes.length, 11 + 4 + 1);
      final back = SosPacket.decode(bytes)!;
      expect(back.kind, SosPacketKind.locate);
      expect(back.power, -9);
      final full = SosPacket.decode(
        SosPacket(
          kind: SosPacketKind.locate,
          id: 'a1b2',
          senderPrefix: prefix,
          senderName: 'Mike',
          power: SosPacket.powerFull,
        ).encode(),
      )!;
      expect(full.power, SosPacket.powerFull);
      final plain = SosPacket.decode(
        SosPacket(
          kind: SosPacketKind.locate,
          id: 'a1b2',
          senderPrefix: prefix,
          senderName: 'Mike',
        ).encode(),
      )!;
      expect(plain.power, isNull);
    });

    test(
      'a beacon says its power and who set it; older beacons just their seq',
      () {
        final b = SosPacket(
          kind: SosPacketKind.beacon,
          id: '0102',
          senderPrefix: prefix,
          senderName: 'Nan',
          seq: 42,
          power: 8,
          setBy: 'Mike from the SES team',
        );
        final back = SosPacket.decode(b.encode())!;
        expect(back.seq, 42);
        expect(back.power, 8);
        expect(back.fullPower, isFalse);
        expect(back.setBy, 'Mike from the SE');
        final old = SosPacket.decode(
          SosPacket(
            kind: SosPacketKind.beacon,
            id: '0102',
            senderPrefix: prefix,
            senderName: 'Nan',
            seq: 3,
          ).encode(),
        )!;
        expect(old.seq, 3);
        expect(old.power, isNull);
      },
    );

    test('decodes the firmware\'s beacon bytes', () {
      // as SosCodec::encodeBeacon writes it: [seq][power][flags][set-by]
      final bytes = Uint8List.fromList([
        1,
        5,
        0x02,
        0x01,
        ...prefix,
        3,
        ...'Nan'.codeUnits,
        7,
        0xF7,
        1,
        4,
        ...'Mike'.codeUnits,
      ]);
      final p = SosPacket.decode(bytes)!;
      expect(p.seq, 7);
      expect(p.power, -9);
      expect(p.fullPower, isTrue);
      expect(p.setBy, 'Mike');
    });

    test('a report round trips', () {
      final r = SosPacket(
        kind: SosPacketKind.report,
        id: 'a1b2',
        senderPrefix: prefix,
        senderName: 'Sam',
        reading: const SosReading(
          latitude: -30.981234,
          longitude: 151.591234,
          rssiDbm: -97,
          snrDb: -6.25,
          beaconPower: 2,
          ageSeconds: 4,
        ),
      );
      final back = SosPacket.decode(r.encode())!;
      expect(back.kind, SosPacketKind.report);
      expect(back.reading!.latitude, closeTo(-30.981234, 1e-6));
      expect(back.reading!.longitude, closeTo(151.591234, 1e-6));
      expect(back.reading!.rssiDbm, -97);
      expect(back.reading!.snrDb, -6.25);
      expect(back.reading!.beaconPower, 2);
      expect(back.reading!.ageSeconds, 4);
    });
  });

  group('radio settings and retune (9.8.3)', () {
    const mid = SosRadio(freqKhz: 915075, bwHz: 125000, sf: 9, cr: 5);
    final key = Uint8List.fromList(List.filled(32, 7));
    SosPacket sos({String? info, SosRadio? radio}) => SosPacket(
      kind: SosPacketKind.sos,
      id: 'a1b2',
      senderPrefix: key.sublist(0, 6),
      senderName: 'Ridge',
      time: DateTime.utc(2026, 10, 29),
      senderKey: key,
      info: info,
      radio: radio,
    );

    test('radio settings round trip in 5 bytes', () {
      expect(mid.encode(), hasLength(SosRadio.size));
      expect(SosRadio.decode(mid.encode(), 0), mid);
      const narrow = SosRadio(freqKhz: 916575, bwHz: 62500, sf: 7, cr: 8);
      expect(SosRadio.decode(narrow.encode(), 0), narrow);
      expect(mid.label, '915.075 MHz · BW 125 · SF9 · CR 4/5');
      expect(narrow.label, '916.575 MHz · BW 62.5 · SF7 · CR 4/8');
    });

    test('settings an SOS cannot carry are dropped', () {
      expect(
        SosRadio.fromRadio(freqKhz: 915075, bwHz: 99000, sf: 9, cr: 5),
        isNull,
      );
      expect(
        SosRadio.fromRadio(freqKhz: null, bwHz: 125000, sf: 9, cr: 5),
        isNull,
      );
      // MeshCore reports the coding rate either as 5..8 or as 1..4
      expect(
        SosRadio.fromRadio(freqKhz: 915075, bwHz: 125000, sf: 9, cr: 1),
        mid,
      );
    });

    test('only frequency, bandwidth and SF decide who hears whom', () {
      const otherCr = SosRadio(freqKhz: 915075, bwHz: 125000, sf: 9, cr: 8);
      const otherSf = SosRadio(freqKhz: 915075, bwHz: 125000, sf: 10, cr: 5);
      expect(mid.canHear(otherCr), isTrue);
      expect(mid.canHear(otherSf), isFalse);
    });

    test('an SOS carries its radio, with or without info', () {
      final bare = SosPacket.decode(sos(radio: mid).encode())!;
      expect(bare.radio, mid);
      expect(bare.info, isNull);
      final both = SosPacket.decode(
        sos(info: 'Back gate', radio: mid).encode(),
      )!;
      expect(both.radio, mid);
      expect(both.info, 'Back gate');
      expect(SosPacket.decode(sos(info: 'Back gate').encode())!.radio, isNull);
    });

    test('an older build reads no info from an SOS with only radio settings', () {
      // the info length byte is written as 0, so the radio bytes after it
      // are never taken for text
      final wire = sos(radio: mid).encode();
      final infoAt = wire.length - SosRadio.size - 1;
      expect(wire[infoAt], 0);
    });

    test('radio settings take their room from the info', () {
      final long = sos(info: 'I' * 40).encode();
      final withRadio = sos(info: 'I' * 40, radio: mid).encode();
      expect(withRadio.length, long.length);
      final back = SosPacket.decode(withRadio)!;
      expect(back.info, 'I' * (SosPacket.maxInfoBytes - SosRadio.size));
      expect(back.radio, mid);
    });

    test('a retune round trips, going and back', () {
      SosPacket retune(bool back) => SosPacket(
        kind: SosPacketKind.retune,
        id: 'a1b2',
        senderPrefix: Uint8List.fromList(List.filled(6, 3)),
        senderName: 'Joe',
        radio: mid,
        back: back,
      );
      final going = SosPacket.decode(retune(false).encode())!;
      expect(going.kind, SosPacketKind.retune);
      expect(going.senderName, 'Joe');
      expect(going.radio, mid);
      expect(going.back, isFalse);
      expect(SosPacket.decode(retune(true).encode())!.back, isTrue);
    });
  });

  test('a stop is just the header, as the SOS radio (firmware 1.8.2) reads it', () {
    final bytes = SosPacket(
      kind: SosPacketKind.stopLocate,
      id: 'a1b2',
      senderPrefix: Uint8List.fromList([1, 2, 3, 4, 5, 6]),
      senderName: 'Joe',
    ).encode();
    // [version 1][kind 8][id LE][prefix][name length][name]
    expect(bytes, [1, 8, 0xb2, 0xa1, 1, 2, 3, 4, 5, 6, 3, ...'Joe'.codeUnits]);
    expect(SosPacketKind.stopLocate.code, 8);
  });
}
