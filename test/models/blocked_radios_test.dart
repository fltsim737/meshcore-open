import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/blocked_radios.dart';

void main() {
  final key = Uint8List.fromList(List<int>.generate(32, (i) => 0xa0 + i));
  final keyHex = key.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  test('a key blocks on its first 6 bytes', () {
    final b = BlockedRadios()..add(keyHex: keyHex, name: 'Spam bot');
    expect(b.isKeyBlocked(key), isTrue);
    expect(b.isKeyBlocked(key.sublist(0, 6)), isTrue); // a DM's sender prefix
    expect(b.isKeyHexBlocked(keyHex.substring(0, 12).toUpperCase()), isTrue);
    final other = Uint8List.fromList(key)..[5] ^= 1;
    expect(b.isKeyBlocked(other), isFalse);
  });

  test('channel messages match the blocked name exactly', () {
    final b = BlockedRadios()..add(keyHex: keyHex, name: 'Spam bot');
    expect(b.isNameBlocked('Spam bot'), isTrue);
    expect(b.isNameBlocked(' Spam bot '), isTrue);
    expect(b.isNameBlocked('Spam'), isFalse);
    expect(b.isNameBlocked(''), isFalse);
  });

  test('a name-only block hides channel messages but no key', () {
    final b = BlockedRadios()..add(name: 'Heckler');
    expect(b.isNameBlocked('Heckler'), isTrue);
    expect(b.isKeyBlocked(key), isFalse);
    expect(b.all.single.id, 'name:Heckler');
    expect(BlockedRadios().add(name: '  '), isNull);
  });

  test('bad keys are refused', () {
    final b = BlockedRadios();
    expect(b.add(keyHex: 'abc', name: 'x'), isNull);
    expect(b.add(keyHex: 'zzzzzzzzzzzz', name: 'x'), isNull);
    expect(b.isEmpty, isTrue);
  });

  test('saved and loaded, keeping the fuller key and first time', () {
    final b = BlockedRadios()
      ..add(keyHex: keyHex.substring(0, 12), name: 'Bot', at: DateTime(2026))
      ..add(keyHex: keyHex, name: 'Bot 2', at: DateTime(2027));
    expect(b.all.single.keyHex, keyHex);
    expect(b.all.single.name, 'Bot 2');
    expect(b.all.single.blockedAt, DateTime(2026));
    final again = BlockedRadios()..load(b.toJson());
    expect(again.isKeyBlocked(key), isTrue);
    expect(again.all.single.name, 'Bot 2');
    expect((BlockedRadios()..load('not json')).isEmpty, isTrue);
  });

  test('removes by id', () {
    final b = BlockedRadios()..add(keyHex: keyHex, name: 'Bot');
    expect(b.remove(keyHex.substring(0, 12)), isTrue);
    expect(b.isKeyBlocked(key), isFalse);
  });

  test('parses the SOS radio\'s block list reply', () {
    final (entries, more) = BlockedRadios.parseRadioList(
      '> 3|a0a1a2a3a4a5,Spam bot|0102030405ff,|+',
    );
    expect(entries.map((e) => e.keyHex), ['a0a1a2a3a4a5', '0102030405ff']);
    expect(entries.first.name, 'Spam bot');
    expect(more, isTrue);
    final (none, noMore) = BlockedRadios.parseRadioList('> 0');
    expect(none, isEmpty);
    expect(noMore, isFalse);
    expect(BlockedRadios.parseRadioList('Unknown command').$1, isEmpty);
  });
}
