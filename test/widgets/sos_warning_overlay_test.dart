import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/sos_codec.dart';
import 'package:meshcore_open/helpers/sos_network_code.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/services/sos_service.dart';
import 'package:meshcore_open/widgets/sos_warning_overlay.dart';
import 'package:provider/provider.dart';

import '../services/sos_service_test.dart'
    show FakeSosTransport, farmNetwork, freshSettings, sosPacketFrom;

void main() {
  testWidgets('stays over the app until the alert is acknowledged', (
    tester,
  ) async {
    final settings = await freshSettings();
    final transport = FakeSosTransport();
    final service = SosService(transport: transport, settings: settings);
    await settings.joinSosNetwork(farmNetwork(SosNetworkRole.responder));

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: service,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) =>
              Stack(children: [child!, const SosWarningOverlay()]),
          home: const Scaffold(body: Text('home')),
        ),
      ),
    );
    expect(find.text('EMERGENCY SOS'), findsNothing);

    service.handleInboundData(
      2,
      sosPacketFrom('Ridge', 9, 'a1b2', lat: -41.28646, lon: 174.77624),
    );
    await tester.pump();
    expect(find.text('EMERGENCY SOS'), findsOneWidget);
    expect(find.text('Ridge'), findsOneWidget);
    expect(find.text('-41.28646, 174.77624'), findsOneWidget);

    await tester.tap(find.text('Send ACK'));
    await tester.pump();
    expect(find.text('EMERGENCY SOS'), findsNothing);
    expect(
      transport.channelPackets.single.$2.kind,
      SosPacketKind.ack,
    ); // Disposed inside the test: its expiry timer must not outlive it.
    service.dispose();
  });

  testWidgets('Send ACK is disabled while disconnected', (tester) async {
    final settings = await freshSettings();
    final transport = FakeSosTransport()..isConnected = false;
    final service = SosService(transport: transport, settings: settings);
    await settings.joinSosNetwork(farmNetwork(SosNetworkRole.responder));
    service.handleInboundData(2, sosPacketFrom('Ridge', 9, 'a1b2'));

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: service,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Stack(children: [SosWarningOverlay()]),
        ),
      ),
    );
    await tester.tap(find.text('Send ACK'));
    await tester.pump();
    expect(find.text('EMERGENCY SOS'), findsOneWidget);
    expect(transport.channelPackets, isEmpty);
    service.dispose();
  });
}
