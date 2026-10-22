import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/repeater_owner_info.dart';

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

void main() {
  test('splits version, name and the multi-line operator text', () {
    final info = RepeaterOwnerInfo.parse(
      _bytes('v1.11.0-abc\nHilltop\nJo Smith\nSOS: SOS1-M-AAAA'),
    )!;
    expect(info.firmwareVersion, 'v1.11.0-abc');
    expect(info.nodeName, 'Hilltop');
    expect(info.ownerInfo, 'Jo Smith\nSOS: SOS1-M-AAAA');
  });

  test('empty operator text and a trailing NUL', () {
    final info = RepeaterOwnerInfo.parse(
      Uint8List.fromList([..._bytes('v1.11.0\nHilltop\n'), 0, 0x41]),
    )!;
    expect(info.nodeName, 'Hilltop');
    expect(info.ownerInfo, isEmpty);
  });

  test('rejects data that is not an owner info reply', () {
    expect(RepeaterOwnerInfo.parse(_bytes('v1.11.0')), isNull);
  });
}
