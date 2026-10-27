import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/sos_codec.dart';
import 'package:meshcore_open/helpers/sos_network_code.dart';
import 'package:meshcore_open/helpers/sos_seal.dart';
import 'package:meshcore_open/models/channel.dart';
import 'package:meshcore_open/models/sos_session_book.dart';
import 'package:meshcore_open/services/app_settings_service.dart';
import 'package:meshcore_open/services/sos_service.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sos_service_test.dart'
    show FakeAlerter, FakePhoneLocation, FakeSosTransport;

/// One phone with its radio, on an SOS2 network.
class Phone {
  final FakeSosTransport transport;
  final AppSettingsService settings;
  final FakeAlerter alerter = FakeAlerter();
  final FakePhoneLocation location = FakePhoneLocation();
  late SosService service;
  int _sent = 0;

  Phone(this.transport, this.settings, DateTime Function() now) {
    service = SosService(
      transport: transport,
      settings: settings,
      phoneLocation: location,
      alerter: alerter,
      now: now,
    );
  }

  /// Network packets sent since last asked.
  List<(int, Uint8List, bool)> takeSent() {
    final out = transport.rawChannelData.sublist(_sent);
    _sent = transport.rawChannelData.length;
    return out;
  }

  int get channel => service.sosChannel!.index;
}

FakeSosTransport radio(String name, int seed) => FakeSosTransport()
  ..selfName = name
  ..selfPublicKey = Uint8List.fromList(List.filled(32, seed))
  ..allChannels = [Channel(index: 0, name: 'Public', psk: Uint8List(16))];

void main() {
  late DateTime now;
  late AppSettingsService settings;

  setUp(() async {
    now = DateTime(2026, 10, 27, 9);
    // The phones share one settings store in tests, so each keeps its own
    // AppSettingsService below and joins its network after the last one.
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    settings = AppSettingsService();
    await settings.loadSettings();
  });

  /// Delivers [sent] to [to] as its radio would hear them.
  void deliver(
    List<(int, Uint8List, bool)> sent,
    Phone to, {
    SosSignal signal = SosSignal.unknown,
  }) {
    for (final (_, bytes, _) in sent) {
      to.transport.dataListener!(to.channel, bytes, signal);
    }
  }

  test('a member\'s SOS is sealed: responders read it, and only they can '
      'acknowledge it', () async {
    // The coordinator sets up an SOS2 network
    final coordSettings = AppSettingsService();
    await coordSettings.loadSettings();
    final coordinator = Phone(radio('Rosie', 0x77), coordSettings, () => now);
    final net = await coordinator.service.createNetwork('Farm');
    expect(net.isSealed, isTrue);
    expect(coordinator.service.isResponder, isTrue);

    // A worker joins with the member code, which holds no network secret
    final memberCode = SosNetworkCode.parse(
      net.withRole(SosNetworkRole.member).qrData,
    )!;
    expect(memberCode.networkSecret, isNull);
    final memberSettings = AppSettingsService();
    await memberSettings.loadSettings();
    final worker = Phone(radio('Alex', 0x3f), memberSettings, () => now);
    await worker.service.joinNetwork(memberCode);
    expect(worker.service.sosChannel, isNotNull);
    // Both radios use the same channel key
    expect(worker.service.sosChannel!.psk, coordinator.service.sosChannel!.psk);

    // The worker sends an SOS
    worker.location.fix = const SosFix(
      latitude: -30.98412,
      longitude: 151.5933,
      source: SosLocationSource.phoneGps,
    );
    await worker.service.activate();
    final sent = worker.takeSent();
    expect(sent, hasLength(1));
    final wire = sent.single.$2;
    expect(wire[0], SosSeal.version);
    // Nothing readable on the air: not the name, not an SOS1 packet
    expect(SosPacket.decode(wire), isNull);
    expect(String.fromCharCodes(wire).contains('Alex'), isFalse);

    // The coordinator (a responder) reads it
    deliver(sent, coordinator);
    final alert = coordinator.service.incoming.single;
    expect(alert.senderName, 'Alex');
    expect(alert.fix.latitude, closeTo(-30.98412, 1e-6));
    expect(alert.sessionRef, isNotNull);
    expect(coordinator.alerter.events, contains('alert:${alert.key}'));

    // Another member hears it too, and gets nothing
    final otherSettings = AppSettingsService();
    await otherSettings.loadSettings();
    final other = Phone(radio('Sam', 0x51), otherSettings, () => now);
    await other.service.joinNetwork(memberCode);
    deliver(sent, other);
    expect(other.service.incoming, isEmpty);

    // A forged SOS1 ACK, made with the channel key every member has, is
    // ignored on an SOS2 network
    final forged = SosPacket(
      kind: SosPacketKind.ack,
      id: worker.service.active!.id,
      senderPrefix: Uint8List.fromList(List.filled(6, 0x51)),
      senderName: 'Fake responder',
    ).encode();
    worker.transport.dataListener!(worker.channel, forged, SosSignal.unknown);
    expect(worker.service.active!.acks, isEmpty);

    // The coordinator acknowledges; the worker reads the sealed ACK
    await coordinator.service.acknowledge(alert);
    final ack = coordinator.takeSent();
    expect(ack, hasLength(1));
    expect(SosPacket.decode(ack.single.$2), isNull);
    deliver(ack, worker);
    expect(worker.service.active!.acks.single.senderName, 'Rosie');

    // A tampered copy of the ACK is rejected
    final tampered = Uint8List.fromList(ack.single.$2)..[12] ^= 0x40;
    worker.service.active!.acks.clear();
    worker.transport.dataListener!(worker.channel, tampered, SosSignal.unknown);
    expect(worker.service.active!.acks, isEmpty);
    deliver(ack, worker);
    expect(worker.service.active!.acks, hasLength(1));

    // Its own SOS heard back from a repeater counts as a heard repeat
    worker.transport.repeatListener!(worker.channel, wire, 'c3');
    expect(worker.service.active!.heardRepeats, 1);

    // Locate: the responder asks, the worker's phone beacons zero hop
    coordinator.service.startLocating(alert);
    await Future<void>.delayed(Duration.zero);
    final locate = coordinator.takeSent();
    expect(locate, hasLength(1));
    deliver(locate, worker);
    await Future<void>.delayed(Duration.zero);
    final beacons = worker.takeSent().where((p) => p.$3).toList();
    expect(beacons, isNotEmpty);
    deliver(
      beacons,
      coordinator,
      signal: const SosSignal(snrDb: 9.5, direct: true),
    );
    expect(coordinator.service.locator!.samples, isNotEmpty);
    coordinator.service.stopLocating();

    // The worker cancels; the coordinator's alert ends
    await worker.service.cancel();
    final cancel = worker.takeSent();
    expect(cancel, isNotEmpty);
    deliver(cancel, coordinator);
    expect(coordinator.service.incoming, isEmpty);
    expect(coordinator.alerter.events, contains('cancelled:${alert.key}'));

    // A late ACK after the cancel (a responder who missed it, checking
    // back) is still read, and answered with the cancel, directly since
    // the responder is now a contact
    now = now.add(const Duration(minutes: 12));
    worker.transport.directSends.clear();
    deliver(ack, worker);
    await Future<void>.delayed(Duration.zero);
    expect(worker.transport.directSends.single.$1, 'Rosie');
    expect(
      SosCodec.parseCancel(worker.transport.directSends.single.$2),
      isNotNull,
    );

    worker.service.dispose();
    coordinator.service.dispose();
    other.service.dispose();
  });

  test('the key book is saved and read back, and forgets old keys', () {
    final net = SosNetworkCode.generateSealed();
    final book = SosSessionBook()
      ..add(
        SosSessionEntry(
          id: 'a1b2',
          session: SosSeal.newSession(net.networkPublicKey!),
          own: true,
          networkHex: 'aa',
          lastUsed: now,
        ),
      )
      ..add(
        SosSessionEntry(
          id: 'c3d4',
          session: SosSeal.newSession(net.networkPublicKey!),
          own: false,
          networkHex: 'aa',
          lastUsed: now.subtract(const Duration(hours: 25)),
        ),
      );
    final back = SosSessionBook()..load(book.toJson());
    expect(back.own('a1b2', 'aa')!.session.ephSecret, isNotNull);
    expect(back.entries, hasLength(2));
    back.prune(now);
    expect(back.entries.single.id, 'a1b2');
    // Our own live SOS's keys are kept however long it lasts
    back.prune(now.add(const Duration(days: 3)), activeId: 'a1b2');
    expect(back.entries, hasLength(1));
  });

  test('an SOS1 network keeps working, with SOS1 packets', () async {
    final key = SosNetworkCode.generateKey();
    await settings.joinSosNetwork(
      SosNetworkCode(role: SosNetworkRole.responder, key: key, name: 'Old'),
    );
    final phone = Phone(radio('Old phone', 0x11), settings, () => now);
    phone.transport.allChannels = [
      ...phone.transport.allChannels,
      Channel(index: 1, name: 'Old', psk: key),
    ];
    expect(phone.service.network!.isSealed, isFalse);
    await phone.service.activate();
    final sent = phone.takeSent();
    expect(SosPacket.decode(sent.single.$2)!.kind, SosPacketKind.sos);
    phone.service.dispose();
  });
}
