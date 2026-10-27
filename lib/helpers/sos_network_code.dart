import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:base32/base32.dart';
import 'package:crypto/crypto.dart';

import 'sos_seal.dart';

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
/// **SOS2** (sealed, made since 9.7.0): the responder code holds the
/// network's X25519 secret, the member code only its public key. Each SOS is
/// sealed to that public key ([SosSeal]), so only responders can read it,
/// and everything else about it (ACKs, the cancel, Locate, voice) is sealed
/// with that SOS's own key. A member code can send but can't read alerts,
/// and can't be turned into a responder code. The channel key, which only
/// hides the packets from radios outside the network, comes from the public
/// key. Typed form: `SOS2-R-` and the 32-byte secret (or `SOS2-M-` and the
/// public key) plus one check byte, `sha256("SOS2" + letter + body)[0]`, in
/// base32 groups of four.
///
/// **SOS1** (older networks): both codes carry the same 16-byte channel key,
/// so the role is kept by the app, not by the encryption. Still joined and
/// understood, so a group can move to a new network at its own pace.
///
/// The QR form appends `#` and the URI-encoded network name.
class SosNetworkCode {
  static const String _prefix1 = 'SOS1';
  static const String _prefix2 = 'SOS2';
  static const int keySize = 16;
  static const int sealedKeySize = 32;
  static const String defaultName = 'Emergency';

  final SosNetworkRole role;

  /// 1: a shared channel key. 2: sealed.
  final int version;

  /// SOS1: the channel key. SOS2: the network secret (responder) or public
  /// key (member).
  final Uint8List secret;
  final String name;

  /// An SOS1 network with the shared channel [key].
  SosNetworkCode({required this.role, required Uint8List key, String? name})
    : version = 1,
      secret = key,
      name = _cleanName(name);

  /// An SOS2 network: [secret] is the network secret for a responder, or
  /// the network public key for a member.
  SosNetworkCode.sealed({
    required this.role,
    required this.secret,
    String? name,
  }) : version = 2,
       name = _cleanName(name);

  static String _cleanName(String? name) =>
      (name == null || name.trim().isEmpty) ? defaultName : name.trim();

  bool get isSealed => version == 2;

  /// The network's public key (SOS2 only).
  Uint8List? get networkPublicKey => !isSealed
      ? null
      : role == SosNetworkRole.responder
      ? SosSeal.publicKeyFor(secret)
      : secret;

  /// The network secret, which reads alerts (SOS2 responders only).
  Uint8List? get networkSecret =>
      isSealed && role == SosNetworkRole.responder ? secret : null;

  /// The radio channel's 16-byte key.
  Uint8List get key =>
      isSealed ? SosSeal.channelKeyFor(networkPublicKey!) : secret;

  /// A new random SOS1 channel key (tests and older networks only).
  static Uint8List generateKey([Random? random]) {
    final rng = random ?? Random.secure();
    return Uint8List.fromList(List.generate(keySize, (_) => rng.nextInt(256)));
  }

  /// A new SOS2 network, held as its responder.
  static SosNetworkCode generateSealed({String? name, Random? random}) {
    final rng = random ?? Random.secure();
    return SosNetworkCode.sealed(
      role: SosNetworkRole.responder,
      secret: Uint8List.fromList(
        List.generate(sealedKeySize, (_) => rng.nextInt(256)),
      ),
      name: name,
    );
  }

  /// Whether this code can produce [newRole]'s code: an SOS2 member holds
  /// only the public key, so it can never make a responder code.
  bool canMakeRole(SosNetworkRole newRole) =>
      !isSealed ||
      newRole == SosNetworkRole.member ||
      role == SosNetworkRole.responder;

  /// The same network in [newRole]; see [canMakeRole].
  SosNetworkCode withRole(SosNetworkRole newRole) {
    if (!isSealed) return SosNetworkCode(role: newRole, key: key, name: name);
    if (!canMakeRole(newRole)) {
      throw StateError('A member code cannot make a responder code');
    }
    return SosNetworkCode.sealed(
      role: newRole,
      secret: newRole == SosNetworkRole.responder ? secret : networkPublicKey!,
      name: name,
    );
  }

  SosNetworkCode withName(String? newName) => isSealed
      ? SosNetworkCode.sealed(role: role, secret: secret, name: newName)
      : SosNetworkCode(role: role, key: secret, name: newName);

  String get _prefix => isSealed ? _prefix2 : _prefix1;

  static int _check(int version, SosNetworkRole role, Uint8List body) => sha256
      .convert([
        if (version == 2) ...utf8.encode(_prefix2),
        ...utf8.encode(role.letter),
        ...body,
      ])
      .bytes
      .first;

  /// The code to type or read out.
  String get text {
    final body = base32
        .encode(Uint8List.fromList([...secret, _check(version, role, secret)]))
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
    r'SOS[12]-[MR](?:-[A-Z2-7]{1,4})+(?:#\S+)?',
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
    final int version;
    if (compact.startsWith(_prefix1)) {
      version = 1;
    } else if (compact.startsWith(_prefix2)) {
      version = 2;
    } else {
      return null;
    }
    if (compact.length < _prefix1.length + 2) return null;
    final roleLetter = compact[_prefix1.length];
    final role = SosNetworkRole.values
        .where((r) => r.letter == roleLetter)
        .firstOrNull;
    if (role == null) return null;
    var body = compact.substring(_prefix1.length + 1);
    while (body.length % 8 != 0) {
      body += '=';
    }
    final Uint8List bytes;
    try {
      bytes = Uint8List.fromList(base32.decode(body));
    } catch (_) {
      return null;
    }
    final size = version == 2 ? sealedKeySize : keySize;
    if (bytes.length != size + 1) return null;
    final secret = Uint8List.fromList(bytes.sublist(0, size));
    if (bytes[size] != _check(version, role, secret)) return null;
    if (version == 1) {
      return SosNetworkCode(role: role, key: secret, name: name);
    }
    final code = SosNetworkCode.sealed(role: role, secret: secret, name: name);
    // A public key that X25519 can't use would make every SOS unreadable.
    if (!SosSeal.isUsablePublicKey(code.networkPublicKey!)) return null;
    return code;
  }
}
