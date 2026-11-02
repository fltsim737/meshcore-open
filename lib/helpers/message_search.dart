import 'package:flutter/painting.dart';

/// One message found by a chat search: enough to list it and to jump to it.
class MessageSearchHit {
  final String messageId;
  final String sender;
  final String text;
  final DateTime time;

  const MessageSearchHit({
    required this.messageId,
    required this.sender,
    required this.text,
    required this.time,
  });
}

/// Matching for the chat search (10.2.6): every word typed must appear in the
/// message or its sender's name, in any order, ignoring capitals and accents.
class MessageSearch {
  MessageSearch._();

  static const _accents = {
    'à': 'a',
    'á': 'a',
    'â': 'a',
    'ã': 'a',
    'ä': 'a',
    'å': 'a',
    'ā': 'a',
    'ç': 'c',
    'č': 'c',
    'ć': 'c',
    'ď': 'd',
    'è': 'e',
    'é': 'e',
    'ê': 'e',
    'ë': 'e',
    'ē': 'e',
    'ě': 'e',
    'ì': 'i',
    'í': 'i',
    'î': 'i',
    'ï': 'i',
    'ī': 'i',
    'ľ': 'l',
    'ł': 'l',
    'ñ': 'n',
    'ň': 'n',
    'ń': 'n',
    'ò': 'o',
    'ó': 'o',
    'ô': 'o',
    'õ': 'o',
    'ö': 'o',
    'ø': 'o',
    'ō': 'o',
    'ř': 'r',
    'š': 's',
    'ś': 's',
    'ť': 't',
    'ù': 'u',
    'ú': 'u',
    'û': 'u',
    'ü': 'u',
    'ū': 'u',
    'ů': 'u',
    'ý': 'y',
    'ÿ': 'y',
    'ž': 'z',
    'ź': 'z',
    'ż': 'z',
  };

  /// Lower case without accents, one character for each one in [s], so
  /// positions found in the folded text are positions in [s] too.
  static String fold(String s) {
    final out = StringBuffer();
    for (final rune in s.runes) {
      final ch = String.fromCharCode(rune);
      final lower = ch.toLowerCase();
      final one = lower.length == ch.length ? lower : ch;
      out.write(_accents[one] ?? one);
    }
    return out.toString();
  }

  /// The words of a query, folded; empty when there's nothing to look for.
  static List<String> terms(String query) => fold(
    query,
  ).split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList(growable: false);

  static bool matches(String text, String sender, List<String> terms) {
    if (terms.isEmpty) return false;
    final hay = fold('$sender\n$text');
    return terms.every(hay.contains);
  }

  /// The hits of [all] matching [query], newest first.
  static List<MessageSearchHit> filter(
    Iterable<MessageSearchHit> all,
    String query,
  ) {
    final t = terms(query);
    final hits = [
      for (final h in all)
        if (matches(h.text, h.sender, t)) h,
    ]..sort((a, b) => b.time.compareTo(a.time));
    return hits;
  }

  /// [text] as spans, with every occurrence of the query's words highlighted.
  static List<TextSpan> highlight(
    String text,
    List<String> terms,
    TextStyle highlightStyle,
  ) {
    if (terms.isEmpty || text.isEmpty) return [TextSpan(text: text)];
    final folded = fold(text);
    final marked = List<bool>.filled(folded.length, false);
    for (final t in terms) {
      var from = 0;
      while (true) {
        final i = folded.indexOf(t, from);
        if (i < 0) break;
        for (var k = i; k < i + t.length && k < marked.length; k++) {
          marked[k] = true;
        }
        from = i + 1;
      }
    }
    // folding keeps one character for each, but surrogate pairs take two code
    // units in [text]; walk both together by rune
    final spans = <TextSpan>[];
    final buf = StringBuffer();
    var on = false;
    var fi = 0;
    for (final rune in text.runes) {
      final ch = String.fromCharCode(rune);
      final isOn = fi < marked.length && marked[fi];
      if (isOn != on && buf.isNotEmpty) {
        spans.add(
          TextSpan(text: buf.toString(), style: on ? highlightStyle : null),
        );
        buf.clear();
      }
      on = isOn;
      buf.write(ch);
      fi += ch.length;
    }
    if (buf.isNotEmpty) {
      spans.add(
        TextSpan(text: buf.toString(), style: on ? highlightStyle : null),
      );
    }
    return spans;
  }
}
