import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/screens/repeater_hub_screen.dart';
import 'package:meshcore_open/services/app_settings_service.dart';

Contact _contact(int type, String name) => Contact(
  publicKey: Uint8List.fromList(List.generate(32, (i) => i + type)),
  name: name,
  type: type,
  pathLength: 0,
  path: Uint8List(0),
  lastSeen: DateTime(2026, 11, 1),
);

Future<void> _pump(WidgetTester tester, Contact c) async {
  tester.view.physicalSize = const Size(400, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppSettingsService()),
        ChangeNotifierProvider(create: (_) => MeshCoreConnector()),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: RepeaterHubScreen(repeater: c, password: 'pw', isAdmin: true),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('sensor management shows sensor tools only', (tester) async {
    await _pump(tester, _contact(advTypeSensor, 'Lagoon St Weather'));
    expect(find.text('Sensor Management'), findsOneWidget);
    expect(find.byIcon(Icons.sensors), findsOneWidget);
    // telemetry, command line and settings work on sensors
    expect(find.byIcon(Icons.bar_chart_sharp), findsOneWidget);
    expect(find.byIcon(Icons.terminal), findsOneWidget);
    // repeater-only tools are hidden
    expect(find.byIcon(Icons.analytics), findsNothing); // status
    expect(find.byIcon(Icons.group), findsNothing); // neighbours
    expect(find.byIcon(Icons.badge_outlined), findsNothing); // owner info
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('repeater management keeps every tool', (tester) async {
    await _pump(tester, _contact(advTypeRepeater, 'Hilltop'));
    expect(find.text('Repeater Management'), findsOneWidget);
    expect(find.byIcon(Icons.analytics), findsOneWidget);
    expect(find.byIcon(Icons.group), findsOneWidget);
    expect(find.byIcon(Icons.badge_outlined), findsOneWidget);
    expect(find.byIcon(Icons.sensors), findsNothing);
    await tester.pump(const Duration(seconds: 2));
  });
}
