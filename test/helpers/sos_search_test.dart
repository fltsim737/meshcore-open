import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/sos_search.dart';

/// Metres east and north of a point, as latitude and longitude.
({double lat, double lon}) offset(
  double lat,
  double lon,
  double east,
  double north,
) => (
  lat: lat + north / 111320.0,
  lon: lon + east / (111320.0 * math.cos(lat * math.pi / 180)),
);

double metresBetween(double lat1, double lon1, double lat2, double lon2) {
  final dy = (lat1 - lat2) * 111320.0;
  final dx = (lon1 - lon2) * 111320.0 * math.cos(lat1 * math.pi / 180);
  return math.sqrt(dx * dx + dy * dy);
}

/// The RSSI the model gives at [metres] from a beacon at [tx] dBm (its inverse).
int rssiAt(double metres, int tx) {
  for (var rssi = 0; rssi > -140; rssi--) {
    if (SosSearch.rangeMetres(rssi, tx) >= metres) return rssi;
  }
  return -140;
}

void main() {
  const lat = -30.98, lon = 151.59; // near Walcha
  final now = DateTime(2026, 10, 29, 12);

  SosSearchReading at(
    String who,
    double east,
    double north,
    int tx, {
    double factor = 1,
  }) {
    final p = offset(lat, lon, east, north);
    final d = math.sqrt(east * east + north * north) * factor;
    return SosSearchReading(
      who: who,
      latitude: p.lat,
      longitude: p.lon,
      rssiDbm: rssiAt(d, tx),
      beaconPower: tx,
      at: now,
    );
  }

  test('a stronger beacon or a lower power means nearer', () {
    expect(
      SosSearch.rangeMetres(-60, 22),
      lessThan(SosSearch.rangeMetres(-100, 22)),
    );
    expect(
      SosSearch.rangeMetres(-80, 2),
      lessThan(SosSearch.rangeMetres(-80, 22)),
    );
    // 20 dB less power, same strength heard: much closer
    expect(
      SosSearch.rangeMetres(-80, 22) / SosSearch.rangeMetres(-80, 2),
      closeTo(math.pow(10, 20 / 27), 0.5),
    );
    final ring = SosSearch.ring(-90, 22);
    expect(ring.inner, lessThan(SosSearch.rangeMetres(-90, 22)));
    expect(ring.outer, greaterThan(SosSearch.rangeMetres(-90, 22)));
  });

  test('one place gives a ring, not an area', () {
    expect(SosSearch.estimate([at('a', 300, 0, 22)], now: now), isNull);
    expect(
      SosSearch.estimate([at('a', 300, 0, 22), at('b', 303, 2, 22)], now: now),
      isNull,
    );
  });

  test('three searchers around the caller find it', () {
    final e = SosSearch.estimate([
      at('a', 400, 0, 22),
      at('b', -250, 300, 22),
      at('c', -100, -350, 22),
    ], now: now)!;
    expect(e.places, 3);
    final miss = metresBetween(e.latitude, e.longitude, lat, lon);
    expect(miss, lessThan(60));
    expect(
      miss,
      lessThanOrEqualTo(e.radiusMetres),
    ); // the caller is inside the area
  });

  test('two searchers: the caller is inside the area', () {
    final e = SosSearch.estimate([
      at('a', 300, 0, 22),
      at('b', 0, 300, 22),
    ], now: now)!;
    expect(
      metresBetween(e.latitude, e.longitude, lat, lon),
      lessThanOrEqualTo(e.radiusMetres),
    );
  });

  test('rough readings still put the caller in the area', () {
    // each ring 40% out, one way or the other, as terrain does
    final e = SosSearch.estimate([
      at('a', 500, 100, 22, factor: 1.4),
      at('b', -300, 400, 22, factor: 0.7),
      at('c', -200, -450, 22, factor: 1.3),
      at('d', 350, -350, 22, factor: 0.75),
    ], now: now)!;
    expect(
      metresBetween(e.latitude, e.longitude, lat, lon),
      lessThanOrEqualTo(e.radiusMetres),
    );
  });

  test('closing in at low power narrows the area', () {
    final far = SosSearch.estimate([
      at('a', 900, 0, 22),
      at('b', -600, 700, 22),
      at('c', -300, -800, 22),
    ], now: now)!;
    final near = SosSearch.estimate([
      at('a', 60, 0, -9),
      at('b', -40, 50, -9),
      at('c', -20, -55, -9),
    ], now: now)!;
    expect(near.radiusMetres, lessThan(far.radiusMetres));
    expect(
      metresBetween(near.latitude, near.longitude, lat, lon),
      lessThan(20),
    );
  });

  test('old readings are left out', () {
    final old = SosSearchReading(
      who: 'b',
      latitude: offset(lat, lon, 0, 300).lat,
      longitude: offset(lat, lon, 0, 300).lon,
      rssiDbm: -90,
      beaconPower: 22,
      at: now.subtract(const Duration(minutes: 11)),
    );
    expect(SosSearch.estimate([at('a', 300, 0, 22), old], now: now), isNull);
  });
}
