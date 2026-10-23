import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/helpers/sos_codec.dart';
import 'package:meshcore_open/review_mode/review_frames.dart';
import 'package:meshcore_open/review_mode/review_radio.dart';
import 'package:meshcore_open/services/image_chunk_transport.dart';
import 'package:meshcore_open/services/message_retry_service.dart';
import 'package:meshcore_open/services/path_history_service.dart';
import 'package:meshcore_open/services/storage_service.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A RESP_CODE_CHANNEL_DATA_RECV frame as the companion firmware builds it.
Uint8List channelDataFrame(int channelIndex, int dataType, Uint8List data) =>
    Uint8List.fromList([
      respCodeChannelDataRecv,
      40, // snr
      0, 0, // reserved
      channelIndex,
      0x02, // flood, 2 hops
      dataType & 0xFF,
      (dataType >> 8) & 0xFF,
      data.length,
      ...data,
    ]);

Future<void> _waitFor(bool Function() condition) async {
  final end = DateTime.now().add(const Duration(seconds: 8));
  while (!condition()) {
    if (DateTime.now().isAfter(end)) fail('Timed out waiting for condition');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

late MeshCoreConnector connector;
late ReviewRadio radio;

/// Connects a fresh review radio; initialize() may only run once.
Future<void> _connect() async {
  radio = ReviewRadio(
    scheduledMessageInterval: const Duration(hours: 1),
    replyDelay: const Duration(hours: 1),
  );
  connector.reviewRadioFactoryForTest = () => radio;
  connector.hiddenChannelPsk = null;
  await connector.connectReview();
  addTearDown(connector.disconnect);
  await _waitFor(() => connector.channelMapConfirmed);
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    connector = MeshCoreConnector();
    final retryService = MessageRetryService();
    connector.initialize(
      retryService: retryService,
      pathHistoryService: PathHistoryService(StorageService()),
    );
    addTearDown(() {
      connector.dispose();
      retryService.dispose();
    });
  });

  // Packets that arrive before the channel list is read (on every connect,
  // including the radio's offline queue) are held and replayed afterwards.
  // Runs first: the map stays confirmed for this connector afterwards.
  test(
    'SOS packets held until the channel list is read are delivered',
    () async {
      final received = <(int, Uint8List)>[];
      connector.sosDataListener = (index, data) => received.add((index, data));
      radio = ReviewRadio(
        scheduledMessageInterval: const Duration(hours: 1),
        replyDelay: const Duration(hours: 1),
      );
      final packet = SosPacket(
        kind: SosPacketKind.sos,
        id: 'c3d4',
        senderPrefix: Uint8List.fromList([1, 2, 3, 4, 5, 6]),
        senderName: 'Gully',
        time: DateTime.utc(2026, 10, 21),
      ).encode();
      connector.reviewRadioFactoryForTest = () => radio;
      connector.hiddenChannelPsk = null;
      // Sent as soon as the channel list starts loading.
      var sent = false;
      final poll = Timer.periodic(const Duration(milliseconds: 1), (timer) {
        if (!connector.isLoadingChannels) return;
        timer.cancel();
        expect(connector.channelMapConfirmed, isFalse);
        radio.emitForTest(channelDataFrame(1, dataTypeSos, packet));
        sent = true;
      });
      addTearDown(poll.cancel);
      await connector.connectReview();
      addTearDown(connector.disconnect);
      await _waitFor(() => sent && connector.channelMapConfirmed);
      await _waitFor(() => received.isNotEmpty);

      expect(received.single.$1, 1);
      expect(SosPacket.decode(received.single.$2)!.senderName, 'Gully');
    },
  );

  // Image messages default to off, which used to drop every SOS packet
  // along with image chunks.
  test('SOS packets reach the listener with image messages off', () async {
    await _connect();
    final received = <(int, Uint8List)>[];
    connector.sosDataListener = (index, data) => received.add((index, data));
    final packet = SosPacket(
      kind: SosPacketKind.sos,
      id: 'a1b2',
      senderPrefix: Uint8List.fromList([1, 2, 3, 4, 5, 6]),
      senderName: 'Ridge',
      time: DateTime.utc(2026, 10, 21),
    ).encode();
    radio.emitForTest(channelDataFrame(1, dataTypeSos, packet));
    // Other data types are not SOS.
    radio.emitForTest(
      channelDataFrame(1, dataTypeAeicImage, Uint8List.fromList([1, 2, 3])),
    );
    await _waitFor(() => received.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(received, hasLength(1));
    expect(received.single.$1, 1);
    expect(SosPacket.decode(received.single.$2)!.senderName, 'Ridge');
  });

  test('an SOS DM reaches the alarm and stays in the chat', () async {
    await _connect();
    await _waitFor(() => connector.contacts.isNotEmpty);
    final sender = connector.contacts.first;
    final heard = <String>[];
    connector.sosTextListener = (inbound) => heard.add(inbound.text);
    final secs = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final sos = SosCodec.encodeSos(
      id: 'e5f6',
      time: DateTime.now(),
      fix: const SosFix(
        latitude: -30.98665,
        longitude: 151.60138,
        source: SosLocationSource.stored,
      ),
      info: 'test only',
    );
    radio.emitForTest(
      ReviewFrames.contactMessage(
        senderPublicKey: sender.publicKey,
        text: sos,
        timestampSecs: secs,
      ),
    );
    radio.emitForTest(
      ReviewFrames.contactMessage(
        senderPublicKey: sender.publicKey,
        text: SosCodec.encodeCancel('e5f6', DateTime.now()),
        timestampSecs: secs + 1,
      ),
    );
    await _waitFor(() => heard.length == 2);
    List<String> chat() =>
        connector.getMessages(sender).map((m) => m.text).toList();
    await _waitFor(() => chat().contains(sos));

    // both stay in the chat as a record, the SOS with its Info line
    expect(chat().where((t) => t.contains('Info: test only')), hasLength(1));
    expect(
      chat().where((t) => t.startsWith(SosCodec.cancelHeader)),
      hasLength(1),
    );
  });

  test('a hidden channel is left out of the list and its chat', () async {
    await _connect();
    final hidden = connector.allChannels.firstWhere((c) => c.index == 1);
    final visibleBefore = connector.channels.length;

    connector.hiddenChannelPsk = hidden.psk;
    expect(connector.channels.any((c) => c.index == 1), isFalse);
    expect(connector.channels, hasLength(visibleBefore - 1));
    expect(connector.allChannels.any((c) => c.index == 1), isTrue);

    final before = connector.getChannelMessages(hidden).length;
    final unreadBefore = connector.getTotalChannelsUnreadCount();
    radio.emitForTest(
      ReviewFrames.channelMessage(
        channelIndex: 1,
        sender: 'Sam',
        message: 'responders only',
        timestampSecs: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(connector.getChannelMessages(hidden), hasLength(before));
    expect(connector.getTotalChannelsUnreadCount(), unreadBefore);

    // Unhidden (a responder): the channel and its chat are back.
    connector.hiddenChannelPsk = null;
    expect(connector.channels.any((c) => c.index == 1), isTrue);
  });
}
