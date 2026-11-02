import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/message_search.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/widgets/message_search_screen.dart';

void main() {
  final history = [
    MessageSearchHit(
      messageId: 'a',
      sender: 'Maya',
      text: 'Meet at the Walcha bridge at noon',
      time: DateTime(2026, 11, 2, 9),
    ),
    MessageSearchHit(
      messageId: 'b',
      sender: 'Sam',
      text: 'Road to Armidale is closed',
      time: DateTime(2026, 11, 2, 10),
    ),
  ];

  Future<String?> runSearch(WidgetTester t, String query, String tap) async {
    String? picked;
    await t.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              picked = await MessageSearchScreen.open(
                context,
                title: 'Search this chat',
                load: () async => history,
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), query);
    await t.pump(const Duration(milliseconds: 300));
    await t.pumpAndSettle();
    expect(find.text('1 found'), findsOneWidget);
    await t.tap(find.textContaining(tap, findRichText: true));
    await t.pumpAndSettle();
    return picked;
  }

  testWidgets('finds a message by its words and returns it', (t) async {
    expect(await runSearch(t, 'walcha', 'noon'), 'a');
  });

  testWidgets('finds a message by its sender', (t) async {
    expect(await runSearch(t, 'sam', 'Armidale'), 'b');
  });

  testWidgets('says so when nothing matches', (t) async {
    await t.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MessageSearchScreen(
          title: 'Search this chat',
          load: () async => history,
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), 'flood');
    await t.pump(const Duration(milliseconds: 300));
    await t.pumpAndSettle();
    expect(find.text('No messages match.'), findsOneWidget);
  });
}
