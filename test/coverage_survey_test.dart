import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/coverage_export.dart';
import 'package:meshcore_open/helpers/coverage_grid.dart';
import 'package:meshcore_open/models/coverage_survey.dart';
import 'package:meshcore_open/services/coverage_survey_store.dart';
import 'package:meshcore_open/services/coverage_survey_service.dart';

const _radio = CoverageRadio(freqHz: 916575000, bwHz: 62500, sf: 7, cr: 7);
const _keyA =
    'aa00000000000000000000000000000000000000000000000000000000000001';
const _keyB =
    'bb00000000000000000000000000000000000000000000000000000000000002';

CoverageReply _reply(String key, double snr, double remote, {String? name}) =>
    CoverageReply(
      keyHex: key,
      name: name ?? key.substring(0, 4),
      snr: snr,
      rssi: -100,
      remoteSnr: remote,
      latitude: -33.9,
      longitude: 151.2,
    );

CoveragePing _ping(
  DateTime at,
  double lat,
  double lon,
  List<CoverageReply> replies, {
  CoverageRadio radio = _radio,
}) => CoveragePing(
  at: at,
  latitude: lat,
  longitude: lon,
  radio: radio,
  replies: replies,
);

class _FakeLink extends ChangeNotifier implements CoverageRadioLink {
  bool connected = true;
  bool discover = true;
  List<CoverageReply> next = [];
  int pings = 0;
  CoveragePosition? radioPos;

  @override
  bool get isConnected => connected;
  @override
  bool get supportsNodeDiscover => discover;
  @override
  CoverageRadio? get radio => connected ? _radio : null;
  @override
  String? get selfName => 'Tester';
  @override
  CoveragePosition? get radioPosition => radioPos;
  @override
  Future<List<CoverageReply>> ping() async {
    pings++;
    return next;
  }
}

class _FakeLocation implements CoverageLocationSource {
  final controller = StreamController<CoveragePosition>.broadcast();
  @override
  Stream<CoveragePosition> watch() => controller.stream;
  @override
  Future<bool> requestPermission() async => true;
}

void main() {
  group('HexCell', () {
    test('nearby points share a cell, distant ones do not', () {
      final a = HexCell.at(-33.86, 151.21);
      final b = HexCell.at(-33.86001, 151.21001);
      final far = HexCell.at(-33.87, 151.21);
      expect(a, b);
      expect(a == far, isFalse);
    });

    test('centre maps back into its own cell, key round-trips', () {
      final cell = HexCell.at(-27.47, 153.02);
      final c = cell.centre;
      expect(HexCell.at(c.latitude, c.longitude), cell);
      expect(HexCell.parse(cell.key), cell);
      expect(cell.corners, hasLength(6));
    });

    test('cell is roughly 100 m across in mid latitudes', () {
      final cell = HexCell.at(-35, 149);
      final corners = cell.corners;
      // opposite corners are two radii apart
      final d = coverageDistanceMetres(
        corners[0].latitude,
        corners[0].longitude,
        corners[3].latitude,
        corners[3].longitude,
      );
      expect(d, inInclusiveRange(100, 130));
    });
  });

  group('CoverageSignal', () {
    test('grades by margin over the SF decode floor', () {
      expect(CoverageSignal.decodeFloor(7), -7.5);
      expect(CoverageSignal.decodeFloor(12), -20);
      expect(CoverageSignal.grade(5, 7), CoverageGrade.strong);
      expect(CoverageSignal.grade(-1, 7), CoverageGrade.good);
      expect(CoverageSignal.grade(-5, 7), CoverageGrade.weak);
      expect(CoverageSignal.grade(-9, 7), CoverageGrade.marginal);
      expect(CoverageSignal.grade(-9, 12), CoverageGrade.strong);
    });

    test('link SNR is the weaker direction', () {
      expect(_reply(_keyA, 6, -2).linkSnr, -2);
      expect(_reply(_keyA, -4, 3).linkSnr, -4);
    });
  });

  group('CoveragePingPlanner', () {
    final t0 = DateTime(2026, 11, 1, 10);
    const here = CoveragePosition(-33.86, 151.21);

    test('first ping goes at once', () {
      expect(CoveragePingPlanner.shouldPing(now: t0, here: here), isTrue);
    });

    test('never inside 30 s, even after moving far', () {
      expect(
        CoveragePingPlanner.shouldPing(
          now: t0.add(const Duration(seconds: 20)),
          here: const CoveragePosition(-33.87, 151.21),
          lastAt: t0,
          lastPos: here,
        ),
        isFalse,
      );
    });

    test('after 30 s only once moved 150 m', () {
      final now = t0.add(const Duration(seconds: 40));
      expect(
        CoveragePingPlanner.shouldPing(
          now: now,
          here: const CoveragePosition(-33.8605, 151.21),
          lastAt: t0,
          lastPos: here,
        ),
        isFalse,
      );
      expect(
        CoveragePingPlanner.shouldPing(
          now: now,
          here: const CoveragePosition(-33.862, 151.21),
          lastAt: t0,
          lastPos: here,
        ),
        isTrue,
      );
    });

    test('standing still pings every 2 minutes', () {
      expect(
        CoveragePingPlanner.shouldPing(
          now: t0.add(const Duration(minutes: 2)),
          here: here,
          lastAt: t0,
          lastPos: here,
        ),
        isTrue,
      );
    });
  });

  group('CoverageMap', () {
    final t0 = DateTime.utc(2026, 11, 1, 10);

    test('cells take the best grade; silent pings show as no reply', () {
      final pings = [
        _ping(t0, -33.86, 151.21, [_reply(_keyA, -6, -6)]),
        _ping(t0.add(const Duration(minutes: 1)), -33.86, 151.21, [
          _reply(_keyB, 4, 5),
        ]),
        _ping(t0.add(const Duration(minutes: 2)), -33.9, 151.21, []),
      ];
      final map = CoverageMap.build(pings, radio: _radio);
      expect(map.cells, hasLength(2));
      final covered = map.cells[HexCell.at(-33.86, 151.21)]!;
      expect(covered.pings, 2);
      expect(covered.grade, CoverageGrade.strong);
      expect(covered.repeaters.keys, containsAll([_keyA, _keyB]));
      final silent = map.cells[HexCell.at(-33.9, 151.21)]!;
      expect(silent.grade, CoverageGrade.none);
      expect(map.repeaters, hasLength(2));
    });

    test('one-repeater view and radio layers filter', () {
      const other = CoverageRadio(
        freqHz: 915000000,
        bwHz: 250000,
        sf: 10,
        cr: 5,
      );
      final pings = [
        _ping(t0, -33.86, 151.21, [_reply(_keyA, 4, 4)]),
        _ping(t0.add(const Duration(minutes: 1)), -33.87, 151.21, [
          _reply(_keyB, 4, 4),
        ]),
        _ping(t0, -33.88, 151.21, [_reply(_keyA, 1, 1)], radio: other),
      ];
      final onlyA = CoverageMap.build(pings, radio: _radio, repeaterKey: _keyA);
      expect(
        onlyA.cells[HexCell.at(-33.86, 151.21)]!.grade,
        CoverageGrade.strong,
      );
      expect(
        onlyA.cells[HexCell.at(-33.87, 151.21)]!.grade,
        CoverageGrade.none,
      );
      expect(onlyA.cells.containsKey(HexCell.at(-33.88, 151.21)), isFalse);
      final otherMap = CoverageMap.build(pings, radio: other);
      expect(otherMap.cells, hasLength(1));
    });
  });

  group('CoverageExport', () {
    final t0 = DateTime.utc(2026, 11, 1, 10);
    final pings = [
      _ping(t0, -33.86, 151.21, [_reply(_keyA, 3, -1, name: 'Hill <&> Top')]),
      _ping(t0.add(const Duration(minutes: 1)), -33.87, 151.22, []),
    ];

    test('survey file round-trips', () {
      final text = CoverageExport.surveyFile(pings, by: 'Me');
      final back = CoverageExport.parseSurveyFile(text);
      expect(back, hasLength(2));
      expect(back.first.id, pings.first.id);
      expect(back.first.replies.single.name, 'Hill <&> Top');
      expect(back.first.replies.single.remoteSnr, -1);
      expect(back.first.radio, _radio);
    });

    test('rejects other files', () {
      expect(
        () => CoverageExport.parseSurveyFile('{"format":"x","pings":[]}'),
        throwsFormatException,
      );
      expect(
        () => CoverageExport.parseSurveyFile('nope'),
        throwsFormatException,
      );
    });

    test('GeoJSON has cells, repeaters and pings', () {
      final json = jsonDecode(CoverageExport.geoJson(pings)) as Map;
      final kinds = [
        for (final f in json['features'] as List) f['properties']['kind'],
      ];
      expect(kinds.where((k) => k == 'cell'), hasLength(2));
      expect(kinds.where((k) => k == 'repeater'), hasLength(1));
      expect(kinds.where((k) => k == 'ping'), hasLength(2));
      final cell = (json['features'] as List).first;
      final ring = cell['geometry']['coordinates'][0] as List;
      expect(ring.first, ring.last);
    });

    test('KML escapes names and closes polygons', () {
      final kml = CoverageExport.kml(pings, title: 'Coverage');
      expect(kml, contains('Hill &lt;&amp;&gt; Top'));
      expect(kml, contains('<styleUrl>#none</styleUrl>'));
      expect(kml.trim(), endsWith('</kml>'));
    });
  });

  group('CoverageSurveyService', () {
    late _FakeLink link;
    late _FakeLocation location;
    late DateTime now;
    var sosBusy = false;
    late CoverageSurveyService service;

    setUp(() {
      link = _FakeLink();
      location = _FakeLocation();
      now = DateTime(2026, 11, 1, 10);
      sosBusy = false;
      service = CoverageSurveyService(
        link: link,
        store: MemoryCoverageStore(),
        location: location,
        sosBusy: () => sosBusy,
        now: () => now,
        tickEvery: const Duration(hours: 1),
      );
    });

    tearDown(() => service.dispose());

    Future<void> moveTo(double lat, double lon) async {
      location.controller.add(CoveragePosition(lat, lon));
      await Future<void>.delayed(Duration.zero);
      await service.tick();
    }

    test('pings on start, then follows distance and the 30 s limit', () async {
      link.next = [_reply(_keyA, 2, 2)];
      await service.start();
      await moveTo(-33.86, 151.21);
      expect(link.pings, 1);
      expect(service.latest!.replies, hasLength(1));
      expect(service.latest!.by, 'Tester');

      now = now.add(const Duration(seconds: 10));
      await moveTo(-33.87, 151.21);
      expect(link.pings, 1, reason: 'inside 30 s');

      now = now.add(const Duration(seconds: 30));
      await moveTo(-33.87, 151.21);
      expect(link.pings, 2);
      expect(service.pings, hasLength(2));
    });

    test('pauses during an SOS and without a radio', () async {
      sosBusy = true;
      await service.start();
      await moveTo(-33.86, 151.21);
      expect(service.pause, CoveragePause.sos);
      expect(link.pings, 0);
      sosBusy = false;
      link.connected = false;
      await service.tick();
      expect(service.pause, CoveragePause.disconnected);
      link.connected = true;
      await service.tick();
      expect(link.pings, 1);
    });

    test('falls back to the radio position without phone GPS', () async {
      link.radioPos = const CoveragePosition(-33.5, 151.0);
      await service.start();
      await service.tick();
      expect(link.pings, 1);
      expect(service.usingRadioPosition, isTrue);
      expect(service.latest!.latitude, -33.5);
    });

    test('ignores rough phone fixes', () async {
      link.radioPos = const CoveragePosition(-33.5, 151.0);
      await service.start();
      location.controller.add(
        const CoveragePosition(-33.86, 151.21, accuracy: 2500),
      );
      await Future<void>.delayed(Duration.zero);
      await service.tick();
      expect(service.latest!.latitude, -33.5);
      expect(service.usingRadioPosition, isTrue);
    });

    test('warns after 3 silent pings in a row', () async {
      link.next = [];
      await service.start();
      await moveTo(-33.86, 151.21);
      for (var i = 0; i < 2; i++) {
        now = now.add(const Duration(minutes: 2));
        await service.tick();
      }
      expect(service.silentStreak, 3);
      expect(service.outOfCoverage, isTrue);
      link.next = [_reply(_keyA, 2, 2)];
      now = now.add(const Duration(minutes: 2));
      await service.tick();
      expect(service.outOfCoverage, isFalse);
    });

    test('import merges without duplicates', () async {
      final t0 = DateTime.utc(2026, 11, 1, 9);
      final file = CoverageExport.surveyFile([
        _ping(t0, -33.86, 151.21, [_reply(_keyA, 2, 2)]),
        _ping(t0.add(const Duration(minutes: 1)), -33.87, 151.21, []),
      ]);
      expect(await service.importSurvey(file), 2);
      expect(await service.importSurvey(file), 0);
      expect(service.pings, hasLength(2));
      await service.clear();
      expect(service.pings, isEmpty);
    });

    test('saved survey loads back', () async {
      final store = MemoryCoverageStore();
      final first = CoverageSurveyService(
        link: link,
        store: store,
        location: location,
        now: () => now,
        tickEvery: const Duration(hours: 1),
      );
      link.next = [_reply(_keyB, 1, 1)];
      await first.start();
      location.controller.add(const CoveragePosition(-33.86, 151.21));
      await Future<void>.delayed(Duration.zero);
      await first.tick();
      first.dispose();
      final second = CoverageSurveyService(link: link, store: store);
      await second.load();
      expect(second.pings, hasLength(1));
      expect(second.pings.single.replies.single.keyHex, _keyB);
      second.dispose();
    });
  });
}
