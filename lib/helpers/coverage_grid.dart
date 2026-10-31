import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// One hexagon of the coverage map, in axial coordinates on a Web Mercator
/// plane. The grid is fixed worldwide, so surveys from different phones land
/// in the same cells and merge cleanly.
class HexCell {
  final int q;
  final int r;

  const HexCell(this.q, this.r);

  /// Hexagon circumradius in Web Mercator metres. Mercator stretches with
  /// latitude, so on the ground a cell is about 120 m across at the equator
  /// and about 100 m across at 35 degrees.
  static const double radius = 70;

  static const double _earthRadius = 6378137;
  static final double _sqrt3 = math.sqrt(3);

  factory HexCell.at(double latitude, double longitude) {
    final p = _toMercator(latitude, longitude);
    final qf = (_sqrt3 / 3 * p.x - p.y / 3) / radius;
    final rf = (2 / 3 * p.y) / radius;
    return _round(qf, rf);
  }

  /// Parses [key], or null when it isn't one.
  static HexCell? parse(String key) {
    final parts = key.split(',');
    if (parts.length != 2) return null;
    final q = int.tryParse(parts[0]);
    final r = int.tryParse(parts[1]);
    if (q == null || r == null) return null;
    return HexCell(q, r);
  }

  String get key => '$q,$r';

  LatLng get centre {
    final x = radius * _sqrt3 * (q + r / 2);
    final y = radius * 1.5 * r;
    return _fromMercator(x, y);
  }

  /// The six corners, pointy-top, anticlockwise from the east-north-east one.
  List<LatLng> get corners {
    final cx = radius * _sqrt3 * (q + r / 2);
    final cy = radius * 1.5 * r;
    return [
      for (var i = 0; i < 6; i++)
        _fromMercator(
          cx + radius * math.cos(math.pi / 180 * (60 * i - 30)),
          cy + radius * math.sin(math.pi / 180 * (60 * i - 30)),
        ),
    ];
  }

  static HexCell _round(double qf, double rf) {
    final sf = -qf - rf;
    var q = qf.round();
    var r = rf.round();
    final s = sf.round();
    final dq = (q - qf).abs();
    final dr = (r - rf).abs();
    final ds = (s - sf).abs();
    if (dq > dr && dq > ds) {
      q = -r - s;
    } else if (dr > ds) {
      r = -q - s;
    }
    return HexCell(q, r);
  }

  static ({double x, double y}) _toMercator(double lat, double lon) {
    final clamped = lat.clamp(-85.0, 85.0);
    final x = _earthRadius * lon * math.pi / 180;
    final y =
        _earthRadius *
        math.log(math.tan(math.pi / 4 + clamped * math.pi / 360));
    return (x: x, y: y);
  }

  static LatLng _fromMercator(double x, double y) {
    final lon = x / _earthRadius * 180 / math.pi;
    final lat =
        (2 * math.atan(math.exp(y / _earthRadius)) - math.pi / 2) *
        180 /
        math.pi;
    return LatLng(lat, lon);
  }

  @override
  bool operator ==(Object other) =>
      other is HexCell && other.q == q && other.r == r;

  @override
  int get hashCode => Object.hash(q, r);

  @override
  String toString() => 'HexCell($q, $r)';
}

/// How usable a link is, from the weaker of the two directions.
enum CoverageGrade {
  /// 10 dB or more above what the radio can still decode.
  strong,

  /// 5 to 10 dB above.
  good,

  /// 0 to 5 dB above: works, but drops out easily.
  weak,

  /// Heard, but below the usual decode limit: unreliable.
  marginal,

  /// Pinged here and no repeater answered.
  none,
}

class CoverageSignal {
  CoverageSignal._();

  /// The lowest SNR LoRa can usually still decode at [spreadingFactor]
  /// (SF7 -7.5 dB, falling 2.5 dB per step to SF12 -20 dB).
  static double decodeFloor(int? spreadingFactor) {
    final sf = (spreadingFactor ?? 7).clamp(5, 12);
    return -7.5 - 2.5 * (sf - 7);
  }

  static CoverageGrade grade(double linkSnr, int? spreadingFactor) {
    final margin = linkSnr - decodeFloor(spreadingFactor);
    if (margin >= 10) return CoverageGrade.strong;
    if (margin >= 5) return CoverageGrade.good;
    if (margin >= 0) return CoverageGrade.weak;
    return CoverageGrade.marginal;
  }

  /// Better grades first, so `a.index < b.index` means a is better.
  static CoverageGrade better(CoverageGrade a, CoverageGrade b) =>
      a.index <= b.index ? a : b;
}

/// Metres between two points along the ground.
double coverageDistanceMetres(
  double lat1,
  double lon1,
  double lat2,
  double lon2,
) {
  const earth = 6371000.0;
  final p1 = lat1 * math.pi / 180;
  final p2 = lat2 * math.pi / 180;
  final dp = (lat2 - lat1) * math.pi / 180;
  final dl = (lon2 - lon1) * math.pi / 180;
  final a =
      math.sin(dp / 2) * math.sin(dp / 2) +
      math.cos(p1) * math.cos(p2) * math.sin(dl / 2) * math.sin(dl / 2);
  return earth * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}
