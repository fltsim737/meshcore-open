import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/sos_codec.dart';
import 'package:meshcore_open/helpers/sos_network_code.dart';
import 'package:meshcore_open/helpers/sos_seal.dart';

Uint8List _b(String hex) => Uint8List.fromList([
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
]);

String _h(List<int> b) =>
    b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();

// Made by an independent implementation (Python `cryptography`); the MeshCore
// SOS radio's firmware tests check the same bytes.
const _v = (
  seed: '0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20',
  ephSeed: '65666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f8081828384',
  netPub: '07a37cbc142093c8b755dc1b10e86cb426374ad16aa853ed0bdfc0b2b86d1c7c',
  ephPub: '5714769d116bf76436ae74bc793d2c30ad1903c59ac5273805c7e2698b410c36',
  channelKey: 'ab870e38b2f6cd9f630508c26beaa238',
  encKey: '1e746540f922b970e2c3361d7ee2c5a9',
  macKey: 'b57ca2d3035120e0101a22574ab7bf133e58af77cd2af65f29d132c9252c19fa',
  memberCode:
      'SOS2-M-A6RX-ZPAU-ECJ4-RN2V-3QNR-B2DM-WQTD-OSWR-NKUF-H3IL-37AL-FODN-DR6I-Y',
  responderCode:
      'SOS2-R-AEBA-GBAF-AYDQ-QCIK-BMGA-2DQP-CAIR-EEYU-CULB-OGAZ-DINR-YHI6-D4QF-6',
  nonce: 'a0a1a2a3a4a5',
  sos:
      '0201b2a15714769d116bf76436ae74bc793d2c30ad1903c59ac5273805c7e2698b410c36'
      'a0a1a2a3a4a5d2115849f6880dc7673e601329c4345bfccab801f5ac8d26b417425aa1'
      'bfa8f01cd767298bd2043ae595d7eb14ad86f9a9557822c3d1fe32a50cf420112b7037'
      '2b1180e08f',
  ack:
      '0202b2a15714769da0a1a2a3a4a5a1366168ac66e16b604d083e66859f4bffe1931c75'
      '12ae1587247169928c9bc32fe4541ab8e13709d6a6e4d85fa38128c3a15c04',
  cancel:
      '0203b2a15714769da0a1a2a3a4a5e9f2a82d9f55e078635b19dffa1da2db274f292a42'
      'c61e',
  locate:
      '0204b2a15714769da0a1a2a3a4a5a1366168ac66e16b604d083e7f3f6c1c84f0190a',
  beacon:
      '0205b2a15714769da0a1a2a3a4a5e9f2a82d9f55e078635b195c79733e1643bf746c',
);

final _me = _b('3fa29c01${'11' * 28}');
final _rosie = _b('77665544${'22' * 28}');

void main() {
  final network = SosNetworkCode.sealed(
    role: SosNetworkRole.responder,
    secret: _b(_v.seed),
    name: 'Farm',
  );
  final sender = SosSeal.senderSession(_b(_v.ephSeed), _b(_v.netPub))!;

  test('derives the network and SOS keys as the reference does', () {
    expect(_h(network.networkPublicKey!), _v.netPub);
    expect(_h(network.key), _v.channelKey);
    expect(_h(sender.ephPublic), _v.ephPub);
    expect(_h(sender.encKey), _v.encKey);
    expect(_h(sender.macKey), _v.macKey);
    final responder = SosSeal.responderSession(
      network.networkSecret!,
      sender.ephPublic,
    )!;
    expect(_h(responder.encKey), _v.encKey);
    expect(_h(responder.macKey), _v.macKey);
  });

  test('codes: the member code holds only the public key', () {
    expect(network.text, _v.responderCode);
    final member = network.withRole(SosNetworkRole.member);
    expect(member.text, _v.memberCode);
    expect(member.networkSecret, isNull);
    expect(member.canMakeRole(SosNetworkRole.responder), isFalse);
    expect(() => member.withRole(SosNetworkRole.responder), throwsStateError);
    final parsed = SosNetworkCode.parse(_v.memberCode)!;
    expect(parsed.isSealed, isTrue);
    expect(parsed.role, SosNetworkRole.member);
    expect(_h(parsed.key), _v.channelKey);
    // Swapping the letter doesn't make a responder code
    expect(
      SosNetworkCode.parse(_v.memberCode.replaceFirst('-M-', '-R-')),
      isNull,
    );
    expect(SosNetworkCode.parse('${_v.responderCode}#Farm')!.name, 'Farm');
    expect(
      SosNetworkCode.findIn('SOS: ${_v.memberCode}').single.text,
      _v.memberCode,
    );
  });

  test('seals every kind of packet byte for byte as the reference', () {
    final nonce = _b(_v.nonce);
    final sos = SosPacket(
      kind: SosPacketKind.sos,
      id: 'a1b2',
      senderPrefix: _me,
      senderName: 'Alex',
      time: DateTime.fromMillisecondsSinceEpoch(1761536460 * 1000),
      fix: const SosFix(
        latitude: -30.98412,
        longitude: 151.5933,
        source: SosLocationSource.phoneGps,
      ),
      senderKey: _me,
      info: 'Gate 1234',
    );
    expect(_h(SosSeal.sealPacket(sos, sender, nonce: nonce)), _v.sos);
    final ack = SosPacket(
      kind: SosPacketKind.ack,
      id: 'a1b2',
      senderPrefix: _rosie,
      senderName: 'Rosie',
      senderKey: _rosie,
    );
    expect(_h(SosSeal.sealPacket(ack, sender, nonce: nonce)), _v.ack);
    final cancel = SosPacket(
      kind: SosPacketKind.cancel,
      id: 'a1b2',
      senderPrefix: _me,
      senderName: 'Alex',
      time: DateTime.fromMillisecondsSinceEpoch(1761536900 * 1000),
    );
    expect(_h(SosSeal.sealPacket(cancel, sender, nonce: nonce)), _v.cancel);
    final locate = SosPacket(
      kind: SosPacketKind.locate,
      id: 'a1b2',
      senderPrefix: _rosie,
      senderName: 'Rosie',
    );
    expect(_h(SosSeal.sealPacket(locate, sender, nonce: nonce)), _v.locate);
    final beacon = SosPacket(
      kind: SosPacketKind.beacon,
      id: 'a1b2',
      senderPrefix: _me,
      senderName: 'Alex',
      seq: 7,
    );
    expect(_h(SosSeal.sealPacket(beacon, sender, nonce: nonce)), _v.beacon);
  });

  test('a responder opens the SOS; anyone else cannot', () {
    final data = _b(_v.sos);
    final head = SosSeal.header(data)!;
    expect(head.id, 'a1b2');
    expect(_h(head.ephPublic!), _v.ephPub);
    final responder = SosSeal.responderSession(
      network.networkSecret!,
      head.ephPublic!,
    )!;
    final sos = SosSeal.openPacket(data, responder)!;
    expect(sos.kind, SosPacketKind.sos);
    expect(sos.senderName, 'Alex');
    expect(sos.senderKey, _me);
    expect(sos.senderPrefix, _me.sublist(0, 6));
    expect(sos.info, 'Gate 1234');
    expect(sos.fix.latitude, closeTo(-30.98412, 1e-6));

    // Another network's responder, or a tampered byte, gets nothing
    final other = SosNetworkCode.generateSealed(random: Random(1));
    final wrong = SosSeal.responderSession(
      other.networkSecret!,
      head.ephPublic!,
    )!;
    expect(SosSeal.openPacket(data, wrong), isNull);
    final tampered = Uint8List.fromList(data)..[60] ^= 1;
    expect(SosSeal.openPacket(tampered, responder), isNull);

    final ack = SosSeal.openPacket(_b(_v.ack), sender)!;
    expect(ack.kind, SosPacketKind.ack);
    expect(ack.senderName, 'Rosie');
    expect(ack.senderKey, _rosie);
    expect(SosSeal.openPacket(_b(_v.beacon), sender)!.seq, 7);
  });

  test('the largest SOS still fits one channel packet', () {
    final s = SosSeal.newSession(network.networkPublicKey!);
    final sos = SosPacket(
      kind: SosPacketKind.sos,
      id: 'ffff',
      senderPrefix: _me,
      senderName: 'N' * 40,
      time: DateTime.now(),
      fix: const SosFix(
        latitude: -89.999999,
        longitude: -179.999999,
        source: SosLocationSource.stored,
      ),
      senderKey: _me,
      info: 'I' * 40,
    );
    expect(SosSeal.sealPacket(sos, s).length, lessThanOrEqualTo(165));
    final withRadio = SosPacket(
      kind: SosPacketKind.sos,
      id: 'ffff',
      senderPrefix: _me,
      senderName: 'N' * 40,
      time: DateTime.now(),
      fix: sos.fix,
      senderKey: _me,
      info: 'I' * 40,
      radio: const SosRadio(freqKhz: 915075, bwHz: 125000, sf: 9, cr: 5),
    );
    expect(
      SosSeal.sealPacket(withRadio, s).length,
      SosSeal.sealPacket(sos, s).length,
    );
    expect(
      SosSeal.openPacket(SosSeal.sealPacket(withRadio, s), s)!.radio,
      withRadio.radio,
    );
  });

  test('sessions survive being saved', () {
    final s = SosSeal.newSession(network.networkPublicKey!);
    final back = SosSession.fromJson(s.toJson())!;
    expect(back.ephPublic, s.ephPublic);
    expect(back.encKey, s.encKey);
    expect(back.macKey, s.macKey);
    expect(back.ephSecret, s.ephSecret);
  });
}
