import '../helpers/sos_seal.dart';

/// One SOS's keys on an SOS2 network: our own SOS's, or another sender's
/// that this responder has opened.
class SosSessionEntry {
  final String id;
  final SosSession session;

  /// Our own SOS: we hold its one-off secret.
  final bool own;

  /// The network public key it was made for (hex), so a session for an old
  /// network is never reused after joining a new one.
  final String networkHex;
  DateTime lastUsed;

  SosSessionEntry({
    required this.id,
    required this.session,
    required this.own,
    required this.networkHex,
    required this.lastUsed,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'session': session.toJson(),
    'own': own,
    'network': networkHex,
    'last_used': lastUsed.millisecondsSinceEpoch,
  };

  static SosSessionEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final session = SosSession.fromJson(json['session']);
    final id = json['id'];
    final network = json['network'];
    final used = json['last_used'];
    if (session == null || id is! String || network is! String) return null;
    return SosSessionEntry(
      id: id,
      session: session,
      own: json['own'] == true,
      networkHex: network,
      lastUsed: DateTime.fromMillisecondsSinceEpoch(used is int ? used : 0),
    );
  }
}

/// The SOS keys this phone knows, found by an SOS's ref (the first bytes of
/// its one-off public key). Kept a day after last use, so a responder who
/// checks back long after a cancel still gets an answer; our own live SOS's
/// keys are kept for as long as it lasts.
class SosSessionBook {
  static const Duration keep = Duration(hours: 24);
  static const int maxEntries = 64;

  final Map<String, SosSessionEntry> _byRef = {};

  Iterable<SosSessionEntry> get entries => _byRef.values;

  SosSessionEntry? byRef(String refHex) => _byRef[refHex];

  /// Our own SOS [id]'s keys for the network [networkHex], if made.
  SosSessionEntry? own(String id, String networkHex) => _byRef.values
      .where((e) => e.own && e.id == id && e.networkHex == networkHex)
      .firstOrNull;

  void add(SosSessionEntry entry) {
    _byRef[entry.session.refHex] = entry;
    if (_byRef.length > maxEntries) {
      final oldest = _byRef.values.reduce(
        (a, b) => a.lastUsed.isBefore(b.lastUsed) ? a : b,
      );
      _byRef.remove(oldest.session.refHex);
    }
  }

  /// Drops entries unused for [keep], except the live SOS [activeId]'s.
  bool prune(DateTime now, {String? activeId}) {
    final before = _byRef.length;
    _byRef.removeWhere(
      (_, e) =>
          !(e.own && e.id == activeId) && now.difference(e.lastUsed) > keep,
    );
    return _byRef.length != before;
  }

  void clear() => _byRef.clear();

  List<Map<String, dynamic>> toJson() => [
    for (final e in _byRef.values) e.toJson(),
  ];

  void load(Object? json) {
    _byRef.clear();
    if (json is! List) return;
    for (final item in json) {
      final entry = SosSessionEntry.fromJson(item);
      if (entry != null) _byRef[entry.session.refHex] = entry;
    }
  }
}
