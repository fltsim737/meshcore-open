import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/helpers/sos_codec.dart';
import 'package:meshcore_open/models/channel.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/models/sos_alert.dart';
import 'package:meshcore_open/services/app_settings_service.dart';
import 'package:meshcore_open/services/sos_location_service.dart';
import 'package:meshcore_open/services/sos_service.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeSosTransport extends ChangeNotifier implements SosTransport {
  @override
  bool isConnected = true;
  @override
  String? selfName = 'Farmhouse';
  @override
  Uint8List? selfPublicKey = Uint8List.fromList(List.filled(32, 0xAA));
  @override
  double? selfLatitude;
  @override
  double? selfLongitude;
  @override
  List<Channel> channels = [
    Channel(index: 0, name: 'Public', psk: Uint8List(16)),
    Channel(index: 2, name: 'Farm', psk: Uint8List(16)),
  ];
  @override
  List<Contact> contacts = [];
  @override
  bool supportsChannelData = true;

  void Function(SosInboundText inbound)? textListener;
  void Function(int channelIndex, Uint8List payload)? dataListener;
  void Function(int ackHash)? ackListener;

  /// (channel index, decoded packet) for every channel send.
  final List<(int, SosPacket)> channelPackets = [];

  /// (recipient name, text) for every direct send.
  final List<(String, String)> directSends = [];
  final Map<String, int> _lastHashFor = {};
  int _nextHash = 1;

  @override
  set sosTextListener(void Function(SosInboundText inbound)? value) =>
      textListener = value;
  @override
  set sosDataListener(void Function(int, Uint8List)? value) =>
      dataListener = value;
  @override
  set sosAckListener(void Function(int ackHash)? value) => ackListener = value;

  @override
  Future<void> sendChannelData(Channel channel, Uint8List payload) async =>
      channelPackets.add((channel.index, SosPacket.decode(payload)!));

  @override
  Future<int?> sendDirectText(Contact contact, String text) async {
    directSends.add((contact.name, text));
    final hash = _nextHash++;
    _lastHashFor[contact.name] = hash;
    return hash;
  }

  /// The recipient's radio confirms the last DM sent to [name].
  void confirmDelivery(String name) => ackListener?.call(_lastHashFor[name]!);

  void setConnected(bool value) {
    isConnected = value;
    notifyListeners();
  }
}

class FakeAlerter implements SosAlerter {
  final List<String> events = [];

  @override
  void alert(IncomingSos alert) => events.add('alert:${alert.key}');
  @override
  void clear(IncomingSos alert) => events.add('clear:${alert.key}');
  @override
  void acknowledged(OutgoingSos sos, SosAck ack) =>
      events.add('ack:${ack.senderName}');
  @override
  void cancelled(IncomingSos alert) => events.add('cancelled:${alert.key}');
}

class FakePhoneLocation implements PhoneLocationProvider {
  SosFix? fix;

  @override
  Future<SosFix?> currentFix({Duration? timeout}) async => fix;

  @override
  Future<bool> requestPermission() async => true;
}

Contact contactFor(String name, int seed, {bool favourite = false}) => Contact(
  publicKey: Uint8List.fromList(List.filled(32, seed)),
  name: name,
  type: advTypeChat,
  flags: favourite ? contactFlagFavorite : 0,
  pathLength: -1,
  path: Uint8List(0),
  lastSeen: DateTime(2026),
);

/// A channel SOS packet from [name], whose key starts with byte [seed].
Uint8List sosPacketFrom(
  String name,
  int seed,
  String id, {
  SosPacketKind kind = SosPacketKind.sos,
  double? lat,
  double? lon,
}) => SosPacket(
  kind: kind,
  id: id,
  senderPrefix: Uint8List.fromList(List.filled(6, seed)),
  senderName: name,
  time: DateTime.utc(2026, 10, 21),
  fix: lat == null
      ? const SosFix.none()
      : SosFix(
          latitude: lat,
          longitude: lon,
          source: SosLocationSource.phoneGps,
        ),
).encode();

Future<AppSettingsService> freshSettings() async {
  SharedPreferences.setMockInitialValues({});
  PrefsManager.reset();
  await PrefsManager.initialize();
  final settings = AppSettingsService();
  await settings.loadSettings();
  return settings;
}

void main() {
  late FakeSosTransport transport;
  late AppSettingsService settings;
  late SosService service;
  late FakePhoneLocation phone;
  late FakeAlerter alerter;
  late DateTime now;

  SosService newService() => SosService(
    transport: transport,
    settings: settings,
    phoneLocation: phone,
    alerter: alerter,
    now: () => now,
  );

  void hear(Uint8List packet, {int channel = 0}) =>
      transport.dataListener!(channel, packet);

  setUp(() async {
    now = DateTime(2026, 10, 21, 9);
    settings = await freshSettings();
    transport = FakeSosTransport();
    phone = FakePhoneLocation();
    alerter = FakeAlerter();
    service = newService();
  });

  tearDown(() => service.dispose());

  test('registers all connector listeners', () {
    expect(transport.textListener, isNotNull);
    expect(transport.dataListener, isNotNull);
    expect(transport.ackListener, isNotNull);
  });

  test('location priority: phone, radio, stored, none', () async {
    phone.fix = const SosFix(
      latitude: -42,
      longitude: 173,
      source: SosLocationSource.phoneGps,
    );
    transport
      ..selfLatitude = -41.1
      ..selfLongitude = 174.2;
    await settings.setSosLocation(-40, 175);
    expect((await service.resolveFix()).source, SosLocationSource.phoneGps);
    phone.fix = null;
    expect((await service.resolveFix()).source, SosLocationSource.radio);
    transport
      ..selfLatitude = 0
      ..selfLongitude = 0;
    expect((await service.resolveFix()).source, SosLocationSource.stored);
    await settings.setSosLocation(null, null);
    expect((await service.resolveFix()).hasPosition, isFalse);
  });

  group('sending', () {
    test('sends a data packet on the channel and DMs contacts', () async {
      final alice = contactFor('Alice', 1);
      final bob = contactFor('Bob', 2, favourite: true);
      transport.contacts = [alice, bob, contactFor('Carol', 3)];
      await settings.setSosChannelIndex(2);
      await settings.setSosContact(alice.publicKeyHex, true);
      phone.fix = const SosFix(
        latitude: -41.28646,
        longitude: 174.77624,
        source: SosLocationSource.phoneGps,
      );

      await service.activate();

      final (channelIndex, packet) = transport.channelPackets.single;
      expect(channelIndex, 2);
      expect(packet.kind, SosPacketKind.sos);
      expect(packet.id, service.active!.id);
      expect(packet.senderName, 'Farmhouse');
      expect(packet.fix.latitude, closeTo(-41.28646, 1e-6));
      expect(transport.directSends.map((s) => s.$1), ['Alice', 'Bob']);
      expect(
        SosCodec.parseSos(transport.directSends.first.$2)!.node,
        'Farmhouse',
      );
    });

    test('sends DMs only when the radio cannot send channel data', () async {
      final alice = contactFor('Alice', 1);
      transport
        ..contacts = [alice]
        ..supportsChannelData = false;
      await settings.setSosContact(alice.publicKeyHex, true);
      await service.activate();
      expect(transport.channelPackets, isEmpty);
      expect(transport.directSends, hasLength(1));
    });

    test('falls back to the first channel when the slot is gone', () async {
      await settings.setSosChannelIndex(7);
      await service.activate();
      expect(transport.channelPackets.single.$1, 0);
    });

    test('counts an ACK once per responder across channel and DM', () async {
      final bob = contactFor('Bob', 2);
      transport.contacts = [bob];
      await service.activate();
      final id = service.active!.id;
      hear(sosPacketFrom('Bob', 2, id, kind: SosPacketKind.ack));
      hear(sosPacketFrom('Bob', 2, id, kind: SosPacketKind.ack));
      service.handleInbound(
        SosInboundText(
          text: 'ACK #$id',
          senderName: 'Bob',
          senderKeyHex: bob.publicKeyHex,
        ),
      );
      service.handleInbound(
        const SosInboundText(text: 'ACK #ffff', senderName: 'Other'),
      );
      expect(service.active!.acks, hasLength(1));
      expect(service.active!.acks.single.senderKeyHex, bob.publicKeyHex);
      expect(alerter.events, ['ack:Bob']);
    });

    test('an active SOS survives a restart', () async {
      await service.activate();
      final id = service.active!.id;
      final reloaded = newService()..load();
      expect(reloaded.active?.id, id);
      reloaded.dispose();
    });
  });

  group('schedule', () {
    test('repeats every minute for 5 minutes, then every 5 minutes', () async {
      final start = now;
      await service.activate();
      final sentAt = <Duration>[Duration.zero];
      for (var t = 0; t < 3600; t += 5) {
        now = start.add(Duration(seconds: t));
        final before = transport.channelPackets.length;
        await service.broadcastIfDue();
        if (transport.channelPackets.length > before) {
          sentAt.add(now.difference(start));
        }
      }
      expect(sentAt.map((d) => d.inMinutes), [
        0, 1, 2, 3, 4, 5, // every minute for the first 5 minutes
        10, 15, 20, 25, 30, 35, 40, 45, 50, 55,
      ]);
    });

    test('an ACK does not slow the schedule', () async {
      final start = now;
      await service.activate();
      hear(sosPacketFrom('N', 9, service.active!.id, kind: SosPacketKind.ack));
      expect(service.nextBroadcastAt, start.add(SosService.burstInterval));
    });

    test('a due broadcast waits for the radio, then catches up', () async {
      transport.setConnected(false);
      await service.activate();
      expect(transport.channelPackets, isEmpty);
      transport.setConnected(true);
      await pumpEventQueue();
      expect(transport.channelPackets, hasLength(1));
    });

    test('catches up when the app returns to the foreground', () async {
      await service.activate();
      now = now.add(SosService.burstInterval);
      service.onAppResumed();
      await pumpEventQueue();
      expect(transport.channelPackets, hasLength(2));
    });
  });

  group('DM fan-out', () {
    late Contact alice, bob, carol;

    setUp(() async {
      alice = contactFor('Alice', 1);
      bob = contactFor('Bob', 2);
      carol = contactFor('Carol', 3);
      transport.contacts = [alice, bob, carol];
      for (final c in transport.contacts) {
        await settings.setSosContact(c.publicKeyHex, true);
      }
    });

    test('stops DMs to contacts that confirmed delivery or ACKed', () async {
      await service.activate();
      expect(transport.directSends.map((s) => s.$1), ['Alice', 'Bob', 'Carol']);

      transport.confirmDelivery('Alice');
      expect(service.active!.deliveredContactKeys, {alice.publicKeyHex});
      // A channel ACK identifies Bob by his key prefix.
      hear(
        sosPacketFrom('Bob', 2, service.active!.id, kind: SosPacketKind.ack),
      );

      transport.directSends.clear();
      now = now.add(SosService.burstInterval);
      await service.broadcastIfDue();
      expect(transport.directSends.map((s) => s.$1), ['Carol']);
    });

    test('ignores delivery confirmations it did not ask for', () async {
      await service.activate();
      service.handleDeliveryAck(999);
      expect(service.active!.deliveredContactKeys, isEmpty);
    });
  });

  group('cancel', () {
    late Contact alice, bob;

    setUp(() async {
      alice = contactFor('Alice', 1);
      bob = contactFor('Bob', 2);
      transport.contacts = [alice, bob];
      await settings.setSosContact(alice.publicKeyHex, true);
      await settings.setSosContact(bob.publicKeyHex, true);
    });

    test('stops at once and notifies everyone, ACKed or not', () async {
      await service.activate();
      final id = service.active!.id;
      transport.confirmDelivery('Bob');
      transport.channelPackets.clear();
      transport.directSends.clear();

      await service.cancel();

      expect(service.isActive, isFalse);
      final (_, packet) = transport.channelPackets.single;
      expect(packet.kind, SosPacketKind.cancel);
      expect(packet.id, id);
      expect(transport.directSends.map((s) => s.$1), ['Alice', 'Bob']);
      expect(
        transport.directSends.every((s) => SosCodec.parseCancel(s.$2) == id),
        isTrue,
      );
      now = now.add(const Duration(hours: 1));
      await service.broadcastIfDue();
      expect(transport.channelPackets, hasLength(1));
    });

    test('a cancel while disconnected is sent on reconnect', () async {
      await service.activate();
      final id = service.active!.id;
      transport.setConnected(false);
      transport.channelPackets.clear();
      await service.cancel();
      expect(transport.channelPackets, isEmpty);
      final reloaded = newService()..load();
      expect(reloaded.pendingCancelId, id);
      reloaded.dispose();

      transport.setConnected(true);
      await pumpEventQueue();
      expect(transport.channelPackets.single.$2.kind, SosPacketKind.cancel);
      expect(service.pendingCancelId, isNull);
    });
  });

  group('receiving', () {
    test('a channel packet raises an alert linked to the contact', () {
      final ridge = contactFor('Ridge', 9);
      transport.contacts = [ridge];
      hear(sosPacketFrom('Ridge', 9, 'a1b2', lat: -41, lon: 174), channel: 2);
      final alert = service.incoming.single;
      expect(alert.senderName, 'Ridge');
      expect(alert.senderKeyHex, ridge.publicKeyHex);
      expect(alert.channelIndex, 2);
      expect(alert.fix.latitude, closeTo(-41, 1e-6));
      expect(alerter.events, ['alert:Ridge#a1b2']);
    });

    test('ignores our own packets heard back from the mesh', () {
      hear(sosPacketFrom('Farmhouse', 0xAA, 'a1b2'));
      expect(service.incoming, isEmpty);
    });

    test('merges repeats from channel and DM into one alert', () {
      final ridge = contactFor('Ridge', 9);
      transport.contacts = [ridge];
      hear(sosPacketFrom('Ridge', 9, 'a1b2', lat: -41, lon: 174));
      hear(sosPacketFrom('Ridge', 9, 'a1b2', lat: -41.5, lon: 174.5));
      service.handleInbound(
        SosInboundText(
          text: SosCodec.encodeSos(
            id: 'a1b2',
            time: now,
            fix: const SosFix.none(),
          ),
          senderName: 'Ridge',
          senderKeyHex: ridge.publicKeyHex,
        ),
      );
      final alert = service.incoming.single;
      expect(alert.receivedCount, 3);
      expect(alert.fix.latitude, closeTo(-41.5, 1e-6));
    });

    test('ACK replies by packet and DM and keeps the position', () async {
      final ridge = contactFor('Ridge', 9);
      transport.contacts = [ridge];
      hear(sosPacketFrom('Ridge', 9, 'a1b2', lat: -41, lon: 174), channel: 2);
      final alert = service.incoming.single;
      await service.acknowledge(alert);
      expect(alert.ackSent, isTrue);
      expect(service.openIncoming, isEmpty);
      expect(service.incoming.single.fix.hasPosition, isTrue);
      final (channelIndex, packet) = transport.channelPackets.single;
      expect(channelIndex, 2);
      expect(packet.kind, SosPacketKind.ack);
      expect(packet.id, 'a1b2');
      expect(transport.directSends, [('Ridge', 'ACK #a1b2')]);
    });

    test('acknowledging while disconnected leaves the alert open', () async {
      hear(sosPacketFrom('Ridge', 9, 'a1b2'));
      transport.setConnected(false);
      await service.acknowledge(service.incoming.single);
      expect(service.openIncoming, hasLength(1));
      expect(transport.channelPackets, isEmpty);
    });

    test('a cancel from the sender deletes the alert; others cannot', () {
      hear(sosPacketFrom('Ridge', 9, 'a1b2', lat: -41, lon: 174));
      hear(sosPacketFrom('Mallory', 7, 'a1b2', kind: SosPacketKind.cancel));
      expect(service.incoming, hasLength(1));
      hear(sosPacketFrom('Ridge', 9, 'a1b2', kind: SosPacketKind.cancel));
      expect(service.incoming, isEmpty);
      expect(alerter.events, [
        'alert:Ridge#a1b2',
        'clear:Ridge#a1b2',
        'cancelled:Ridge#a1b2',
      ]);
    });

    test('dismiss deletes the alert and its position', () async {
      hear(sosPacketFrom('Ridge', 9, 'a1b2', lat: -41, lon: 174));
      await service.dismiss(service.incoming.single);
      expect(service.incoming, isEmpty);
      final reloaded = newService()..load();
      expect(reloaded.incoming, isEmpty);
      reloaded.dispose();
    });

    test('an alert not heard for 60 minutes is deleted', () async {
      hear(sosPacketFrom('Ridge', 9, 'a1b2', lat: -41, lon: 174));
      await service.acknowledge(service.incoming.single);
      now = now.add(const Duration(minutes: 59));
      service.purgeExpired();
      expect(service.incoming, hasLength(1));
      // A repeat keeps it alive.
      hear(sosPacketFrom('Ridge', 9, 'a1b2', lat: -41, lon: 174));
      now = now.add(const Duration(minutes: 59));
      service.purgeExpired();
      expect(service.incoming, hasLength(1));
      now = now.add(const Duration(minutes: 2));
      service.purgeExpired();
      expect(service.incoming, isEmpty);
    });

    test('expired alerts are gone after a restart', () async {
      hear(sosPacketFrom('Ridge', 9, 'a1b2'));
      now = now.add(const Duration(hours: 2));
      final reloaded = newService()..load();
      expect(reloaded.incoming, isEmpty);
      reloaded.dispose();
    });

    test('sounds for every repeat until acknowledged', () async {
      hear(sosPacketFrom('Ridge', 9, 'a1b2'));
      hear(sosPacketFrom('Ridge', 9, 'a1b2'));
      await service.acknowledge(service.incoming.single);
      hear(sosPacketFrom('Ridge', 9, 'a1b2'));
      expect(alerter.events, [
        'alert:Ridge#a1b2',
        'alert:Ridge#a1b2',
        'clear:Ridge#a1b2',
      ]);
    });

    test('notes other responders', () {
      hear(sosPacketFrom('Ridge', 9, 'a1b2'));
      hear(sosPacketFrom('Valley', 5, 'a1b2', kind: SosPacketKind.ack));
      expect(service.incoming.single.ackedBy, {'Valley'});
    });
  });
}
