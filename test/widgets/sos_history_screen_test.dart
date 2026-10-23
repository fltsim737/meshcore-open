import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/sos_codec.dart';
import 'package:meshcore_open/helpers/sos_network_code.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/screens/sos_history_screen.dart';
import 'package:meshcore_open/services/sos_service.dart';
import 'package:provider/provider.dart';

import '../services/sos_service_test.dart'
    show FakeSosTransport, farmNetwork, freshSettings, sosPacketFrom;

void main() {
  testWidgets('lists alerts and shows the full record', (tester) async {
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
          home: const SosHistoryScreen(),
        ),
      ),
    );
    expect(find.textContaining('No SOS alerts yet'), findsOneWidget);

    service.handleInboundData(
      2,
      sosPacketFrom('Ridge', 9, 'a1b2', lat: -41.28646, lon: 174.77624),
    );
    service.handleInboundData(
      2,
      sosPacketFrom('Ridge', 9, 'a1b2', kind: SosPacketKind.cancel),
    );
    await tester.pump();
    expect(find.text('Ridge  #a1b2'), findsOneWidget);
    expect(find.textContaining('Cancelled by the sender'), findsOneWidget);

    await tester.tap(find.text('Ridge  #a1b2'));
    await tester.pumpAndSettle();
    expect(find.textContaining('-41.28646, 174.77624'), findsOneWidget);
    expect(find.byTooltip('Share'), findsOneWidget);

    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(service.history, isEmpty);
    expect(find.textContaining('No SOS alerts yet'), findsOneWidget);
    service.dispose();
  });
}
