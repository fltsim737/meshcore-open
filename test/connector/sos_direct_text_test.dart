import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/models/contact.dart';

class _RecordingConnector extends MeshCoreConnector {
  final List<Uint8List> sentFrames = [];

  @override
  bool get isConnected => true;

  @override
  Uint8List? get selfPublicKey => Uint8List(32);

  @override
  Future<void> sendFrame(
    Uint8List data, {
    String? channelSendQueueId,
    bool expectsGenericAck = false,
    bool waitForGenericAck = false,
  }) async {
    sentFrames.add(data);
  }
}

void main() {
  test('an SOS message clears the stored route first, so it floods', () async {
    final connector = _RecordingConnector();
    final contact = Contact(
      publicKey: Uint8List.fromList(List<int>.generate(32, (i) => i + 1)),
      name: 'Emergency contact',
      type: advTypeChat,
      pathLength: 2,
      path: Uint8List.fromList([0x11, 0x22]),
      lastSeen: DateTime.now(),
    );

    final hash = await connector.sendSosDirectText(contact, 'SOS test');

    expect(hash, isNotNull);
    expect(connector.sentFrames.map((f) => f[0]).toList(), [
      cmdResetPath,
      cmdSendTxtMsg,
    ]);
    expect(connector.sentFrames[0].sublist(1, 33), contact.publicKey);
  });
}
