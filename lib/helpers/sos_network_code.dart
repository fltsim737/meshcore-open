import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:base32/base32.dart';
import 'package:crypto/crypto.dart';

/// What a holder of an emergency network code may do.
enum SosNetworkRole {
  /// Sends SOS alerts into the network; the channel stays hidden.
  member('M'),

  /// Also sees the channel and receives alerts.
  responder('R');

  final String letter;
  const SosNetworkRole(this.letter);
}

/// An emergency network: a private channel whose key travels as a code.
///
/// The typed form is `SOS1-R-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX`: the role
/// letter, then the 16-byte channel key and one check byte in base32. The QR
/// form appends `#` and the URI-encoded network name.
///
/// Both roles carry the same key (senders need it to encrypt), so the role
/// is enforced by the app, not by the encryption.
class SosNetworkCode {
  static const String _prefix = 'SOS1';
  static const int keySize = 16;
  static const String defaultName = 'Emergency';

  final SosNetworkRole role;
  final Uint8List key;
  final String name;

  SosNetworkCode({required this.role, required this.key, String? name})
    : name = (name == null || name.trim().isEmpty) ? defaultName : name.trim();

  /// A new network with a random key.
  static Uint8List generateKey([Random? random]) {
    final rng = random ?? Random.secure();
    return Uint8List.fromList(List.generate(keySize, (_) => rng.nextInt(256)));
  }

  SosNetworkCode withRole(SosNetworkRole newRole) =>
      SosNetworkCode(role: newRole, key: key, name: name);

  static int _check(SosNetworkRole role, Uint8List key) =>
      sha256.convert([...utf8.encode(role.letter), ...key]).bytes.first;

  /// The code to type or read out.
  String get text {
    final body = base32
        .encode(Uint8List.fromList([...key, _check(role, key)]))
        .replaceAll('=', '');
    final groups = [
      for (var i = 0; i < body.length; i += 4)
        body.substring(i, min(i + 4, body.length)),
    ];
    return '$_prefix-${role.letter}-${groups.join('-')}';
  }

  /// The QR payload, which also carries the network name.
  String get qrData => '$text#${Uri.encodeComponent(name)}';

  static final RegExp _inText = RegExp(
    r'SOS1-[MR](?:-[A-Z2-7]{1,4})+(?:#\S+)?',
    caseSensitive: false,
  );

  /// The valid codes written somewhere in free text, such as a repeater's
  /// operator info, in order and without repeats.
  static List<SosNetworkCode> findIn(String text) {
    final found = <SosNetworkCode>[];
    final seen = <String>{};
    for (final match in _inText.allMatches(text)) {
      final code = parse(match.group(0)!);
      if (code != null && seen.add(code.text)) found.add(code);
    }
    return found;
  }

  /// Parses a typed code or QR payload; null if it is not a valid code.
  static SosNetworkCode? parse(String input) {
    var raw = input.trim();
    String? name;
    final hash = raw.indexOf('#');
    if (hash >= 0) {
      try {
        name = Uri.decodeComponent(raw.substring(hash + 1));
      } catch (_) {
        name = null;
      }
      raw = raw.substring(0, hash);
    }
    final compact = raw.toUpperCase().replaceAll(RegExp(r'[\s-]'), '');
    if (!compact.startsWith(_prefix) || compact.length < _prefix.length + 2) {
      return null;
    }
    final roleLetter = compact[_prefix.length];
    final role = SosNetworkRole.values
        .where((r) => r.letter == roleLetter)
        .firstOrNull;
    if (role == null) return null;
    var body = compact.substring(_prefix.length + 1);
    while (body.length % 8 != 0) {
      body += '=';
    }
    final Uint8List bytes;
    try {
      bytes = Uint8List.fromList(base32.decode(body));
    } catch (_) {
      return null;
    }
    if (bytes.length != keySize + 1) return null;
    final key = Uint8List.fromList(bytes.sublist(0, keySize));
    if (bytes[keySize] != _check(role, key)) return null;
    return SosNetworkCode(role: role, key: key, name: name);
  }
}
