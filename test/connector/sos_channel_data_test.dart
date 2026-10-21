import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/helpers/sos_codec.dart';
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

void main() {
  // Image messages default to off, which used to drop every SOS packet
  // along with image chunks.
  test('SOS packets reach the listener with image messages off', () async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    final connector = MeshCoreConnector();
    final retryService = MessageRetryService();
    connector.initialize(
      retryService: retryService,
      pathHistoryService: PathHistoryService(StorageService()),
    );
    final radio = ReviewRadio(
      scheduledMessageInterval: const Duration(hours: 1),
      replyDelay: const Duration(hours: 1),
    );
    connector.reviewRadioFactoryForTest = () => radio;
    await connector.connectReview();
    addTearDown(() async {
      await connector.disconnect();
      connector.dispose();
      retryService.dispose();
    });
    await _waitFor(() => connector.channelMapConfirmed);

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
}
