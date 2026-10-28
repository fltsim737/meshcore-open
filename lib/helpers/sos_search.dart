import 'dart:math' as math;

/// One beacon heard by a searcher, where they stood when they heard it.
class SosSearchReading {
  final String who; // the searcher (key prefix hex, or 'me')
  final double latitude;
  final double longitude;
  final int rssiDbm;
  final int beaconPower; // dBm the beacon was sent at
  final DateTime at;

  const SosSearchReading({
    required this.who,
    required this.latitude,
    required this.longitude,
    required this.rssiDbm,
    required this.beaconPower,
    required this.at,
  });
}

/// Where the SOS radio probably is: a point, and how far around it to search.
class SosSearchEstimate {
  final double latitude;
  final double longitude;
  final double radiusMetres;
  final int readings;
  final int places; // the different spots they were taken from

  const SosSearchEstimate({
    required this.latitude,
    required this.longitude,
    required this.radiusMetres,
    required this.readings,
    required this.places,
  });
}

/// Turns beacon strengths into distances, and several searchers' distances into
/// a search area. Signal strength only gives a distance, and a rough one
/// (terrain, trees and bodies weaken it), so each reading is a ring, and the
/// estimate is where the rings agree: an area to search, not a pin.
class SosSearch {
  /// How fast the signal fades with distance: 2 in open air, about 2.7 over
  /// ground with some cover.
  static const double pathLossExponent = 2.7;

  /// Antennas, cable and a body or two, on top of free-space loss at 1 m.
  static const double extraLossDb = 6;

  /// How far a ring may be out either way (one standard deviation): a factor
  /// of about 1.8.
  static const double rangeSpread = 1.8;

  /// Readings older than this are left out: searchers move, so does the signal.
  static const Duration maxAge = Duration(minutes: 10);

  /// Places closer than this count as one.
  static const double samePlaceMetres = 10;

  /// Roughly how far away a beacon heard at [rssiDbm] was, sent at [txDbm].
  static double rangeMetres(
    int rssiDbm,
    int txDbm, {
    double frequencyMhz = 915,
  }) {
    final atOneMetre = 20 * _log10(frequencyMhz) - 27.55 + extraLossDb;
    final loss = txDbm - rssiDbm - atOneMetre;
    final d = math.pow(10, loss / (10 * pathLossExponent)).toDouble();
    return d.clamp(1.0, 50000.0);
  }

  /// The ring's inner and outer edge, one spread either side.
  static ({double inner, double outer}) ring(
    int rssiDbm,
    int txDbm, {
    double frequencyMhz = 915,
  }) {
    final r = rangeMetres(rssiDbm, txDbm, frequencyMhz: frequencyMhz);
    return (inner: r / rangeSpread, outer: r * rangeSpread);
  }

  /// The search area from [readings]: null until they come from at least two
  /// places, as one place gives a ring, not an area.
  static SosSearchEstimate? estimate(
    List<SosSearchReading> readings, {
    DateTime? now,
    double frequencyMhz = 915,
  }) {
    final cutoff = (now ?? DateTime.now()).subtract(maxAge);
    final used = readings.where((r) => r.at.isAfter(cutoff)).toList();
    if (used.length < 2) return null;

    // a flat local map around the readings, in metres
    final lat0 =
        used.map((r) => r.latitude).reduce((a, b) => a + b) / used.length;
    final lon0 =
        used.map((r) => r.longitude).reduce((a, b) => a + b) / used.length;
    final mPerLat = 111320.0;
    final mPerLon = 111320.0 * math.cos(lat0 * math.pi / 180);
    final pts = [
      for (final r in used)
        (
          x: (r.longitude - lon0) * mPerLon,
          y: (r.latitude - lat0) * mPerLat,
          range: rangeMetres(
            r.rssiDbm,
            r.beaconPower,
            frequencyMhz: frequencyMhz,
          ),
        ),
    ];

    final places = <({double x, double y})>[];
    for (final p in pts) {
      if (!places.any((q) => _dist(p.x, p.y, q.x, q.y) < samePlaceMetres)) {
        places.add((x: p.x, y: p.y));
      }
    }
    if (places.length < 2) return null;

    // the fit: how far, in log terms, each ring is from a point (log, so that
    // being 100 m out on a 50 m ring counts more than on a 2 km one)
    double cost(double x, double y) {
      var c = 0.0;
      for (final p in pts) {
        final d = math.max(1.0, _dist(x, y, p.x, p.y));
        final e = math.log(d / p.range);
        c += e * e;
      }
      return c;
    }

    final maxRange = pts.map((p) => p.range).reduce(math.max);
    final half = (maxRange * 1.5).clamp(200.0, 20000.0);
    var best = (x: 0.0, y: 0.0, c: double.infinity);
    const n = 80;
    final step = 2 * half / n;
    final grid = <({double x, double y, double c})>[];
    for (var i = 0; i <= n; i++) {
      for (var j = 0; j <= n; j++) {
        final x = -half + i * step, y = -half + j * step;
        final c = cost(x, y);
        grid.add((x: x, y: y, c: c));
        if (c < best.c) best = (x: x, y: y, c: c);
      }
    }
    // a finer look around the best spot
    final fine = step / 10;
    for (var i = -15; i <= 15; i++) {
      for (var j = -15; j <= 15; j++) {
        final x = best.x + i * fine, y = best.y + j * fine;
        final c = cost(x, y);
        if (c < best.c) best = (x: x, y: y, c: c);
      }
    }

    // everywhere that fits nearly as well: within about one standard
    // deviation for a two-coordinate fit
    final sigma = math.log(rangeSpread);
    final limit = best.c + 2.3 * sigma * sigma;
    var radius = fine * 2;
    for (final g in grid) {
      if (g.c <= limit) {
        radius = math.max(radius, _dist(g.x, g.y, best.x, best.y));
      }
    }
    radius = math.max(radius, step); // never finer than the grid could tell

    return SosSearchEstimate(
      latitude: lat0 + best.y / mPerLat,
      longitude: lon0 + best.x / mPerLon,
      radiusMetres: radius,
      readings: used.length,
      places: places.length,
    );
  }

  static double _dist(double x1, double y1, double x2, double y2) =>
      math.sqrt((x1 - x2) * (x1 - x2) + (y1 - y2) * (y1 - y2));

  static double _log10(double v) => math.log(v) / math.ln10;
}
