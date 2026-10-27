import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/sos_codec.dart';
import 'package:meshcore_open/helpers/sos_network_code.dart';
import 'package:meshcore_open/helpers/sos_seal.dart';
import 'package:meshcore_open/helpers/sos_voice_packet.dart';
import 'package:meshcore_open/models/channel.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/services/app_settings_service.dart';
import 'package:meshcore_open/services/sos_service.dart';
import 'package:meshcore_open/services/sos_voice_service.dart';
import 'package:meshcore_open/services/voice_audio.dart';
import 'package:meshcore_open/services/voice_codec.dart';

import 'sos_service_test.dart'
    show
        FakePhoneLocation,
        FakeSosTransport,
        contactFor,
        farmNetwork,
        freshSettings,
        sosPacketFrom;

class FakeVoiceTransport implements SosVoiceTransport {
  @override
  Uint8List? selfPublicKey = Uint8List.fromList(List.filled(32, 0xAA));
  @override
  List<Contact> contacts = [];
  void Function(int channelIndex, Uint8List payload)? listener;

  /// (channel, blobs) for every clip sent.
  final List<(int, List<Uint8List>)> sent = [];

  @override
  set voiceListener(void Function(int, Uint8List)? value) => listener = value;

  @override
  Duration chunkGap(int bytes) => Duration.zero;

  @override
  Future<bool> sendChunks(
    int channelIndex,
    List<Uint8List> blobs, {
    required Duration gap,
    void Function(int sent, int total)? onProgress,
  }) async {
    sent.add((channelIndex, blobs));
    for (var i = 0; i < blobs.length; i++) {
      onProgress?.call(i + 1, blobs.length);
    }
    return true;
  }
}

class FakeVoiceAudio implements VoiceAudio {
  bool permission = true;
  StreamController<Int16List>? mic;
  final List<Int16List> played = [];

  /// When set, playback waits for it, as a real clip takes time to play.
  Completer<void>? playGate;

  @override
  Future<bool> ensureMicPermission() async => permission;
  @override
  Future<Stream<Int16List>> startMic() async {
    mic = StreamController<Int16List>();
    return mic!.stream;
  }

  @override
  Future<void> stopMic() async {
    await mic?.close();
    mic = null;
  }

  @override
  Future<void> play(Int16List pcm) async {
    played.add(pcm);
    await playGate?.future;
  }

  @override
  Future<void> stopPlayback() async => playGate?.complete();
  @override
  Future<void> dispose() async {}
}

/// Stores each frame's first sample in its first bytes, so tests can tell
/// frames apart after a round trip.
class FakeCodec implements VoiceCodec {
  @override
  List<Uint8List> encode(List<Int16List> frames, SosVoiceQuality quality) {
    final bytes = (quality.bitsPerFrame + 7) ~/ 8;
    return [
      for (final f in frames)
        Uint8List(bytes)
          ..[0] = (f[0] >> 8) & 0xFF
          ..[1] = f[0] & 0xFF,
    ];
  }

  @override
  Int16List decode(List<Uint8List?> frames, SosVoiceQuality quality) {
    final out = Int16List(frames.length * SosVoicePacket.samplesPerFrame);
    for (var i = 0; i < frames.length; i++) {
      final f = frames[i];
      if (f == null) continue;
      out[i * SosVoicePacket.samplesPerFrame] = ((f[0] << 8) | f[1]).toSigned(
        16,
      );
    }
    return out;
  }
}

Int16List loud(int i) => Int16List.fromList([
  for (var s = 0; s < 320; s++) (9000 * sin(s * 0.3)).round() + i,
]);

Int16List quiet(int i) =>
    Int16List.fromList([for (var s = 0; s < 320; s++) (s * 7 + i) % 30 - 15]);

/// A voice clip for [sosId] from a sender whose key starts with [seed].
List<Uint8List> clipFrom(
  int seed,
  String sosId, {
  int frames = 60,
  bool sealed = false,
}) => [
  for (final p in SosVoicePacket.split(
    frames: FakeCodec().encode([
      for (var i = 0; i < frames; i++) loud(i),
    ], SosVoiceQuality.low),
    quality: SosVoiceQuality.low,
    sosId: sosId,
    senderPrefix: Uint8List.fromList(List.filled(6, seed)),
    clipId: 3,
    sealed: sealed,
  ))
    p.encode(),
];

void main() {
  late FakeSosTransport sosTransport;
  late AppSettingsService settings;
  late SosService sos;
  late FakeVoiceTransport transport;
  late FakeVoiceAudio audio;
  late SosVoiceService voice;
  late List<bool> backgroundMic;

  setUp(() async {
    settings = await freshSettings();
    sosTransport = FakeSosTransport();
    sos = SosService(
      transport: sosTransport,
      settings: settings,
      phoneLocation: FakePhoneLocation(),
    );
    transport = FakeVoiceTransport();
    audio = FakeVoiceAudio();
    backgroundMic = [];
    voice = SosVoiceService(
      sos: sos,
      transport: transport,
      audio: audio,
      codec: FakeCodec(),
      setBackgroundMic: (on) async => backgroundMic.add(on),
    );
  });

  tearDown(() {
    voice.dispose();
    sos.dispose();
  });

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  Future<void> say(Int16List Function(int) frame, int count) async {
    for (var i = 0; i < count; i++) {
      audio.mic!.add(frame(i));
    }
    await settle();
  }

  void hear(List<Uint8List> blobs, {int channel = 2}) {
    for (final b in blobs) {
      transport.listener!(channel, b);
    }
  }

  test('voice is only for a live SOS on the emergency network', () async {
    expect(voice.blockFor('a1b2'), SosVoiceBlock.noSos);
    await sos.activate();
    final id = sos.active!.id;
    expect(voice.blockFor(id), SosVoiceBlock.noNetwork);
    await settings.joinSosNetwork(farmNetwork(SosNetworkRole.member));
    expect(voice.blockFor(id), isNull);
    sosTransport.setConnected(false);
    expect(voice.blockFor(id), SosVoiceBlock.radio);
  });

  group('with a network', () {
    setUp(() async {
      await settings.joinSosNetwork(farmNetwork(SosNetworkRole.member));
      await sos.activate();
    });

    test('push-to-talk sends a clip on the network channel', () async {
      final id = sos.active!.id;
      expect(await voice.startTalking(id), isTrue);
      await say(loud, 50);
      await voice.stopTalking();
      await settle();

      final (channel, blobs) = transport.sent.single;
      expect(channel, 2);
      final packets = [for (final b in blobs) SosVoicePacket.decode(b)!];
      expect(packets.every((p) => p.sosId == id), isTrue);
      expect(packets.first.senderPrefix, List.filled(6, 0xAA));
      expect(packets.expand((p) => p.frames), hasLength(50));
      final clip = voice.clipsFor(id).single;
      expect(clip.outgoing, isTrue);
      expect(clip.status, VoiceClipStatus.sent);
      expect(audio.mic, isNull);
    });

    test('a tap too short to be speech is not sent', () async {
      await voice.startTalking(sos.active!.id);
      await say(loud, 5);
      await voice.stopTalking();
      await settle();
      expect(transport.sent, isEmpty);
    });

    test('no microphone permission, no talking', () async {
      audio.permission = false;
      expect(await voice.startTalking(sos.active!.id), isFalse);
      expect(voice.micDenied, isTrue);
      expect(audio.mic, isNull);
    });

    test('hands-free sends each stretch of speech', () async {
      final id = sos.active!.id;
      expect(await voice.setHandsFree(id, true), isTrue);
      expect(backgroundMic, [true]);
      await say(quiet, 40);
      await say(loud, 40);
      await say(quiet, 40);
      await settle();
      expect(transport.sent, hasLength(1));

      await voice.setHandsFree(id, false);
      expect(backgroundMic, [true, false]);
      expect(audio.mic, isNull);
    });

    test('replies play aloud, named from contacts', () async {
      final id = sos.active!.id;
      transport.contacts = [contactFor('Ranger', 5)];
      hear(clipFrom(5, id));
      await settle();
      expect(audio.played, hasLength(1));
      final clip = voice.clipsFor(id).single;
      expect(clip.outgoing, isFalse);
      expect(clip.senderName, 'Ranger');
      expect(clip.status, VoiceClipStatus.received);
      expect(clip.duration, const Duration(milliseconds: 60 * 40));
    });

    test('ignores other SOS IDs, other channels and our own echo', () async {
      final id = sos.active!.id;
      final other = id == '0000' ? '0001' : '0000';
      hear(clipFrom(5, other));
      hear(clipFrom(5, id), channel: 0);
      hear(clipFrom(0xAA, id));
      await settle();
      expect(audio.played, isEmpty);
      expect(voice.clipsFor(id), isEmpty);
    });

    test('hands-free ignores the speaker while a clip plays', () async {
      final id = sos.active!.id;
      await voice.setHandsFree(id, true);
      audio.playGate = Completer<void>();
      hear(clipFrom(5, id));
      await settle();
      expect(voice.playing, isNotNull);
      await say(loud, 60);
      await say(quiet, 40);
      expect(transport.sent, isEmpty);
      audio.playGate!.complete();
      await settle();
      expect(voice.playing, isNull);
    });

    test('cancelling the SOS turns hands-free off', () async {
      final id = sos.active!.id;
      await voice.setHandsFree(id, true);
      await sos.cancel();
      await settle();
      expect(voice.isHandsFree(id), isFalse);
      expect(audio.mic, isNull);
      expect(voice.blockFor(id), SosVoiceBlock.noSos);
    });
  });

  test('a responder hears voice for a live alert, a member does not', () async {
    await settings.joinSosNetwork(farmNetwork(SosNetworkRole.responder));
    sosTransport.dataListener!(
      2,
      sosPacketFrom('Jo', 9, 'beef', withKey: true),
      SosSignal.unknown,
    );
    expect(sos.incoming.single.id, 'beef');
    expect(voice.blockFor('beef'), isNull);
    hear(clipFrom(9, 'beef'));
    await settle();
    expect(voice.clipsFor('beef').single.senderName, 'Jo');

    await settings.joinSosNetwork(farmNetwork(SosNetworkRole.member));
    expect(voice.blockFor('beef'), SosVoiceBlock.noSos);
  });

  group('on a sealed (SOS2) network', () {
    late SosNetworkCode net;
    late SosSession responder;

    setUp(() async {
      net = SosNetworkCode.generateSealed(name: 'Farm');
      sosTransport.allChannels = [
        for (final c in sosTransport.allChannels)
          if (c.index != 2) c,
        Channel(index: 2, name: 'Farm', psk: net.key),
      ];
      await settings.joinSosNetwork(net.withRole(SosNetworkRole.member));
      await sos.activate();
      // What a responder works out from the sealed SOS this phone sent
      final head = SosSeal.header(sosTransport.rawChannelData.last.$2)!;
      responder = SosSeal.responderSession(
        net.networkSecret!,
        head.ephPublic!,
      )!;
    });

    Uint8List seal(Uint8List b) =>
        SosSeal.sealRaw([2, b[1], b[2], b[3]], responder, b.sublist(4));

    test('clips are sealed, and only the network\'s responders can play '
        'them', () async {
      final id = sos.active!.id;
      expect(await voice.startTalking(id), isTrue);
      await say(loud, 50);
      await voice.stopTalking();
      await settle();

      final (_, blobs) = transport.sent.single;
      expect(blobs.every((b) => SosVoicePacket.decode(b) == null), isTrue);
      expect(
        blobs.every((b) => b.length <= SosVoicePacket.maxBlobBytes),
        isTrue,
      );
      final frames = <Uint8List>[];
      for (final b in blobs) {
        final head = SosSeal.header(b, fullKeyKind: null)!;
        final body = SosSeal.openRaw(b, head.length, responder)!;
        final packet = SosVoicePacket.decode(
          Uint8List.fromList([1, head.kind, b[2], b[3], ...body]),
        )!;
        frames.addAll(packet.frames);
      }
      expect(frames, hasLength(50));

      // A responder's sealed reply plays; an unsealed one is ignored
      hear([for (final b in clipFrom(5, id, sealed: true)) seal(b)]);
      await settle();
      expect(audio.played, hasLength(1));
      hear(clipFrom(6, id));
      await settle();
      expect(audio.played, hasLength(1));
    });

    test('the longest clip still fits, sealed', () {
      for (final quality in SosVoiceQuality.values) {
        final packets = SosVoicePacket.split(
          frames: FakeCodec().encode([
            for (var i = 0; i < quality.maxFrames + 10; i++) loud(i),
          ], quality),
          quality: quality,
          sosId: 'a1b2',
          senderPrefix: Uint8List(6),
          clipId: 1,
          sealed: true,
        );
        expect(packets.length, lessThanOrEqualTo(SosVoicePacket.maxChunks));
        for (final p in packets) {
          expect(
            seal(p.encode()).length,
            lessThanOrEqualTo(SosVoicePacket.maxBlobBytes),
          );
        }
      }
    });
  });
}
