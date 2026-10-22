import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/sos_network_code.dart';

void main() {
  final key = Uint8List.fromList(List.generate(16, (i) => i * 17));

  test('round-trips the typed code and the QR payload', () {
    final code = SosNetworkCode(
      role: SosNetworkRole.responder,
      key: key,
      name: 'Smith Farm',
    );
    expect(code.text, startsWith('SOS1-R-'));
    final typed = SosNetworkCode.parse(code.text)!;
    expect(typed.role, SosNetworkRole.responder);
    expect(typed.key, key);
    expect(typed.name, SosNetworkCode.defaultName);
    final scanned = SosNetworkCode.parse(code.qrData)!;
    expect(scanned.name, 'Smith Farm');
    expect(scanned.key, key);
  });

  test('member and responder codes share the key but differ', () {
    final member = SosNetworkCode(role: SosNetworkRole.member, key: key);
    final responder = member.withRole(SosNetworkRole.responder);
    expect(member.text, isNot(responder.text));
    expect(member.text, startsWith('SOS1-M-'));
    expect(SosNetworkCode.parse(member.text)!.role, SosNetworkRole.member);
    expect(SosNetworkCode.parse(responder.text)!.key, key);
  });

  test('accepts sloppy typing but catches typos and role edits', () {
    final text = SosNetworkCode(role: SosNetworkRole.member, key: key).text;
    expect(
      SosNetworkCode.parse(' ${text.toLowerCase().replaceAll('-', ' ')} '),
      isNotNull,
    );
    final typo = text.replaceRange(
      text.length - 2,
      text.length - 1,
      text[text.length - 2] == 'A' ? 'B' : 'A',
    );
    expect(SosNetworkCode.parse(typo), isNull);
    expect(SosNetworkCode.parse(text.replaceFirst('-M-', '-R-')), isNull);
    expect(SosNetworkCode.parse('hello'), isNull);
    expect(SosNetworkCode.parse('SOS1-X-AAAA'), isNull);
  });

  test('generated keys are random and the right size', () {
    final a = SosNetworkCode.generateKey();
    final b = SosNetworkCode.generateKey();
    expect(a, hasLength(SosNetworkCode.keySize));
    expect(a, isNot(b));
  });

  test('finds valid codes in free text', () {
    final member = SosNetworkCode(role: SosNetworkRole.member, key: key);
    final responder = member.withRole(SosNetworkRole.responder);
    final broken = '${member.text.substring(0, member.text.length - 1)}A';
    final text =
        'Jo Smith, 0400 000 000\nArea SOS: ${member.text.toLowerCase()}.\n'
        'Again ${member.text}, bad $broken, '
        'team ${responder.withRole(SosNetworkRole.responder).qrData}';
    final found = SosNetworkCode.findIn(text);
    expect(found.map((c) => c.text), [member.text, responder.text]);
    expect(found.last.role, SosNetworkRole.responder);
    expect(SosNetworkCode.findIn('no codes here'), isEmpty);
  });
}
