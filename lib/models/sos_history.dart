import '../helpers/sos_codec.dart';

enum SosHistoryDirection { received, sent }

/// How an alert ended, or [ongoing] while it is still live.
enum SosHistoryOutcome {
  ongoing,
  cancelledBySender,
  cancelledByMe,
  dismissed,
  expired,
  leftNetwork,
}

/// A position heard (or sent) at a given time.
class SosHistoryPosition {
  final DateTime at;
  final SosFix fix;

  const SosHistoryPosition(this.at, this.fix);

  Map<String, dynamic> toJson() => {
    'at': at.millisecondsSinceEpoch,
    'lat': fix.latitude,
    'lon': fix.longitude,
    'source': fix.source.name,
  };

  factory SosHistoryPosition.fromJson(Map<String, dynamic> json) =>
      SosHistoryPosition(
        DateTime.fromMillisecondsSinceEpoch(json['at'] as int? ?? 0),
        SosFix(
          latitude: (json['lat'] as num?)?.toDouble(),
          longitude: (json['lon'] as num?)?.toDouble(),
          source: SosLocationSource.values.firstWhere(
            (s) => s.name == json['source'],
            orElse: () => SosLocationSource.none,
          ),
        ),
      );
}

/// Someone who acknowledged (or, for [SosHistoryRecord.deliveredTo], whose
/// radio confirmed delivery), and when this phone first heard it.
class SosHistoryEvent {
  final String name;
  final DateTime at;

  const SosHistoryEvent(this.name, this.at);

  Map<String, dynamic> toJson() => {
    'name': name,
    'at': at.millisecondsSinceEpoch,
  };

  factory SosHistoryEvent.fromJson(Map<String, dynamic> json) =>
      SosHistoryEvent(
        json['name'] as String? ?? '',
        DateTime.fromMillisecondsSinceEpoch(json['at'] as int? ?? 0),
      );
}

/// A lasting record of one SOS, received or sent, kept after the live alert
/// is gone so it can be handed to paramedics or emergency services. Kept
/// until the user deletes it.
class SosHistoryRecord {
  /// Positions kept per record; a long SOS repeats every 5 minutes.
  static const int maxPositions = 500;

  final SosHistoryDirection direction;
  final String id;

  /// Who sent it: the other node, or this radio's name for a sent SOS.
  final String senderName;
  String? senderKeyHex;
  String? info;

  /// First heard, or when this phone started sending.
  final DateTime startedAt;

  /// Last heard, or last broadcast.
  DateTime lastAt;

  /// Times heard, or broadcasts made.
  int count;

  /// How it was heard: `network`, `DM`, `channel text`.
  final Set<String> heardVia;
  final List<SosHistoryPosition> positions;

  /// Received: when this phone sent its ACK.
  DateTime? ackSentAt;

  /// Received: others who acknowledged. Sent: responders who acknowledged.
  final List<SosHistoryEvent> acks;

  /// Sent: emergency contacts whose radio confirmed the direct message.
  final List<SosHistoryEvent> deliveredTo;

  SosHistoryOutcome outcome;
  DateTime? endedAt;

  SosHistoryRecord({
    required this.direction,
    required this.id,
    required this.senderName,
    required this.startedAt,
    required this.lastAt,
    this.senderKeyHex,
    this.info,
    this.count = 0,
    this.ackSentAt,
    this.outcome = SosHistoryOutcome.ongoing,
    this.endedAt,
    Set<String>? heardVia,
    List<SosHistoryPosition>? positions,
    List<SosHistoryEvent>? acks,
    List<SosHistoryEvent>? deliveredTo,
  }) : heardVia = heardVia ?? {},
       positions = positions ?? [],
       acks = acks ?? [],
       deliveredTo = deliveredTo ?? [];

  bool get isOngoing => outcome == SosHistoryOutcome.ongoing;

  SosFix? get latestFix => positions.isEmpty ? null : positions.last.fix;

  /// Adds [fix] unless it has no position or matches the last one.
  void addPosition(DateTime at, SosFix fix) {
    if (!fix.hasPosition) return;
    final last = latestFix;
    if (last != null &&
        last.latitude == fix.latitude &&
        last.longitude == fix.longitude &&
        last.source == fix.source) {
      return;
    }
    positions.add(SosHistoryPosition(at, fix));
    if (positions.length > maxPositions) positions.removeAt(0);
  }

  /// Adds [name] to [list] once.
  static bool addEvent(List<SosHistoryEvent> list, String name, DateTime at) {
    if (name.isEmpty || list.any((e) => e.name == name)) return false;
    list.add(SosHistoryEvent(name, at));
    return true;
  }

  void end(SosHistoryOutcome how, DateTime at) {
    if (!isOngoing) return;
    outcome = how;
    endedAt = at;
  }

  Map<String, dynamic> toJson() => {
    'direction': direction.name,
    'id': id,
    'sender_name': senderName,
    'sender_key_hex': senderKeyHex,
    'info': info,
    'started_at': startedAt.millisecondsSinceEpoch,
    'last_at': lastAt.millisecondsSinceEpoch,
    'count': count,
    'heard_via': heardVia.toList(),
    'positions': positions.map((p) => p.toJson()).toList(),
    'ack_sent_at': ackSentAt?.millisecondsSinceEpoch,
    'acks': acks.map((e) => e.toJson()).toList(),
    'delivered_to': deliveredTo.map((e) => e.toJson()).toList(),
    'outcome': outcome.name,
    'ended_at': endedAt?.millisecondsSinceEpoch,
  };

  factory SosHistoryRecord.fromJson(Map<String, dynamic> json) {
    DateTime? time(Object? ms) =>
        ms is int ? DateTime.fromMillisecondsSinceEpoch(ms) : null;
    List<Map<String, dynamic>> maps(Object? list) => (list as List? ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final startedAt = time(json['started_at']) ?? DateTime.now();
    return SosHistoryRecord(
      direction: SosHistoryDirection.values.firstWhere(
        (d) => d.name == json['direction'],
        orElse: () => SosHistoryDirection.received,
      ),
      id: json['id'] as String? ?? '',
      senderName: json['sender_name'] as String? ?? '',
      senderKeyHex: json['sender_key_hex'] as String?,
      info: json['info'] as String?,
      startedAt: startedAt,
      lastAt: time(json['last_at']) ?? startedAt,
      count: json['count'] as int? ?? 0,
      heardVia: (json['heard_via'] as List? ?? [])
          .map((e) => e.toString())
          .toSet(),
      positions: maps(
        json['positions'],
      ).map(SosHistoryPosition.fromJson).toList(),
      ackSentAt: time(json['ack_sent_at']),
      acks: maps(json['acks']).map(SosHistoryEvent.fromJson).toList(),
      deliveredTo: maps(
        json['delivered_to'],
      ).map(SosHistoryEvent.fromJson).toList(),
      outcome: SosHistoryOutcome.values.firstWhere(
        (o) => o.name == json['outcome'],
        orElse: () => SosHistoryOutcome.ongoing,
      ),
      endedAt: time(json['ended_at']),
    );
  }

  /// A plain-text report to hand over, e.g. to paramedics. Fixed English,
  /// like the SOS messages themselves, so whoever receives it can read it.
  String toReport() {
    String two(int v) => v.toString().padLeft(2, '0');
    String local(DateTime t) {
      final l = t.toLocal();
      return '${l.year}-${two(l.month)}-${two(l.day)} '
          '${two(l.hour)}:${two(l.minute)}:${two(l.second)} ${l.timeZoneName}';
    }

    String utc(DateTime t) {
      final u = t.toUtc();
      return '${two(u.hour)}:${two(u.minute)}:${two(u.second)} UTC';
    }

    String when(DateTime t) => '${local(t)} (${utc(t)})';
    String coords(SosFix f) =>
        '${f.latitude!.toStringAsFixed(5)}, ${f.longitude!.toStringAsFixed(5)}';

    final received = direction == SosHistoryDirection.received;
    final lines = <String>[
      'EMERGENCY SOS RECORD',
      'Alert: #$id (${received ? 'received by this phone' : 'sent from this phone'})',
      '${received ? 'From' : 'Sent by'}: ${senderName.isEmpty ? 'unknown' : senderName}',
      if (senderKeyHex != null) 'Public key: $senderKeyHex',
      if (info != null) 'Info: $info',
      '${received ? 'First heard' : 'Started'}: ${when(startedAt)}',
      '${received ? 'Last heard' : 'Last sent'}: ${when(lastAt)}',
      received
          ? 'Times heard: $count${heardVia.isEmpty ? '' : ' (${heardVia.join(', ')})'}'
          : 'Broadcasts: $count',
    ];
    final fix = latestFix;
    if (fix == null) {
      lines.add('Position: none received');
    } else {
      lines
        ..add('Latest position: ${coords(fix)} (${fix.source.wireLabel})')
        ..add(
          'Map: https://www.openstreetmap.org/?mlat=${fix.latitude!.toStringAsFixed(5)}'
          '&mlon=${fix.longitude!.toStringAsFixed(5)}#map=16/'
          '${fix.latitude!.toStringAsFixed(5)}/${fix.longitude!.toStringAsFixed(5)}',
        );
      if (positions.length > 1) {
        lines.add('Positions:');
        for (final p in positions) {
          lines.add(
            '  ${local(p.at)}  ${coords(p.fix)}  ${p.fix.source.wireLabel}',
          );
        }
      }
    }
    if (received) {
      lines.add(
        ackSentAt == null
            ? 'Acknowledged by this phone: no'
            : 'Acknowledged by this phone: ${when(ackSentAt!)}',
      );
    }
    if (acks.isNotEmpty) {
      lines.add('${received ? 'Also acknowledged by' : 'Acknowledged by'}:');
      for (final a in acks) {
        lines.add('  ${a.name} at ${local(a.at)}');
      }
    } else if (!received) {
      lines.add('Acknowledged by: nobody heard');
    }
    if (deliveredTo.isNotEmpty) {
      lines.add('Message delivered to:');
      for (final d in deliveredTo) {
        lines.add('  ${d.name} at ${local(d.at)}');
      }
    }
    final ended = endedAt == null ? '' : ' at ${when(endedAt!)}';
    lines.add(
      'Outcome: ${switch (outcome) {
        SosHistoryOutcome.ongoing => 'still in progress',
        SosHistoryOutcome.cancelledBySender => 'cancelled by the sender$ended',
        SosHistoryOutcome.cancelledByMe => 'cancelled from this phone$ended',
        SosHistoryOutcome.dismissed => 'dismissed on this phone$ended',
        SosHistoryOutcome.expired => 'no longer heard (expired)$ended',
        SosHistoryOutcome.leftNetwork => 'removed when this phone left the network$ended',
      }}',
    );
    lines.add('Recorded by MeshCore Open SOS. LoRa delivery is best effort.');
    return lines.join('\n');
  }
}
