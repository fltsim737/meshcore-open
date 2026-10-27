import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart'
    show KeyPairType, SecretKeyData, SimpleKeyPairData, SimplePublicKey;
import 'package:cryptography/dart.dart' show DartX25519;
import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart' as pc;

import 'sos_codec.dart';

/// The keys for one SOS on an SOS2 network, shared by its sender and every
/// responder, and by nobody else: members can't work them out.
class SosSession {
  /// The sender's one-off public key for this SOS, carried in every alert.
  final Uint8List ephPublic;
  final Uint8List encKey;
  final Uint8List macKey;

  /// The sender's one-off secret: only on the sending phone, kept with the
  /// SOS so a restart can carry on with the same keys.
  final Uint8List? ephSecret;

  SosSession({
    required this.ephPublic,
    required this.encKey,
    required this.macKey,
    this.ephSecret,
  });

  /// What other packets about this SOS carry instead of the whole key.
  Uint8List get ref => Uint8List.sublistView(ephPublic, 0, SosSeal.refSize);
  String get refHex => _hex(ref);

  Map<String, dynamic> toJson() => {
    'eph_public': _hex(ephPublic),
    'enc_key': _hex(encKey),
    'mac_key': _hex(macKey),
    if (ephSecret != null) 'eph_secret': _hex(ephSecret!),
  };

  static SosSession? fromJson(Object? json) {
    if (json is! Map) return null;
    final eph = _unhex(json['eph_public']);
    final enc = _unhex(json['enc_key']);
    final mac = _unhex(json['mac_key']);
    if (eph == null || enc == null || mac == null) return null;
    if (eph.length != 32 || enc.length != 16 || mac.length != 32) return null;
    return SosSession(
      ephPublic: eph,
      encKey: enc,
      macKey: mac,
      ephSecret: _unhex(json['eph_secret']),
    );
  }
}

/// The cleartext start of a sealed packet: enough to find its [SosSession].
class SosSealedHeader {
  /// The SOS kind (or voice quality) byte.
  final int kind;
  final String id;

  /// The sender's one-off public key, in an SOS; null in other packets.
  final Uint8List? ephPublic;
  final Uint8List ref;
  final int length;

  const SosSealedHeader({
    required this.kind,
    required this.id,
    required this.ephPublic,
    required this.ref,
    required this.length,
  });

  String get refHex => _hex(ref);
}

/// SOS2 sealing, shared with the MeshCore SOS radio's firmware.
///
/// Per SOS the sender makes a one-off X25519 key pair and works out a shared
/// secret with the network's public key; responders work out the same from
/// the network secret and the one-off public key. From it come an AES-128
/// key and an HMAC-SHA256 key ([SosSession]).
///
/// A sealed packet is `[2][kind][id u16]`, then the one-off public key (in
/// an SOS) or its first 4 bytes (in everything else), a 6-byte random nonce,
/// the body encrypted with AES-128-CTR (IV: the nonce and 10 zero bytes),
/// and the first 8 bytes of HMAC-SHA256 over everything before it. The body
/// is the SOS1 packet without its first 4 bytes; an SOS also drops the key
/// prefix, as the full key follows anyway.
class SosSeal {
  static const int version = 2;
  static const int refSize = 4;
  static const int nonceSize = 6;
  static const int tagSize = 8;
  static const int keySize = 32;

  /// What sealing adds to a non-SOS packet's body: ref, nonce and tag.
  static const int overhead = refSize + nonceSize + tagSize;

  static const DartX25519 _x25519 = DartX25519();
  static final Uint8List _basePoint = Uint8List(32)..[0] = 9;

  static Uint8List _x(Uint8List secret, Uint8List public) {
    final pair = SimpleKeyPairData(
      DartX25519.modifiedPrivateKeyBytes(secret),
      publicKey: SimplePublicKey(_basePoint, type: KeyPairType.x25519),
      type: KeyPairType.x25519,
    );
    final shared = _x25519.sharedSecretSync(
      keyPairData: pair,
      remotePublicKey: SimplePublicKey(public, type: KeyPairType.x25519),
    );
    return Uint8List.fromList((shared as SecretKeyData).bytes);
  }

  /// The network's (or a one-off) public key for [secret].
  static Uint8List publicKeyFor(Uint8List secret) => _x(secret, _basePoint);

  /// The radio channel key that goes with a network public key.
  static Uint8List channelKeyFor(Uint8List networkPublic) => Uint8List.fromList(
    sha256
        .convert([...utf8.encode('MeshCore SOS2 channel'), ...networkPublic])
        .bytes
        .sublist(0, 16),
  );

  /// False for the few points X25519 turns into an all-zero secret.
  static bool isUsablePublicKey(Uint8List public) =>
      public.length == keySize && !_isZero(_x(_basePoint, public));

  static bool _isZero(Uint8List b) => b.every((v) => v == 0);

  static SosSession? _session(
    Uint8List shared,
    Uint8List ephPublic, [
    Uint8List? ephSecret,
  ]) {
    if (_isZero(shared)) return null;
    List<int> derive(int label) => sha256.convert([
      label,
      ...utf8.encode('SOS2'),
      ...shared,
      ...ephPublic,
    ]).bytes;
    return SosSession(
      ephPublic: ephPublic,
      encKey: Uint8List.fromList(derive(1).sublist(0, 16)),
      macKey: Uint8List.fromList(derive(2)),
      ephSecret: ephSecret,
    );
  }

  /// A new SOS's keys, for its sender.
  static SosSession newSession(Uint8List networkPublic, {Random? random}) {
    final rng = random ?? Random.secure();
    while (true) {
      final secret = Uint8List.fromList(
        List.generate(keySize, (_) => rng.nextInt(256)),
      );
      final session = senderSession(secret, networkPublic);
      if (session != null) return session;
    }
  }

  /// The sender's keys from its one-off [ephSecret].
  static SosSession? senderSession(
    Uint8List ephSecret,
    Uint8List networkPublic,
  ) => _session(
    _x(ephSecret, networkPublic),
    publicKeyFor(ephSecret),
    ephSecret,
  );

  /// A responder's keys for the SOS whose one-off public key is [ephPublic].
  static SosSession? responderSession(
    Uint8List networkSecret,
    Uint8List ephPublic,
  ) => _session(_x(networkSecret, ephPublic), ephPublic);

  static Uint8List _nonce(Random? random) {
    final rng = random ?? Random.secure();
    return Uint8List.fromList(
      List.generate(nonceSize, (_) => rng.nextInt(256)),
    );
  }

  static Uint8List _ctr(Uint8List key, Uint8List nonce, Uint8List data) {
    final iv = Uint8List(16)..setRange(0, nonceSize, nonce);
    final cipher = pc.CTRStreamCipher(pc.AESEngine())
      ..init(true, pc.ParametersWithIV(pc.KeyParameter(key), iv));
    return cipher.process(data);
  }

  static Uint8List _tag(SosSession s, List<int> signed) => Uint8List.fromList(
    Hmac(sha256, s.macKey).convert(signed).bytes.sublist(0, tagSize),
  );

  /// Seals [body] under the 4-byte [head] `[2][kind][id u16]`, followed by
  /// the whole one-off key when [fullKey], else its ref.
  static Uint8List sealRaw(
    List<int> head,
    SosSession s,
    List<int> body, {
    bool fullKey = false,
    Uint8List? nonce,
    Random? random,
  }) {
    final n = nonce ?? _nonce(random);
    final header = [...head, ...(fullKey ? s.ephPublic : s.ref)];
    final ct = _ctr(s.encKey, n, Uint8List.fromList(body));
    final signed = [...header, ...n, ...ct];
    return Uint8List.fromList([...signed, ..._tag(s, signed)]);
  }

  /// The body of a packet sealed with [s], or null when it wasn't (another
  /// SOS, someone without the keys, or a damaged packet).
  static Uint8List? openRaw(Uint8List data, int headerLength, SosSession s) {
    if (data.length < headerLength + nonceSize + tagSize) return null;
    final signedEnd = data.length - tagSize;
    final expected = _tag(s, Uint8List.sublistView(data, 0, signedEnd));
    var diff = 0;
    for (var i = 0; i < tagSize; i++) {
      diff |= expected[i] ^ data[signedEnd + i];
    }
    if (diff != 0) return null;
    final nonce = Uint8List.sublistView(
      data,
      headerLength,
      headerLength + nonceSize,
    );
    return _ctr(
      s.encKey,
      Uint8List.fromList(nonce),
      Uint8List.sublistView(data, headerLength + nonceSize, signedEnd),
    );
  }

  /// The cleartext start of a sealed packet; [fullKeyKind] is the kind that
  /// carries the whole one-off key (null: none does, as in voice).
  static SosSealedHeader? header(Uint8List data, {int? fullKeyKind = 1}) {
    if (data.length < 4 || data[0] != version) return null;
    final full = fullKeyKind != null && data[1] == fullKeyKind;
    final length = 4 + (full ? keySize : refSize);
    if (data.length < length + nonceSize + tagSize) return null;
    final key = Uint8List.fromList(data.sublist(4, length));
    return SosSealedHeader(
      kind: data[1],
      id: (data[2] | (data[3] << 8)).toRadixString(16).padLeft(4, '0'),
      ephPublic: full ? key : null,
      ref: Uint8List.fromList(key.sublist(0, refSize)),
      length: length,
    );
  }

  /// Seals an SOS packet; an SOS must carry the sender's full key.
  static Uint8List sealPacket(
    SosPacket packet,
    SosSession s, {
    Uint8List? nonce,
    Random? random,
  }) {
    final plain = packet.encode();
    final isSos = packet.kind == SosPacketKind.sos;
    if (isSos && packet.senderKey?.length != SosPacket.publicKeySize) {
      throw ArgumentError('A sealed SOS carries the full key');
    }
    return sealRaw(
      [version, ...plain.sublist(1, 4)],
      s,
      plain.sublist(isSos ? 4 + SosPacket.keyPrefixSize : 4),
      fullKey: isSos,
      nonce: nonce,
      random: random,
    );
  }

  /// Opens a sealed SOS packet with [s]; null if it isn't one of its packets.
  static SosPacket? openPacket(Uint8List data, SosSession s) {
    final head = header(data);
    if (head == null) return null;
    final body = openRaw(data, head.length, s);
    if (body == null) return null;
    final prefix = <int>[];
    if (head.kind == SosPacketKind.sos.code) {
      // [name len][name][time 4][source][has position][lat 4][lon 4][key]
      if (body.isEmpty) return null;
      final keyAt = 1 + body[0] + 14;
      if (body.length < keyAt + SosPacket.publicKeySize) return null;
      prefix.addAll(body.sublist(keyAt, keyAt + SosPacket.keyPrefixSize));
    }
    return SosPacket.decode(
      Uint8List.fromList([
        SosPacket.version,
        head.kind,
        data[2],
        data[3],
        ...prefix,
        ...body,
      ]),
    );
  }
}

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List? _unhex(Object? value) {
  if (value is! String || value.length.isOdd) return null;
  final out = Uint8List(value.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final b = int.tryParse(value.substring(i * 2, i * 2 + 2), radix: 16);
    if (b == null) return null;
    out[i] = b;
  }
  return out;
}
