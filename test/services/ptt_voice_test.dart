import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/sos_voice_packet.dart';
import 'package:meshcore_open/models/channel.dart';
import 'package:meshcore_open/services/app_settings_service.dart';
import 'package:meshcore_open/services/sos_service.dart';
import 'package:meshcore_open/services/sos_voice_service.dart';

import 'package:meshcore_open/helpers/sos_network_code.dart';

import 'sos_service_test.dart'
    show
        FakePhoneLocation,
        FakeSosTransport,
        contactFor,
        farmNetwork,
        freshSettings;
import 'sos_voice_service_test.dart'
    show FakeCodec, FakeVoiceAudio, FakeVoiceTransport, loud;

/// A push-to-talk clip of [frames] frames from a sender whose key starts
/// with [seed], as channel data blobs, or as direct message texts.
List<SosVoicePacket> pttClip(
  int seed, {
  int frames = 60,
  bool direct = false,
}) => SosVoicePacket.split(
  frames: FakeCodec().encode([
    for (var i = 0; i < frames; i++) loud(i),
  ], SosVoiceQuality.low),
  quality: SosVoiceQuality.low,
  sosId: '0000',
  senderPrefix: Uint8List.fromList(List.filled(6, seed)),
  clipId: 9,
  ptt: true,
  framesPerChunk: direct
      ? SosVoicePacket.directFramesPerChunk(SosVoiceQuality.low)
      : null,
);

void main() {
  late FakeSosTransport sosTransport;
  late AppSettingsService settings;
  late SosService sos;
  late FakeVoiceTransport transport;
  late FakeVoiceAudio audio;
  late SosVoiceService voice;
  late DateTime now;
  late Set<String> remembered;

  /// The Public channel in slot 0, as on every MeshCore radio.
  final public = Channel(
    index: 0,
    name: 'Public',
    psk: Uint8List.fromList(List.generate(16, (i) => 0x8b + i)),
  );

  setUp(() async {
    settings = await freshSettings();
    sosTransport = FakeSosTransport();
    now = DateTime(2026, 10, 31, 9);
    sos = SosService(
      transport: sosTransport,
      settings: settings,
      phoneLocation: FakePhoneLocation(),
      now: () => now,
    );
    transport = FakeVoiceTransport()..channels = [public];
    audio = FakeVoiceAudio();
    remembered = {};
    voice = SosVoiceService(
      sos: sos,
      transport: transport,
      audio: audio,
      codec: FakeCodec(),
      now: () => now,
      pttChannelAddedBefore: remembered.contains,
      rememberPttChannelAdded: remembered.add,
    );
  });

  tearDown(() {
    voice.dispose();
    sos.dispose();
  });

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  Future<void> addVoiceChannel() async {
    transport.change!();
    await settle();
  }

  Future<void> talk(String key, int frames) async {
    expect(await voice.startTalking(key), isTrue);
    for (var i = 0; i < frames; i++) {
      audio.mic!.add(loud(i));
    }
    await settle();
    await voice.stopTalking();
    await settle();
  }

  group('the Voice channel', () {
    test('is added once, to the last free slot, beside Public', () async {
      await addVoiceChannel();
      final added = voice.pttChannel!;
      expect(added.name, '#voice');
      expect(added.index, 7);
      expect(added.psk, Channel.derivePskFromHashtag('#voice'));
      expect(added.psk, isNot(public.psk));
      expect(transport.channels.first, same(public)); // Public untouched
      expect(remembered, hasLength(1));
    });

    test('stays removed once the user removes it', () async {
      await addVoiceChannel();
      transport.channels = [public];
      await addVoiceChannel();
      expect(voice.pttChannel, isNull);
    });

    test('is not added when the radio has no free slot', () async {
      transport.channels = [
        for (var i = 0; i < 8; i++)
          Channel(index: i, name: 'c$i', psk: Uint8List(16)..[0] = i + 1),
      ];
      await addVoiceChannel();
      expect(voice.pttChannel, isNull);
      expect(
        voice.blockFor(SosVoiceService.pttChannelKey),
        SosVoiceBlock.noChannel,
      );
    });
  });

  group('push-to-talk on the Voice channel', () {
    setUp(addVoiceChannel);

    test(
      'sends push-to-talk chunks on the Voice channel, never Public',
      () async {
        await talk(SosVoiceService.pttChannelKey, 50);
        final (channel, blobs) = transport.sent.single;
        expect(channel, voice.pttChannel!.index);
        expect(channel, isNot(public.index));
        final packets = blobs.map(SosVoicePacket.decode).toList();
        expect(packets.every((p) => p!.ptt), isTrue);
        expect(
          voice.clipsFor(SosVoiceService.pttChannelKey).single.status,
          VoiceClipStatus.sent,
        );
      },
    );

    test('a clip stops at 10 seconds', () async {
      await talk(SosVoiceService.pttChannelKey, 400);
      final clip = voice.clipsFor(SosVoiceService.pttChannelKey).single;
      expect(clip.duration, const Duration(seconds: 10));
    });

    test('a reply can follow straight away: no wait between clips', () async {
      await talk(SosVoiceService.pttChannelKey, 50);
      expect(voice.blockFor(SosVoiceService.pttChannelKey), isNull);
      await talk(SosVoiceService.pttChannelKey, 30);
      expect(transport.sent, hasLength(2));
    });

    test('is busy while someone else\'s clip is arriving', () async {
      final blobs = [for (final p in pttClip(0x42)) p.encode()];
      transport.listener!(voice.pttChannel!.index, blobs.first);
      expect(voice.channelBusy, isTrue);
      expect(voice.blockFor(SosVoiceService.pttChannelKey), SosVoiceBlock.busy);
      for (final b in blobs.skip(1)) {
        transport.listener!(voice.pttChannel!.index, b);
      }
      await settle();
      expect(voice.channelBusy, isFalse);
      expect(audio.played, hasLength(1)); // and it played
    });

    test('busy ends 4 seconds after the last chunk of a broken clip', () {
      final blobs = [for (final p in pttClip(0x42)) p.encode()];
      transport.listener!(voice.pttChannel!.index, blobs.first);
      now = now.add(const Duration(seconds: 5));
      expect(voice.channelBusy, isFalse);
    });

    test('our own clip repeated back is ignored', () async {
      final self = transport.selfPublicKey![0];
      for (final p in pttClip(self)) {
        transport.listener!(voice.pttChannel!.index, p.encode());
      }
      await settle();
      expect(voice.clipsFor(SosVoiceService.pttChannelKey), isEmpty);
    });

    test(
      'an SOS clip on the Voice channel is not played as push-to-talk',
      () async {
        final sosPackets = SosVoicePacket.split(
          frames: FakeCodec().encode([loud(0), loud(1)], SosVoiceQuality.low),
          quality: SosVoiceQuality.low,
          sosId: 'beef',
          senderPrefix: Uint8List.fromList(List.filled(6, 0x42)),
          clipId: 1,
        );
        transport.listener!(
          voice.pttChannel!.index,
          sosPackets.single.encode(),
        );
        await settle();
        expect(voice.clipsFor(SosVoiceService.pttChannelKey), isEmpty);
      },
    );

    test(
      'an SOS pauses push-to-talk and stops a clip being recorded',
      () async {
        expect(await voice.startTalking(SosVoiceService.pttChannelKey), isTrue);
        await sos.activate();
        await settle();
        expect(voice.isTalking(SosVoiceService.pttChannelKey), isFalse);
        expect(
          voice.blockFor(SosVoiceService.pttChannelKey),
          SosVoiceBlock.sosLive,
        );
        expect(transport.sent, isEmpty);
      },
    );

    test('during an SOS, clips heard wait to be played by hand', () async {
      await sos.activate();
      for (final p in pttClip(0x42)) {
        transport.listener!(voice.pttChannel!.index, p.encode());
      }
      await settle();
      expect(voice.clipsFor(SosVoiceService.pttChannelKey), hasLength(1));
      expect(audio.played, isEmpty);
    });

    test('is never hands-free', () async {
      expect(
        await voice.setHandsFree(SosVoiceService.pttChannelKey, true),
        isFalse,
      );
    });
  });

  group('standing aside for text, and the talk limit', () {
    setUp(addVoiceChannel);

    test('waits 15 seconds after a text message', () {
      transport.recentTextTraffic = [now.subtract(const Duration(seconds: 5))];
      expect(
        voice.blockFor(SosVoiceService.pttChannelKey),
        SosVoiceBlock.meshBusy,
      );
      expect(voice.meshBusyWait, const Duration(seconds: 10));
      now = now.add(const Duration(seconds: 10));
      expect(voice.blockFor(SosVoiceService.pttChannelKey), isNull);
    });

    test('waits while 4 or more text messages went in the last minute', () {
      transport.recentTextTraffic = [
        for (final s in [50, 40, 30, 20]) now.subtract(Duration(seconds: s)),
      ];
      // the oldest must age out of the minute: 10 s more
      expect(voice.meshBusyWait, const Duration(seconds: 10));
      transport.recentTextTraffic = [
        for (final s in [50, 40, 30]) now.subtract(Duration(seconds: s)),
      ];
      expect(voice.meshBusyWait, Duration.zero);
    });

    test('direct messages stand aside for text too', () {
      final joe = contactFor('Joe', 0x42);
      transport.contacts = [joe];
      transport.recentTextTraffic = [now];
      expect(
        voice.blockFor(SosVoiceService.pttDirectKey(joe.publicKeyHex)),
        SosVoiceBlock.meshBusy,
      );
    });

    Future<void> hearChannelClip(int seed, int frames) async {
      for (final p in pttClip(seed, frames: frames)) {
        transport.listener!(voice.pttChannel!.index, p.encode());
      }
      await settle();
    }

    test(
      '3 minutes of talk in a conversation: the talkers rest 5 minutes',
      () async {
        // a back-and-forth: 9 clips each way, 10 s each
        for (var i = 0; i < 9; i++) {
          await talk(SosVoiceService.pttChannelKey, 250);
          await hearChannelClip(0x42 + i, 250);
          now = now.add(const Duration(seconds: 25));
        }
        expect(
          voice.blockFor(SosVoiceService.pttChannelKey),
          SosVoiceBlock.talkLimit,
        );
        expect(voice.talkLimitWait, const Duration(minutes: 4, seconds: 35));
        // the rest covers direct messages too
        final joe = contactFor('Joe', 0x42);
        transport.contacts = [joe];
        expect(
          voice.blockFor(SosVoiceService.pttDirectKey(joe.publicKeyHex)),
          SosVoiceBlock.talkLimit,
        );
        // two tones played
        expect(
          audio.played.any(
            (pcm) => pcm.length == SosVoiceService.restTones().length,
          ),
          isTrue,
        );
        now = now.add(const Duration(minutes: 4, seconds: 35));
        expect(voice.blockFor(SosVoiceService.pttChannelKey), isNull);
        expect(voice.sessionTalk(SosVoiceService.pttChannelKey), Duration.zero);
      },
    );

    test('someone who only listened is not stopped', () async {
      for (var i = 0; i < 18; i++) {
        await hearChannelClip(0x42 + i, 250);
        now = now.add(const Duration(seconds: 12));
      }
      expect(voice.blockFor(SosVoiceService.pttChannelKey), isNull);
      expect(voice.talkLimitWait, Duration.zero);
      expect(voice.sessionTalk(SosVoiceService.pttChannelKey), Duration.zero);
    });

    test(
      'a clip is cut short so the conversation stays within 3 minutes',
      () async {
        for (var i = 0; i < 17; i++) {
          await hearChannelClip(0x42 + i, 250);
        }
        await talk(SosVoiceService.pttChannelKey, 125); // 2:55
        await talk(SosVoiceService.pttChannelKey, 250); // only 5 s allowed
        final mine = voice
            .clipsFor(SosVoiceService.pttChannelKey)
            .where((c) => c.outgoing)
            .toList();
        expect(mine.last.duration, const Duration(seconds: 5));
        expect(voice.talkLimitWait, const Duration(minutes: 5));
      },
    );

    test('5 minutes without voice ends the session', () async {
      for (var i = 0; i < 6; i++) {
        await talk(SosVoiceService.pttChannelKey, 250);
      }
      expect(
        voice.sessionTalk(SosVoiceService.pttChannelKey),
        const Duration(minutes: 1),
      );
      now = now.add(const Duration(minutes: 5));
      expect(voice.sessionTalk(SosVoiceService.pttChannelKey), Duration.zero);
    });

    test('each direct message is a conversation of its own', () async {
      final joe = contactFor('Joe', 0x42);
      transport.contacts = [joe];
      final dm = SosVoiceService.pttDirectKey(joe.publicKeyHex);
      for (var i = 0; i < 6; i++) {
        await talk(dm, 250);
      }
      expect(voice.sessionTalk(dm), const Duration(minutes: 1));
      expect(voice.sessionTalk(SosVoiceService.pttChannelKey), Duration.zero);
    });

    test('SOS voice is never limited', () async {
      for (var i = 0; i < 18; i++) {
        await talk(SosVoiceService.pttChannelKey, 250);
      }
      // 3 minutes talked: resting
      expect(voice.talkLimitWait, greaterThan(Duration.zero));
      transport.recentTextTraffic = [now];
      expect(voice.blockFor('a1b2'), SosVoiceBlock.noSos); // not talkLimit
    });
  });

  group('an SOS the member can\'t read still pauses push-to-talk', () {
    setUp(() async {
      await addVoiceChannel();
      await settings.joinSosNetwork(farmNetwork(SosNetworkRole.member));
      await settle();
    });

    void hearSosPacket() =>
        sos.handleInboundData(sos.sosChannel!.index, Uint8List(40)..[0] = 9);

    test('for 5 minutes after any SOS packet on the network', () {
      expect(voice.blockFor(SosVoiceService.pttChannelKey), isNull);
      hearSosPacket(); // unreadable: just noise to a member
      expect(sos.incoming, isEmpty); // nothing was read
      expect(
        voice.blockFor(SosVoiceService.pttChannelKey),
        SosVoiceBlock.sosLive,
      );
      now = now.add(const Duration(minutes: 4));
      hearSosPacket(); // the SOS repeats: still paused
      now = now.add(const Duration(minutes: 4));
      expect(
        voice.blockFor(SosVoiceService.pttChannelKey),
        SosVoiceBlock.sosLive,
      );
      now = now.add(const Duration(minutes: 1, seconds: 1));
      expect(voice.blockFor(SosVoiceService.pttChannelKey), isNull);
    });

    test('a clip being recorded is cancelled', () async {
      expect(await voice.startTalking(SosVoiceService.pttChannelKey), isTrue);
      hearSosPacket();
      await settle();
      expect(voice.isTalking(SosVoiceService.pttChannelKey), isFalse);
      expect(transport.sent, isEmpty);
    });

    test('a clip already going out stops at the next packet', () async {
      transport.beforeChunk = (i) {
        if (i == 2) hearSosPacket();
      };
      await talk(SosVoiceService.pttChannelKey, 250); // 6 packets
      expect(transport.stoppedAfter, 2); // 2 went, 4 held back
      expect(
        voice.clipsFor(SosVoiceService.pttChannelKey).single.status,
        VoiceClipStatus.failed,
      );
    });

    test('a direct message clip stops too', () async {
      final joe = contactFor('Joe', 0x42);
      transport.contacts = [joe];
      transport.beforeChunk = (i) {
        if (i == 1) hearSosPacket();
      };
      await talk(SosVoiceService.pttDirectKey(joe.publicKeyHex), 100);
      expect(transport.stoppedAfter, 1);
    });
  });

  group('push-to-talk in a direct message', () {
    final joe = contactFor('Joe', 0x42);
    late String key;

    setUp(() {
      transport.contacts = [joe];
      key = SosVoiceService.pttDirectKey(joe.publicKeyHex);
    });

    test('goes to the contact as short direct messages', () async {
      await talk(key, 100);
      final (to, texts) = transport.sentDirect.single;
      expect(to, same(joe));
      expect(texts, hasLength(4)); // 100 frames, 26 to a message
      for (final t in texts) {
        expect(t, startsWith(SosVoicePacket.directPrefix));
        expect(t.length, lessThanOrEqualTo(SosVoicePacket.maxDirectText));
      }
      expect(transport.sent, isEmpty); // nothing on any channel
    });

    test('needs no Voice channel', () async {
      expect(voice.pttChannel, isNull);
      expect(voice.blockFor(key), isNull);
    });

    test('clips heard from the contact play', () async {
      for (final p in pttClip(0x42, direct: true)) {
        transport.direct!(joe.publicKeyHex, p.toDirectText());
      }
      await settle();
      final clip = voice.clipsFor(key).single;
      expect(clip.senderName, 'Joe');
      expect(clip.status, VoiceClipStatus.received);
      expect(audio.played, hasLength(1));
    });

    test('a clip heard is announced and marked unheard until seen', () async {
      final heard = <(String, String?)>[];
      voice.onPttClipHeard = (conv, clip) => heard.add((conv, clip.senderName));
      for (final p in pttClip(0x42, direct: true)) {
        transport.direct!(joe.publicKeyHex, p.toDirectText());
      }
      await settle();
      expect(heard, [(key, 'Joe')]);
      expect(voice.hasUnheard(key), isTrue);
      expect(voice.hasUnheard(SosVoiceService.pttChannelKey), isFalse);
      voice.markHeard(key);
      expect(voice.hasUnheard(key), isFalse);
    });

    test('our own clips are not announced', () async {
      var announced = 0;
      voice.onPttClipHeard = (_, _) => announced++;
      await talk(key, 50);
      expect(announced, 0);
      expect(voice.hasUnheard(key), isFalse);
    });

    test('a reply can follow straight away', () async {
      await talk(key, 50);
      expect(voice.blockFor(key), isNull);
      await talk(key, 50);
      expect(transport.sentDirect, hasLength(2));
    });
  });

  group('SosVoicePacket for push-to-talk', () {
    test('a direct message chunk round-trips', () {
      final p = pttClip(0x42, direct: true).first;
      final back = SosVoicePacket.fromDirectText(p.toDirectText())!;
      expect(back.ptt, isTrue);
      expect(back.frames.length, p.frames.length);
      expect(back.senderPrefix, p.senderPrefix);
    });

    test('ordinary text and SOS chunks are not push-to-talk', () {
      expect(SosVoicePacket.fromDirectText('hello'), isNull);
      expect(SosVoicePacket.fromDirectText('~ptt1:not base64!'), isNull);
      final sos = SosVoicePacket.split(
        frames: FakeCodec().encode([loud(0)], SosVoiceQuality.low),
        quality: SosVoiceQuality.low,
        sosId: 'beef',
        senderPrefix: Uint8List(6),
        clipId: 1,
      ).single;
      expect(SosVoicePacket.decode(sos.encode())!.ptt, isFalse);
    });

    test('a 10-second clip fits in direct messages at either quality', () {
      for (final q in SosVoiceQuality.values) {
        final frames = 10000 ~/ SosVoicePacket.frameMs;
        final chunks =
            (frames + SosVoicePacket.directFramesPerChunk(q) - 1) ~/
            SosVoicePacket.directFramesPerChunk(q);
        expect(
          chunks,
          lessThanOrEqualTo(SosVoicePacket.maxPttChunks),
          reason: q.name,
        );
      }
    });
  });
}
