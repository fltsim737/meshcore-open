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

  void Function(SosInboundText inbound)? listener;
  final List<(int, String)> channelSends = [];
  final List<(String, String)> directSends = [];

  @override
  set sosTextListener(void Function(SosInboundText inbound)? value) =>
      listener = value;

  @override
  Future<void> sendChannelText(Channel channel, String text) async =>
      channelSends.add((channel.index, text));

  @override
  Future<void> sendDirectText(Contact contact, String text) async =>
      directSends.add((contact.name, text));

  final Set<String> delivered = {};
  final Set<String> pending = {};

  @override
  bool hasDeliveredSos(Contact contact, String sosId) =>
      delivered.contains(contact.name);

  @override
  bool hasPendingSos(Contact contact, String sosId) =>
      pending.contains(contact.name);

  void markDelivered(String name) {
    delivered.add(name);
    notifyListeners();
  }

  void setConnected(bool value) {
    isConnected = value;
    notifyListeners();
  }
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

String sosText(String id, {double? lat, double? lon}) => SosCodec.encodeSos(
  id: id,
  time: DateTime.utc(2026, 10, 21),
  fix: lat == null
      ? const SosFix.none()
      : SosFix(
          latitude: lat,
          longitude: lon,
          source: SosLocationSource.phoneGps,
        ),
);

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
  late DateTime now;

  late FakePhoneLocation phone;

  SosService newService() => SosService(
    transport: transport,
    settings: settings,
    phoneLocation: phone,
    now: () => now,
  );

  setUp(() async {
    now = DateTime(2026, 10, 21, 9);
    settings = await freshSettings();
    transport = FakeSosTransport();
    phone = FakePhoneLocation();
    service = newService();
  });

  tearDown(() => service.dispose());

  test('registers as the connector text listener', () {
    expect(transport.listener, isNotNull);
  });

  group('location priority', () {
    test('uses phone GPS first', () async {
      phone.fix = const SosFix(
        latitude: -42,
        longitude: 173,
        source: SosLocationSource.phoneGps,
      );
      transport
        ..selfLatitude = -41.1
        ..selfLongitude = 174.2;
      expect((await service.resolveFix()).source, SosLocationSource.phoneGps);
      phone.fix = null;
      expect((await service.resolveFix()).source, SosLocationSource.radio);
    });

    test('uses the radio position before the stored location', () async {
      transport
        ..selfLatitude = -41.1
        ..selfLongitude = 174.2;
      await settings.setSosLocation(-40, 175);
      final fix = await service.resolveFix();
      expect(fix.source, SosLocationSource.radio);
      expect(fix.latitude, -41.1);
    });

    test('treats a 0,0 radio position as absent', () async {
      transport
        ..selfLatitude = 0
        ..selfLongitude = 0;
      await settings.setSosLocation(-40, 175);
      expect((await service.resolveFix()).source, SosLocationSource.stored);
    });

    test('falls back to no location', () async {
      expect((await service.resolveFix()).hasPosition, isFalse);
    });
  });

  group('sending', () {
    test('broadcasts on the SOS channel and DMs emergency contacts', () async {
      final alice = contactFor('Alice', 1);
      final bob = contactFor('Bob', 2, favourite: true);
      final carol = contactFor('Carol', 3);
      transport.contacts = [alice, bob, carol];
      await settings.setSosChannelIndex(2);
      await settings.setSosContact(alice.publicKeyHex, true);

      await service.activate();

      expect(service.isActive, isTrue);
      expect(transport.channelSends.single.$1, 2);
      final sent = SosCodec.parseSos(transport.channelSends.single.$2)!;
      expect(sent.id, service.active!.id);
      expect(sent.node, isNull);
      expect(transport.directSends.map((s) => s.$1), ['Alice', 'Bob']);
      expect(
        SosCodec.parseSos(transport.directSends.first.$2)!.node,
        'Farmhouse',
      );
    });

    test('falls back to the first channel when the slot is gone', () async {
      await settings.setSosChannelIndex(7);
      await service.activate();
      expect(transport.channelSends.single.$1, 0);
    });

    test('counts an ACK once per responder across channel and DM', () async {
      final bob = contactFor('Bob', 2);
      transport.contacts = [bob];
      await service.activate();
      final ack = 'ACK #${service.active!.id}';
      service.handleInbound(
        SosInboundText(text: ack, senderName: 'Bob', channelIndex: 0),
      );
      service.handleInbound(
        SosInboundText(text: ack, senderName: 'Bob', channelIndex: 0),
      );
      service.handleInbound(
        SosInboundText(
          text: ack,
          senderName: 'Bob',
          senderKeyHex: bob.publicKeyHex,
        ),
      );
      service.handleInbound(
        const SosInboundText(text: 'ACK #zzzz', senderName: 'Other'),
      );
      expect(service.active!.acks, hasLength(1));
      expect(service.active!.acks.single.senderKeyHex, bob.publicKeyHex);
    });

    test('cancel clears the active SOS and its saved state', () async {
      await service.activate();
      await service.cancel();
      expect(service.isActive, isFalse);
      final reloaded = newService()..load();
      expect(reloaded.isActive, isFalse);
      reloaded.dispose();
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
    test(
      'repeats every 5 minutes, then every 15 after the first ACK',
      () async {
        await service.activate();
        expect(transport.channelSends, hasLength(1));

        now = now.add(const Duration(minutes: 4, seconds: 59));
        await service.broadcastIfDue();
        expect(transport.channelSends, hasLength(1));

        now = now.add(const Duration(seconds: 1));
        await service.broadcastIfDue();
        expect(transport.channelSends, hasLength(2));
        expect(service.active!.broadcastCount, 2);

        service.handleInbound(
          SosInboundText(text: 'ACK #${service.active!.id}', senderName: 'N'),
        );
        expect(
          service.nextBroadcastAt,
          now.add(SosService.acknowledgedRepeatInterval),
        );
        now = now.add(const Duration(minutes: 14));
        await service.broadcastIfDue();
        expect(transport.channelSends, hasLength(2));
        now = now.add(const Duration(minutes: 1));
        await service.broadcastIfDue();
        expect(transport.channelSends, hasLength(3));
        expect(service.isActive, isTrue);
      },
    );

    test('a due broadcast waits for the radio', () async {
      transport.setConnected(false);
      await service.activate();
      expect(transport.channelSends, isEmpty);
      expect(service.active!.lastBroadcastAt, isNull);
      transport.isConnected = true;
      await service.broadcastIfDue();
      expect(transport.channelSends, hasLength(1));
    });

    test('a cancelled SOS stops repeating', () async {
      await service.activate();
      await service.cancel();
      now = now.add(const Duration(hours: 1));
      await service.broadcastIfDue();
      expect(transport.channelSends, hasLength(1));
      expect(service.nextBroadcastAt, isNull);
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

      transport.markDelivered('Alice');
      expect(service.active!.deliveredContactKeys, {alice.publicKeyHex});
      // A channel ACK carries only the name.
      service.handleInbound(
        SosInboundText(
          text: 'ACK #${service.active!.id}',
          senderName: 'Bob',
          channelIndex: 0,
        ),
      );

      transport.directSends.clear();
      now = now.add(SosService.acknowledgedRepeatInterval);
      await service.broadcastIfDue();
      expect(transport.directSends.map((s) => s.$1), ['Carol']);
      expect(transport.channelSends, hasLength(2));
    });

    test('does not queue a DM while the last one is retrying', () async {
      await service.activate();
      transport.pending.addAll(['Alice', 'Bob', 'Carol']);
      transport.directSends.clear();
      now = now.add(SosService.repeatInterval);
      await service.broadcastIfDue();
      expect(transport.directSends, isEmpty);
      expect(transport.channelSends, hasLength(2));
    });
  });

  group('receiving', () {
    test('merges repeats of the same alert and keeps the latest fix', () {
      service.handleInbound(
        SosInboundText(
          text: sosText('a1b2', lat: -41, lon: 174),
          senderName: 'Ridge',
          channelIndex: 0,
        ),
      );
      service.handleInbound(
        SosInboundText(
          text: sosText('a1b2', lat: -41.5, lon: 174.5),
          senderName: 'Ridge',
          channelIndex: 0,
        ),
      );
      service.handleInbound(
        SosInboundText(text: sosText('a1b2'), senderName: 'Ridge'),
      );
      final alert = service.incoming.single;
      expect(alert.receivedCount, 3);
      expect(alert.fix.latitude, -41.5);
      expect(service.openIncoming, hasLength(1));
    });

    test('acknowledging replies on the channel and by DM', () async {
      final ridge = contactFor('Ridge', 9);
      transport.contacts = [ridge];
      service.handleInbound(
        SosInboundText(
          text: sosText('a1b2'),
          senderName: 'Ridge',
          channelIndex: 2,
        ),
      );
      service.handleInbound(
        SosInboundText(
          text: sosText('a1b2'),
          senderName: 'Ridge',
          senderKeyHex: ridge.publicKeyHex,
        ),
      );
      final alert = service.incoming.single;
      await service.acknowledge(alert);
      expect(alert.ackSent, isTrue);
      expect(service.openIncoming, isEmpty);
      expect(transport.channelSends, [(2, 'ACK #a1b2')]);
      expect(transport.directSends, [('Ridge', 'ACK #a1b2')]);
    });

    test('acknowledging while disconnected leaves the alert open', () async {
      service.handleInbound(
        SosInboundText(
          text: sosText('a1b2'),
          senderName: 'Ridge',
          channelIndex: 0,
        ),
      );
      transport.setConnected(false);
      expect(service.isConnected, isFalse);
      await service.acknowledge(service.incoming.single);
      expect(service.incoming.single.isOpen, isTrue);
      expect(transport.channelSends, isEmpty);
    });

    test('notes other responders and survives a restart', () async {
      service.handleInbound(
        SosInboundText(text: sosText('a1b2'), senderName: 'Ridge'),
      );
      service.handleInbound(
        const SosInboundText(text: 'ACK #a1b2', senderName: 'Valley'),
      );
      await service.dismiss(service.incoming.single);
      final reloaded = newService()..load();
      final alert = reloaded.incoming.single;
      expect(alert.ackedBy, {'Valley'});
      expect(alert.dismissed, isTrue);
      reloaded.dispose();
    });

    test('keeps open alerts when trimming history', () async {
      service.handleInbound(
        SosInboundText(text: sosText('0000'), senderName: 'First'),
      );
      for (var i = 1; i <= 60; i++) {
        final id = i.toRadixString(16).padLeft(4, '0');
        service.handleInbound(
          SosInboundText(text: sosText(id), senderName: 'N$i'),
        );
        await service.dismiss(service.incoming.first);
      }
      expect(service.incoming.length, lessThanOrEqualTo(51));
      expect(service.incoming.any((a) => a.senderName == 'First'), isTrue);
    });
  });
}
