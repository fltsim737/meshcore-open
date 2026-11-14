import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/screens/path_trace_builder_screen.dart';
import 'package:provider/provider.dart';

Contact _repeater(int prefix, String name) => Contact(
  publicKey: Uint8List(32)..first = prefix,
  name: name,
  type: advTypeRepeater,
  pathLength: 0,
  path: Uint8List(0),
  lastSeen: DateTime.utc(2026),
);

Widget _app(List<Contact> contacts) => ChangeNotifierProvider(
  create: (_) => MeshCoreConnector(),
  child: MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: PathTraceBuilderScreen(contactsForTest: contacts),
  ),
);

String _hex(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField).first).controller!.text;

FilledButton _traceButton(WidgetTester tester) => tester.widget<FilledButton>(
  find.ancestor(
    of: find.text('Trace there and back'),
    matching: find.byWidgetPredicate((w) => w is FilledButton),
  ),
);

void main() {
  final repeaters = [_repeater(0xA1, 'Hilltop'), _repeater(0xB2, 'Harbour')];

  testWidgets('hex path is at the top and typing it builds the hops', (
    tester,
  ) async {
    await tester.pumpWidget(_app(repeaters));
    await tester.pumpAndSettle();
    expect(find.text('Path (hex)'), findsOneWidget);
    expect(_traceButton(tester).onPressed, isNull);

    await tester.enterText(find.byType(TextField).first, 'a1,b2');
    await tester.pump();
    expect(find.text('0 of 64 hops'), findsNothing);
    expect(find.text('2 of 64 hops'), findsOneWidget);
    expect(find.text('Hilltop'), findsWidgets); // the hop is named
    expect(_traceButton(tester).onPressed, isNotNull);

    await tester.enterText(find.byType(TextField).first, 'a1,zz');
    await tester.pump();
    expect(find.text('Invalid: zz'), findsOneWidget);
    expect(_traceButton(tester).onPressed, isNull);
  });

  testWidgets('tapping repeaters below fills the hex path', (tester) async {
    await tester.pumpWidget(_app(repeaters));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Harbour'));
    await tester.pump();
    await tester.tap(find.text('Hilltop').last);
    await tester.pump();
    expect(_hex(tester), 'B2,A1');
    expect(find.text('2 of 64 hops'), findsOneWidget);

    await tester.tap(find.byTooltip('Remove hop').first);
    await tester.pump();
    expect(_hex(tester), 'A1');

    await tester.tap(find.text('Clear'));
    await tester.pump();
    expect(_hex(tester), '');
  });
}
