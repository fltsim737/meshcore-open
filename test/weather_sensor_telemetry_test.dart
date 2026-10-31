import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/cayenne_lpp.dart';
import 'package:meshcore_open/screens/telemetry_screen.dart';

/// Telemetry as the MeshCore weather sensor firmware builds it (layout 1).
Uint8List weatherFrame({bool marker = true}) {
  final b = BytesBuilder();
  void i16(int v) => b.add([(v >> 8) & 0xFF, v & 0xFF]);
  void u32(int v) =>
      b.add([(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF]);
  b.add([1, 116]); // ch1 voltage 4.10 V
  i16(410);
  b.add([1, 103]); // ch1 MCU temperature 30.0
  i16(300);
  if (marker) b.add([99, 0, 1]); // marker: digital input 1
  b.add([2, 103]); // air temperature 12.1
  i16(121);
  b.add([2, 104, 192]); // humidity 96 %
  b.add([2, 115]); // pressure 1008.1 hPa
  i16(10081);
  b.add([3, 103]); // dew point 11.4
  i16(114);
  b.add([4, 2]); // wind speed 9.00 km/h
  i16(900);
  b.add([4, 3]); // gust 10.90 km/h
  i16(1090);
  b.add([4, 132]); // direction 9 degrees
  i16(9);
  b.add([5, 2]); // rain rate 33.78 mm/h
  i16(3378);
  b.add([5, 3]); // rain today 9.65 mm
  i16(965);
  b.add([6, 2]); // UV 0
  i16(0);
  b.add([6, 100]); // solar 2 W/m2 (generic)
  u32(2);
  return b.toBytes();
}

void main() {
  test('weather sensor telemetry is recognised by its marker', () {
    final parsed = CayenneLpp.parseByChannel(weatherFrame());
    expect(isWeatherSensorTelemetry(parsed), isTrue);
  });

  test('ordinary sensor telemetry is not treated as weather', () {
    final parsed = CayenneLpp.parseByChannel(weatherFrame(marker: false));
    expect(isWeatherSensorTelemetry(parsed), isFalse);
    expect(isWeatherSensorTelemetry(null), isFalse);
    expect(isWeatherSensorTelemetry(const []), isFalse);
  });

  test('a marker with another value is not layout 1', () {
    final parsed = CayenneLpp.parseByChannel(
      Uint8List.fromList([99, 0, 2, 2, 103, 0, 121]),
    );
    expect(isWeatherSensorTelemetry(parsed), isFalse);
  });

  test('weather readings decode to the expected values per channel', () {
    final parsed = CayenneLpp.parseByChannel(weatherFrame());
    Map<String, dynamic> ch(int n) =>
        parsed.firstWhere((c) => c['channel'] == n)['values']
            as Map<String, dynamic>;
    expect(ch(2)['temperature'], closeTo(12.1, 0.001));
    expect(ch(2)['humidity'], 96);
    expect(ch(2)['pressure'], closeTo(1008.1, 0.001));
    expect(ch(3)['temperature'], closeTo(11.4, 0.001));
    expect(ch(4)['analogInput'], closeTo(9.0, 0.001));
    expect(ch(4)['analogOutput'], closeTo(10.9, 0.001));
    expect(ch(4)['direction'], 9);
    expect(ch(5)['analogInput'], closeTo(33.78, 0.001));
    expect(ch(5)['analogOutput'], closeTo(9.65, 0.001));
    expect(ch(6)['analogInput'], 0);
    expect(ch(6)['generic'], 2);
  });
}
