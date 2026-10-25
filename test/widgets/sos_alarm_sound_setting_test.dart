import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/services/app_settings_service.dart';
import 'package:meshcore_open/services/sos_service.dart';
import 'package:meshcore_open/widgets/sos_settings_section.dart';
import 'package:provider/provider.dart';

import '../services/sos_service_test.dart' show FakeSosTransport, freshSettings;

void main() {
  testWidgets('the alarm sound can be switched to the classic tone', (
    tester,
  ) async {
    final settings = await freshSettings();
    final service = SosService(
      transport: FakeSosTransport(),
      settings: settings,
    );
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: settings),
          ChangeNotifierProvider.value(value: service),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(child: SosSettingsSection()),
          ),
        ),
      ),
    );
    expect(find.text('Alarm sound'), findsOneWidget);
    expect(find.text('SOS in Morse code'), findsOneWidget);

    await tester.tap(find.text('Alarm sound'));
    await tester.pumpAndSettle();
    expect(find.text('The two-tone alarm of earlier versions'), findsOneWidget);
    await tester.tap(find.text('Classic alert tone'));
    await tester.pumpAndSettle();

    expect(settings.sosAlarmTone, AppSettingsService.alarmToneClassic);
    expect(
      find.text('Classic alert tone'),
      findsOneWidget,
    ); // the tile's summary
    service.dispose();
  });
}
