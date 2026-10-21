import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/sos_location_service.dart';

void main() {
  test('only GPS-grade fixes are sent', () {
    // GPS, and a platform that reports no accuracy.
    expect(GeolocatorPhoneLocation.isPreciseEnough(8), isTrue);
    expect(GeolocatorPhoneLocation.isPreciseEnough(0), isTrue);
    expect(GeolocatorPhoneLocation.isPreciseEnough(500), isTrue);
    // Network estimates and Android's approximate location.
    expect(GeolocatorPhoneLocation.isPreciseEnough(1200), isFalse);
    expect(GeolocatorPhoneLocation.isPreciseEnough(2000), isFalse);
  });
}
