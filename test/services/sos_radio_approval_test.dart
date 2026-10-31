import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/sos_network_code.dart';
import 'package:meshcore_open/models/channel.dart';
import 'package:meshcore_open/services/sos_service.dart';

import 'sos_service_test.dart'
    show FakePhoneLocation, FakeSosTransport, farmNetwork, freshSettings;

void main() {
  late FakeSosTransport transport;
  late SosService sos;

  setUp(() async {
    final settings = await freshSettings();
    transport = FakeSosTransport();
    sos = SosService(
      transport: transport,
      settings: settings,
      phoneLocation: FakePhoneLocation(),
    );
  });

  tearDown(() => sos.dispose());

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  bool hasNetworkChannel() => transport.allChannels.any(
    (c) => listEquals(c.psk, farmNetwork(SosNetworkRole.member).key),
  );

  /// Unplugs the radio and plugs in another, [seed], with [channels].
  Future<void> connectRadio(int seed, {List<Channel>? channels}) async {
    transport.setConnected(false);
    transport.selfPublicKey = Uint8List.fromList(List.filled(32, seed));
    transport.allChannels =
        channels ??
        transport.allChannels
            .where(
              (c) => !listEquals(c.psk, farmNetwork(SosNetworkRole.member).key),
            )
            .toList();
    transport.setConnected(true);
    await settle();
  }

  test('joining while connected puts the network on that radio', () async {
    await sos.joinNetwork(farmNetwork(SosNetworkRole.responder));
    await settle();
    expect(hasNetworkChannel(), isTrue);
    expect(sos.networkStatus, SosNetworkStatus.ready);
  });

  test(
    'another radio connecting is asked about, not given the channel',
    () async {
      await sos.joinNetwork(farmNetwork(SosNetworkRole.responder));
      await settle();
      await connectRadio(0x37); // a radio being tested on this computer
      expect(hasNetworkChannel(), isFalse);
      expect(sos.networkStatus, SosNetworkStatus.needsApproval);
      expect(sos.radioDeclined, isFalse);

      await sos.addNetworkToRadio();
      await settle();
      expect(hasNetworkChannel(), isTrue);
      expect(sos.networkStatus, SosNetworkStatus.ready);
    },
  );

  test('a member\'s app asks too', () async {
    await sos.joinNetwork(farmNetwork(SosNetworkRole.member));
    await settle();
    await connectRadio(0x37);
    expect(hasNetworkChannel(), isFalse);
    expect(sos.networkStatus, SosNetworkStatus.needsApproval);
  });

  test('"Not this radio" keeps it off, also after reconnecting', () async {
    await sos.joinNetwork(farmNetwork(SosNetworkRole.responder));
    await settle();
    await connectRadio(0x37);
    sos.declineRadio();
    expect(sos.radioDeclined, isTrue);
    await connectRadio(0x37);
    expect(hasNetworkChannel(), isFalse);
    expect(sos.radioDeclined, isTrue);
  });

  test('an agreed radio gets it back by itself after reconnecting', () async {
    await sos.joinNetwork(farmNetwork(SosNetworkRole.responder));
    await settle();
    final first = transport.selfPublicKey![0];
    await connectRadio(0x37);
    await connectRadio(first); // the radio it was joined on, channel lost
    expect(hasNetworkChannel(), isTrue);
  });

  test('a radio that already has the channel is ready', () async {
    await sos.joinNetwork(farmNetwork(SosNetworkRole.responder));
    await settle();
    final withChannel = List.of(transport.allChannels);
    await connectRadio(0x38, channels: withChannel);
    expect(sos.networkStatus, SosNetworkStatus.ready);
  });

  test('"Remove from this radio" takes it off and keeps the network', () async {
    await sos.joinNetwork(farmNetwork(SosNetworkRole.responder));
    await settle();
    await sos.removeNetworkFromRadio();
    await settle();
    expect(hasNetworkChannel(), isFalse);
    expect(sos.network, isNotNull);
    expect(sos.radioDeclined, isTrue);
    expect(sos.networkStatus, SosNetworkStatus.needsApproval);
  });

  test('no network: nothing is ever added', () async {
    await connectRadio(0x37);
    expect(hasNetworkChannel(), isFalse);
    expect(sos.networkStatus, SosNetworkStatus.none);
  });
}
