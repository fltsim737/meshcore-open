import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:meshcore_open/helpers/coverage_export.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/models/coverage_survey.dart';
import 'package:meshcore_open/screens/coverage_survey_screen.dart';
import 'package:meshcore_open/services/app_settings_service.dart';
import 'package:meshcore_open/services/coverage_survey_service.dart';
import 'package:meshcore_open/services/coverage_survey_store.dart';
import 'package:meshcore_open/services/map_tile_cache_service.dart';

const _radio = CoverageRadio(freqHz: 916575000, bwHz: 62500, sf: 7, cr: 7);

class _Link extends ChangeNotifier implements CoverageRadioLink {
  @override
  bool get isConnected => true;
  @override
  bool get supportsNodeDiscover => true;
  @override
  CoverageRadio? get radio => _radio;
  @override
  String? get selfName => 'Tester';
  @override
  CoveragePosition? get radioPosition => const CoveragePosition(-33.86, 151.21);
  @override
  Future<List<CoverageReply>> ping() async => const [
    CoverageReply(
      keyHex:
          'aa00000000000000000000000000000000000000000000000000000000000001',
      name: 'Hilltop',
      snr: 6.5,
      rssi: -90,
      remoteSnr: 3.25,
      latitude: -33.84,
      longitude: 151.23,
    ),
  ];
}

class _NoGps implements CoverageLocationSource {
  @override
  Stream<CoveragePosition> watch() => const Stream.empty();
  @override
  Future<bool> requestPermission() async => false;
}

void main() {
  testWidgets('coverage survey screen draws, starts, pings and stops', (
    tester,
  ) async {
    final tmp = Directory.systemTemp.createTempSync('coverage_test');
    addTearDown(() => tmp.deleteSync(recursive: true));
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => tmp.path,
    );
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final settings = AppSettingsService();
    final service = CoverageSurveyService(
      link: _Link(),
      store: MemoryCoverageStore(),
      location: _NoGps(),
      tickEvery: const Duration(hours: 1),
    );
    final t0 = DateTime.now().toUtc().subtract(const Duration(hours: 1));
    await service.importSurvey(
      CoverageExport.surveyFile([
        CoveragePing(
          at: t0,
          latitude: -33.87,
          longitude: 151.2,
          radio: _radio,
          replies: const [],
        ),
      ]),
    );

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<CoverageSurveyService>.value(value: service),
          ChangeNotifierProvider<MapTileCacheService>(
            create: (_) => MapTileCacheService(appSettingsService: settings),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const CoverageSurveyScreen(),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Coverage survey'), findsOneWidget);
    expect(find.text('Start survey'), findsOneWidget);
    expect(find.textContaining('Survey stopped'), findsOneWidget);
    expect(find.text('No reply'), findsOneWidget);

    await tester.tap(find.text('Start survey'));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 2));
    expect(service.pings, hasLength(2));
    expect(find.text('Stop survey'), findsOneWidget);
    expect(find.textContaining('Hilltop'), findsWidgets);
    expect(find.textContaining('answered the last ping'), findsOneWidget);
    expect(find.textContaining("radio's position"), findsOneWidget);

    await tester.tap(find.text('Stop survey'));
    await tester.pump();
    expect(find.text('Start survey'), findsOneWidget);

    // ping settings: choose By time, and the status and saved setting follow
    final saved = <CoveragePingSettings>[];
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ping settings'));
    await tester.pumpAndSettle();
    expect(find.text('Distance or time'), findsOneWidget);
    expect(find.byKey(const Key('coverage-ping-distance')), findsOneWidget);
    expect(find.byKey(const Key('coverage-ping-interval')), findsOneWidget);
    service.addListener(() => saved.add(service.settings));
    await tester.tap(find.text('By time'));
    await tester.pumpAndSettle();
    expect(service.settings.mode, CoveragePingMode.time);
    expect(find.byKey(const Key('coverage-ping-distance')), findsNothing);
    expect(
      find.textContaining('Never more often than every 30 seconds'),
      findsOneWidget,
    );
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(saved.last.mode, CoveragePingMode.time);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    service.dispose();
  });
}
