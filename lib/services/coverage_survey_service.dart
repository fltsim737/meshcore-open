import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../helpers/coverage_export.dart';
import '../helpers/coverage_grid.dart';
import '../models/coverage_survey.dart';
import '../utils/app_logger.dart';
import '../storage/prefs_manager.dart';
import '../utils/platform_info.dart';
import 'coverage_file_store.dart';
import 'coverage_survey_store.dart';
import 'sos_location_service.dart';
import 'sos_service.dart';

/// Where the phone is, for a ping.
class CoveragePosition {
  final double latitude;
  final double longitude;
  final double? accuracy;

  const CoveragePosition(this.latitude, this.longitude, {this.accuracy});
}

/// What the survey needs from the radio. [MeshCoreConnector] in the app,
/// a fake in tests.
abstract class CoverageRadioLink implements Listenable {
  bool get isConnected;
  bool get supportsNodeDiscover;
  CoverageRadio? get radio;
  String? get selfName;

  /// The radio's own position (a GPS radio, or one set by hand), if any.
  CoveragePosition? get radioPosition;

  /// One zero-hop ping for repeaters; completes when the reply window shuts.
  Future<List<CoverageReply>> ping();
}

class ConnectorCoverageLink implements CoverageRadioLink {
  final MeshCoreConnector connector;

  ConnectorCoverageLink(this.connector);

  /// Long enough for every repeater's random reply delay.
  static const Duration replyWindow = Duration(seconds: 12);

  @override
  bool get isConnected => connector.isConnected;

  @override
  bool get supportsNodeDiscover => connector.supportsNodeDiscover;

  @override
  CoverageRadio? get radio {
    final f = connector.currentFreqHz, b = connector.currentBwHz;
    final s = connector.currentSf, c = connector.currentCr;
    if (f == null || b == null || s == null || c == null) return null;
    return CoverageRadio(freqHz: f, bwHz: b, sf: s, cr: c);
  }

  @override
  String? get selfName => connector.selfName;

  @override
  CoveragePosition? get radioPosition {
    final lat = connector.selfLatitude, lon = connector.selfLongitude;
    if (lat == null || lon == null || (lat == 0 && lon == 0)) return null;
    return CoveragePosition(lat, lon);
  }

  @override
  Future<List<CoverageReply>> ping() async {
    final replies = <CoverageReply>[];
    await for (final r in connector.discoverNearbyNodes(
      typeMask: 1 << advTypeRepeater,
      timeout: replyWindow,
    )) {
      final contact = connector.contactForDiscoverResponse(r);
      replies.add(
        CoverageReply(
          keyHex: r.publicKeyHex,
          name: contact.name,
          snr: r.snr,
          rssi: r.rssi,
          remoteSnr: r.remoteSnr,
          latitude: contact.latitude,
          longitude: contact.longitude,
        ),
      );
    }
    return replies;
  }

  @override
  void addListener(VoidCallback listener) => connector.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      connector.removeListener(listener);
}

abstract class CoverageLocationSource {
  /// Phone positions as the phone moves. May error where there is no GPS.
  Stream<CoveragePosition> watch();
  Future<bool> requestPermission();
}

class GeolocatorCoverageLocation implements CoverageLocationSource {
  @override
  Stream<CoveragePosition> watch() => Geolocator.getPositionStream(
    locationSettings: const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 10,
    ),
  ).map((p) => CoveragePosition(p.latitude, p.longitude, accuracy: p.accuracy));

  @override
  Future<bool> requestPermission() =>
      GeolocatorPhoneLocation().requestPermission();
}

/// No phone GPS: pings use the radio's own position.
class NoCoverageLocation implements CoverageLocationSource {
  @override
  Stream<CoveragePosition> watch() => const Stream.empty();

  @override
  Future<bool> requestPermission() async => false;
}

/// When the next ping goes out. Each ping makes every repeater in range
/// answer, and a stock repeater answers at most 4 pings in 2 minutes from
/// everyone together, so pings follow distance travelled, not a clock.
/// How the survey decides when to ping.
enum CoveragePingMode {
  /// Each time you've moved the set distance (nothing while standing still).
  distance,

  /// Every set interval, moving or not.
  time,

  /// Whichever comes first (the default: 150 m, or 2 minutes).
  either,
}

/// The user's choice of how often the survey pings. Never closer together
/// than [CoveragePingPlanner.minInterval], whatever is chosen.
class CoveragePingSettings {
  final CoveragePingMode mode;
  final double distanceMetres;
  final Duration interval;

  const CoveragePingSettings({
    this.mode = CoveragePingMode.either,
    this.distanceMetres = 150,
    this.interval = const Duration(minutes: 2),
  });

  /// The distances offered, in metres.
  static const List<double> distanceChoices = [
    50,
    100,
    150,
    250,
    500,
    1000,
    2000,
  ];

  /// The intervals offered, in seconds (30 s is the repeaters' limit).
  static const List<int> intervalChoices = [30, 60, 120, 300, 600, 900];

  bool get usesDistance => mode != CoveragePingMode.time;
  bool get usesTime => mode != CoveragePingMode.distance;

  CoveragePingSettings copyWith({
    CoveragePingMode? mode,
    double? distanceMetres,
    Duration? interval,
  }) => CoveragePingSettings(
    mode: mode ?? this.mode,
    distanceMetres: distanceMetres ?? this.distanceMetres,
    interval: interval ?? this.interval,
  );

  Map<String, dynamic> toJson() => {
    'mode': mode.name,
    'distance_m': distanceMetres,
    'interval_s': interval.inSeconds,
  };

  /// Anything unreadable or out of range falls back to the default.
  static CoveragePingSettings fromJson(Object? json) {
    if (json is! Map) return const CoveragePingSettings();
    final mode = CoveragePingMode.values.firstWhere(
      (m) => m.name == json['mode'],
      orElse: () => CoveragePingMode.either,
    );
    final d = json['distance_m'];
    final i = json['interval_s'];
    return CoveragePingSettings(
      mode: mode,
      distanceMetres: d is num ? d.toDouble().clamp(50, 2000).toDouble() : 150,
      interval: Duration(
        seconds: i is num
            ? i.toInt().clamp(CoveragePingPlanner.minInterval.inSeconds, 900)
            : 120,
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CoveragePingSettings &&
      other.mode == mode &&
      other.distanceMetres == distanceMetres &&
      other.interval == interval;

  @override
  int get hashCode => Object.hash(mode, distanceMetres, interval);
}

class CoveragePingPlanner {
  CoveragePingPlanner._();

  /// Never closer together than this (the repeaters' rate limit).
  static const Duration minInterval = Duration(seconds: 30);

  /// Ping again after moving this far...
  static const double distanceMetres = 150;

  /// ...or after this long standing still.
  static const Duration idleInterval = Duration(minutes: 2);

  static bool shouldPing({
    required DateTime now,
    required CoveragePosition here,
    DateTime? lastAt,
    CoveragePosition? lastPos,
    CoveragePingSettings settings = const CoveragePingSettings(),
  }) {
    if (lastAt == null || lastPos == null) return true;
    final elapsed = now.difference(lastAt);
    if (elapsed < minInterval) return false;
    final timeUp = elapsed >= settings.interval;
    if (settings.mode == CoveragePingMode.time) return timeUp;
    if (settings.mode == CoveragePingMode.either && timeUp) return true;
    return coverageDistanceMetres(
          here.latitude,
          here.longitude,
          lastPos.latitude,
          lastPos.longitude,
        ) >=
        settings.distanceMetres;
  }
}

/// Why the survey is running but not pinging.
enum CoveragePause { none, disconnected, unsupported, sos, noLocation }

/// Maps repeater coverage while the user travels: pings for repeaters in
/// direct range, records who answers and how well, and keeps the pings on
/// disk so the map builds up over many trips.
class CoverageSurveyService extends ChangeNotifier {
  final CoverageRadioLink _link;
  final CoverageSurveyStore _store;
  final CoverageLocationSource _location;

  /// True while an SOS of ours or someone else's is open: the survey keeps
  /// off the air so SOS traffic gets the channel.
  final bool Function() _sosBusy;
  final Listenable? _sosChanges;
  final DateTime Function() _now;
  final Duration _tickEvery;

  /// After this many pings in a row with no answer, warn the user.
  static const int silentAlertAfter = 3;

  /// Oldest pings drop off beyond this.
  static const int maxPings = 10000;

  /// Phone fixes less accurate than this are ignored.
  static const double maxAccuracyMetres = 100;

  CoverageSurveyService({
    required CoverageRadioLink link,
    CoverageSurveyStore? store,
    CoverageLocationSource? location,
    bool Function()? sosBusy,
    Listenable? sosChanges,
    DateTime Function()? now,
    Duration tickEvery = const Duration(seconds: 5),
    CoveragePingSettings settings = const CoveragePingSettings(),
    void Function(CoveragePingSettings)? saveSettings,
  }) : _settings = settings,
       _saveSettings = saveSettings,
       _link = link,
       _store = store ?? CoverageFileStore(),
       _location = location ?? GeolocatorCoverageLocation(),
       _sosBusy = sosBusy ?? (() => false),
       _sosChanges = sosChanges,
       _now = now ?? DateTime.now,
       _tickEvery = tickEvery;

  /// [phoneGps] is off on Windows, whose network-based position is often
  /// kilometres out: there the radio's own position is used.
  factory CoverageSurveyService.forApp(
    MeshCoreConnector connector,
    SosService sos, {
    bool phoneGps = true,
  }) => CoverageSurveyService(
    link: ConnectorCoverageLink(connector),
    location: phoneGps ? null : NoCoverageLocation(),
    sosBusy: () => sos.isActive || sos.openIncoming.isNotEmpty,
    sosChanges: sos,
    settings: _readSettings(),
    saveSettings: (s) =>
        PrefsManager.instance.setString(settingsKey, jsonEncode(s.toJson())),
  );

  /// Where the ping settings are kept (on this phone, for every radio).
  static const String settingsKey = 'coverage_ping_settings';

  static CoveragePingSettings _readSettings() {
    try {
      final raw = PrefsManager.instance.getString(settingsKey);
      return raw == null
          ? const CoveragePingSettings()
          : CoveragePingSettings.fromJson(jsonDecode(raw));
    } catch (_) {
      return const CoveragePingSettings();
    }
  }

  CoveragePingSettings _settings;
  final void Function(CoveragePingSettings)? _saveSettings;

  /// How often the survey pings.
  CoveragePingSettings get settings => _settings;

  void setSettings(CoveragePingSettings value) {
    if (value == _settings) return;
    _settings = value;
    _saveSettings?.call(value);
    notifyListeners();
  }

  final List<CoveragePing> _pings = [];
  final Set<String> _ids = {};
  bool _loaded = false;
  bool _running = false;
  bool _pinging = false;
  CoveragePause _pause = CoveragePause.none;
  CoveragePosition? _phone;
  bool _usingRadioPosition = false;
  DateTime? _lastPingAt;
  CoveragePosition? _lastPingPos;
  CoveragePing? _latest;
  DateTime? _latestDoneAt;
  int _silentStreak = 0;
  StreamSubscription<CoveragePosition>? _positionSub;
  Timer? _ticker;

  List<CoveragePing> get pings => List.unmodifiable(_pings);
  bool get loaded => _loaded;
  bool get running => _running;
  bool get pinging => _pinging;
  CoveragePause get pause => _pause;

  /// Where the next ping will be stamped.
  CoveragePosition? get position => _phone ?? _link.radioPosition;

  /// True when there is no phone GPS and the radio's own position is used.
  bool get usingRadioPosition => _usingRadioPosition;
  CoveragePing? get latest => _latest;

  /// When the latest ping's reply window closed (its radar lines start then).
  DateTime? get latestDoneAt => _latestDoneAt;
  DateTime? get lastPingAt => _lastPingAt;
  CoverageRadio? get currentRadio => _link.radio;

  /// Pings in a row that no repeater answered.
  int get silentStreak => _silentStreak;
  bool get outOfCoverage => _silentStreak >= silentAlertAfter;

  /// When a timed ping is next due ([CoveragePingMode.time] and
  /// [CoveragePingMode.either]); null before the first ping.
  DateTime? get nextTimedAt =>
      _settings.usesTime ? _lastPingAt?.add(_settings.interval) : null;

  /// The earliest the next ping may go (the repeaters' rate limit).
  DateTime? get nextAllowedAt =>
      _lastPingAt?.add(CoveragePingPlanner.minInterval);

  Future<void> load() async {
    if (_loaded) return;
    try {
      final text = await _store.read();
      if (text != null && text.isNotEmpty) {
        _addAll(CoverageExport.parseSurveyFile(text));
      }
    } catch (e) {
      appLogger.warn('Coverage survey could not be read: $e', tag: 'Coverage');
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> start() async {
    if (_running) return;
    await load();
    _running = true;
    _silentStreak = 0;
    _link.addListener(_onChange);
    _sosChanges?.addListener(_onChange);
    notifyListeners();
    final allowed = await _location.requestPermission();
    if (!_running) return;
    if (allowed) {
      try {
        _positionSub = _location.watch().listen(
          (p) {
            // a rough fix (WiFi or IP based, as a desktop's location
            // service often gives) would paint the wrong hexagons
            final acc = p.accuracy;
            if (acc != null && acc > maxAccuracyMetres) return;
            _phone = p;
            _usingRadioPosition = false;
            _tick();
          },
          onError: (Object e) {
            appLogger.warn('Coverage GPS: $e', tag: 'Coverage');
          },
        );
      } catch (e) {
        appLogger.warn('Coverage GPS unavailable: $e', tag: 'Coverage');
      }
    }
    _ticker = Timer.periodic(_tickEvery, (_) => _tick());
    _keepScreenOn(true);
    _tick();
  }

  void stop() {
    if (!_running) return;
    _running = false;
    _ticker?.cancel();
    _ticker = null;
    unawaited(_positionSub?.cancel());
    _positionSub = null;
    _link.removeListener(_onChange);
    _sosChanges?.removeListener(_onChange);
    _pause = CoveragePause.none;
    _silentStreak = 0;
    _keepScreenOn(false);
    notifyListeners();
  }

  void _onChange() {
    if (!_running) return;
    final before = _pause;
    _pause = _pauseReason();
    if (before != _pause) notifyListeners();
  }

  CoveragePause _pauseReason() {
    if (!_link.isConnected || _link.radio == null) {
      return CoveragePause.disconnected;
    }
    if (!_link.supportsNodeDiscover) return CoveragePause.unsupported;
    if (_sosBusy()) return CoveragePause.sos;
    if (position == null) return CoveragePause.noLocation;
    return CoveragePause.none;
  }

  /// Checks whether a ping is due. Public for tests.
  @visibleForTesting
  Future<void> tick() => _tick();

  Future<void> _tick() async {
    if (!_running || _pinging) return;
    final reason = _pauseReason();
    if (reason != _pause) {
      _pause = reason;
      notifyListeners();
    }
    if (reason != CoveragePause.none) return;
    final here = position!;
    final now = _now();
    if (!CoveragePingPlanner.shouldPing(
      now: now,
      here: here,
      lastAt: _lastPingAt,
      lastPos: _lastPingPos,
      settings: _settings,
    )) {
      return;
    }
    await _ping(here, now);
  }

  /// Pings now if the rate limit allows (the "Ping now" button).
  Future<bool> pingNow() async {
    if (!_running || _pinging) return false;
    if (_pauseReason() != CoveragePause.none) return false;
    final now = _now();
    final next = nextAllowedAt;
    if (next != null && now.isBefore(next)) return false;
    await _ping(position!, now);
    return true;
  }

  Future<void> _ping(CoveragePosition here, DateTime now) async {
    final radio = _link.radio;
    if (radio == null) return;
    _pinging = true;
    _usingRadioPosition = _phone == null;
    _lastPingAt = now;
    _lastPingPos = here;
    notifyListeners();
    List<CoverageReply> replies;
    try {
      replies = await _link.ping();
    } catch (e) {
      appLogger.warn('Coverage ping failed: $e', tag: 'Coverage');
      _pinging = false;
      notifyListeners();
      return;
    }
    final ping = CoveragePing(
      at: now,
      latitude: here.latitude,
      longitude: here.longitude,
      accuracy: here.accuracy,
      radio: radio,
      replies: replies,
      by: _link.selfName,
    );
    _addAll([ping]);
    _latest = ping;
    _latestDoneAt = _now();
    final wasOut = outOfCoverage;
    _silentStreak = replies.isEmpty ? _silentStreak + 1 : 0;
    if (!wasOut && outOfCoverage) {
      unawaited(HapticFeedback.heavyImpact().catchError((_) {}));
    }
    _pinging = false;
    notifyListeners();
    await _save();
  }

  void _addAll(Iterable<CoveragePing> pings) {
    var added = 0;
    for (final p in pings) {
      if (_ids.add(p.id)) {
        _pings.add(p);
        added++;
      }
    }
    if (added == 0) return;
    _pings.sort((a, b) => a.at.compareTo(b.at));
    if (_pings.length > maxPings) {
      final drop = _pings.length - maxPings;
      for (final p in _pings.take(drop)) {
        _ids.remove(p.id);
      }
      _pings.removeRange(0, drop);
    }
  }

  /// Merges another survey file. Returns how many pings were new.
  Future<int> importSurvey(String text) async {
    await load();
    final incoming = CoverageExport.parseSurveyFile(text);
    final before = _pings.length;
    _addAll(incoming);
    final added = _pings.length - before;
    if (added > 0) {
      notifyListeners();
      await _save();
    }
    return added < 0 ? 0 : added;
  }

  Future<void> clear() async {
    _pings.clear();
    _ids.clear();
    _latest = null;
    _silentStreak = 0;
    notifyListeners();
    try {
      await _store.delete();
    } catch (e) {
      appLogger.warn('Coverage survey not deleted: $e', tag: 'Coverage');
    }
  }

  String exportSurvey() =>
      CoverageExport.surveyFile(_pings, by: _link.selfName);

  Future<void> _save() async {
    try {
      await _store.write(
        jsonEncode({
          'format': CoverageExport.format,
          'version': CoverageExport.version,
          'pings': [for (final p in _pings) p.toJson()],
        }),
      );
    } catch (e) {
      appLogger.warn('Coverage survey not saved: $e', tag: 'Coverage');
    }
  }

  static const MethodChannel _screen = MethodChannel('meshcore_open/screen');

  /// Android: keeps the screen on during a survey so GPS keeps coming.
  void _keepScreenOn(bool on) {
    if (!PlatformInfo.isAndroid) return;
    unawaited(
      _screen.invokeMethod<bool>('keepOn', {'on': on}).catchError((Object e) {
        appLogger.warn('Keep screen on failed: $e', tag: 'Coverage');
        return false;
      }),
    );
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
