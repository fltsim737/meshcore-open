import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/message_search.dart';

MessageSearchHit hit(String id, String sender, String text, int minute) =>
    MessageSearchHit(
      messageId: id,
      sender: sender,
      text: text,
      time: DateTime(2026, 11, 2, 10, minute),
    );

void main() {
  final all = [
    hit('1', 'Maya', 'Meet at the Walcha bridge at noon', 1),
    hit('2', 'Sam', 'Road to Armidale is closed', 2),
    hit('3', 'José', 'Bringing the spare battery', 3),
    hit('4', 'Maya', 'Bridge is under water now 🌊', 4),
  ];

  test('every word must match, in any order, ignoring capitals', () {
    expect(MessageSearch.filter(all, 'BRIDGE walcha').map((h) => h.messageId), [
      '1',
    ]);
    expect(MessageSearch.filter(all, 'bridge').map((h) => h.messageId), [
      '4',
      '1',
    ]); // newest first
  });

  test('matches the sender\'s name too', () {
    expect(MessageSearch.filter(all, 'maya water').map((h) => h.messageId), [
      '4',
    ]);
  });

  test('ignores accents both ways', () {
    expect(MessageSearch.filter(all, 'jose').map((h) => h.messageId), ['3']);
    expect(MessageSearch.filter(all, 'José').map((h) => h.messageId), ['3']);
  });

  test('an empty query finds nothing', () {
    expect(MessageSearch.filter(all, '   '), isEmpty);
  });

  test('highlights each occurrence, keeping the original text', () {
    const hl = TextStyle(fontWeight: FontWeight.bold);
    final spans = MessageSearch.highlight(
      'Bridge is under water now 🌊, bridge',
      MessageSearch.terms('bridge'),
      hl,
    );
    expect(
      spans.map((s) => s.text).join(),
      'Bridge is under water now 🌊, bridge',
    );
    expect(spans.where((s) => s.style == hl).map((s) => s.text), [
      'Bridge',
      'bridge',
    ]);
  });

  test('highlights a word after an emoji in the right place', () {
    const hl = TextStyle(fontWeight: FontWeight.bold);
    final spans = MessageSearch.highlight(
      '🌊 flood at the ford',
      MessageSearch.terms('ford'),
      hl,
    );
    expect(spans.where((s) => s.style == hl).map((s) => s.text), ['ford']);
  });
}
