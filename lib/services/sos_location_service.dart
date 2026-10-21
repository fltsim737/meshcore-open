import 'dart:async';

import 'package:geolocator/geolocator.dart';

import '../helpers/sos_codec.dart';
import '../utils/app_logger.dart';

/// The phone's own position for an SOS, or null when it has none.
abstract class PhoneLocationProvider {
  /// Never prompts and gives up after about [timeout]: an SOS must not sit
  /// behind a permission dialog or a slow first fix.
  Future<SosFix?> currentFix({Duration timeout});

  /// Asks for location permission if it has not been refused for good.
  /// Call from the foreground only.
  Future<bool> requestPermission();
}

class GeolocatorPhoneLocation implements PhoneLocationProvider {
  /// A last-known position this recent is used without waiting for a fix.
  static const Duration freshLastKnownAge = Duration(minutes: 2);

  /// A last-known position this recent still beats having none.
  static const Duration maxLastKnownAge = Duration(minutes: 10);

  /// Coarser than this is a network estimate, not GPS (Android's approximate
  /// location is about 2 km): the radio's or stored position is better.
  static const double maxAccuracyMetres = 500;

  /// Whether a reported accuracy is good enough to send. Zero means the
  /// platform did not report one.
  static bool isPreciseEnough(double accuracyMetres) =>
      accuracyMetres <= maxAccuracyMetres;

  @override
  Future<SosFix?> currentFix({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    try {
      return await _currentFix(
        timeout,
      ).timeout(timeout + const Duration(seconds: 2), onTimeout: () => null);
    } catch (e) {
      appLogger.warn('Phone location unavailable: $e', tag: 'SOS');
      return null;
    }
  }

  Future<SosFix?> _currentFix(Duration timeout) async {
    if (!await Geolocator.isLocationServiceEnabled()) return null;
    final permission = await Geolocator.checkPermission();
    if (permission != LocationPermission.always &&
        permission != LocationPermission.whileInUse) {
      return null;
    }
    final last = await _lastKnown();
    if (last != null && _age(last) <= freshLastKnownAge) {
      final fix = _toFix(last);
      if (fix != null) return fix;
    }
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: timeout,
        ),
      );
      return _toFix(position);
    } on TimeoutException {
      if (last == null || _age(last) > maxLastKnownAge) return null;
      return _toFix(last);
    }
  }

  /// Not supported on every platform (web throws).
  Future<Position?> _lastKnown() async {
    try {
      return await Geolocator.getLastKnownPosition();
    } catch (_) {
      return null;
    }
  }

  Duration _age(Position position) =>
      DateTime.now().difference(position.timestamp);

  SosFix? _toFix(Position position) {
    if (!isPreciseEnough(position.accuracy)) {
      appLogger.info(
        'Ignoring a ${position.accuracy.round()} m phone fix',
        tag: 'SOS',
      );
      return null;
    }
    return SosFix(
      latitude: position.latitude,
      longitude: position.longitude,
      source: SosLocationSource.phoneGps,
    );
  }

  @override
  Future<bool> requestPermission() async {
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      return permission == LocationPermission.always ||
          permission == LocationPermission.whileInUse;
    } catch (e) {
      appLogger.warn('Location permission request failed: $e', tag: 'SOS');
      return false;
    }
  }
}
