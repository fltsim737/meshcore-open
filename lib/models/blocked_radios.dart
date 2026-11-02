import 'dart:convert';
import 'dart:typed_data';

/// A radio the user blocked (10.2.4).
///
/// Most blocks name a radio by its public key ([keyHex], at least the first
/// [BlockedRadios.prefixHexLength] hex digits). A channel message carries only
/// a name, so a sender with no known key can be blocked by [name] alone
/// ([keyHex] null); such a block only hides channel messages.
class BlockedRadio {
  final String? keyHex;
  final String name;
  final DateTime blockedAt;

  const BlockedRadio({
    required this.keyHex,
    required this.name,
    required this.blockedAt,
  });

  /// The id the list is kept by: the key prefix, or `name:<name>`.
  String get id => keyHex != null
      ? keyHex!.substring(0, BlockedRadios.prefixHexLength)
      : 'name:$name';

  Map<String, dynamic> toJson() => {
    if (keyHex != null) 'k': keyHex,
    'n': name,
    't': blockedAt.millisecondsSinceEpoch,
  };

  static BlockedRadio? fromJson(Object? json) {
    if (json is! Map) return null;
    final key = json['k'];
    final name = json['n'];
    final t = json['t'];
    if (name is! String) return null;
    final keyHex = key is String ? BlockedRadios.normaliseKeyHex(key) : null;
    if (key != null && keyHex == null) return null;
    if (keyHex == null && name.trim().isEmpty) return null;
    return BlockedRadio(
      keyHex: keyHex,
      name: name,
      blockedAt: DateTime.fromMillisecondsSinceEpoch(t is int ? t : 0),
    );
  }
}

/// The phone's list of blocked radios, kept for every radio the phone
/// connects to (a radio that floods the mesh does so everywhere).
///
/// A blocked radio's adverts are ignored (it never shows in Discovered or
/// Contacts), it's removed from the connected radio's contacts, its direct
/// messages are dropped, and channel messages sent under its name are
/// hidden. SOS alerts are never blocked.
class BlockedRadios {
  static const String prefsKey = 'blocked_radios';

  /// Keys match on their first 6 bytes, as the SOS radio firmware does.
  static const int prefixHexLength = 12;

  final Map<String, BlockedRadio> _byId = {};

  /// Lower-case hex of at least [prefixHexLength] digits, else null.
  static String? normaliseKeyHex(String hex) {
    final h = hex.trim().toLowerCase();
    if (h.length < prefixHexLength || h.length.isOdd) return null;
    if (!RegExp(r'^[0-9a-f]+$').hasMatch(h)) return null;
    return h;
  }

  static String keyPrefixHex(Uint8List key) {
    final n = key.length < prefixHexLength ~/ 2
        ? key.length
        : prefixHexLength ~/ 2;
    return key
        .sublist(0, n)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  /// Newest first.
  List<BlockedRadio> get all =>
      _byId.values.toList()..sort((a, b) => b.blockedAt.compareTo(a.blockedAt));

  bool get isEmpty => _byId.isEmpty;

  bool isKeyBlocked(Uint8List key) =>
      key.length >= prefixHexLength ~/ 2 &&
      _byId.containsKey(keyPrefixHex(key));

  bool isKeyHexBlocked(String keyHex) {
    final h = normaliseKeyHex(keyHex);
    return h != null && _byId.containsKey(h.substring(0, prefixHexLength));
  }

  /// A channel message's sender name matches a blocked radio's name.
  bool isNameBlocked(String? senderName) {
    final n = senderName?.trim();
    if (n == null || n.isEmpty) return false;
    return _byId.values.any((b) => b.name.trim() == n);
  }

  /// Adds (or renames) a block. Returns it, or null for a bad key or a blank
  /// name-only block.
  BlockedRadio? add({String? keyHex, required String name, DateTime? at}) {
    final hex = keyHex == null ? null : normaliseKeyHex(keyHex);
    if (keyHex != null && hex == null) return null;
    if (hex == null && name.trim().isEmpty) return null;
    final entry = BlockedRadio(
      keyHex: hex,
      name: name.trim(),
      blockedAt: at ?? DateTime.now(),
    );
    final existing = _byId[entry.id];
    // keep the fuller key, and the original time
    _byId[entry.id] = existing == null
        ? entry
        : BlockedRadio(
            keyHex: (existing.keyHex?.length ?? 0) >= (hex?.length ?? 0)
                ? existing.keyHex
                : hex,
            name: entry.name.isNotEmpty ? entry.name : existing.name,
            blockedAt: existing.blockedAt,
          );
    return _byId[entry.id];
  }

  bool remove(String id) => _byId.remove(id) != null;

  BlockedRadio? byId(String id) => _byId[id];

  void load(String? json) {
    _byId.clear();
    if (json == null || json.isEmpty) return;
    try {
      final list = jsonDecode(json);
      if (list is! List) return;
      for (final item in list) {
        final b = BlockedRadio.fromJson(item);
        if (b != null) _byId[b.id] = b;
      }
    } catch (_) {
      // a damaged list starts empty
    }
  }

  String toJson() => jsonEncode([for (final b in all) b.toJson()]);

  /// Parses the SOS radio's `block list` reply: `> <count>|<hex12>,<name>|...`,
  /// ending `|+` when more follow. Returns the entries and whether more follow.
  static (List<({String keyHex, String name})>, bool) parseRadioList(
    String reply,
  ) {
    final entries = <({String keyHex, String name})>[];
    var text = reply.trim();
    if (!text.startsWith('>')) return (entries, false);
    final parts = text.substring(1).split('|');
    var more = false;
    for (final p in parts.skip(1)) {
      if (p == '+') {
        more = true;
        continue;
      }
      final comma = p.indexOf(',');
      final hex = normaliseKeyHex(comma < 0 ? p : p.substring(0, comma));
      if (hex == null) continue;
      entries.add((keyHex: hex, name: comma < 0 ? '' : p.substring(comma + 1)));
    }
    return (entries, more);
  }
}
