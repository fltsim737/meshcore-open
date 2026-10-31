import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

Uint8List _contactFrame(int code, Uint8List key, String name) {
  final data = ByteData(1 + 32 + 3 + 64 + 32 + 4 + 12);
  final bytes = data.buffer.asUint8List();
  bytes[0] = code;
  bytes.setRange(1, 33, key);
  bytes[33] = advTypeChat;
  bytes[35] = 0xFF; // path unknown
  bytes.setRange(100, 100 + name.length, name.codeUnits);
  data.setUint32(132, 1700000000, Endian.little);
  return bytes;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
  });

  final key = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
  final other = Uint8List.fromList(List<int>.generate(32, (i) => 200 - i));

  test('a custom name is shown everywhere the app names the contact', () async {
    final connector = MeshCoreConnector();
    connector.handleFrameForTest(_contactFrame(respCodeContact, key, 'Bob'));
    connector.handleFrameForTest(_contactFrame(respCodeContact, other, 'Sue'));
    final hex = connector.contacts
        .firstWhere((c) => c.name == 'Bob')
        .publicKeyHex;

    await connector.setCustomName(hex, '  Dad  ');

    expect(connector.contacts.map((c) => c.name), containsAll(['Dad', 'Sue']));
    expect(connector.getContactByPubKeyHex(hex)!.name, 'Dad');
    expect(connector.allContactsUnfiltered.any((c) => c.name == 'Dad'), isTrue);
    expect(connector.customNameFor(hex), 'Dad');
    // the contact's own name is still known, and is what goes to the radio
    expect(
      connector.advertisedNameFor(connector.getContactByPubKeyHex(hex)!),
      'Bob',
    );
  });

  test('it is kept across restarts of the app', () async {
    final first = MeshCoreConnector();
    first.handleFrameForTest(_contactFrame(respCodeContact, key, 'Bob'));
    final hex = first.contacts.single.publicKeyHex;
    await first.setCustomName(hex, 'Dad');

    final again = MeshCoreConnector();
    again.handleFrameForTest(_contactFrame(respCodeContact, key, 'Bob'));
    expect(again.contacts.single.name, 'Dad');
  });

  test('it stays when the contact advertises a new name', () async {
    final connector = MeshCoreConnector();
    connector.handleFrameForTest(_contactFrame(respCodeContact, key, 'Bob'));
    final hex = connector.contacts.single.publicKeyHex;
    await connector.setCustomName(hex, 'Dad');

    connector.handleFrameForTest(_contactFrame(respCodeContact, key, 'Robert'));
    expect(connector.contacts.single.name, 'Dad');
    expect(connector.advertisedNameFor(connector.contacts.single), 'Robert');
  });

  test('an empty name goes back to the contact\'s own', () async {
    final connector = MeshCoreConnector();
    connector.handleFrameForTest(_contactFrame(respCodeContact, key, 'Bob'));
    final hex = connector.contacts.single.publicKeyHex;
    await connector.setCustomName(hex, 'Dad');
    await connector.setCustomName(hex, '   ');

    expect(connector.contacts.single.name, 'Bob');
    expect(connector.customNameFor(hex), isNull);
  });

  test('discovered radios show a custom name too', () async {
    final connector = MeshCoreConnector();
    connector.handleFrameForTest(_contactFrame(pushCodeNewAdvert, key, 'Bob'));
    final hex = connector.discoveredContacts.single.publicKeyHex;
    await connector.setCustomName(hex, 'Dad');
    expect(connector.discoveredContacts.single.name, 'Dad');
  });
}
