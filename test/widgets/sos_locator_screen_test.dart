import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/sos_codec.dart';
import 'package:meshcore_open/helpers/sos_network_code.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/screens/sos_locator_screen.dart';
import 'package:meshcore_open/screens/sos_search_map_screen.dart';
import 'package:meshcore_open/services/map_tile_cache_service.dart';
import 'package:meshcore_open/services/sos_service.dart';
import 'package:provider/provider.dart';

import '../services/sos_service_test.dart'
    show FakeSosTransport, farmNetwork, freshSettings, sosPacketFrom;

Uint8List beacon(int seq) => SosPacket(
  kind: SosPacketKind.beacon,
  id: 'a1b2',
  senderPrefix: Uint8List.fromList(List.filled(6, 9)),
  senderName: 'Ridge',
  seq: seq,
).encode();

void main() {
  testWidgets('asks for beacons, shows them, and stops when closed', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    final settings = await freshSettings();
    final transport = FakeSosTransport();
    final service = SosService(transport: transport, settings: settings);
    await settings.joinSosNetwork(farmNetwork(SosNetworkRole.responder));
    service.handleInboundData(
      2,
      sosPacketFrom('Ridge', 9, 'a1b2', lat: -41.28646, lon: 174.77624),
    );
    final alert = service.incoming.single;

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: service,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Navigator(
            onGenerateRoute: (_) => MaterialPageRoute(
              builder: (_) => SosLocatorScreen(alert: alert),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Locate Ridge'), findsOneWidget);
    expect(find.text('No signal yet'), findsOneWidget);
    expect(service.locator, isNotNull);

    // getting closer: each beacon a little stronger
    for (var i = 0; i < 8; i++) {
      service.handleInboundData(
        2,
        beacon(i),
        SosSignal(snrDb: 2.0 + i, direct: true, rssiDbm: -104 + i * 4),
      );
    }
    await tester.pump();
    expect(find.text('Warmer: getting closer'), findsOneWidget);
    expect(find.textContaining('-76 dBm'), findsOneWidget);
    expect(find.text('Close'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    expect(service.locator, isNull); // closing the screen stops the search
    service.dispose();
  });

  testWidgets('beacon power: shows who set it, and any searcher can change it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 6000);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    final settings = await freshSettings();
    final transport = FakeSosTransport();
    final service = SosService(transport: transport, settings: settings);
    await settings.joinSosNetwork(farmNetwork(SosNetworkRole.responder));
    service.handleInboundData(2, sosPacketFrom('Ridge', 9, 'a1b2', lat: -41.28646, lon: 174.77624));
    final alert = service.incoming.single;
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: service,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: SosLocatorScreen(alert: alert),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    // an older beacon: the power can't be changed
    service.handleInboundData(2, beacon(0), const SosSignal(snrDb: 3, direct: true, rssiDbm: -95));
    await tester.pump();
    expect(find.textContaining("can't be changed"), findsOneWidget);
    // a 1.6.1 radio's beacon
    service.handleInboundData(
      2,
      SosPacket(kind: SosPacketKind.beacon, id: 'a1b2', senderPrefix: Uint8List.fromList(List.filled(6, 9)), senderName: 'Ridge', seq: 1, power: 8, setBy: 'Mike').encode(),
      const SosSignal(snrDb: 3, direct: true, rssiDbm: -95),
    );
    await tester.pump();
    expect(find.text('Beacons at 8 dBm · set by Mike'), findsOneWidget);
    await tester.tap(find.text('Low · 2 dBm'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    final asks = transport.channelPackets.map((p) => p.$2).where((p) => p.kind == SosPacketKind.locate && p.power != null);
    expect(asks.last.power, 2);
    expect(find.text('Asking for Low…'), findsOneWidget);
    expect(find.text('Search map'), findsWidgets);
    expect(find.text('Find the direction'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    service.dispose();
  });

  testWidgets('the search map explains a single place gives only a ring', (
    tester,
  ) async {
    final settings = await freshSettings();
    final transport = FakeSosTransport();
    final service = SosService(transport: transport, settings: settings);
    await settings.joinSosNetwork(farmNetwork(SosNetworkRole.responder));
    service.handleInboundData(2, sosPacketFrom('Ridge', 9, 'a1b2', lat: -41.28646, lon: 174.77624));
    final alert = service.incoming.single;
    service.startLocating(alert);
    service.handleInboundData(
      2,
      SosPacket(
        kind: SosPacketKind.report,
        id: 'a1b2',
        senderPrefix: Uint8List.fromList(List.filled(6, 7)),
        senderName: 'Sam',
        reading: const SosReading(latitude: -41.285, longitude: 174.775, rssiDbm: -90, snrDb: 1, beaconPower: 8),
      ).encode(),
    );
    final tiles = MapTileCacheService(appSettingsService: settings);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: service),
          ChangeNotifierProvider.value(value: tiles),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: SosSearchMapScreen(alert: alert),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Search map'), findsOneWidget);
    expect(find.textContaining('One place gives a ring'), findsOneWidget);
    expect(find.text('Sam'), findsOneWidget);
    expect(find.text('Last known position'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    service.stopLocating();
    service.dispose();
  });
}
