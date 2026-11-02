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
  bytes[35] = 0xFF;
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

  final bot = Uint8List.fromList(List<int>.generate(32, (i) => 0x50 + i));
  final botHex = bot.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  final bob = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));

  test('a blocked radio\'s adverts are ignored; others still show', () async {
    final connector = MeshCoreConnector();
    await connector.loadContactCache();
    await connector.blockRadio(keyHex: botHex, name: 'Spam bot');
    connector.handleFrameForTest(
      _contactFrame(pushCodeNewAdvert, bot, 'Spam bot'),
    );
    connector.handleFrameForTest(_contactFrame(pushCodeNewAdvert, bob, 'Bob'));
    expect(connector.discoveredContacts.map((c) => c.name), ['Bob']);
  });

  test(
    'blocking takes it out of Discovered, and unblocking lets it back',
    () async {
      final connector = MeshCoreConnector();
      await connector.loadContactCache();
      connector.handleFrameForTest(
        _contactFrame(pushCodeNewAdvert, bot, 'Spam bot'),
      );
      expect(connector.discoveredContacts, hasLength(1));
      await connector.blockRadio(keyHex: botHex, name: 'Spam bot');
      expect(connector.discoveredContacts, isEmpty);
      expect(connector.isRadioBlocked(botHex), isTrue);

      await connector.unblockRadio(botHex.substring(0, 12));
      connector.handleFrameForTest(
        _contactFrame(pushCodeNewAdvert, bot, 'Spam bot'),
      );
      expect(connector.discoveredContacts, hasLength(1));
    },
  );

  test('the block list is kept on the phone', () async {
    final first = MeshCoreConnector();
    await first.loadContactCache();
    await first.blockRadio(keyHex: botHex, name: 'Spam bot');
    await Future<void>.delayed(Duration.zero);

    final second = MeshCoreConnector();
    await second.loadContactCache();
    expect(second.blockedRadios.single.name, 'Spam bot');
    expect(second.isRadioBlocked(botHex), isTrue);
  });

  test('a radio without block support is not asked', () async {
    final connector = MeshCoreConnector();
    expect(connector.radioCanBlock, isFalse);
  });
}
