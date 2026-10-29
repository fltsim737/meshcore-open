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

  /// Copies of this SOS heard passed on by repeaters, every broadcast
  /// together: proof it is travelling, not that anyone has read it.
  int heardRepeats;

  /// The repeaters heard passing it on, by path hash (hex), with how many
  /// copies each.
  final Map<String, int> repeaters;

  OutgoingSos({
    required this.id,
    required this.startedAt,
    this.lastBroadcastAt,
    this.broadcastCount = 0,
    this.lastFix = const SosFix.none(),
    List<SosAck>? acks,
    Set<String>? deliveredContactKeys,
    this.heardRepeats = 0,
    Map<String, int>? repeaters,
  }) : acks = acks ?? [],
       deliveredContactKeys = deliveredContactKeys ?? {},
       repeaters = repeaters ?? {};

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
    'heard_repeats': heardRepeats,
    'repeaters': repeaters,
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
    heardRepeats: json['heard_repeats'] as int? ?? 0,
    repeaters: {
      for (final e
          in (json['repeaters'] as Map<dynamic, dynamic>? ?? const {}).entries)
        e.key.toString(): (e.value as num).toInt(),
    },
  );
}

/// A cancelled SOS whose cancellation is still being sent. The channel copy
/// repeats a few times, and direct copies repeat until delivered, so a
/// responder who misses one still hears that the SOS is over.
class SosCancellation {
  final String id;
  final DateTime cancelledAt;

  /// Responders who acknowledged, who get a direct copy even when they are
  /// not emergency contacts.
  final Set<String> responderKeys;

  /// Contacts whose radio confirmed delivery of a direct copy.
  final Set<String> deliveredKeys;

  int sends;
  DateTime? lastSentAt;

  SosCancellation({
    required this.id,
    required this.cancelledAt,
    Set<String>? responderKeys,
    Set<String>? deliveredKeys,
    this.sends = 0,
    this.lastSentAt,
  }) : responderKeys = responderKeys ?? {},
       deliveredKeys = deliveredKeys ?? {};

  Map<String, dynamic> toJson() => {
    'id': id,
    'cancelled_at': cancelledAt.millisecondsSinceEpoch,
    'responder_keys': responderKeys.toList(),
    'delivered_keys': deliveredKeys.toList(),
    'sends': sends,
    'last_sent_at': lastSentAt?.millisecondsSinceEpoch,
  };

  factory SosCancellation.fromJson(Map<String, dynamic> json) =>
      SosCancellation(
        id: json['id'] as String,
        cancelledAt: _timeFromJson(json['cancelled_at']) ?? DateTime.now(),
        responderKeys: (json['responder_keys'] as List<dynamic>? ?? const [])
            .map((e) => e.toString())
            .toSet(),
        deliveredKeys: (json['delivered_keys'] as List<dynamic>? ?? const [])
            .map((e) => e.toString())
            .toSet(),
        sends: json['sends'] as int? ?? 0,
        lastSentAt: _timeFromJson(json['last_sent_at']),
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

  /// Put aside on this phone with Dismiss. It's kept, so the responder can
  /// bring it back at once with Show again, until the sender cancels it or it
  /// expires; a repeat brings back one that wasn't acknowledged.
  bool dismissed;

  /// The sender's line of text, such as a short address, if it sent one.
  String? info;

  /// Other nodes seen acknowledging this SOS.
  final Set<String> ackedBy;

  /// On an SOS2 network: the ref of this SOS's keys, which seal our ACK and
  /// Locate requests to it.
  String? sessionRef;

  /// The sender's radio settings, when its SOS says (9.8.3 apps, MeshCore
  /// SOS firmware 1.7.0).
  SosRadio? senderRadio;

  /// Other responders who retuned their radio for this SOS (to the sender's
  /// settings, say across a bridge) and so may be out of reach on ours, by
  /// name, with the settings they moved to. Cleared when they say they're
  /// back.
  final Map<String, SosRadio> retunedResponders;

  /// The ways copies of this SOS reached our radio, with how many came each
  /// way: the repeaters' path hashes (hex) joined by commas, nearest the
  /// sender first, or '' for straight from the sender's radio.
  final Map<String, int> routes;

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
    this.dismissed = false,
    this.info,
    this.sessionRef,
    Set<String>? ackedBy,
    Map<String, int>? routes,
    this.senderRadio,
    Map<String, SosRadio>? retunedResponders,
  }) : ackedBy = ackedBy ?? {},
       routes = routes ?? {},
       retunedResponders = retunedResponders ?? {};

  /// Heard straight from the sender's radio at least once, so its Locate
  /// beacons can reach this radio.
  bool get heardDirect => routes.containsKey('');

  /// [routes], most copies first.
  List<MapEntry<String, int>> get routesByCount =>
      routes.entries.toList()..sort((a, b) => b.value.compareTo(a.value));

  static List<String> routeHops(String route) =>
      route.isEmpty ? const [] : route.split(',');

  String get key => keyFor(senderName, id);

  static String keyFor(String senderName, String id) => '$senderName#$id';

  /// Needs attention until this device acknowledges or dismisses it.
  /// Cancelled and expired alerts are deleted outright.
  bool get isOpen => !ackSent && !dismissed;

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
    'dismissed': dismissed,
    'info': info,
    'acked_by': ackedBy.toList(),
    'session_ref': sessionRef,
    'routes': routes,
    'sender_radio': senderRadio?.toJson(),
    'retuned_responders': {
      for (final e in retunedResponders.entries) e.key: e.value.toJson(),
    },
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
      dismissed: json['dismissed'] as bool? ?? false,
      info: json['info'] as String?,
      sessionRef: json['session_ref'] as String?,
      ackedBy: (json['acked_by'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toSet(),
      routes: {
        for (final e
            in (json['routes'] as Map<dynamic, dynamic>? ?? const {}).entries)
          e.key.toString(): (e.value as num).toInt(),
      },
      senderRadio: SosRadio.fromJson(json['sender_radio']),
      retunedResponders: {
        for (final e
            in (json['retuned_responders'] as Map<dynamic, dynamic>? ??
                    const {})
                .entries)
          e.key.toString(): ?SosRadio.fromJson(e.value),
      },
    );
  }
}

/// This phone's radio, retuned with Retune to an SOS sender's settings, and
/// the settings to go back to. Kept until the responder goes back, also over
/// a restart: nothing switches back by itself.
class SosRetune {
  final String alertKey;
  final String alertId;
  final String senderName;
  final SosRadio from;
  final SosRadio to;
  final DateTime at;

  const SosRetune({
    required this.alertKey,
    required this.alertId,
    required this.senderName,
    required this.from,
    required this.to,
    required this.at,
  });

  Map<String, dynamic> toJson() => {
    'alert_key': alertKey,
    'alert_id': alertId,
    'sender_name': senderName,
    'from': from.toJson(),
    'to': to.toJson(),
    'at': at.millisecondsSinceEpoch,
  };

  static SosRetune? fromJson(Map<String, dynamic> json) {
    final from = SosRadio.fromJson(json['from']);
    final to = SosRadio.fromJson(json['to']);
    final at = _timeFromJson(json['at']);
    if (from == null || to == null || at == null) return null;
    return SosRetune(
      alertKey: json['alert_key'] as String? ?? '',
      alertId: json['alert_id'] as String? ?? '',
      senderName: json['sender_name'] as String? ?? '',
      from: from,
      to: to,
      at: at,
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
