import '../helpers/coverage_grid.dart';

/// The radio settings a ping went out on. Coverage is only comparable between
/// pings made on the same settings, so each survey layer is one of these.
class CoverageRadio {
  final int freqHz;
  final int bwHz;
  final int sf;
  final int cr;

  const CoverageRadio({
    required this.freqHz,
    required this.bwHz,
    required this.sf,
    required this.cr,
  });

  String get key => '$freqHz/$bwHz/$sf/$cr';

  /// "916.575 MHz · 62.5 kHz · SF7 · CR7"
  String get label {
    String trim(double v, int places) {
      var s = v.toStringAsFixed(places);
      if (s.contains('.')) {
        s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
      }
      return s;
    }

    return '${trim(freqHz / 1e6, 3)} MHz · ${trim(bwHz / 1e3, 1)} kHz · '
        'SF$sf · CR$cr';
  }

  Map<String, dynamic> toJson() => {
    'freq_hz': freqHz,
    'bw_hz': bwHz,
    'sf': sf,
    'cr': cr,
  };

  static CoverageRadio? fromJson(Object? json) {
    if (json is! Map) return null;
    final f = json['freq_hz'], b = json['bw_hz'], s = json['sf'];
    final c = json['cr'];
    if (f is! int || b is! int || s is! int || c is! int) return null;
    if (f <= 0 || b <= 0 || s < 5 || s > 12 || c < 5 || c > 8) return null;
    return CoverageRadio(freqHz: f, bwHz: b, sf: s, cr: c);
  }

  @override
  bool operator ==(Object other) => other is CoverageRadio && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

/// One repeater's answer to a ping.
class CoverageReply {
  /// Hex public key, or its first 8 bytes when only a prefix was sent.
  final String keyHex;
  final String name;

  /// SNR of the repeater's answer at our radio (dB).
  final double snr;
  final int rssi;

  /// SNR of our ping at the repeater (dB).
  final double remoteSnr;

  /// The repeater's advertised position when the ping was made, if any.
  final double? latitude;
  final double? longitude;

  const CoverageReply({
    required this.keyHex,
    required this.name,
    required this.snr,
    required this.rssi,
    required this.remoteSnr,
    this.latitude,
    this.longitude,
  });

  /// The weaker direction: a link is only as good as its worse half.
  double get linkSnr => snr < remoteSnr ? snr : remoteSnr;

  bool get hasLocation =>
      latitude != null &&
      longitude != null &&
      !(latitude == 0 && longitude == 0);

  Map<String, dynamic> toJson() => {
    'key': keyHex,
    'name': name,
    'snr': snr,
    'rssi': rssi,
    'remote_snr': remoteSnr,
    if (hasLocation) 'lat': latitude,
    if (hasLocation) 'lon': longitude,
  };

  static CoverageReply? fromJson(Object? json) {
    if (json is! Map) return null;
    final key = json['key'];
    final snr = json['snr'], remote = json['remote_snr'];
    if (key is! String || !RegExp(r'^[0-9a-f]{16,64}$').hasMatch(key)) {
      return null;
    }
    if (snr is! num || remote is! num) return null;
    final name = json['name'];
    final rssi = json['rssi'];
    final lat = json['lat'], lon = json['lon'];
    final hasPos =
        lat is num && lon is num && lat.abs() <= 90 && lon.abs() <= 180;
    return CoverageReply(
      keyHex: key,
      name: name is String && name.isNotEmpty
          ? (name.length > 64 ? name.substring(0, 64) : name)
          : key.substring(0, 8).toUpperCase(),
      snr: snr.toDouble(),
      rssi: rssi is int ? rssi : 0,
      remoteSnr: remote.toDouble(),
      latitude: hasPos ? lat.toDouble() : null,
      longitude: hasPos ? lon.toDouble() : null,
    );
  }

  /// True when both keys name the same repeater (one may be a prefix).
  bool sameRepeater(String otherKeyHex) =>
      keyHex.startsWith(otherKeyHex) || otherKeyHex.startsWith(keyHex);
}

/// One ping: where it was sent, on what settings, and who answered.
class CoveragePing {
  final DateTime at;
  final double latitude;
  final double longitude;

  /// GPS accuracy in metres, when known.
  final double? accuracy;
  final CoverageRadio radio;
  final List<CoverageReply> replies;

  /// The radio name of whoever made the ping (shown for imported surveys).
  final String? by;

  const CoveragePing({
    required this.at,
    required this.latitude,
    required this.longitude,
    required this.radio,
    required this.replies,
    this.accuracy,
    this.by,
  });

  /// The same ping imported twice keeps one copy.
  String get id =>
      '${at.millisecondsSinceEpoch}_${latitude.toStringAsFixed(5)}_'
      '${longitude.toStringAsFixed(5)}';

  HexCell get cell => HexCell.at(latitude, longitude);

  Map<String, dynamic> toJson() => {
    'at': at.toUtc().toIso8601String(),
    'lat': latitude,
    'lon': longitude,
    if (accuracy != null) 'acc': accuracy,
    'radio': radio.toJson(),
    if (by != null) 'by': by,
    'replies': [for (final r in replies) r.toJson()],
  };

  static CoveragePing? fromJson(Object? json) {
    if (json is! Map) return null;
    final at = json['at'] is String ? DateTime.tryParse(json['at']) : null;
    final lat = json['lat'], lon = json['lon'];
    final radio = CoverageRadio.fromJson(json['radio']);
    if (at == null || lat is! num || lon is! num || radio == null) return null;
    if (lat.abs() > 90 || lon.abs() > 180) return null;
    final rawReplies = json['replies'];
    final replies = <CoverageReply>[
      if (rawReplies is List)
        for (final r in rawReplies.take(64)) ?CoverageReply.fromJson(r),
    ];
    final acc = json['acc'];
    final by = json['by'];
    return CoveragePing(
      at: at,
      latitude: lat.toDouble(),
      longitude: lon.toDouble(),
      accuracy: acc is num ? acc.toDouble() : null,
      radio: radio,
      replies: replies,
      by: by is String && by.isNotEmpty
          ? (by.length > 64 ? by.substring(0, 64) : by)
          : null,
    );
  }
}

/// What one hexagon shows for the chosen radio settings and repeater.
class CoverageCellSummary {
  final HexCell cell;
  int pings = 0;

  /// Pings here that the chosen repeater (or any repeater) answered.
  int answered = 0;
  double? bestLinkSnr;
  CoverageGrade grade = CoverageGrade.none;

  /// Best link SNR per repeater key heard in this cell.
  final Map<String, double> repeaters = {};

  CoverageCellSummary(this.cell);
}

/// A repeater that answered at least one ping in the current view.
class CoverageRepeater {
  final String keyHex;
  String name;
  double? latitude;
  double? longitude;
  double bestLinkSnr;
  CoverageGrade grade;
  int cells = 0;
  DateTime lastHeard;

  CoverageRepeater({
    required this.keyHex,
    required this.name,
    required this.bestLinkSnr,
    required this.grade,
    required this.lastHeard,
    this.latitude,
    this.longitude,
  });

  bool get hasLocation => latitude != null && longitude != null;
}

/// The coverage map built from a set of pings.
class CoverageMap {
  final Map<HexCell, CoverageCellSummary> cells;
  final Map<String, CoverageRepeater> repeaters;

  const CoverageMap(this.cells, this.repeaters);

  /// Builds the map for one radio layer. With [repeaterKey], a cell counts as
  /// covered only when that repeater answered there.
  factory CoverageMap.build(
    Iterable<CoveragePing> pings, {
    required CoverageRadio? radio,
    String? repeaterKey,
  }) {
    final cells = <HexCell, CoverageCellSummary>{};
    final repeaters = <String, CoverageRepeater>{};
    final repeaterCells = <String, Set<HexCell>>{};
    for (final ping in pings) {
      if (radio != null && ping.radio != radio) continue;
      final cell = ping.cell;
      final summary = cells.putIfAbsent(cell, () => CoverageCellSummary(cell));
      summary.pings++;
      var answered = false;
      for (final reply in ping.replies) {
        final key = _canonicalKey(reply.keyHex, repeaters.keys);
        final link = reply.linkSnr;
        final grade = CoverageSignal.grade(link, ping.radio.sf);
        final existing = repeaters[key];
        if (existing == null) {
          repeaters[key] = CoverageRepeater(
            keyHex: key,
            name: reply.name,
            bestLinkSnr: link,
            grade: grade,
            lastHeard: ping.at,
            latitude: reply.hasLocation ? reply.latitude : null,
            longitude: reply.hasLocation ? reply.longitude : null,
          );
        } else {
          if (link > existing.bestLinkSnr) {
            existing.bestLinkSnr = link;
            existing.grade = grade;
          }
          if (!ping.at.isBefore(existing.lastHeard)) {
            existing.lastHeard = ping.at;
            existing.name = reply.name;
            if (reply.hasLocation) {
              existing.latitude = reply.latitude;
              existing.longitude = reply.longitude;
            }
          } else if (!existing.hasLocation && reply.hasLocation) {
            existing.latitude = reply.latitude;
            existing.longitude = reply.longitude;
          }
        }
        (repeaterCells[key] ??= {}).add(cell);
        final prev = summary.repeaters[key];
        if (prev == null || link > prev) summary.repeaters[key] = link;
        if (repeaterKey != null && !reply.sameRepeater(repeaterKey)) continue;
        answered = true;
        if (summary.bestLinkSnr == null || link > summary.bestLinkSnr!) {
          summary.bestLinkSnr = link;
        }
        summary.grade = CoverageSignal.better(summary.grade, grade);
      }
      if (answered) summary.answered++;
    }
    for (final entry in repeaterCells.entries) {
      repeaters[entry.key]?.cells = entry.value.length;
    }
    return CoverageMap(cells, repeaters);
  }

  /// Full keys and 8-byte prefixes of the same repeater share one entry.
  static String _canonicalKey(String key, Iterable<String> known) {
    for (final k in known) {
      if (k.startsWith(key) || key.startsWith(k)) return k;
    }
    return key;
  }
}
