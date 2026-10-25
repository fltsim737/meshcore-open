import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/sos_codec.dart';
import 'package:meshcore_open/helpers/sos_network_code.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/screens/sos_locator_screen.dart';
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
}
