import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'dart:typed_data';

import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/screens/path_trace_map.dart';
import 'package:meshcore_open/services/app_settings_service.dart';
import 'package:meshcore_open/services/map_tile_cache_service.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/services/path_history_service.dart';
import 'package:meshcore_open/services/storage_service.dart';
import 'package:meshcore_open/models/path_history.dart';

class _FakeStorageService extends StorageService {
  @override
  Future<void> savePathHistory(
    String contactPubKeyHex,
    ContactPathHistory history,
  ) async {}
  @override
  Future<ContactPathHistory?> loadPathHistory(String contactPubKeyHex) async =>
      null;
  @override
  Future<void> clearPathHistory(String contactPubKeyHex) async {}
}

class _FakeMeshCoreConnector extends MeshCoreConnector {
  final StreamController<Uint8List> _receivedFramesController =
      StreamController<Uint8List>.broadcast();

  @override
  Stream<Uint8List> get receivedFrames => _receivedFramesController.stream;

  @override
  Uint8List? get selfPublicKey =>
      Uint8List.fromList(List.generate(32, (i) => i));

  List<Contact> fakeContacts = [];
  double? fakeLat;
  double? fakeLon;

  @override
  double? get selfLatitude => fakeLat;

  @override
  double? get selfLongitude => fakeLon;

  @override
  List<Contact> get allContactsUnfiltered => fakeContacts;

  @override
  List<Contact> get contacts => fakeContacts;

  void emitFrame(Uint8List frame) {
    _receivedFramesController.add(frame);
  }

  final List<Uint8List> sentFrames = [];

  @override
  Future<void> sendFrame(
    Uint8List frame, {
    String? channelSendQueueId,
    bool expectsGenericAck = false,
    bool waitForGenericAck = false,
  }) async {
    sentFrames.add(frame);
  }
}

Widget _buildTestApp({
  required MeshCoreConnector connector,
  required Widget child,
}) {
  final appSettingsService = AppSettingsService();

  return MultiProvider(
    providers: [
      ChangeNotifierProvider<MeshCoreConnector>.value(value: connector),
      ChangeNotifierProvider<AppSettingsService>.value(
        value: appSettingsService,
      ),
      ChangeNotifierProvider<MapTileCacheService>(
        create: (_) =>
            MapTileCacheService(appSettingsService: appSettingsService),
      ),
      ChangeNotifierProvider<PathHistoryService>(
        create: (_) => PathHistoryService(_FakeStorageService()),
      ),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: child,
    ),
  );
}


Contact _rep(int first, String name, double lat, double lon, List<int> path) => Contact(
      publicKey: Uint8List.fromList([first, ...List.generate(31, (i) => i + 1)]),
      name: name,
      type: advTypeRepeater,
      pathLength: path.length,
      path: Uint8List.fromList(path),
      latitude: lat,
      longitude: lon,
      lastSeen: DateTime.now(),
    );

Future<String> _runTrace(WidgetTester tester, {double? lat, double? lon}) async {
  final connector = _FakeMeshCoreConnector()
    ..fakeLat = lat
    ..fakeLon = lon;
  final walcha = _rep(0x37, 'Walcha', -30.978826, 151.602468, []);
  final wilgar = _rep(0x41, 'Wilgar West', -30.977281, 151.478229, [0x37]);
  connector.fakeContacts = [walcha, wilgar];
  final screen = PathTraceMapScreen(
    title: 'Wilgar West',
    path: wilgar.pathBytesForDisplay,
    flipPathAround: true,
    targetContact: wilgar,
    pathHashByteWidth: 1,
  );
  await tester.pumpWidget(_buildTestApp(connector: connector, child: screen));
  await tester.pump();
  final sent = connector.sentFrames.first;
  final tag = sent.sublist(1, 5);
  final route = sent.sublist(10);
  // RESP_CODE_SENT: [6][flood][tag x4][timeout x4], as the firmware sends it (~5 s)
  connector.emitFrame(Uint8List.fromList([respCodeSent, 0, ...tag, 0x88, 0x13, 0, 0]));
  await tester.pump(const Duration(seconds: 2));
  // PUSH_CODE_TRACE_DATA exactly as MyMesh::onTraceRecv builds it
  connector.emitFrame(Uint8List.fromList([
    pushCodeTraceData, 0, route.length, sent[9], ...tag, 0, 0, 0, 0,
    ...route, 0x2e, 0x08, 0xeb, 0x30,
  ]));
  for (int i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
  final failed = find.text('Path trace not available.').evaluate().isNotEmpty;
  final err = tester.takeException();
  return 'route=${route.map((b) => b.toRadixString(16)).join(",")} '
      'tagInSendFrame=${sent.sublist(1, 5)} failed=$failed exception=$err';
}

Future<String> _runMapTrace(WidgetTester tester, int width) async {
  final connector = _FakeMeshCoreConnector();
  final walcha = _rep(0x37, 'Walcha', -30.978826, 151.602468, []);
  connector.fakeContacts = [walcha];
  final screen = PathTraceMapScreen(
    title: 'Path trace',
    path: Uint8List.fromList(walcha.publicKey.sublist(0, width)),
    flipPathAround: false,
    pathHashByteWidth: width,
    pathContacts: [walcha],
  );
  await tester.pumpWidget(_buildTestApp(connector: connector, child: screen));
  await tester.pump();
  if (connector.sentFrames.isEmpty) {
    await tester.pump(const Duration(seconds: 1));
    final failed = find.text('Path trace not available.').evaluate().isNotEmpty;
    return 'NOTHING SENT failed=$failed exception=${tester.takeException()}';
  }
  final sent = connector.sentFrames.first;
  final tag = sent.sublist(1, 5);
  final route = sent.sublist(10);
  connector.emitFrame(Uint8List.fromList([respCodeSent, 0, ...tag, 0x88, 0x13, 0, 0]));
  await tester.pump(const Duration(seconds: 1));
  connector.emitFrame(Uint8List.fromList([
    pushCodeTraceData, 0, route.length, sent[9], ...tag, 0, 0, 0, 0,
    ...route, 0x2e, 0x30,
  ]));
  for (int i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
  final failed = find.text('Path trace not available.').evaluate().isNotEmpty;
  return 'sent=${sent.map((b) => b.toRadixString(16).padLeft(2, "0")).join()} failed=$failed exception=${tester.takeException()}';
}

void main() {
  for (final w in [1, 2, 3]) {
    testWidgets('map one-way trace to 37, width $w', (tester) async {
      debugPrint('MAP w=$w: ${await _runMapTrace(tester, w)}');
    });
  }
  testWidgets('real trace, desktop without GPS', (tester) async {
    debugPrint('NO GPS: ${await _runTrace(tester)}');
  });
  testWidgets('real trace, with GPS', (tester) async {
    debugPrint('GPS: ${await _runTrace(tester, lat: -30.98, lon: 151.59)}');
  });
}
