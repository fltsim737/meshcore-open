import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/screens/setup_wizard_screen.dart';
import 'package:meshcore_open/services/app_settings_service.dart';
import 'package:meshcore_open/services/sos_service.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:provider/provider.dart';

import '../services/sos_service_test.dart'
    show FakePhoneLocation, FakeSosTransport, freshSettings;

void main() {
  late AppSettingsService settings;
  late SosService sos;

  setUp(() async {
    settings = await freshSettings();
    sos = SosService(
      transport: FakeSosTransport(),
      settings: settings,
      phoneLocation: FakePhoneLocation(),
    );
  });

  tearDown(() => sos.dispose());

  Widget app(Widget home) => MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: settings),
      ChangeNotifierProvider.value(value: sos),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    ),
  );

  void bigScreen(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
  }

  testWidgets('walks through the five steps to connecting a radio', (
    tester,
  ) async {
    bigScreen(tester);
    await tester.pumpWidget(app(const SetupWizardScreen()));
    expect(find.text('Step 1 of 5'), findsOneWidget);
    expect(find.textContaining('best effort'), findsOneWidget);

    await tester.tap(find.text("I'm setting up a group"));
    await tester.pump();
    for (final (step, title) in [
      (2, 'Alerts on this device'),
      (3, 'Emergency network'),
      (4, 'Your emergency location'),
      (5, 'Connect your radio'),
    ]) {
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      expect(find.text('Step $step of 5'), findsOneWidget);
      expect(find.text(title), findsOneWidget);
    }
    expect(
      find.textContaining('Settings → App Settings → Emergency SOS'),
      findsOneWidget,
    );
    expect(find.text('Connect a radio'), findsOneWidget);

    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Step 4 of 5'), findsOneWidget);
  });

  testWidgets('the coordinator is told to create the network', (tester) async {
    bigScreen(tester);
    await tester.pumpWidget(app(const SetupWizardScreen()));
    await tester.tap(find.text("I'm setting up a group"));
    await tester.pump();
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Create the network.'), findsOneWidget);
    expect(find.text('Not set up yet'), findsOneWidget);
  });

  group('on first start', () {
    Widget launcher() => Builder(
      builder: (context) => TextButton(
        onPressed: () => SetupWizardScreen.showIfFirstRun(context),
        child: const Text('start'),
      ),
    );

    testWidgets('opens once on a new install', (tester) async {
      bigScreen(tester);
      await tester.pumpWidget(app(launcher()));
      await tester.tap(find.text('start'));
      await tester.pumpAndSettle();
      expect(find.byType(SetupWizardScreen), findsOneWidget);

      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();
      expect(find.byType(SetupWizardScreen), findsNothing);
      await tester.tap(find.text('start'));
      await tester.pumpAndSettle();
      expect(find.byType(SetupWizardScreen), findsNothing);
    });

    testWidgets('an app already set up skips it', (tester) async {
      bigScreen(tester);
      await settings.setSosLocation(-41.28, 174.77);
      await tester.pumpWidget(app(launcher()));
      await tester.tap(find.text('start'));
      await tester.pumpAndSettle();
      expect(find.byType(SetupWizardScreen), findsNothing);
      expect(PrefsManager.instance.getBool('setup_wizard_done'), isTrue);
    });
  });
}
