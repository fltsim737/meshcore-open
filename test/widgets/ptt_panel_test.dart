import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/services/sos_service.dart';
import 'package:meshcore_open/services/sos_voice_service.dart';
import 'package:meshcore_open/widgets/ptt_panel.dart';
import 'package:provider/provider.dart';

import '../services/sos_service_test.dart'
    show FakePhoneLocation, FakeSosTransport, contactFor, freshSettings;
import '../services/sos_voice_service_test.dart'
    show FakeCodec, FakeVoiceAudio, FakeVoiceTransport;

void main() {
  late SosService sos;
  late FakeVoiceTransport transport;
  late SosVoiceService voice;

  setUp(() async {
    final settings = await freshSettings();
    sos = SosService(
      transport: FakeSosTransport(),
      settings: settings,
      phoneLocation: FakePhoneLocation(),
    );
    transport = FakeVoiceTransport();
    voice = SosVoiceService(
      sos: sos,
      transport: transport,
      audio: FakeVoiceAudio(),
      codec: FakeCodec(),
    );
  });

  tearDown(() {
    voice.dispose();
    sos.dispose();
  });

  Widget app(Widget panel) => ChangeNotifierProvider.value(
    value: voice,
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Align(alignment: Alignment.bottomCenter, child: panel),
      ),
    ),
  );

  testWidgets('the Voice channel: hold to talk, with its limits', (
    tester,
  ) async {
    transport.change!(); // the Voice channel goes on the radio
    await tester.pumpWidget(
      app(const PttPanel(conversation: SosVoiceService.pttChannelKey)),
    );
    expect(find.text('Hold to talk'), findsOneWidget);
    expect(
      find.textContaining('Every clip uses airtime the whole mesh shares'),
      findsOneWidget,
    );
  });

  testWidgets('says when the Voice channel is missing', (tester) async {
    transport.channels = [];
    transport.channelsReady = false; // not added yet
    await tester.pumpWidget(
      app(const PttPanel(conversation: SosVoiceService.pttChannelKey)),
    );
    expect(
      find.textContaining("The Voice channel isn't on this radio"),
      findsOneWidget,
    );
  });

  testWidgets('a direct message names the contact', (tester) async {
    final joe = contactFor('Joe', 0x42);
    transport.contacts = [joe];
    await tester.pumpWidget(
      app(
        PttPanel(
          conversation: SosVoiceService.pttDirectKey(joe.publicKeyHex),
          contactName: 'Joe',
        ),
      ),
    );
    expect(find.textContaining('sent straight to Joe'), findsOneWidget);
  });
}
