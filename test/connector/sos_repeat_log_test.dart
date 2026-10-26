import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/helpers/sos_codec.dart';
import 'package:meshcore_open/models/channel.dart';
import 'package:meshcore_open/review_mode/review_radio.dart';
import 'package:meshcore_open/review_mode/review_script.dart';
import 'package:meshcore_open/services/message_retry_service.dart';
import 'package:meshcore_open/services/path_history_service.dart';
import 'package:meshcore_open/services/storage_service.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _waitFor(bool Function() condition) async {
  final end = DateTime.now().add(const Duration(seconds: 8));
  while (!condition()) {
    if (DateTime.now().isAfter(end)) fail('Timed out waiting for condition');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// A LOG_RX_DATA frame: a channel datagram (GRP_DATA) on [psk], flooded,
/// heard after the repeaters in [path] (1-byte path hashes).
Uint8List _logRxGroupData(
  Uint8List psk,
  int dataType,
  List<int> data,
  List<int> path,
) {
  final plain = [dataType & 0xFF, dataType >> 8, data.length, ...data];
  final padded = Uint8List(((plain.length + 15) ~/ 16) * 16)
    ..setRange(0, plain.length, plain);
  final cipher = ECBBlockCipher(AESEngine())..init(true, KeyParameter(psk));
  final encrypted = Uint8List(padded.length);
  for (var i = 0; i < padded.length; i += 16) {
    cipher.processBlock(padded, i, encrypted, i);
  }
  final key32 = Uint8List(32)..setRange(0, 16, psk);
  final mac = crypto.Hmac(crypto.sha256, key32).convert(encrypted).bytes;
  final channelHash = crypto.sha256.convert(psk).bytes[0];
  return Uint8List.fromList([
    pushCodeLogRxData,
    40, // snr
    0xA0, // rssi
    0x19, // flood route, GRP_DATA payload
    path.length, // hops, 1-byte hashes
    ...path,
    channelHash,
    mac[0],
    mac[1],
    ...encrypted,
  ]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('hands each repeated copy of an SOS packet to the SOS service', () async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    final connector = MeshCoreConnector();
    final retryService = MessageRetryService();
    connector.initialize(
      retryService: retryService,
      pathHistoryService: PathHistoryService(StorageService()),
    );
    addTearDown(() {
      connector.dispose();
      retryService.dispose();
    });
    connector.reviewRadioFactoryForTest = () => ReviewRadio(
      scheduledMessageInterval: const Duration(hours: 1),
      replyDelay: const Duration(hours: 1),
    );
    await connector.connectReview();
    addTearDown(connector.disconnect);
    await _waitFor(() => connector.channelMapConfirmed);

    final heard = <(int, List<int>, String)>[];
    connector.sosRepeatListener = (index, payload, lastHop) =>
        heard.add((index, payload, lastHop));
    final psk = Channel.parsePskHex(ReviewScript.channels[1].pskHex);
    final sos = [1, 2, 3, 4, 5];

    connector.handleFrameForTest(
      _logRxGroupData(psk, dataTypeSos, sos, [0x11, 0x3a]),
    );
    // not passed on: no path (heard straight from the sender), or not SOS data
    connector.handleFrameForTest(_logRxGroupData(psk, dataTypeSos, sos, []));
    connector.handleFrameForTest(_logRxGroupData(psk, 0xAE1C, sos, [0x3a]));

    expect(heard, hasLength(1));
    expect(heard.single.$1, 1);
    expect(heard.single.$2, sos);
    expect(heard.single.$3, '3a');
  });
}
