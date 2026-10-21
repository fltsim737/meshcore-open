import '../helpers/sos_codec.dart';

class SosAck {
  final String senderName;
  final String? senderKeyHex;
  final DateTime receivedAt;

  const SosAck({
    required this.senderName,
    required this.receivedAt,
    this.senderKeyHex,
  });

  Map<String, dynamic> toJson() => {
    'sender_name': senderName,
    'sender_key_hex': senderKeyHex,
    'received_at': receivedAt.millisecondsSinceEpoch,
  };

  factory SosAck.fromJson(Map<String, dynamic> json) => SosAck(
    senderName: json['sender_name'] as String? ?? '',
    senderKeyHex: json['sender_key_hex'] as String?,
    receivedAt: DateTime.fromMillisecondsSinceEpoch(
      json['received_at'] as int? ?? 0,
    ),
  );
}

Map<String, dynamic> _fixToJson(SosFix fix) => {
  'lat': fix.latitude,
  'lon': fix.longitude,
  'source': fix.source.name,
};

SosFix _fixFromJson(Object? json) {
  if (json is! Map) return const SosFix.none();
  return SosFix(
    latitude: (json['lat'] as num?)?.toDouble(),
    longitude: (json['lon'] as num?)?.toDouble(),
    source: SosLocationSource.values.firstWhere(
      (s) => s.name == json['source'],
      orElse: () => SosLocationSource.none,
    ),
  );
}

DateTime? _timeFromJson(Object? ms) =>
    ms is int ? DateTime.fromMillisecondsSinceEpoch(ms) : null;

/// The SOS this device is sending. Stays active until the user cancels it.
class OutgoingSos {
  final String id;
  final DateTime startedAt;
  DateTime? lastBroadcastAt;
  int broadcastCount;
  SosFix lastFix;
  final List<SosAck> acks;

  /// Contacts whose radio confirmed delivery of an SOS direct message.
  final Set<String> deliveredContactKeys;

  OutgoingSos({
    required this.id,
    required this.startedAt,
    this.lastBroadcastAt,
    this.broadcastCount = 0,
    this.lastFix = const SosFix.none(),
    List<SosAck>? acks,
    Set<String>? deliveredContactKeys,
  }) : acks = acks ?? [],
       deliveredContactKeys = deliveredContactKeys ?? {};

  bool get isAcknowledged => acks.isNotEmpty;

  /// Delivered to, or acknowledged by, this contact. A channel ACK carries
  /// only a name, so the contact's name counts too.
  bool isContactAcknowledged(String keyHex, String name) =>
      deliveredContactKeys.contains(keyHex) ||
      acks.any((ack) => ack.senderKeyHex == keyHex || ack.senderName == name);

  Map<String, dynamic> toJson() => {
    'id': id,
    'started_at': startedAt.millisecondsSinceEpoch,
    'last_broadcast_at': lastBroadcastAt?.millisecondsSinceEpoch,
    'broadcast_count': broadcastCount,
    'last_fix': _fixToJson(lastFix),
    'acks': acks.map((ack) => ack.toJson()).toList(),
    'delivered_contact_keys': deliveredContactKeys.toList(),
  };

  factory OutgoingSos.fromJson(Map<String, dynamic> json) => OutgoingSos(
    id: json['id'] as String,
    startedAt: _timeFromJson(json['started_at']) ?? DateTime.now(),
    lastBroadcastAt: _timeFromJson(json['last_broadcast_at']),
    broadcastCount: json['broadcast_count'] as int? ?? 0,
    lastFix: _fixFromJson(json['last_fix']),
    acks: (json['acks'] as List<dynamic>? ?? const [])
        .map((e) => SosAck.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(),
    deliveredContactKeys:
        (json['delivered_contact_keys'] as List<dynamic>? ?? const [])
            .map((e) => e.toString())
            .toSet(),
  );
}

/// An SOS heard from another node, merged across repeats, channel and DM.
class IncomingSos {
  final String id;
  final String senderName;
  String? senderKeyHex;
  int? channelIndex;
  final DateTime firstSeen;
  DateTime lastSeen;
  SosFix fix;
  int receivedCount;
  bool ackSent;

  /// Other nodes seen acknowledging this SOS.
  final Set<String> ackedBy;

  IncomingSos({
    required this.id,
    required this.senderName,
    required this.firstSeen,
    required this.lastSeen,
    required this.fix,
    this.senderKeyHex,
    this.channelIndex,
    this.receivedCount = 1,
    this.ackSent = false,
    Set<String>? ackedBy,
  }) : ackedBy = ackedBy ?? {};

  String get key => keyFor(senderName, id);

  static String keyFor(String senderName, String id) => '$senderName#$id';

  /// Needs attention until this device acknowledges it. Dismissed, cancelled
  /// and expired alerts are deleted outright.
  bool get isOpen => !ackSent;

  Map<String, dynamic> toJson() => {
    'id': id,
    'sender_name': senderName,
    'sender_key_hex': senderKeyHex,
    'channel_index': channelIndex,
    'first_seen': firstSeen.millisecondsSinceEpoch,
    'last_seen': lastSeen.millisecondsSinceEpoch,
    'fix': _fixToJson(fix),
    'received_count': receivedCount,
    'ack_sent': ackSent,
    'acked_by': ackedBy.toList(),
  };

  factory IncomingSos.fromJson(Map<String, dynamic> json) {
    final firstSeen = _timeFromJson(json['first_seen']) ?? DateTime.now();
    return IncomingSos(
      id: json['id'] as String,
      senderName: json['sender_name'] as String? ?? '',
      senderKeyHex: json['sender_key_hex'] as String?,
      channelIndex: json['channel_index'] as int?,
      firstSeen: firstSeen,
      lastSeen: _timeFromJson(json['last_seen']) ?? firstSeen,
      fix: _fixFromJson(json['fix']),
      receivedCount: json['received_count'] as int? ?? 1,
      ackSent: json['ack_sent'] as bool? ?? false,
      ackedBy: (json['acked_by'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toSet(),
    );
  }
}

/// A text message the connector heard, offered to the SOS service.
class SosInboundText {
  final String text;
  final String senderName;
  final String? senderKeyHex;
  final int? channelIndex;

  const SosInboundText({
    required this.text,
    required this.senderName,
    this.senderKeyHex,
    this.channelIndex,
  });
}
