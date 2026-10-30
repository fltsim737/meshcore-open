import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/helpers/sos_codec.dart';
import 'package:meshcore_open/helpers/sos_network_code.dart';
import 'package:meshcore_open/models/channel.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/models/sos_alert.dart';
import 'package:meshcore_open/models/sos_history.dart';
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
  SosRadio? selfRadio = narrowRadio;

  /// Every retune asked of the radio, with the channel packets sent before it.
  final List<(SosRadio, int)> radioChanges = [];
  bool refuseRadio = false;
  @override
  Future<bool> setRadio(SosRadio radio) async {
    if (refuseRadio) return false;
    radioChanges.add((radio, channelPackets.length));
    selfRadio = radio;
    return true;
  }

  @override
  List<Channel> allChannels = [
    Channel(index: 0, name: 'Public', psk: Uint8List(16)),
    Channel(index: 2, name: 'Farm', psk: farmKey),
  ];
  @override
  List<Contact> contacts = [];
  @override
  bool supportsChannelData = true;
  @override
  int maxChannels = 4;
  @override
  bool channelsReady = true;
  @override
  Uint8List? hiddenChannelPsk;

  final List<(int, String)> installed = [];
  final List<int> deleted = [];

  @override
  Future<void> setChannel(int index, String name, Uint8List psk) async {
    installed.add((index, name));
    allChannels = [...allChannels, Channel(index: index, name: name, psk: psk)];
    notifyListeners();
  }

  @override
  Future<void> deleteChannel(int index) async {
    deleted.add(index);
    allChannels = allChannels.where((c) => c.index != index).toList();
    notifyListeners();
  }

  void Function(SosInboundText inbound)? textListener;
  void Function(int channelIndex, Uint8List payload, SosSignal signal)?
  dataListener;
  void Function(int ackHash)? ackListener;
  void Function(int channelIndex, Uint8List payload, String lastHopHex)?
  repeatListener;

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
  set sosDataListener(void Function(int, Uint8List, SosSignal)? value) =>
      dataListener = value;
  @override
  set sosAckListener(void Function(int ackHash)? value) => ackListener = value;
  @override
  set sosRepeatListener(
    void Function(int channelIndex, Uint8List payload, String lastHopHex)?
    value,
  ) => repeatListener = value;
  void Function(int channelIndex, Uint8List payload, List<String> pathHex)?
  routeListener;
  @override
  set sosRouteListener(
    void Function(int channelIndex, Uint8List payload, List<String> pathHex)?
    value,
  ) => routeListener = value;

  @override
  Future<void> sendChannelData(
    Channel channel,
    Uint8List payload, {
    bool zeroHop = false,
  }) async {
    rawChannelData.add((channel.index, payload, zeroHop));
    final packet = SosPacket.decode(payload);
    if (packet == null) return; // sealed (SOS2)
    channelPackets.add((channel.index, packet));
    if (zeroHop) zeroHopPackets.add(packet);
  }

  /// Packets sent zero hop (locator beacons).
  final zeroHopPackets = <SosPacket>[];

  /// Every channel send as sent: (channel index, bytes, zero hop).
  final List<(int, Uint8List, bool)> rawChannelData = [];

  @override
  Future<int?> sendDirectText(Contact contact, String text) async {
    directSends.add((contact.name, text));
    final hash = _nextHash++;
    _lastHashFor[contact.name] = hash;
    return hash;
  }

  /// (name, key) for every contact saved.
  final List<(String, Uint8List)> addedContacts = [];

  @override
  Future<Contact?> addContact(Uint8List publicKey, String name) async {
    addedContacts.add((name, publicKey));
    final contact = Contact(
      publicKey: publicKey,
      name: name,
      type: advTypeChat,
      pathLength: -1,
      path: Uint8List(0),
      lastSeen: DateTime(2026),
    );
    contacts = [...contacts, contact];
    return contact;
  }

  /// The recipient's radio confirms the last DM sent to [name].
  void confirmDelivery(String name) => ackListener?.call(_lastHashFor[name]!);

  void setConnected(bool value) {
    isConnected = value;
    notifyListeners();
  }

  List<Channel> _loadedChannels = [];

  /// The radio rereads its channel list, as on every connect: the list is
  /// empty until [finishChannelReload].
  void startChannelReload() {
    _loadedChannels = allChannels;
    allChannels = [];
    channelsReady = false;
    notifyListeners();
  }

  void finishChannelReload() {
    allChannels = _loadedChannels;
    channelsReady = true;
    notifyListeners();
  }
}

/// Key of the "Farm" channel in slot 2, used as the emergency network.
final Uint8List farmKey = Uint8List.fromList(List.filled(16, 7));

SosNetworkCode farmNetwork(SosNetworkRole role) =>
    SosNetworkCode(role: role, key: farmKey, name: 'Farm');

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

const narrowRadio = SosRadio(freqKhz: 916575, bwHz: 62500, sf: 7, cr: 5);
const midRadio = SosRadio(freqKhz: 915075, bwHz: 125000, sf: 9, cr: 5);

/// A channel SOS packet from [name], whose key starts with byte [seed].
Uint8List sosPacketFrom(
  String name,
  int seed,
  String id, {
  SosPacketKind kind = SosPacketKind.sos,
  double? lat,
  double? lon,
  bool withKey = false,
  SosRadio? radio,
  bool back = false,
}) => SosPacket(
  kind: kind,
  id: id,
  senderPrefix: Uint8List.fromList(List.filled(6, seed)),
  senderName: name,
  time: DateTime.utc(2026, 10, 21),
  senderKey: withKey || radio != null
      ? Uint8List.fromList(List.filled(32, seed))
      : null,
  radio: radio,
  back: back,
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
    retuneSendGap: Duration.zero,
  );

  /// A packet on the network channel (slot 2) unless [channel] says not.
  void hear(
    Uint8List packet, {
    int channel = 2,
    SosSignal signal = SosSignal.unknown,
  }) => transport.dataListener!(channel, packet, signal);

  setUp(() async {
    now = DateTime(2026, 10, 21, 9);
    settings = await freshSettings();
    transport = FakeSosTransport();
    phone = FakePhoneLocation();
    alerter = FakeAlerter();
    service = newService();
    await settings.joinSosNetwork(farmNetwork(SosNetworkRole.responder));
  });

  tearDown(() => service.dispose());

  test('registers all connector listeners', () {
    expect(transport.textListener, isNotNull);
    expect(transport.dataListener, isNotNull);
    expect(transport.ackListener, isNotNull);
    expect(transport.repeatListener, isNotNull);
    expect(transport.routeListener, isNotNull);
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

    test('without a network only emergency contacts are alerted', () async {
      final alice = contactFor('Alice', 1);
      transport.contacts = [alice];
      await settings.setSosContact(alice.publicKeyHex, true);
      await settings.leaveSosNetwork();
      await service.activate();
      expect(transport.channelPackets, isEmpty);
      expect(transport.directSends.map((s) => s.$1), ['Alice']);
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

    test('counts heard repeats of our own SOS, by repeater', () async {
      transport.contacts = [
        Contact(
          publicKey: Uint8List.fromList([0x3a, ...List.filled(31, 1)]),
          name: 'Hill repeater',
          type: advTypeRepeater,
          pathLength: -1,
          path: Uint8List(0),
          lastSeen: now,
        ),
      ];
      await service.activate();
      final ours = transport.channelPackets.single.$2.encode();
      transport.repeatListener!(2, ours, '3a');
      transport.repeatListener!(2, ours, '7c');
      transport.repeatListener!(2, ours, '3a');
      // not counted: another channel, someone else's SOS, an ACK
      transport.repeatListener!(5, ours, '3a');
      transport.repeatListener!(2, sosPacketFrom('Bob', 2, 'beef'), '3a');
      transport.repeatListener!(
        2,
        sosPacketFrom('Bob', 2, service.active!.id, kind: SosPacketKind.ack),
        '3a',
      );

      final sos = service.active!;
      expect(sos.heardRepeats, 3);
      expect(sos.repeaters, {'3a': 2, '7c': 1});
      expect(service.repeaterName('3a'), 'Hill repeater');
      expect(service.repeaterName('7c'), '7c');

      final reloaded = newService()..load();
      expect(reloaded.active?.heardRepeats, 3);
      expect(reloaded.active?.repeaters, {'3a': 2, '7c': 1});
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

    test('a cancel waits for the channel list after reconnecting', () async {
      await service.activate();
      transport.setConnected(false);
      transport.channelPackets.clear();
      await service.cancel();

      transport.startChannelReload();
      transport.setConnected(true);
      await pumpEventQueue();
      expect(transport.channelPackets, isEmpty);
      transport.finishChannelReload();
      await pumpEventQueue();
      expect(transport.channelPackets.single.$2.kind, SosPacketKind.cancel);
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

    test('reads a cancel left pending by an older version', () async {
      await PrefsManager.instance.setString('sos_pending_cancel', 'beef');
      final reloaded = newService()..load();
      expect(reloaded.pendingCancelId, 'beef');
      reloaded.dispose();
    });

    test('repeats the cancel, and its DMs until each is delivered', () async {
      await service.activate();
      final id = service.active!.id;
      transport.channelPackets.clear();
      await service.cancel();
      transport.confirmDelivery('Alice');
      transport.directSends.clear();

      for (var i = 1; i <= SosService.cancelSends; i++) {
        now = now.add(SosService.cancelInterval);
        await service.sendCancelIfDue();
      }

      final cancels = transport.channelPackets.where(
        (p) => p.$2.kind == SosPacketKind.cancel && p.$2.id == id,
      );
      expect(cancels, hasLength(SosService.cancelSends));
      expect(transport.directSends.map((s) => s.$1), ['Bob', 'Bob']);
    });

    test('a responder who ACKed gets the cancel by DM', () async {
      final dana = contactFor('Dana', 4);
      transport.contacts = [...transport.contacts, dana];
      await service.activate();
      hear(
        sosPacketFrom('Dana', 4, service.active!.id, kind: SosPacketKind.ack),
      );
      transport.directSends.clear();

      await service.cancel();

      expect(transport.directSends.map((s) => s.$1), ['Alice', 'Bob', 'Dana']);
    });

    test('an ACK after the cancel gets the cancel again', () async {
      final dana = contactFor('Dana', 4);
      transport.contacts = [...transport.contacts, dana];
      await service.activate();
      final id = service.active!.id;
      await service.cancel();
      transport.directSends.clear();
      transport.channelPackets.clear();

      hear(sosPacketFrom('Dana', 4, id, kind: SosPacketKind.ack));
      await pumpEventQueue();
      expect(transport.directSends.single.$1, 'Dana');
      expect(SosCodec.parseCancel(transport.directSends.single.$2), id);

      // The same ACK by DM moments later doesn't send it twice.
      service.handleInbound(
        SosInboundText(
          text: SosCodec.encodeAck(id),
          senderName: 'Dana',
          senderKeyHex: dana.publicKeyHex,
        ),
      );
      await pumpEventQueue();
      expect(transport.directSends, hasLength(1));

      // Someone who isn't a contact hears it on the network.
      hear(sosPacketFrom('Eve', 5, id, kind: SosPacketKind.ack));
      await pumpEventQueue();
      expect(transport.channelPackets.single.$2.kind, SosPacketKind.cancel);
    });
  });

  group('quiet alerts', () {
    test('an ACKed alert that goes quiet is ACKed again', () async {
      final ridge = contactFor('Ridge', 9);
      transport.contacts = [ridge];
      hear(sosPacketFrom('Ridge', 9, 'a1b2'));
      hear(sosPacketFrom('Ridge', 9, 'c3d4'));
      await service.acknowledge(
        service.incoming.firstWhere((a) => a.id == 'a1b2'),
      );
      transport.directSends.clear();
      transport.channelPackets.clear();

      now = now.add(SosService.quietCheckAfter - const Duration(minutes: 1));
      service.checkQuietAlerts();
      await pumpEventQueue();
      expect(transport.directSends, isEmpty);

      now = now.add(const Duration(minutes: 1));
      service.checkQuietAlerts();
      await pumpEventQueue();
      // Only the alert this phone acknowledged.
      expect(transport.directSends, [('Ridge', 'ACK #a1b2')]);
      expect(transport.channelPackets.single.$2.kind, SosPacketKind.ack);

      service.checkQuietAlerts();
      await pumpEventQueue();
      expect(transport.directSends, hasLength(1));
    });

    test('an alert still repeating is not ACKed again', () async {
      hear(sosPacketFrom('Ridge', 9, 'a1b2'));
      await service.acknowledge(service.incoming.single);
      transport.channelPackets.clear();
      for (var i = 0; i < 4; i++) {
        now = now.add(SosService.repeatInterval);
        hear(sosPacketFrom('Ridge', 9, 'a1b2'));
        service.checkQuietAlerts();
      }
      await pumpEventQueue();
      expect(transport.channelPackets, isEmpty);
    });
  });

  group('locator', () {
    Future<void> settle() async {
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    const direct = SosSignal(snrDb: 6.5, direct: true, rssiDbm: -92);

    test('a locate request for our SOS sends a beacon zero hop', () async {
      await service.activate();
      final id = service.active!.id;
      hear(sosPacketFrom('Pat', 5, 'ffff', kind: SosPacketKind.locate));
      await settle();
      expect(transport.zeroHopPackets, isEmpty); // not our SOS
      hear(sosPacketFrom('Pat', 5, id, kind: SosPacketKind.locate));
      await settle();
      final beacon = transport.zeroHopPackets.single;
      expect(beacon.kind, SosPacketKind.beacon);
      expect(beacon.id, id);
      expect(beacon.seq, 0);
      await service.cancel(); // stops the beacons with the SOS
    });

    test('beacons go on while anyone searches, and stop with the last', () async {
      await service.activate();
      final id = service.active!.id;
      hear(sosPacketFrom('Pat', 5, id, kind: SosPacketKind.locate));
      hear(sosPacketFrom('Kim', 6, id, kind: SosPacketKind.locate));
      hear(sosPacketFrom('Kim', 6, id, kind: SosPacketKind.locate)); // counted once
      await settle();
      expect(service.beaconing, isTrue);
      expect(service.searching, 2);
      hear(sosPacketFrom('Pat', 5, id, kind: SosPacketKind.stopLocate));
      await settle();
      expect(service.beaconing, isTrue); // Kim is still searching
      expect(service.searching, 1);
      hear(sosPacketFrom('Kim', 6, id, kind: SosPacketKind.stopLocate));
      await settle();
      expect(service.beaconing, isFalse); // the last one: beacons off
      hear(sosPacketFrom('Kim', 6, id, kind: SosPacketKind.stopLocate)); // a repeat
      await settle();
      expect(service.beaconing, isFalse);
      await service.cancel();
    });

    test('a searcher quiet for 2.5 minutes counts as stopped', () async {
      expect(SosService.searcherTimeout, const Duration(seconds: 150));
      expect(SosService.locateRepeat, const Duration(minutes: 1));
      await service.activate();
      final id = service.active!.id;
      hear(sosPacketFrom('Pat', 5, id, kind: SosPacketKind.locate));
      await settle();
      now = now.add(const Duration(seconds: 149)); // one request lost: still searching
      expect(service.searching, 1);
      now = now.add(const Duration(seconds: 1));
      expect(service.searching, 0);
      await service.cancel();
    });

    test('leaving Locate tells the SOS sender, twice', () async {
      hear(sosPacketFrom('Ridge', 9, 'a1b2', lat: -41, lon: 174));
      service.startLocating(service.incoming.single);
      await settle();
      transport.channelPackets.clear();
      service.stopLocating();
      await settle();
      expect(
        transport.channelPackets.where((p) => p.$2.kind == SosPacketKind.stopLocate),
        hasLength(1),
      );
      await Future<void>.delayed(SosService.stopResends.last + const Duration(milliseconds: 100));
      await settle();
      final stops = transport.channelPackets.where((p) => p.$2.kind == SosPacketKind.stopLocate).toList();
      expect(stops, hasLength(2));
      expect(stops.first.$2.id, 'a1b2');
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('a member still answers a locate request for its own SOS', () async {
      await service.joinNetwork(farmNetwork(SosNetworkRole.member));
      await service.activate();
      hear(
        sosPacketFrom('Pat', 5, service.active!.id, kind: SosPacketKind.locate),
      );
      await settle();
      expect(transport.zeroHopPackets, hasLength(1));
      await service.cancel();
    });

    test(
      'a responder searching asks for beacons and counts direct ones',
      () async {
        hear(sosPacketFrom('Ridge', 9, 'a1b2', lat: -41, lon: 174));
        final alert = service.incoming.single;
        service.startLocating(alert);
        await settle();
        final (_, request) = transport.channelPackets.last;
        expect(request.kind, SosPacketKind.locate);
        expect(request.id, 'a1b2');

        Uint8List beacon(int seq) => SosPacket(
          kind: SosPacketKind.beacon,
          id: 'a1b2',
          senderPrefix: Uint8List.fromList(List.filled(6, 9)),
          senderName: 'Ridge',
          seq: seq,
        ).encode();
        hear(beacon(0), signal: const SosSignal(snrDb: 3, direct: false));
        expect(service.locator!.samples, isEmpty); // came through a repeater
        for (var i = 0; i < 6; i++) {
          hear(
            beacon(i),
            signal: SosSignal(
              snrDb: i.toDouble(),
              direct: true,
              rssiDbm: -110 + i * 3,
            ),
          );
        }
        expect(service.locator!.samples, hasLength(6));
        expect(service.locator!.latest!.rssiDbm, -95);
        expect(service.locator!.trend, greaterThan(0)); // getting closer
        hear(beacon(9), signal: direct);
        expect(service.locator!.latest!.seq, 9);
        service.stopLocating();
        expect(service.locator, isNull);
      },
    );

    Uint8List powerBeacon(
      int seq,
      int power, {
      bool full = false,
      String by = '',
    }) => SosPacket(
      kind: SosPacketKind.beacon,
      id: 'a1b2',
      senderPrefix: Uint8List.fromList(List.filled(6, 9)),
      senderName: 'Ridge',
      seq: seq,
      power: power,
      fullPower: full,
      setBy: by,
    ).encode();

    test(
      'any searcher can set the beacon power; a beacon confirms it',
      () async {
        hear(sosPacketFrom('Ridge', 9, 'a1b2', lat: -41, lon: 174));
        service.startLocating(service.incoming.single);
        await settle();
        hear(powerBeacon(0, 22, full: true), signal: direct);
        expect(service.locator!.beaconPower, 22);
        expect(service.locator!.beaconFull, isTrue);
        service.setBeaconPower(2);
        await settle();
        final (_, ask) = transport.channelPackets.last;
        expect(ask.kind, SosPacketKind.locate);
        expect(ask.power, 2);
        expect(service.locator!.askedPower, 2); // until a beacon says so
        hear(powerBeacon(1, 2, by: 'Farmhouse'), signal: direct);
        expect(service.locator!.askedPower, isNull);
        expect(service.locator!.setBy, 'Farmhouse');
        expect(service.locator!.latest!.beaconPower, 2);
        // back to the radio's own power
        service.setBeaconPower(null);
        await settle();
        expect(transport.channelPackets.last.$2.power, SosPacket.powerFull);
        service.stopLocating(); // and the resends with it
      },
    );

    test('shares a reading with its position, and maps the others', () async {
      hear(sosPacketFrom('Ridge', 9, 'a1b2', lat: -41, lon: 174));
      service.startLocating(service.incoming.single);
      await settle();
      phone.fix = const SosFix(
        latitude: -41.001,
        longitude: 174.002,
        source: SosLocationSource.phoneGps,
      );
      await service.shareReading();
      expect(
        transport.channelPackets.where(
          (p) => p.$2.kind == SosPacketKind.report,
        ),
        isEmpty,
      ); // no beacon yet
      hear(
        powerBeacon(0, 8),
        signal: const SosSignal(snrDb: -3.5, direct: true, rssiDbm: -97),
      );
      await service.shareReading();
      final report = transport.channelPackets.last.$2;
      expect(report.kind, SosPacketKind.report);
      expect(report.reading!.rssiDbm, -97);
      expect(report.reading!.beaconPower, 8);
      expect(report.reading!.latitude, closeTo(-41.001, 1e-6));
      // another searcher's
      hear(
        SosPacket(
          kind: SosPacketKind.report,
          id: 'a1b2',
          senderPrefix: Uint8List.fromList(List.filled(6, 7)),
          senderName: 'Sam',
          reading: const SosReading(
            latitude: -40.998,
            longitude: 174.0,
            rssiDbm: -88,
            snrDb: 2,
            beaconPower: 8,
          ),
        ).encode(),
      );
      final searchers = service.locator!.searchers.values.toList();
      expect(searchers.map((s) => s.name), containsAll(['Farmhouse', 'Sam']));
      expect(searchers.firstWhere((s) => s.name == 'Farmhouse').mine, isTrue);
      expect(service.locator!.readings, hasLength(2));
      expect(
        service.locator!.estimate(now: now),
        isNotNull,
      ); // two places: an area
      service.stopLocating();
    });

    test(
      'a phone app\'s beacons, which don\'t say their power, aren\'t shared',
      () async {
        hear(sosPacketFrom('Ridge', 9, 'a1b2', lat: -41, lon: 174));
        service.startLocating(service.incoming.single);
        await settle();
        phone.fix = const SosFix(
          latitude: -41.001,
          longitude: 174.002,
          source: SosLocationSource.phoneGps,
        );
        hear(
          SosPacket(
            kind: SosPacketKind.beacon,
            id: 'a1b2',
            senderPrefix: Uint8List.fromList(List.filled(6, 9)),
            senderName: 'Ridge',
            seq: 0,
          ).encode(),
          signal: direct,
        );
        expect(service.locator!.beaconPower, isNull); // can't be changed
        await service.shareReading();
        expect(
          transport.channelPackets.where(
            (p) => p.$2.kind == SosPacketKind.report,
          ),
          isEmpty,
        );
        service.stopLocating();
      },
    );
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

    test('opening a chat sends the network ACK again, with its key', () async {
      final ridge = contactFor('Ridge', 9);
      transport.contacts = [ridge];
      hear(sosPacketFrom('Ridge', 9, 'a1b2'), channel: 2);
      final alert = service.incoming.single;
      // not before an ACK: it would answer for the responder
      await service.reintroduceBeforeMessage(alert);
      expect(transport.channelPackets, isEmpty);
      await service.acknowledge(alert);
      transport.channelPackets.clear();
      transport.directSends.clear();
      await service.reintroduceBeforeMessage(alert);
      final (channelIndex, packet) = transport.channelPackets.single;
      expect(channelIndex, 2);
      expect(packet.kind, SosPacketKind.ack);
      expect(packet.senderKey, isNotNull);
      // the radio can't read a DM from a phone it doesn't know yet
      expect(transport.directSends, isEmpty);
      // at most every 30 s
      await service.reintroduceBeforeMessage(alert);
      expect(transport.channelPackets, hasLength(1));
      now = now.add(SosService.reintroduceEvery);
      await service.reintroduceBeforeMessage(alert);
      expect(transport.channelPackets, hasLength(2));
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

    test('dismiss puts the alert aside; Show again brings it back', () async {
      hear(sosPacketFrom('Ridge', 9, 'a1b2', lat: -41, lon: 174));
      await service.acknowledge(service.incoming.single);
      final alert = service.incoming.single;
      await service.dismiss(alert);
      expect(alert.dismissed, isTrue);
      expect(service.openIncoming, isEmpty);
      // kept across a restart, acknowledgement and position included
      final reloaded = newService()..load();
      final kept = reloaded.incoming.single;
      expect(kept.dismissed, isTrue);
      expect(kept.ackSent, isTrue);
      expect(kept.fix.latitude, -41);
      reloaded.dispose();

      await service.showAgain(alert);
      expect(alert.dismissed, isFalse);
      expect(alert.ackSent, isTrue);
      expect(
        service.openIncoming,
        isEmpty,
      ); // acknowledged: no full-screen alert
    });

    test(
      'a repeat of an acknowledged, dismissed alert stays put aside',
      () async {
        hear(sosPacketFrom('Ridge', 9, 'a1b2'));
        await service.acknowledge(service.incoming.single);
        await service.dismiss(service.incoming.single);
        alerter.events.clear();
        hear(sosPacketFrom('Ridge', 9, 'a1b2'));
        expect(service.incoming.single.dismissed, isTrue);
        expect(service.incoming.single.receivedCount, 2);
        expect(alerter.events, isEmpty);
      },
    );

    test('a repeat of an unanswered, dismissed alert sounds again', () async {
      hear(sosPacketFrom('Ridge', 9, 'a1b2'));
      await service.dismiss(service.incoming.single);
      expect(service.openIncoming, isEmpty);
      alerter.events.clear();
      hear(sosPacketFrom('Ridge', 9, 'a1b2'));
      expect(service.openIncoming, hasLength(1));
      expect(alerter.events, ['alert:Ridge#a1b2']);
    });

    test(
      'a dismissed alert is still deleted when the sender cancels',
      () async {
        hear(sosPacketFrom('Ridge', 9, 'a1b2'));
        await service.dismiss(service.incoming.single);
        hear(sosPacketFrom('Ridge', 9, 'a1b2', kind: SosPacketKind.cancel));
        expect(service.incoming, isEmpty);
      },
    );

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
      now = now.add(const Duration(minutes: 1));
      hear(sosPacketFrom('Ridge', 9, 'a1b2'));
      await service.acknowledge(service.incoming.single);
      now = now.add(const Duration(minutes: 1));
      hear(sosPacketFrom('Ridge', 9, 'a1b2'));
      expect(alerter.events, [
        'alert:Ridge#a1b2',
        'alert:Ridge#a1b2',
        'clear:Ridge#a1b2',
      ]);
    });

    test('the DM copy arriving moments later does not re-sound the alarm', () {
      // re-posting Android's looping alarm that soon silences it
      final ridge = contactFor('Ridge', 9);
      transport.contacts = [ridge];
      hear(sosPacketFrom('Ridge', 9, 'a1b2', lat: -41, lon: 174));
      now = now.add(const Duration(seconds: 2));
      service.handleInbound(
        SosInboundText(
          text: SosCodec.encodeSos(
            id: 'a1b2',
            time: now,
            fix: const SosFix.none(),
            info: 'Back gate',
          ),
          senderName: 'Ridge',
          senderKeyHex: ridge.publicKeyHex,
        ),
      );
      final alert = service.incoming.single;
      expect(alert.receivedCount, 2);
      expect(alert.info, 'Back gate');
      expect(alerter.events, ['alert:Ridge#a1b2']);

      now = now.add(SosService.resoundGap);
      hear(sosPacketFrom('Ridge', 9, 'a1b2'));
      expect(alerter.events, ['alert:Ridge#a1b2', 'alert:Ridge#a1b2']);
    });

    test('keeps the info line, also after a restart', () {
      transport.dataListener!(
        2,
        SosPacket(
          kind: SosPacketKind.sos,
          id: 'c3d4',
          senderPrefix: Uint8List.fromList(List.filled(6, 4)),
          senderName: 'Hut',
          senderKey: Uint8List.fromList(List.filled(32, 4)),
          time: now,
          info: 'Lot 14, gate 2',
        ).encode(),
        SosSignal.unknown,
      );
      expect(service.incoming.single.info, 'Lot 14, gate 2');
      hear(sosPacketFrom('Hut', 4, 'c3d4')); // a repeat without it keeps it
      expect(service.incoming.single.info, 'Lot 14, gate 2');
      final reloaded = newService()..load();
      expect(reloaded.incoming.single.info, 'Lot 14, gate 2');
      reloaded.dispose();
    });

    test('records the routes an SOS reached us by, and keeps them', () {
      transport.contacts = [
        Contact(
          publicKey: Uint8List.fromList([0x3a, ...List.filled(31, 1)]),
          name: 'Scaramouche',
          type: advTypeRepeater,
          pathLength: -1,
          path: Uint8List(0),
          lastSeen: now,
        ),
        Contact(
          publicKey: Uint8List.fromList([0x7c, ...List.filled(31, 2)]),
          name: 'Superstar',
          type: advTypeRepeater,
          pathLength: -1,
          path: Uint8List(0),
          lastSeen: now,
        ),
      ];
      final sos = sosPacketFrom('Ridge', 9, 'a1b2');
      // the raw copy reaches the app just before the decoded alert
      transport.routeListener!(2, sos, ['3a', '7c']);
      hear(sos);
      transport.routeListener!(2, sos, ['3a', '7c']);
      transport.routeListener!(2, sos, ['7c']);
      // not counted: another channel, an ACK, our own SOS
      transport.routeListener!(5, sos, ['3a']);
      transport.routeListener!(
        2,
        sosPacketFrom('Ridge', 9, 'a1b2', kind: SosPacketKind.ack),
        ['3a'],
      );
      transport.routeListener!(2, sosPacketFrom('Me', 0xAA, 'a1b2'), ['3a']);

      final alert = service.incoming.single;
      expect(alert.routes, {'3a,7c': 2, '7c': 1});
      expect(alert.heardDirect, isFalse);
      expect(alert.routesByCount.first.key, '3a,7c');
      expect(service.routeNames('3a,7c'), ['Scaramouche', 'Superstar']);
      expect(service.routeNames('5e'), ['5e']); // not a contact: its hash

      transport.routeListener!(2, sos, []); // straight from their radio
      expect(alert.heardDirect, isTrue);

      final reloaded = newService()..load();
      expect(reloaded.incoming.single.routes, {'3a,7c': 2, '7c': 1, '': 1});
      reloaded.dispose();
    });

    test('members keep no routes', () async {
      await settings.joinSosNetwork(farmNetwork(SosNetworkRole.member));
      transport.routeListener!(2, sosPacketFrom('Ridge', 9, 'a1b2'), ['3a']);
      hear(sosPacketFrom('Ridge', 9, 'a1b2'));
      expect(service.incoming, isEmpty);
    });

    test('notes other responders', () {
      hear(sosPacketFrom('Ridge', 9, 'a1b2'));
      hear(sosPacketFrom('Valley', 5, 'a1b2', kind: SosPacketKind.ack));
      expect(service.incoming.single.ackedBy, {'Valley'});
    });
  });

  group('retune', () {
    test('our SOS says what our radio is on', () async {
      await service.activate();
      expect(transport.channelPackets.first.$2.radio, narrowRadio);
    });

    test('an SOS from another frequency offers Retune; one from ours not', () {
      hear(sosPacketFrom('Ridge', 9, 'a1b2', radio: midRadio));
      final alert = service.incoming.single;
      expect(alert.senderRadio, midRadio);
      expect(service.canRetuneTo(alert), isTrue);

      hear(sosPacketFrom('Hut', 4, 'c3d4', radio: narrowRadio));
      expect(service.canRetuneTo(service.incoming.first), isFalse);
      // an SOS that doesn't say (older app or radio): nothing to retune to
      hear(sosPacketFrom('Barn', 5, 'e5f6'));
      expect(service.canRetuneTo(service.incoming.first), isFalse);
    });

    test(
      'tells the other responders first, then retunes, and only on request',
      () async {
        hear(sosPacketFrom('Ridge', 9, 'a1b2', radio: midRadio));
        final alert = service.incoming.single;
        expect(transport.radioChanges, isEmpty); // never by itself

        expect(await service.retuneTo(alert), isTrue);
        final note = transport.channelPackets.last.$2;
        expect(note.kind, SosPacketKind.retune);
        expect(note.id, 'a1b2');
        expect(note.radio, midRadio);
        expect(note.back, isFalse);
        // the note was sent before the radio moved
        final (radio, sentBefore) = transport.radioChanges.single;
        expect(radio, midRadio);
        expect(sentBefore, transport.channelPackets.length);
        expect(service.retune!.from, narrowRadio);
        expect(service.retune!.to, midRadio);
        expect(service.canRetuneTo(alert), isFalse); // there now

        // kept over a restart, and nothing goes back by itself
        final reloaded = newService()..load();
        expect(reloaded.retune?.from, narrowRadio);
        reloaded.dispose();

        expect(await service.retuneBack(), isTrue);
        expect(transport.radioChanges.last.$1, narrowRadio);
        final back = transport.channelPackets.last.$2;
        expect(back.kind, SosPacketKind.retune);
        expect(back.back, isTrue);
        expect(back.radio, narrowRadio);
        expect(service.retune, isNull);
      },
    );

    test('a radio that refuses: says so, and takes the note back', () async {
      hear(sosPacketFrom('Ridge', 9, 'a1b2', radio: midRadio));
      transport.refuseRadio = true;
      expect(await service.retuneTo(service.incoming.single), isFalse);
      expect(service.retune, isNull);
      expect(transport.channelPackets.last.$2.back, isTrue);
    });

    test('shows who re-tuned, until they say they are back', () {
      hear(sosPacketFrom('Ridge', 9, 'a1b2', radio: midRadio));
      final alert = service.incoming.single;
      hear(
        sosPacketFrom(
          'Joe',
          3,
          'a1b2',
          kind: SosPacketKind.retune,
          radio: midRadio,
        ),
      );
      expect(alert.retunedResponders, {'Joe': midRadio});
      // kept over a restart: carry on with the reloaded service
      service.dispose();
      service = newService()..load();
      expect(service.incoming.single.retunedResponders, {'Joe': midRadio});

      hear(
        sosPacketFrom(
          'Joe',
          3,
          'a1b2',
          kind: SosPacketKind.retune,
          radio: narrowRadio,
          back: true,
        ),
      );
      expect(service.incoming.single.retunedResponders, isEmpty);
    });
  });

  group('history', () {
    test('keeps a received alert after the sender cancels it', () async {
      final ridge = contactFor('Ridge', 9);
      transport.contacts = [ridge];
      hear(sosPacketFrom('Ridge', 9, 'a1b2', lat: -41, lon: 174));
      now = now.add(const Duration(seconds: 2));
      service.handleInbound(
        SosInboundText(
          text: SosCodec.encodeSos(
            id: 'a1b2',
            time: now,
            fix: const SosFix(
              latitude: -41.5,
              longitude: 174.5,
              source: SosLocationSource.stored,
            ),
            info: 'Back gate',
          ),
          senderName: 'Ridge',
          senderKeyHex: ridge.publicKeyHex,
        ),
      );
      await service.acknowledge(service.incoming.single);
      hear(sosPacketFrom('Valley', 5, 'a1b2', kind: SosPacketKind.ack));
      now = now.add(const Duration(minutes: 3));
      hear(sosPacketFrom('Ridge', 9, 'a1b2', kind: SosPacketKind.cancel));

      expect(service.incoming, isEmpty);
      final record = service.history.single;
      expect(record.direction, SosHistoryDirection.received);
      expect(record.senderName, 'Ridge');
      expect(record.senderKeyHex, ridge.publicKeyHex);
      expect(record.info, 'Back gate');
      expect(record.count, 2);
      expect(record.heardVia, {'network', 'DM'});
      expect(record.positions.map((p) => p.fix.latitude), [-41, -41.5]);
      expect(record.ackSentAt, isNotNull);
      expect(record.acks.map((a) => a.name), ['Valley']);
      expect(record.outcome, SosHistoryOutcome.cancelledBySender);
      expect(record.endedAt, now);

      final report = record.toReport();
      expect(report, contains('Alert: #a1b2 (received by this phone)'));
      expect(report, contains('Info: Back gate'));
      expect(report, contains('Latest position: -41.50000, 174.50000'));
      expect(report, contains('Valley at'));
      expect(report, contains('Outcome: cancelled by the sender at'));

      final reloaded = newService()..load();
      expect(reloaded.history.single.toReport(), report);
      reloaded.dispose();
    });

    test(
      'a dismissed alert keeps its record, ended as dismissed if it expires',
      () async {
        hear(sosPacketFrom('Ridge', 9, 'a1b2'));
        await service.dismiss(service.incoming.single);
        hear(sosPacketFrom('Ridge', 9, 'a1b2'));
        expect(service.history.single.isOngoing, isTrue);
        expect(service.history.single.count, 2);
        await service.dismiss(service.incoming.single);
        now = now.add(SosService.alertExpiry + const Duration(minutes: 1));
        service.purgeExpired();
        expect(service.history.single.outcome, SosHistoryOutcome.dismissed);
      },
    );

    test('records an expired alert', () {
      hear(sosPacketFrom('Ridge', 9, 'a1b2'));
      now = now.add(SosService.alertExpiry + const Duration(minutes: 1));
      service.purgeExpired();
      expect(service.history.single.outcome, SosHistoryOutcome.expired);
    });

    test('keeps our own SOS after we cancel it', () async {
      final alice = contactFor('Alice', 1);
      transport.contacts = [alice];
      await settings.setSosContact(alice.publicKeyHex, true);
      phone.fix = const SosFix(
        latitude: -41.28646,
        longitude: 174.77624,
        source: SosLocationSource.phoneGps,
      );
      await service.activate();
      final id = service.active!.id;
      transport.confirmDelivery('Alice');
      hear(sosPacketFrom('Valley', 5, id, kind: SosPacketKind.ack));
      await service.cancel();

      final record = service.history.single;
      expect(record.direction, SosHistoryDirection.sent);
      expect(record.senderName, 'Farmhouse');
      expect(record.count, 1);
      expect(record.positions.single.fix.latitude, closeTo(-41.28646, 1e-6));
      expect(record.deliveredTo.map((d) => d.name), ['Alice']);
      expect(record.acks.map((a) => a.name), ['Valley']);
      expect(record.outcome, SosHistoryOutcome.cancelledByMe);
      expect(record.toReport(), contains('sent from this phone'));
    });
  });

  group('emergency network', () {
    test('a responder sees the channel; a member has it hidden', () async {
      expect(transport.hiddenChannelPsk, isNull);
      expect(service.isResponder, isTrue);
      await settings.joinSosNetwork(farmNetwork(SosNetworkRole.member));
      expect(transport.hiddenChannelPsk, farmKey);
      expect(service.isResponder, isFalse);
    });

    test(
      'a member ignores channel alerts but hears ACKs for its SOS',
      () async {
        await settings.joinSosNetwork(farmNetwork(SosNetworkRole.member));
        hear(sosPacketFrom('Ridge', 9, 'a1b2', lat: -41, lon: 174));
        expect(service.incoming, isEmpty);
        expect(alerter.events, isEmpty);

        await service.activate();
        final id = service.active!.id;
        expect(transport.channelPackets.single.$1, 2);
        hear(sosPacketFrom('Valley', 5, id, kind: SosPacketKind.ack));
        expect(service.active!.acks.single.senderName, 'Valley');
      },
    );

    test('a broadcast waits for the channel list to load', () async {
      transport.startChannelReload();
      final activating = service.activate();
      await pumpEventQueue();
      expect(transport.channelPackets, isEmpty);
      transport.finishChannelReload();
      await activating;
      expect(transport.channelPackets.single.$1, 2);
      expect(transport.installed, isEmpty);
    });

    test('alerts are heard while the channel list reloads', () {
      transport.startChannelReload();
      hear(sosPacketFrom('Ridge', 9, 'a1b2'));
      expect(service.incoming.single.senderName, 'Ridge');
    });

    test('an SOS carrying its key saves the sender as a contact', () async {
      hear(sosPacketFrom('Ridge', 9, 'a1b2', withKey: true));
      await pumpEventQueue();
      final (name, key) = transport.addedContacts.single;
      expect(name, 'Ridge');
      expect(key, List.filled(32, 9));
      final alert = service.incoming.single;
      expect(service.contactFor(alert.senderKeyHex)?.name, 'Ridge');

      // Repeats do not add it again.
      hear(sosPacketFrom('Ridge', 9, 'a1b2', withKey: true));
      await pumpEventQueue();
      expect(transport.addedContacts, hasLength(1));
    });

    test('our SOS and ACK packets carry our key', () async {
      await service.activate();
      expect(
        transport.channelPackets.single.$2.senderKey,
        List.filled(32, 0xAA),
      );
      hear(sosPacketFrom('Ridge', 9, 'a1b2'));
      await service.acknowledge(service.incoming.single);
      final ack = transport.channelPackets.last.$2;
      expect(ack.kind, SosPacketKind.ack);
      expect(ack.senderKey, List.filled(32, 0xAA));
    });

    test('a member saves the responder who ACKed its SOS', () async {
      await settings.joinSosNetwork(farmNetwork(SosNetworkRole.member));
      await service.activate();
      final id = service.active!.id;
      // An ACK for someone else's SOS is not ours to save.
      hear(
        sosPacketFrom(
          'Hill',
          4,
          'ffff',
          kind: SosPacketKind.ack,
          withKey: true,
        ),
      );
      await pumpEventQueue();
      expect(transport.addedContacts, isEmpty);

      hear(
        sosPacketFrom('Valley', 5, id, kind: SosPacketKind.ack, withKey: true),
      );
      await pumpEventQueue();
      expect(transport.addedContacts.single.$1, 'Valley');
      final ack = service.active!.acks.single;
      expect(service.contactFor(ack.senderKeyHex)?.name, 'Valley');
    });

    test('packets on other channels are ignored', () {
      hear(sosPacketFrom('Ridge', 9, 'a1b2'), channel: 0);
      expect(service.incoming, isEmpty);
    });

    test('installs the channel in the first free slot', () async {
      final other = SosNetworkCode(
        role: SosNetworkRole.member,
        key: Uint8List.fromList(List.filled(16, 3)),
        name: 'Ridge Station',
      );
      await service.joinNetwork(other);
      expect(transport.installed, [(1, 'Ridge Station')]);
      expect(transport.deleted, [2]);
      expect(service.sosChannel?.index, 1);
      expect(service.networkStatus, SosNetworkStatus.ready);
      expect(transport.hiddenChannelPsk, other.key);
    });

    test('reports when the radio has no free slot', () async {
      transport
        ..maxChannels = 2
        ..allChannels = [
          Channel(index: 0, name: 'Public', psk: Uint8List(16)),
          Channel(index: 1, name: 'Hiking', psk: Uint8List(16)),
        ];
      transport.notifyListeners();
      expect(service.networkStatus, SosNetworkStatus.noFreeSlot);
      expect(transport.installed, isEmpty);
    });

    test('leaving removes the channel and its alerts', () async {
      hear(sosPacketFrom('Ridge', 9, 'a1b2'));
      expect(service.incoming, hasLength(1));
      await service.leaveNetwork();
      expect(transport.deleted, [2]);
      expect(transport.installed, isEmpty);
      expect(service.network, isNull);
      expect(service.incoming, isEmpty);
      expect(service.networkStatus, SosNetworkStatus.none);
    });

    test('creating a network makes this phone its coordinator', () async {
      await settings.leaveSosNetwork();
      final net = await service.createNetwork('Smith Farm');
      expect(net.role, SosNetworkRole.responder);
      expect(service.isCoordinator, isTrue);
      expect(service.network!.name, 'Smith Farm');
      expect(transport.installed.single.$2, 'Smith Farm');
      expect(net.key, isNot(farmKey));
    });
  });
}
