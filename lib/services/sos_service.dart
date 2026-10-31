import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../storage/prefs_manager.dart';

import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../helpers/sos_codec.dart';
import '../helpers/sos_network_code.dart';
import '../helpers/sos_search.dart';
import '../helpers/sos_seal.dart';
import '../models/channel.dart';
import '../models/contact.dart';
import '../models/sos_alert.dart';
import '../models/sos_history.dart';
import '../models/sos_session_book.dart';
import '../storage/sos_store.dart';
import '../utils/app_logger.dart';
import 'app_settings_service.dart';
import 'notification_service.dart';
import 'sos_location_service.dart';

/// The parts of the connector the SOS feature uses, so it can be faked.
/// Notifies when the connection state may have changed.
///
/// Nothing sent or received here enters chat history: channel copies travel
/// as [dataTypeSos] channel data, which no chat shows, and direct messages
/// are sent as raw frames and diverted on arrival.
abstract class SosTransport implements Listenable {
  bool get isConnected;
  String? get selfName;
  Uint8List? get selfPublicKey;
  double? get selfLatitude;
  double? get selfLongitude;

  /// The radio's LoRa settings, when known (and ones an SOS can carry).
  SosRadio? get selfRadio;

  /// Retunes the radio; true once it has taken the settings.
  Future<bool> setRadio(SosRadio radio);

  /// Every channel on the radio, the hidden network channel included.
  List<Channel> get allChannels;
  List<Contact> get contacts;
  int get maxChannels;

  /// The channel list has been read from the radio and can be trusted.
  bool get channelsReady;

  /// Channel data needs companion firmware v1.15 or newer.
  bool get supportsChannelData;

  /// Key of the channel to keep out of the UI, or null.
  Uint8List? get hiddenChannelPsk;
  set hiddenChannelPsk(Uint8List? psk);

  Future<void> setChannel(int index, String name, Uint8List psk);
  Future<void> deleteChannel(int index);

  set sosTextListener(void Function(SosInboundText inbound)? listener);
  set sosDataListener(
    void Function(int channelIndex, Uint8List payload, SosSignal signal)?
    listener,
  );
  set sosAckListener(void Function(int ackHash)? listener);

  /// A copy of an SOS packet heard passed on by a repeater, with that
  /// repeater's path hash (hex).
  set sosRepeatListener(
    void Function(int channelIndex, Uint8List payload, String lastHopHex)?
    listener,
  );

  /// Every copy of an SOS packet heard, with the repeaters it came through
  /// (path hashes in hex, nearest the sender first; empty: straight from the
  /// sender's radio).
  set sosRouteListener(
    void Function(int channelIndex, Uint8List payload, List<String> pathHex)?
    listener,
  );

  /// Flooded across the mesh, or [zeroHop]: only radios in direct range.
  Future<void> sendChannelData(
    Channel channel,
    Uint8List payload, {
    bool zeroHop = false,
  });

  /// Returns the ACK hash the recipient's radio will confirm delivery with.
  Future<int?> sendDirectText(Contact contact, String text);

  /// Saves [publicKey] as a chat contact unless it already is one.
  Future<Contact?> addContact(Uint8List publicKey, String name);
}

class ConnectorSosTransport implements SosTransport {
  final MeshCoreConnector connector;

  ConnectorSosTransport(this.connector);

  @override
  bool get isConnected => connector.isConnected;
  @override
  String? get selfName => connector.selfName;
  @override
  Uint8List? get selfPublicKey => connector.selfPublicKey;
  @override
  double? get selfLatitude => connector.selfLatitude;
  @override
  double? get selfLongitude => connector.selfLongitude;
  @override
  SosRadio? get selfRadio => SosRadio.fromRadio(
    freqKhz: connector.currentFreqHz, // kHz, despite the name
    bwHz: connector.currentBwHz,
    sf: connector.currentSf,
    cr: connector.currentCr,
  );
  @override
  Future<bool> setRadio(SosRadio radio) async {
    final ok = await connector.setRadioParams(
      radio.freqKhz,
      radio.bwHz,
      radio.sf,
      radio.cr,
    );
    if (ok) await connector.refreshDeviceInfo();
    return ok;
  }

  @override
  List<Channel> get allChannels => connector.allChannels;
  @override
  List<Contact> get contacts => connector.contacts;
  @override
  int get maxChannels => connector.maxChannels;
  @override
  bool get channelsReady =>
      connector.hasLoadedChannels && !connector.isLoadingChannels;
  @override
  bool get supportsChannelData => connector.supportsChannelData;
  @override
  Uint8List? get hiddenChannelPsk => connector.hiddenChannelPsk;
  @override
  set hiddenChannelPsk(Uint8List? psk) => connector.hiddenChannelPsk = psk;
  @override
  Future<void> setChannel(int index, String name, Uint8List psk) =>
      connector.setChannel(index, name, psk);
  @override
  Future<void> deleteChannel(int index) => connector.deleteChannel(index);
  @override
  set sosTextListener(void Function(SosInboundText inbound)? listener) =>
      connector.sosTextListener = listener;
  @override
  set sosDataListener(
    void Function(int channelIndex, Uint8List payload, SosSignal signal)?
    listener,
  ) => connector.sosDataListener = listener;
  @override
  set sosAckListener(void Function(int ackHash)? listener) =>
      connector.sosAckListener = listener;
  @override
  set sosRepeatListener(
    void Function(int channelIndex, Uint8List payload, String lastHopHex)?
    listener,
  ) => connector.sosRepeatListener = listener;
  @override
  set sosRouteListener(
    void Function(int channelIndex, Uint8List payload, List<String> pathHex)?
    listener,
  ) => connector.sosRouteListener = listener;
  @override
  Future<void> sendChannelData(
    Channel channel,
    Uint8List payload, {
    bool zeroHop = false,
  }) => connector.sendSosChannelData(channel.index, payload, zeroHop: zeroHop);
  @override
  Future<int?> sendDirectText(Contact contact, String text) =>
      connector.sendSosDirectText(contact, text);
  @override
  Future<Contact?> addContact(Uint8List publicKey, String name) =>
      connector.addSosContact(publicKey, name);
  @override
  void addListener(VoidCallback listener) => connector.addListener(listener);
  @override
  void removeListener(VoidCallback listener) =>
      connector.removeListener(listener);
}

enum SosNetworkStatus {
  /// No network joined: SOS goes to emergency contacts only.
  none,
  disconnected,
  needsFirmware,
  installing,
  noFreeSlot,

  /// The connected radio doesn't have the network's channel, and hasn't been
  /// agreed to: the app asks before putting it on ([addNetworkToRadio]).
  needsApproval,
  ready,
}

/// How alerts reach the user outside the Emergency tab.
abstract class SosAlerter {
  void alert(IncomingSos alert);
  void clear(IncomingSos alert);
  void acknowledged(OutgoingSos sos, SosAck ack);
  void cancelled(IncomingSos alert);
}

class NotificationSosAlerter implements SosAlerter {
  @override
  void alert(IncomingSos alert) =>
      unawaited(NotificationService().showSosAlert(alert));
  @override
  void clear(IncomingSos alert) =>
      unawaited(NotificationService().cancelSosAlert(alert));
  @override
  void acknowledged(OutgoingSos sos, SosAck ack) =>
      unawaited(NotificationService().showSosAcknowledged(sos, ack));
  @override
  void cancelled(IncomingSos alert) =>
      unawaited(NotificationService().showSosCancelled(alert));
}

class SosService extends ChangeNotifier {
  static const int _maxIncoming = 50;

  /// Repeats every [burstInterval] for the first [burstWindow], so anyone who
  /// missed the first copy soon hears another, then every [repeatInterval]
  /// until cancelled. An ACK does not slow it: it proves reception, not rescue.
  static const Duration burstInterval = Duration(minutes: 1);
  static const Duration burstWindow = Duration(minutes: 5);
  static const Duration repeatInterval = Duration(minutes: 5);

  /// A received alert, and the position it holds, is deleted once no repeat
  /// has been heard for this long.
  static const Duration alertExpiry = Duration(minutes: 60);

  /// A cancellation goes out on the network this many times, this far
  /// apart. Direct copies repeat with it until each recipient's radio
  /// confirms one, since a single copy is easily lost.
  static const int cancelSends = 3;
  static const Duration cancelInterval = Duration(minutes: 1);

  /// A responder who acknowledged an alert and has heard nothing more for
  /// this long, two missed repeats, sends its ACK again. A sender who has
  /// cancelled answers with the cancellation the responder missed.
  static const Duration quietCheckAfter = Duration(minutes: 12);

  /// How often opening a chat with an SOS sender sends the network ACK again.
  static const Duration reintroduceEvery = Duration(seconds: 30);

  /// The least time between cancellations sent again to one responder.
  static const Duration lateCancelGap = Duration(minutes: 1);

  /// An open alert heard again within this time doesn't sound again. The
  /// same SOS usually arrives twice within a second or two, on the network
  /// and by DM, and re-posting Android's looping alarm notification that
  /// soon silences it instead of sounding it again.
  static const Duration resoundGap = Duration(seconds: 30);

  /// When each open alert last sounded, by [IncomingSos.key].
  final Map<String, DateTime> _lastSounded = {};

  final List<SosHistoryRecord> _history = [];

  /// Every SOS received or sent, newest first, kept after the alert itself
  /// is gone so it can be reported afterwards. Only the user deletes them.
  List<SosHistoryRecord> get history => List.unmodifiable(_history);

  /// How long the first broadcast waits for a phone fix; repeats wait longer.
  static const Duration firstFixTimeout = Duration(seconds: 8);
  static const Duration repeatFixTimeout = Duration(seconds: 20);

  /// Retry delay for a due broadcast while the radio is disconnected.
  static const Duration disconnectedRetry = Duration(seconds: 30);

  /// How long a channel send waits for the radio's channel list to load.
  static const Duration channelsWait = Duration(seconds: 30);

  final SosTransport _transport;
  final AppSettingsService _settings;
  final PhoneLocationProvider? _phoneLocation;
  final SosAlerter? _alerter;
  final SosStore _store;
  final DateTime Function() _now;

  /// When an SOS packet of any kind was last heard on the network's channel,
  /// readable or not (10.0.0). SOS Voice pauses push-to-talk for a while
  /// after it, so members who can't read an alert still give it the air.
  DateTime? _sosTrafficAt;
  DateTime? get sosTrafficAt => _sosTrafficAt;

  OutgoingSos? _active;
  SosCancellation? _cancellation;
  final List<IncomingSos> _incoming = [];
  bool _wasConnected;
  Timer? _timer;
  Timer? _cancelTimer;

  // ---- the radio locator ----
  /// While our SOS is live and a responder is searching: a zero-hop beacon
  /// every [beaconInterval], while any searcher is: until each has stopped
  /// (a [SosPacketKind.stopLocate]) or gone quiet for [searcherTimeout].
  static const Duration beaconInterval = Duration(seconds: 5);

  /// A searcher not heard from for this long has stopped (2.5 requests, so one
  /// lost request doesn't end a search), as the SOS radio's firmware 1.8.2.
  static const Duration searcherTimeout = Duration(seconds: 150);

  /// How often a responder searching repeats its request.
  static const Duration locateRepeat = Duration(minutes: 1);

  /// Leaving the Locate screen says so now and again a little later, as one
  /// can be missed.
  static const List<Duration> stopResends = [
    Duration.zero,
    Duration(seconds: 5),
  ];

  /// How often a searcher shares what they hear, and how fresh a beacon must
  /// be to be shared.
  static const Duration reportEvery = Duration(seconds: 30);

  /// A power change goes out at once and twice more, as one can be missed.
  static const List<Duration> powerResends = [
    Duration.zero,
    Duration(seconds: 3),
    Duration(seconds: 8),
  ];

  Timer? _beaconTimer;
  int _beaconSeq = 0;

  /// The responders searching for our SOS, by key prefix, and when each last
  /// asked.
  final Map<String, DateTime> _searchers = {};

  SosLocatorSession? _locator;
  Timer? _locateTimer;
  Timer? _reportTimer;
  final List<Timer> _powerTimers = [];
  final List<Timer> _stopTimers =
      []; // "stopped searching", sent after the screen closes

  /// The search this device is running for someone's SOS, if any.
  SosLocatorSession? get locator => _locator;

  /// A responder starts searching for [alert]'s radio: asks it for beacons
  /// now, and again every [locateRepeat] while the search screen is open.
  void startLocating(IncomingSos alert) {
    if (_locator?.alertKey == alert.key) return;
    _locator = SosLocatorSession(alertKey: alert.key, id: alert.id);
    _locateTimer?.cancel();
    _locateTimer = Timer.periodic(locateRepeat, (_) => _requestBeacons());
    _reportTimer?.cancel();
    _reportTimer = Timer.periodic(
      reportEvery,
      (_) => unawaited(shareReading()),
    );
    unawaited(_requestBeacons());
    notifyListeners();
  }

  void stopLocating({bool notify = true}) {
    _locateTimer?.cancel();
    _locateTimer = null;
    _reportTimer?.cancel();
    _reportTimer = null;
    for (final t in _powerTimers) {
      t.cancel();
    }
    _powerTimers.clear();
    final session = _locator;
    if (session == null) return;
    _locator = null;
    // tell the SOS sender: when the last searcher has stopped, its beacons stop
    // and go back to full power
    _stopTimers.removeWhere((t) => !t.isActive);
    for (final delay in stopResends) {
      _stopTimers.add(Timer(delay, () => unawaited(_sayStopped(session))));
    }
    if (notify) notifyListeners();
  }

  Future<void> _sayStopped(SosLocatorSession session) async {
    if (_locator?.alertKey == session.alertKey) return; // searching again
    final alert = _incoming.where((a) => a.key == session.alertKey).firstOrNull;
    await _sendChannelPacket(
      _packet(SosPacketKind.stopLocate, session.id),
      session: alert == null ? null : _alertSession(alert),
    );
  }

  Future<void> _requestBeacons() async {
    final session = _locator;
    if (session == null) return;
    session.lastRequestAt = _now();
    session.requests++;
    notifyListeners();
    final alert = _incoming.where((a) => a.key == session.alertKey).firstOrNull;
    await _sendChannelPacket(
      _packet(SosPacketKind.locate, session.id),
      session: alert == null ? null : _alertSession(alert),
    );
  }

  /// Any searcher may set the beacons' power ([dbm] null: the radio's own),
  /// agreeing it with the others over the radio: lower as they close in, so
  /// only those near still hear them. Only a MeshCore SOS radio does this
  /// (firmware 1.6.1); its beacons then say the power they go at.
  void setBeaconPower(int? dbm) {
    final session = _locator;
    if (session == null) return;
    final power = dbm ?? SosPacket.powerFull;
    session.askedPower = power;
    session.askedAt = _now();
    for (final t in _powerTimers) {
      t.cancel();
    }
    _powerTimers.clear();
    for (final delay in powerResends) {
      _powerTimers.add(
        Timer(delay, () => unawaited(_askForPower(session, power))),
      );
    }
    notifyListeners();
  }

  Future<void> _askForPower(SosLocatorSession session, int power) async {
    if (_locator != session || session.askedPower != power) return;
    final alert = _incoming.where((a) => a.key == session.alertKey).firstOrNull;
    final packet = SosPacket(
      kind: SosPacketKind.locate,
      id: session.id,
      senderPrefix: _transport.selfPublicKey ?? Uint8List(0),
      senderName: _transport.selfName ?? '',
      power: power,
    );
    await _sendChannelPacket(
      packet,
      session: alert == null ? null : _alertSession(alert),
    );
  }

  /// Shares where this searcher is and how strong the latest beacon was, so
  /// every searcher's map can combine them. Needs a beacon heard in the last
  /// [reportEvery] that says its power, and the phone's position.
  @visibleForTesting
  Future<void> shareReading() async {
    final session = _locator;
    final latest = session?.latest;
    if (session == null ||
        latest == null ||
        latest.rssiDbm == null ||
        latest.beaconPower == null) {
      return;
    }
    final age = _now().difference(latest.at);
    if (age > reportEvery) return;
    final fix = await _phoneLocation?.currentFix(
      timeout: const Duration(seconds: 6),
    );
    if (_locator != session || fix == null || !fix.hasPosition) return;
    final reading = SosReading(
      latitude: fix.latitude!,
      longitude: fix.longitude!,
      rssiDbm: latest.rssiDbm!,
      snrDb: latest.snrDb,
      beaconPower: latest.beaconPower!,
      ageSeconds: age.inSeconds,
    );
    session.addReading(
      _selfPrefixHex ?? 'me',
      _transport.selfName ?? '',
      reading,
      latest.at,
      mine: true,
    );
    notifyListeners();
    final alert = _incoming.where((a) => a.key == session.alertKey).firstOrNull;
    await _sendChannelPacket(
      SosPacket(
        kind: SosPacketKind.report,
        id: session.id,
        senderPrefix: _transport.selfPublicKey ?? Uint8List(0),
        senderName: _transport.selfName ?? '',
        reading: reading,
      ),
      session: alert == null ? null : _alertSession(alert),
    );
  }

  String? get _selfPrefixHex {
    final k = _transport.selfPublicKey;
    return k == null || k.length < SosPacket.keyPrefixSize
        ? null
        : _hex(k.sublist(0, SosPacket.keyPrefixSize));
  }

  /// Another searcher's reading of the radio we're searching for.
  void _onReport(SosPacket packet) {
    final session = _locator;
    final r = packet.reading;
    if (session == null || session.id != packet.id || r == null) return;
    session.addReading(
      _hex(packet.senderPrefix),
      packet.senderName,
      r,
      _now().subtract(Duration(seconds: r.ageSeconds)),
    );
    notifyListeners();
  }

  /// Someone searching for our SOS: (re)start our beacons.
  void _onLocateRequest(String id, String from, Uint8List prefix) {
    if (_active?.id != id) return;
    if (_beaconTimer == null) {
      appLogger.info(
        '$from is searching nearby: sending locator beacons',
        tag: 'SOS',
      );
    }
    _searchers[_hex(prefix)] = _now();
    _beaconTimer ??= Timer.periodic(beaconInterval, (_) => _sendBeacon());
    unawaited(_sendBeacon());
  }

  /// A searcher left the Locate screen: the last one stops our beacons.
  void _onStopLocate(String id, String from, Uint8List prefix) {
    if (_active?.id != id || _beaconTimer == null) return;
    _searchers.remove(_hex(prefix));
    if (_activeSearchers() == 0) {
      appLogger.info('$from stopped searching: beacons off', tag: 'SOS');
      _stopBeacons();
    }
  }

  /// Whether our SOS is sending locator beacons, and for how many searchers.
  @visibleForTesting
  bool get beaconing => _beaconTimer != null;
  @visibleForTesting
  int get searching => _activeSearchers();

  /// How many are searching now; those quiet too long are dropped.
  int _activeSearchers() {
    final now = _now();
    _searchers.removeWhere((_, at) => now.difference(at) >= searcherTimeout);
    return _searchers.length;
  }

  Future<void> _sendBeacon() async {
    final sos = _active;
    if (sos == null || _activeSearchers() == 0) {
      _stopBeacons();
      return;
    }
    final channel = sosChannel;
    if (channel == null || !_transport.supportsChannelData) return;
    final packet = SosPacket(
      kind: SosPacketKind.beacon,
      id: sos.id,
      senderPrefix: _transport.selfPublicKey ?? Uint8List(0),
      senderName: _transport.selfName ?? '',
      seq: _beaconSeq++ & 0xFF,
    );
    final wire = _wire(packet, _ownSession(sos.id));
    if (wire == null) return;
    try {
      await _transport.sendChannelData(channel, wire, zeroHop: true);
    } catch (e) {
      appLogger.warn('Locator beacon failed: $e', tag: 'SOS');
    }
  }

  void _stopBeacons() {
    _beaconTimer?.cancel();
    _beaconTimer = null;
    _searchers.clear();
    _beaconSeq = 0;
  }

  /// A beacon from the radio being searched for.
  void _onBeacon(SosPacket packet, SosSignal signal) {
    final session = _locator;
    if (session == null || session.id != packet.id || !signal.direct) return;
    session.add(
      SosBeaconSample(
        at: _now(),
        snrDb: signal.snrDb,
        rssiDbm: signal.rssiDbm,
        seq: packet.seq,
        beaconPower: packet.power,
      ),
    );
    session.beaconPower = packet.power;
    session.beaconFull = packet.fullPower;
    session.setBy = packet.setBy;
    final asked = session.askedPower;
    if (asked != null &&
        packet.power != null &&
        (asked == SosPacket.powerFull
            ? packet.fullPower
            : packet.power == asked ||
                  packet.fullPower && asked > packet.power!)) {
      session.askedPower = null; // it took
    }
    notifyListeners();
  }

  Timer? _expiryTimer;
  bool _broadcasting = false;

  /// The keys of each SOS on an SOS2 network that this phone can read.
  final SosSessionBook _sessions = SosSessionBook();
  bool _sendingCancel = false;

  /// ACK hash of each SOS direct message sent, mapped to its recipient.
  final Map<int, String> _dmAckHashes = {};

  /// The same for direct copies of the cancellation.
  final Map<int, String> _cancelAckHashes = {};

  /// When a cancellation was last sent again, by SOS ID and responder name.
  final Map<String, DateTime> _lateCancelSentAt = {};

  /// When each quiet acknowledged alert was last asked about, by key.
  final Map<String, DateTime> _lastQuietCheck = {};
  final Map<String, DateTime> _lastReintroduced = {};

  SosService({
    required SosTransport transport,
    required AppSettingsService settings,
    PhoneLocationProvider? phoneLocation,
    SosAlerter? alerter,
    SosStore? store,
    DateTime Function()? now,
    this.retuneSendGap = defaultRetuneSendGap,
  }) : _transport = transport,
       _settings = settings,
       _phoneLocation = phoneLocation,
       _alerter = alerter,
       _store = store ?? SosStore(),
       _now = now ?? DateTime.now,
       _wasConnected = transport.isConnected {
    _transport.sosTextListener = handleInbound;
    _transport.sosDataListener = handleInboundData;
    _transport.sosAckListener = handleDeliveryAck;
    _transport.sosRepeatListener = handleHeardRepeat;
    _transport.sosRouteListener = handleHeardRoute;
    _transport.addListener(_onTransportChanged);
    _settings.addListener(_syncNetwork);
    _expiryTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      purgeExpired();
      checkQuietAlerts();
    });
  }

  PhoneLocationProvider? get phoneLocation => _phoneLocation;

  OutgoingSos? get active => _active;
  bool get isActive => _active != null;

  /// Whether ACKs and broadcasts can go out right now.
  bool get isConnected => _transport.isConnected;

  /// Whether channel alerts can be sent with the connected radio.
  bool get supportsChannelAlerts => _transport.supportsChannelData;

  /// The ID of a cancellation still waiting for the radio, if any.
  String? get pendingCancelId {
    final cancellation = _cancellation;
    return cancellation != null && cancellation.sends == 0
        ? cancellation.id
        : null;
  }

  /// Newest first. Only live alerts are kept.
  List<IncomingSos> get incoming => List.unmodifiable(_incoming);
  List<IncomingSos> get openIncoming =>
      _incoming.where((alert) => alert.isOpen).toList();

  void load() {
    _active = _store.loadOutgoing();
    _cancellation = _store.loadCancellation();
    _incoming
      ..clear()
      ..addAll(_store.loadIncoming());
    _history
      ..clear()
      ..addAll(_store.loadHistory());
    _sessions.load(_store.loadSessions());
    _retune = _store.loadRetune();
    purgeExpired();
    notifyListeners();
    _schedule();
    _scheduleCancel();
  }

  // ---------------------------------------------------------------------
  // Outgoing SOS
  // ---------------------------------------------------------------------

  /// When the next broadcast is due; overdue when it is in the past.
  DateTime? get nextBroadcastAt {
    final sos = _active;
    if (sos == null) return null;
    final last = sos.lastBroadcastAt;
    if (last == null) return sos.startedAt;
    final inBurst = last.difference(sos.startedAt) < burstWindow;
    return last.add(inBurst ? burstInterval : repeatInterval);
  }

  void _schedule([Duration? delay]) {
    _timer?.cancel();
    _timer = null;
    final next = nextBroadcastAt;
    if (next == null) return;
    final wait = delay ?? next.difference(_now());
    _timer = Timer(wait.isNegative ? Duration.zero : wait, () {
      unawaited(broadcastIfDue());
    });
  }

  /// Sends the SOS if it is due, then schedules the next one.
  @visibleForTesting
  Future<void> broadcastIfDue() async {
    final sos = _active;
    final next = nextBroadcastAt;
    if (sos == null || next == null || _broadcasting) return;
    if (_now().isBefore(next)) {
      _schedule();
      return;
    }
    if (!_transport.isConnected) {
      _schedule(disconnectedRetry);
      return;
    }
    _broadcasting = true;
    try {
      await _broadcast(sos);
    } finally {
      _broadcasting = false;
    }
    _schedule();
  }

  /// Timers can stall while the app is suspended (iOS especially), so catch
  /// up as soon as it is back in the foreground.
  void onAppResumed() {
    purgeExpired();
    checkQuietAlerts();
    unawaited(broadcastIfDue());
    unawaited(sendCancelIfDue());
  }

  void _onTransportChanged() {
    _syncNetwork();
    final connected = _transport.isConnected;
    if (connected == _wasConnected) return;
    _wasConnected = connected;
    notifyListeners();
    // Anything that fell due while disconnected goes out right away.
    if (connected) {
      unawaited(sendCancelIfDue());
      unawaited(broadcastIfDue());
    }
  }

  // ---------------------------------------------------------------------
  // Emergency network
  // ---------------------------------------------------------------------

  /// The joined emergency network, or null.
  SosNetworkCode? get network => _settings.settings.sosNetwork;

  /// Sees the network channel and receives alerts from it.
  bool get isResponder => network?.role == SosNetworkRole.responder;

  bool get isCoordinator =>
      network != null && _settings.settings.sosNetworkCoordinator;

  bool _installing = false;
  bool _noFreeSlot = false;

  /// The connected radio needs agreeing to before the network's channel goes
  /// on it (see [networkStatus]).
  bool _needsApproval = false;

  /// The network channel's slot as last read, used while the radio's
  /// channel list reloads (on every connect and after a channel change).
  int? _knownSosChannelIndex;

  /// The network's channel on the connected radio, or null when there is no
  /// network or it is not installed (yet).
  Channel? get sosChannel {
    final key = network?.key;
    if (key == null) return null;
    return _transport.allChannels
        .where((c) => listEquals(c.psk, key))
        .firstOrNull;
  }

  SosNetworkStatus get networkStatus {
    if (network == null) return SosNetworkStatus.none;
    if (!_transport.isConnected) return SosNetworkStatus.disconnected;
    if (!_transport.supportsChannelData) return SosNetworkStatus.needsFirmware;
    if (sosChannel != null) return SosNetworkStatus.ready;
    if (_needsApproval) return SosNetworkStatus.needsApproval;
    if (_noFreeSlot) return SosNetworkStatus.noFreeSlot;
    return SosNetworkStatus.installing;
  }

  /// Hides the channel from members and puts it on the radio if missing.
  void _syncNetwork() {
    final net = network;
    if (net == null) {
      _knownSosChannelIndex = null;
    } else if (_transport.channelsReady) {
      _knownSosChannelIndex = sosChannel?.index;
    }
    final hide = net != null && net.role == SosNetworkRole.member
        ? net.key
        : null;
    final current = _transport.hiddenChannelPsk;
    if (!(hide == null ? current == null : listEquals(current, hide))) {
      _transport.hiddenChannelPsk = hide;
    }
    if (net == null ||
        _installing ||
        !_transport.isConnected ||
        !_transport.channelsReady) {
      return;
    }
    final radio = _radioHex;
    if (sosChannel != null) {
      // already on this radio: agreed to, whoever put it there
      if (radio != null) _setRadioChoice(net, radio, approved: true);
      if (_needsApproval) {
        _needsApproval = false;
        notifyListeners();
      }
      return;
    }
    // Never on a radio by itself: only one the user has agreed to (a radio
    // for testing, someone else's, or one meant for another network must not
    // pick up this network's channel just by being connected).
    final approved = radio != null && _radioApproved(net, radio);
    if (_needsApproval != !approved) {
      _needsApproval = !approved;
      notifyListeners();
    }
    if (!approved) return;
    final used = _transport.allChannels.map((c) => c.index).toSet();
    final free = [
      for (var i = 0; i < _transport.maxChannels; i++)
        if (!used.contains(i)) i,
    ];
    if (free.isEmpty) {
      if (!_noFreeSlot) {
        _noFreeSlot = true;
        notifyListeners();
      }
      return;
    }
    _noFreeSlot = false;
    _installing = true;
    unawaited(() async {
      try {
        await _transport.setChannel(
          free.first,
          _radioChannelName(net),
          net.key,
        );
      } catch (e) {
        appLogger.warn('Installing SOS channel failed: $e', tag: 'SOS');
      } finally {
        _installing = false;
        notifyListeners();
      }
    }());
  }

  /// The connected radio's public key, as hex.
  String? get _radioHex {
    final key = _transport.selfPublicKey;
    if (key == null || key.isEmpty) return null;
    return key.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static String _choiceKey(SosNetworkCode net, {required bool approved}) =>
      'sos_net_${Channel.storageIdForPsk(net.key)}_'
      '${approved ? 'radios' : 'declined'}';

  List<String> _radioList(SosNetworkCode net, {required bool approved}) {
    try {
      return PrefsManager.instance.getStringList(
            _choiceKey(net, approved: approved),
          ) ??
          const [];
    } catch (_) {
      return const []; // no settings store (as in tests)
    }
  }

  bool _radioApproved(SosNetworkCode net, String radio) =>
      _radioList(net, approved: true).contains(radio);

  /// The user declined to put the network on the connected radio.
  bool get radioDeclined {
    final net = network;
    final radio = _radioHex;
    return net != null &&
        radio != null &&
        _radioList(net, approved: false).contains(radio);
  }

  void _setRadioChoice(
    SosNetworkCode net,
    String radio, {
    required bool approved,
  }) {
    final yes = {..._radioList(net, approved: true)};
    final no = {..._radioList(net, approved: false)};
    final changed = approved
        ? yes.add(radio) | no.remove(radio)
        : no.add(radio) | yes.remove(radio);
    if (!changed) return;
    try {
      final prefs = PrefsManager.instance;
      unawaited(
        prefs.setStringList(_choiceKey(net, approved: true), yes.toList()),
      );
      unawaited(
        prefs.setStringList(_choiceKey(net, approved: false), no.toList()),
      );
    } catch (_) {
      // no settings store (as in tests)
    }
  }

  /// Puts the network's channel on the connected radio, and remembers that
  /// this radio is agreed to.
  Future<void> addNetworkToRadio() async {
    final net = network;
    final radio = _radioHex;
    if (net == null || radio == null) return;
    _setRadioChoice(net, radio, approved: true);
    _syncNetwork();
    notifyListeners();
  }

  /// Keeps the network's channel off the connected radio (it's still asked
  /// about from the network's screen).
  void declineRadio() {
    final net = network;
    final radio = _radioHex;
    if (net == null || radio == null) return;
    _setRadioChoice(net, radio, approved: false);
    notifyListeners();
  }

  /// Takes the network's channel off the connected radio, and keeps it off.
  /// The network stays joined in the app, for other radios.
  Future<void> removeNetworkFromRadio() async {
    final net = network;
    final radio = _radioHex;
    final channel = sosChannel;
    if (net == null || radio == null) return;
    _setRadioChoice(net, radio, approved: false);
    if (channel != null && _transport.isConnected) {
      await _transport.deleteChannel(channel.index);
    }
    _needsApproval = true;
    notifyListeners();
  }

  /// Radio channel names hold at most 31 bytes.
  static String _radioChannelName(SosNetworkCode net) {
    var name = net.name;
    while (utf8.encode(name).length > 31) {
      name = name.substring(0, name.length - 1);
    }
    return name;
  }

  /// Creates a network with a new random key; this phone is its responder
  /// and coordinator.
  Future<SosNetworkCode> createNetwork(String name) async {
    final net = SosNetworkCode.generateSealed(name: name);
    await joinNetwork(net, coordinator: true);
    return net;
  }

  Future<void> joinNetwork(
    SosNetworkCode net, {
    bool coordinator = false,
  }) async {
    // Save first: removing the old channel triggers a sync, which must
    // already see the new network or it would put the old one back.
    final old = sosChannel;
    await _settings.joinSosNetwork(net, coordinator: coordinator);
    // joining while connected is setting up this radio: it's agreed to
    final radio = _transport.isConnected ? _radioHex : null;
    if (radio != null) _setRadioChoice(net, radio, approved: true);
    if (old != null && !listEquals(old.psk, net.key)) {
      await _transport.deleteChannel(old.index);
    }
    _syncNetwork();
    notifyListeners();
  }

  /// Removes the channel from the radio and forgets the network, together
  /// with any alerts heard on it.
  Future<void> leaveNetwork() async {
    final channel = sosChannel;
    await _settings.leaveSosNetwork();
    if (channel != null && _transport.isConnected) {
      await _transport.deleteChannel(channel.index);
    }
    final fromChannel = _incoming.where((a) => a.channelIndex != null).toList();
    for (final alert in fromChannel) {
      _incoming.remove(alert);
      _clearAlarm(alert, 'left the network');
      _receivedRecord(alert)?.end(SosHistoryOutcome.leftNetwork, _now());
      _saveHistory();
    }
    await _store.saveIncoming(_incoming);
    _syncNetwork();
    notifyListeners();
  }

  List<Contact> get emergencyContacts {
    final settings = _settings.settings;
    return _transport.contacts
        .where(
          (c) =>
              c.type == advTypeChat &&
              (settings.sosContactKeys.contains(c.publicKeyHex) ||
                  (settings.sosIncludeFavourites && c.isFavorite)),
        )
        .toList();
  }

  /// Phone GPS, then the radio's position, then the stored location.
  Future<SosFix> resolveFix({Duration timeout = repeatFixTimeout}) async {
    final phoneFix = await _phoneLocation?.currentFix(timeout: timeout);
    if (phoneFix != null && _isUsable(phoneFix.latitude, phoneFix.longitude)) {
      return phoneFix;
    }
    final radioLat = _transport.selfLatitude;
    final radioLon = _transport.selfLongitude;
    if (_isUsable(radioLat, radioLon)) {
      return SosFix(
        latitude: radioLat,
        longitude: radioLon,
        source: SosLocationSource.radio,
      );
    }
    final settings = _settings.settings;
    if (_isUsable(settings.sosLatitude, settings.sosLongitude)) {
      return SosFix(
        latitude: settings.sosLatitude,
        longitude: settings.sosLongitude,
        source: SosLocationSource.stored,
      );
    }
    return const SosFix.none();
  }

  /// The radio reports 0,0 when it has no position.
  static bool _isUsable(double? lat, double? lon) =>
      lat != null &&
      lon != null &&
      !(lat == 0 && lon == 0) &&
      lat.abs() <= 90 &&
      lon.abs() <= 180;

  /// [withKey] adds our full key, so the other side can save us as a contact.
  SosPacket _packet(
    SosPacketKind kind,
    String id, {
    SosFix? fix,
    bool withKey = false,
    SosRadio? radio,
    bool back = false,
  }) => SosPacket(
    kind: kind,
    id: id,
    senderPrefix: _transport.selfPublicKey ?? Uint8List(0),
    senderName: _transport.selfName ?? '',
    time: _now(),
    fix: fix ?? const SosFix.none(),
    senderKey: withKey ? _transport.selfPublicKey : null,
    // an SOS says what its radio is on, so a responder across a bridge on
    // another frequency knows where to retune to
    radio: radio ?? (kind == SosPacketKind.sos ? _transport.selfRadio : null),
    back: back,
  );

  Future<void> activate() async {
    if (_active != null) return;
    final sos = OutgoingSos(id: SosCodec.newId(), startedAt: _now());
    _active = sos;
    _history.insert(
      0,
      SosHistoryRecord(
        direction: SosHistoryDirection.sent,
        id: sos.id,
        senderName: _transport.selfName ?? '',
        senderKeyHex: _selfKeyHex,
        startedAt: sos.startedAt,
        lastAt: sos.startedAt,
      ),
    );
    _saveHistory();
    _dmAckHashes.clear();
    _ownSession(sos.id, create: true);
    notifyListeners();
    await _store.saveOutgoing(sos);
    await broadcastIfDue();
  }

  /// Stops the SOS at once and tells responders it was cancelled (when the
  /// radio next connects, if it is not connected now).
  Future<void> cancel() async {
    final sos = _active;
    if (sos == null) return;
    _timer?.cancel();
    _timer = null;
    _stopBeacons();
    _active = null;
    _dmAckHashes.clear();
    final cancellation = SosCancellation(
      id: sos.id,
      cancelledAt: _now(),
      responderKeys: {for (final ack in sos.acks) ?ack.senderKeyHex},
    );
    _cancellation = cancellation;
    _cancelAckHashes.clear();
    _sentRecord(sos.id)?.end(SosHistoryOutcome.cancelledByMe, _now());
    _saveHistory();
    notifyListeners();
    await _store.saveOutgoing(null);
    await _store.saveCancellation(cancellation);
    await sendCancelIfDue();
  }

  /// When the next copy of the cancellation is due, or null when done.
  DateTime? get _nextCancelAt {
    final cancellation = _cancellation;
    if (cancellation == null) return null;
    final last = cancellation.lastSentAt;
    return last == null ? cancellation.cancelledAt : last.add(cancelInterval);
  }

  void _scheduleCancel() {
    _cancelTimer?.cancel();
    _cancelTimer = null;
    final next = _nextCancelAt;
    if (next == null) return;
    final wait = next.difference(_now());
    _cancelTimer = Timer(wait.isNegative ? Duration.zero : wait, () {
      unawaited(sendCancelIfDue());
    });
  }

  /// Sends the next copy of the cancellation if one is due: on the network
  /// each time, and directly to every emergency contact and responder whose
  /// radio has not confirmed one yet. While disconnected it waits for the
  /// radio to come back.
  @visibleForTesting
  Future<void> sendCancelIfDue() async {
    final cancellation = _cancellation;
    final next = _nextCancelAt;
    if (cancellation == null || next == null || _sendingCancel) return;
    if (_now().isBefore(next)) {
      _scheduleCancel();
      return;
    }
    if (!_transport.isConnected) return;
    _sendingCancel = true;
    try {
      cancellation
        ..sends += 1
        ..lastSentAt = _now();
      final isLast = cancellation.sends >= cancelSends;
      if (isLast) _cancellation = null;
      notifyListeners();
      await _store.saveCancellation(_cancellation);

      await _sendChannelPacket(_packet(SosPacketKind.cancel, cancellation.id));
      final text = SosCodec.encodeCancel(cancellation.id, _now());
      for (final contact in _cancelRecipients(cancellation)) {
        if (cancellation.deliveredKeys.contains(contact.publicKeyHex)) {
          continue;
        }
        final hash = await _sendDirect(contact, text);
        if (hash != null && !isLast) {
          _cancelAckHashes[hash] = contact.publicKeyHex;
        }
      }
      if (isLast) _cancelAckHashes.clear();
    } finally {
      _sendingCancel = false;
    }
    _scheduleCancel();
  }

  /// Everyone who may have heard the SOS: emergency contacts, and the
  /// responders who acknowledged it, each once.
  List<Contact> _cancelRecipients(SosCancellation cancellation) {
    final byKey = {
      for (final contact in emergencyContacts) contact.publicKeyHex: contact,
    };
    for (final key in cancellation.responderKeys) {
      if (contactFor(key) case final contact?) {
        byKey.putIfAbsent(key, () => contact);
      }
    }
    return byKey.values.toList();
  }

  bool _isCancelledByMe(String id) =>
      _sentRecord(id)?.outcome == SosHistoryOutcome.cancelledByMe;

  /// An ACK for an SOS this phone already cancelled: the responder missed
  /// the cancellation, so send it again, directly when they are a contact.
  void _answerLateAck(String id, String senderName, String? senderKeyHex) {
    if (!_isCancelledByMe(id) || !_transport.isConnected) return;
    final key = '$id/$senderName';
    final last = _lateCancelSentAt[key];
    if (last != null && _now().difference(last) < lateCancelGap) return;
    _lateCancelSentAt[key] = _now();
    appLogger.info(
      'SOS $id: $senderName acknowledged after it was cancelled; '
      'sending the cancellation again',
      tag: 'SOS',
    );
    if (contactFor(senderKeyHex) case final contact?) {
      unawaited(_sendDirect(contact, SosCodec.encodeCancel(id, _now())));
    } else {
      unawaited(_sendChannelPacket(_packet(SosPacketKind.cancel, id)));
    }
  }

  Future<void> _broadcast(OutgoingSos sos) async {
    final fix = await resolveFix(
      timeout: sos.broadcastCount == 0 ? firstFixTimeout : repeatFixTimeout,
    );
    // Cancelled while waiting for a fix.
    if (!identical(sos, _active)) return;
    final now = _now();
    sos
      ..lastFix = fix
      ..lastBroadcastAt = now
      ..broadcastCount += 1;
    final record = _sentRecord(sos.id);
    if (record != null) {
      record
        ..lastAt = now
        ..count = sos.broadcastCount
        ..addPosition(now, fix);
      _saveHistory();
    }
    notifyListeners();
    await _store.saveOutgoing(sos);

    await _sendChannelPacket(
      _packet(SosPacketKind.sos, sos.id, fix: fix, withKey: true),
      session: _ownSession(sos.id, create: true),
    );

    final dmText = SosCodec.encodeSos(
      id: sos.id,
      time: now,
      fix: fix,
      node: _transport.selfName,
      maxBytes: maxTextPayloadBytesAfterFullLengthAttempts,
    );
    for (final contact in emergencyContacts) {
      // Cancelled part way through: send nothing more.
      if (!identical(sos, _active)) return;
      if (sos.isContactAcknowledged(contact.publicKeyHex, contact.name)) {
        continue;
      }
      final hash = await _sendDirect(contact, dmText);
      if (hash != null) _dmAckHashes[hash] = contact.publicKeyHex;
    }
  }

  /// The channel list is reread on every connect and after each channel
  /// change, and the network channel cannot be found until it is back.
  /// False if the radio disconnects or the list takes too long.
  Future<bool> _waitForChannels() async {
    bool ready() =>
        _transport.isConnected && _transport.channelsReady && !_installing;
    if (ready()) return true;
    final done = Completer<bool>();
    void check() {
      if (done.isCompleted) return;
      if (!_transport.isConnected) done.complete(false);
      if (ready()) done.complete(true);
    }

    _transport.addListener(check);
    addListener(check);
    try {
      return await done.future.timeout(channelsWait, onTimeout: ready);
    } finally {
      _transport.removeListener(check);
      removeListener(check);
    }
  }

  /// Sends [packet] on the network: sealed with [session] on an SOS2
  /// network, or by default with our own SOS's keys.
  Future<void> _sendChannelPacket(
    SosPacket packet, {
    SosSession? session,
  }) async {
    if (network == null || !await _waitForChannels()) return;
    final channel = sosChannel;
    if (channel == null || !_transport.supportsChannelData) return;
    final wire = _wire(packet, session ?? _ownSession(packet.id));
    if (wire == null) return;
    try {
      await _transport.sendChannelData(channel, wire);
    } catch (e) {
      appLogger.warn('SOS channel send failed: $e', tag: 'SOS');
    }
  }

  // ---- SOS2 sealing ----

  bool get _sealed => network?.isSealed ?? false;

  String? get _networkHex {
    final key = network?.networkPublicKey;
    return key == null ? null : _hex(key);
  }

  void _saveSessions() {
    _sessions.prune(_now(), activeId: _active?.id);
    unawaited(_store.saveSessions(_sessions.toJson()));
  }

  /// Our own SOS [id]'s keys on the SOS2 network, made when [create].
  SosSession? _ownSession(String id, {bool create = false}) {
    final net = network;
    final hex = _networkHex;
    if (net == null || hex == null) return null;
    final entry = _sessions.own(id, hex);
    if (entry != null) {
      entry.lastUsed = _now();
      return entry.session;
    }
    if (!create) return null;
    final session = SosSeal.newSession(net.networkPublicKey!);
    _sessions.add(
      SosSessionEntry(
        id: id,
        session: session,
        own: true,
        networkHex: hex,
        lastUsed: _now(),
      ),
    );
    _saveSessions();
    return session;
  }

  /// The keys of someone else's SOS, opened on the SOS2 network.
  SosSession? _alertSession(IncomingSos alert) {
    final ref = alert.sessionRef;
    final entry = ref == null ? null : _sessions.byRef(ref);
    if (entry == null || entry.networkHex != _networkHex) return null;
    entry.lastUsed = _now();
    return entry.session;
  }

  /// Whether network packets are sealed: an SOS2 network.
  bool get sealsNetwork => _sealed;

  /// The keys for voice about SOS [sosId]: our own live SOS's, or those of a
  /// live alert this responder has opened.
  SosSession? _sessionForSos(String sosId) {
    if (_active?.id == sosId) return _ownSession(sosId);
    for (final alert in _incoming) {
      if (alert.id != sosId) continue;
      final session = _alertSession(alert);
      if (session != null) return session;
    }
    return null;
  }

  /// A voice chunk as sent on this network: [blob] as it is on SOS1, sealed
  /// with its SOS's keys on SOS2. Null when there are no keys to seal with.
  Uint8List? sealVoice(Uint8List blob) {
    if (!_sealed) return blob;
    if (blob.length < 4) return null;
    final id = (blob[2] | (blob[3] << 8)).toRadixString(16).padLeft(4, '0');
    final session = _sessionForSos(id);
    if (session == null) return null;
    return SosSeal.sealRaw(
      [SosSeal.version, blob[1], blob[2], blob[3]],
      session,
      blob.sublist(4),
    );
  }

  /// A voice chunk heard on this network, unsealed on SOS2; null when it
  /// isn't one we can read (another SOS, a member's phone, or tampered).
  Uint8List? openVoice(Uint8List data) {
    if (!_sealed) return data;
    final head = SosSeal.header(data, fullKeyKind: null);
    if (head == null) return null;
    final entry = _sessions.byRef(head.refHex);
    if (entry == null ||
        entry.networkHex != _networkHex ||
        entry.id != head.id) {
      return null;
    }
    final body = SosSeal.openRaw(data, head.length, entry.session);
    if (body == null) return null;
    return Uint8List.fromList([1, head.kind, data[2], data[3], ...body]);
  }

  /// [packet] as sent: as it is on an SOS1 network, sealed with [session] on
  /// SOS2. Null when it has no keys to seal with (nothing is sent then).
  Uint8List? _wire(SosPacket packet, SosSession? session) {
    if (!_sealed) return packet.encode();
    if (session == null) {
      appLogger.warn(
        'SOS ${packet.id}: no keys to seal its ${packet.kind.name}, not sent',
        tag: 'SOS',
      );
      return null;
    }
    return SosSeal.sealPacket(packet, session);
  }

  /// Opens a packet heard on the SOS2 network, with the keys of an SOS we
  /// know, or, for a responder, a new SOS's own (then kept). Null for
  /// anything we can't read or that fails its check: members can't read
  /// other people's alerts, and nobody without the keys can fake an ACK.
  ({SosPacket packet, String ref})? _openSealed(Uint8List data) {
    final head = SosSeal.header(data);
    final hex = _networkHex;
    if (head == null || hex == null) return null;
    var entry = _sessions.byRef(head.refHex);
    if (entry != null && entry.networkHex != hex) entry = null;
    if (entry == null) {
      final eph = head.ephPublic;
      final secret = network?.networkSecret;
      if (eph == null || secret == null) return null;
      final session = SosSeal.responderSession(secret, eph);
      if (session == null) return null;
      final packet = SosSeal.openPacket(data, session);
      if (packet == null) return null;
      _sessions.add(
        SosSessionEntry(
          id: head.id,
          session: session,
          own: false,
          networkHex: hex,
          lastUsed: _now(),
        ),
      );
      _saveSessions();
      return (packet: packet, ref: head.refHex);
    }
    final packet = SosSeal.openPacket(data, entry.session);
    if (packet == null || packet.id != entry.id) return null;
    entry.lastUsed = _now();
    return (packet: packet, ref: head.refHex);
  }

  Future<int?> _sendDirect(Contact contact, String text) async {
    try {
      return await _transport.sendDirectText(contact, text);
    } catch (e) {
      appLogger.warn('SOS DM to ${contact.name} failed: $e', tag: 'SOS');
      return null;
    }
  }

  /// A recipient's radio confirmed one of our SOS direct messages.
  @visibleForTesting
  void handleDeliveryAck(int ackHash) {
    final cancelKey = _cancelAckHashes.remove(ackHash);
    if (cancelKey != null) {
      final cancellation = _cancellation;
      if (cancellation != null && cancellation.deliveredKeys.add(cancelKey)) {
        unawaited(_store.saveCancellation(cancellation));
      }
      return;
    }
    final sos = _active;
    final key = _dmAckHashes.remove(ackHash);
    if (sos == null || key == null) return;
    if (sos.deliveredContactKeys.add(key)) {
      final record = _sentRecord(sos.id);
      final name = contactFor(key)?.name ?? key.substring(0, 8);
      if (record != null &&
          SosHistoryRecord.addEvent(record.deliveredTo, name, _now())) {
        _saveHistory();
      }
      unawaited(_store.saveOutgoing(sos));
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------------
  // Incoming SOS, ACK and cancellation
  // ---------------------------------------------------------------------

  /// Text arriving by DM (or on a channel from another client).
  @visibleForTesting
  void handleInbound(SosInboundText inbound) {
    final ackId = SosCodec.parseAck(inbound.text);
    if (ackId != null) {
      _handleAck(ackId, inbound.senderName, inbound.senderKeyHex);
      return;
    }
    final cancelId = SosCodec.parseCancel(inbound.text);
    if (cancelId != null) {
      _handleCancel(cancelId, inbound.senderName, inbound.senderKeyHex);
      return;
    }
    final payload = SosCodec.parseSos(inbound.text);
    if (payload == null) return;
    final senderName = inbound.senderName.isNotEmpty
        ? inbound.senderName
        : (payload.node ?? '');
    _handleSos(
      id: payload.id,
      senderName: senderName,
      senderKeyHex: inbound.senderKeyHex,
      channelIndex: inbound.channelIndex,
      fix: payload.fix,
      info: payload.info,
      via: inbound.channelIndex == null ? 'DM' : 'channel text',
    );
  }

  /// A channel data packet of type [dataTypeSos].
  @visibleForTesting
  /// Our own SOS heard again, passed on by the repeater [lastHopHex].
  void handleHeardRepeat(int channelIndex, Uint8List data, String lastHopHex) {
    final sos = _active;
    if (sos == null) return;
    final networkIndex = _transport.channelsReady
        ? sosChannel?.index
        : _knownSosChannelIndex;
    if (networkIndex != channelIndex) return;
    if (_sealed) {
      // Ours if it carries our SOS's one-off key; no need to open it.
      final head = SosSeal.header(data);
      final own = _ownSession(sos.id);
      if (head == null ||
          own == null ||
          head.kind != SosPacketKind.sos.code ||
          head.id != sos.id ||
          !listEquals(head.ephPublic, own.ephPublic)) {
        return;
      }
    } else {
      final packet = SosPacket.decode(data);
      if (packet == null ||
          packet.kind != SosPacketKind.sos ||
          packet.id != sos.id) {
        return;
      }
      final self = _transport.selfPublicKey;
      if (self == null ||
          self.length < SosPacket.keyPrefixSize ||
          !listEquals(
            self.sublist(0, SosPacket.keyPrefixSize),
            packet.senderPrefix,
          )) {
        return;
      }
    }
    sos.heardRepeats += 1;
    sos.repeaters[lastHopHex] = (sos.repeaters[lastHopHex] ?? 0) + 1;
    notifyListeners();
    unawaited(_store.saveOutgoing(sos));
  }

  /// Routes of SOS copies heard before the alert itself was decoded (the raw
  /// copy reaches the app just ahead of it), by alert key.
  final Map<String, ({DateTime at, Map<String, int> routes})> _pendingRoutes =
      {};

  /// Someone else's SOS heard on the network: remember the way it came, so a
  /// responder can see whether it reached them straight from the sender's
  /// radio (Locate can hear its beacons) or only through repeaters, perhaps
  /// across a bridge to another frequency (it can't).
  void handleHeardRoute(int channelIndex, Uint8List data, List<String> path) {
    if (!isResponder) return;
    final networkIndex = _transport.channelsReady
        ? sosChannel?.index
        : _knownSosChannelIndex;
    if (networkIndex != channelIndex) return;
    final packet = _sealed ? _openSealed(data)?.packet : SosPacket.decode(data);
    if (packet == null || packet.kind != SosPacketKind.sos) return;
    final self = _transport.selfPublicKey;
    if (self != null &&
        self.length >= SosPacket.keyPrefixSize &&
        listEquals(
          self.sublist(0, SosPacket.keyPrefixSize),
          packet.senderPrefix,
        )) {
      return; // our own SOS: counted by handleHeardRepeat
    }
    final key = IncomingSos.keyFor(packet.senderName, packet.id);
    final route = path.join(',');
    final alert = _incoming.where((a) => a.key == key).firstOrNull;
    if (alert == null) {
      final now = _now();
      _pendingRoutes.removeWhere(
        (_, p) => now.difference(p.at) > const Duration(minutes: 1),
      );
      final pending = _pendingRoutes.putIfAbsent(
        key,
        () => (at: now, routes: <String, int>{}),
      );
      pending.routes[route] = (pending.routes[route] ?? 0) + 1;
      return;
    }
    alert.routes[route] = (alert.routes[route] ?? 0) + 1;
    notifyListeners();
    unawaited(_store.saveIncoming(_incoming));
  }

  /// [route] (see [IncomingSos.routes]) as repeater names, nearest the sender
  /// first.
  List<String> routeNames(String route) =>
      IncomingSos.routeHops(route).map(repeaterName).toList();

  /// A repeater heard passing on our SOS: its name when it is a contact
  /// whose key starts with [hashHex], else the hash itself.
  String repeaterName(String hashHex) {
    for (final contact in _transport.contacts) {
      if (contact.type == advTypeRepeater &&
          contact.publicKeyHex.toLowerCase().startsWith(hashHex)) {
        return contact.name;
      }
    }
    return hashHex;
  }

  void handleInboundData(
    int channelIndex,
    Uint8List data, [
    SosSignal signal = SosSignal.unknown,
  ]) {
    // Only the network's own channel carries alerts.
    final networkIndex = _transport.channelsReady
        ? sosChannel?.index
        : _knownSosChannelIndex;
    if (networkIndex != channelIndex) return;
    // Something is happening on the network, even if this phone can't read it
    // (a member can't read other people's alerts): push-to-talk gives way.
    _sosTrafficAt = _now();
    notifyListeners();
    // An SOS2 network takes only sealed packets, so nobody can slip in an
    // unsealed one; an SOS1 network takes only SOS1 packets.
    String? sessionRef;
    final SosPacket? packet;
    if (_sealed) {
      final opened = _openSealed(data);
      packet = opened?.packet;
      sessionRef = opened?.ref;
    } else {
      packet = SosPacket.decode(data);
    }
    if (packet == null) return;
    // Members only hear ACKs for their own SOS, and requests to locate it (and
    // to stop).
    if (!isResponder &&
        packet.kind != SosPacketKind.ack &&
        packet.kind != SosPacketKind.locate &&
        packet.kind != SosPacketKind.stopLocate) {
      return;
    }
    final self = _transport.selfPublicKey;
    if (self != null &&
        self.length >= SosPacket.keyPrefixSize &&
        listEquals(
          self.sublist(0, SosPacket.keyPrefixSize),
          packet.senderPrefix,
        )) {
      return; // Our own packet, repeated back to us.
    }
    var senderKeyHex = _contactKeyForPrefix(packet.senderPrefix);
    // Someone in an SOS with us: save them as a contact so we can message.
    final fullKey = packet.senderKey;
    final involvesUs =
        packet.kind == SosPacketKind.sos ||
        (packet.kind == SosPacketKind.ack &&
            (_active?.id == packet.id || _isCancelledByMe(packet.id)));
    if (fullKey != null && involvesUs) {
      final known = _contactKeyForKey(fullKey);
      if (known == null) {
        senderKeyHex = _hex(fullKey);
        unawaited(_addContact(fullKey, packet.senderName));
      } else {
        senderKeyHex = known;
      }
    }
    switch (packet.kind) {
      case SosPacketKind.sos:
        _handleSos(
          id: packet.id,
          senderName: packet.senderName,
          senderKeyHex: senderKeyHex,
          channelIndex: channelIndex,
          fix: packet.fix,
          info: packet.info,
          via: 'network',
          sessionRef: sessionRef,
          radio: packet.radio,
        );
      case SosPacketKind.ack:
        _handleAck(packet.id, packet.senderName, senderKeyHex);
      case SosPacketKind.cancel:
        _handleCancel(packet.id, packet.senderName, senderKeyHex);
      case SosPacketKind.locate:
        _onLocateRequest(packet.id, packet.senderName, packet.senderPrefix);
      case SosPacketKind.stopLocate:
        _onStopLocate(packet.id, packet.senderName, packet.senderPrefix);
      case SosPacketKind.beacon:
        _onBeacon(packet, signal);
      case SosPacketKind.report:
        _onReport(packet);
      case SosPacketKind.retune:
        _onRetune(packet);
    }
  }

  /// Another responder retuned for an SOS, or came back.
  void _onRetune(SosPacket packet) {
    final radio = packet.radio;
    if (radio == null) return;
    var changed = false;
    for (final alert in _incoming.where((a) => a.id == packet.id)) {
      if (packet.back) {
        changed |= alert.retunedResponders.remove(packet.senderName) != null;
      } else {
        alert.retunedResponders[packet.senderName] = radio;
        changed = true;
      }
    }
    if (!changed) return;
    appLogger.info(
      packet.back
          ? '${packet.senderName} is back on ${radio.label} (SOS #${packet.id})'
          : '${packet.senderName} retuned to ${radio.label} for SOS '
                '#${packet.id}, may be unreachable',
      tag: 'SOS',
    );
    unawaited(_store.saveIncoming(_incoming));
    notifyListeners();
  }

  // ---------------------------------------------------------------------
  // Retune: a responder moves their own radio to an SOS sender's settings
  // ---------------------------------------------------------------------

  /// Time for the note to other responders to go out before the radio
  /// leaves their frequency: sending only queues it on the radio.
  static const Duration defaultRetuneSendGap = Duration(seconds: 5);
  final Duration retuneSendGap;

  SosRetune? _retune;

  /// While this phone's radio is retuned to an SOS sender's settings: the
  /// settings to go back to. Nothing goes back by itself.
  SosRetune? get retune => _retune;

  /// [alert]'s sender is on radio settings ours can't hear (another frequency,
  /// say across a bridge): Retune would move ours there.
  bool canRetuneTo(IncomingSos alert) {
    final theirs = alert.senderRadio;
    final ours = _transport.selfRadio;
    return theirs != null && ours != null && !ours.canHear(theirs);
  }

  /// Moves our radio to [alert]'s sender's settings, when the responder knows
  /// they're within coverage on that side. Tells this mesh's responders first,
  /// as afterwards we can't reach them. False if the radio refused.
  Future<bool> retuneTo(IncomingSos alert) async {
    final target = alert.senderRadio;
    final current = _transport.selfRadio;
    if (target == null || current == null || !isConnected) return false;
    // Retuned already (to another SOS): go back to the original in the end.
    final from = _retune?.from ?? current;
    await _sendChannelPacket(
      _packet(SosPacketKind.retune, alert.id, radio: target),
      session: _alertSession(alert),
    );
    await Future<void>.delayed(retuneSendGap);
    if (!await _transport.setRadio(target)) {
      appLogger.warn('Radio refused ${target.label} for retune', tag: 'SOS');
      await _sendChannelPacket(
        _packet(SosPacketKind.retune, alert.id, radio: current, back: true),
        session: _alertSession(alert),
      );
      return false;
    }
    _retune = SosRetune(
      alertKey: alert.key,
      alertId: alert.id,
      senderName: alert.senderName,
      from: from,
      to: target,
      at: _now(),
    );
    appLogger.info(
      'Retuned from ${from.label} to ${target.label} for '
      '${alert.senderName}\'s SOS #${alert.id}',
      tag: 'SOS',
    );
    unawaited(_store.saveRetune(_retune));
    notifyListeners();
    return true;
  }

  /// Back to the radio settings we retuned from, and tells the responders
  /// there we're reachable again. False if the radio refused.
  Future<bool> retuneBack() async {
    final retune = _retune;
    if (retune == null || !isConnected) return false;
    if (!await _transport.setRadio(retune.from)) {
      appLogger.warn(
        'Radio refused ${retune.from.label} going back',
        tag: 'SOS',
      );
      return false;
    }
    _retune = null;
    unawaited(_store.saveRetune(null));
    notifyListeners();
    appLogger.info('Back on ${retune.from.label}', tag: 'SOS');
    final alert = _incoming.where((a) => a.key == retune.alertKey).firstOrNull;
    await _sendChannelPacket(
      _packet(
        SosPacketKind.retune,
        retune.alertId,
        radio: retune.from,
        back: true,
      ),
      session: alert == null ? null : _alertSession(alert),
    );
    return true;
  }

  String? _contactKeyForPrefix(Uint8List prefix) => _transport.contacts
      .where(
        (c) =>
            c.publicKey.length >= prefix.length &&
            listEquals(c.publicKey.sublist(0, prefix.length), prefix),
      )
      .firstOrNull
      ?.publicKeyHex;

  String? _contactKeyForKey(Uint8List key) => _transport.contacts
      .where((c) => listEquals(c.publicKey, key))
      .firstOrNull
      ?.publicKeyHex;

  static String _hex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  Future<void> _addContact(Uint8List key, String name) async {
    try {
      await _transport.addContact(key, name);
      notifyListeners();
    } catch (e) {
      appLogger.warn('Saving SOS contact $name failed: $e', tag: 'SOS');
    }
  }

  /// The saved contact for [keyHex], or null.
  Contact? contactFor(String? keyHex) => keyHex == null
      ? null
      : _transport.contacts.where((c) => c.publicKeyHex == keyHex).firstOrNull;

  void _handleAck(String id, String senderName, String? senderKeyHex) {
    var changed = false;
    final sos = _active;
    if (sos != null && sos.id == id) {
      // The same responder often ACKs on the channel and by DM.
      final index = sos.acks.indexWhere((ack) => ack.senderName == senderName);
      if (index == -1) {
        final ack = SosAck(
          senderName: senderName,
          senderKeyHex: senderKeyHex,
          receivedAt: _now(),
        );
        sos.acks.add(ack);
        _alerter?.acknowledged(sos, ack);
        changed = true;
        final record = _sentRecord(id);
        if (record != null &&
            SosHistoryRecord.addEvent(
              record.acks,
              senderName,
              ack.receivedAt,
            )) {
          _saveHistory();
        }
      } else if (sos.acks[index].senderKeyHex == null && senderKeyHex != null) {
        final known = sos.acks[index];
        sos.acks[index] = SosAck(
          senderName: known.senderName,
          senderKeyHex: senderKeyHex,
          receivedAt: known.receivedAt,
        );
        changed = true;
      }
      if (changed) unawaited(_store.saveOutgoing(sos));
    } else {
      _answerLateAck(id, senderName, senderKeyHex);
    }
    var incomingChanged = false;
    for (final alert in _incoming) {
      if (alert.id == id && alert.ackedBy.add(senderName)) {
        incomingChanged = true;
        final record = _receivedRecord(alert);
        if (record != null &&
            SosHistoryRecord.addEvent(record.acks, senderName, _now())) {
          _saveHistory();
        }
      }
    }
    if (incomingChanged) unawaited(_store.saveIncoming(_incoming));
    if (changed || incomingChanged) notifyListeners();
  }

  /// Only the original sender can cancel; the alert and its position are
  /// deleted.
  void _handleCancel(String id, String senderName, String? senderKeyHex) {
    final alert = _incoming
        .where(
          (a) =>
              a.id == id &&
              (a.senderName == senderName ||
                  (senderKeyHex != null && a.senderKeyHex == senderKeyHex)),
        )
        .firstOrNull;
    if (alert == null) return;
    _incoming.remove(alert);
    _clearAlarm(alert, 'cancelled by the sender');
    _receivedRecord(alert)?.end(SosHistoryOutcome.cancelledBySender, _now());
    _saveHistory();
    _alerter?.cancelled(alert);
    unawaited(_store.saveIncoming(_incoming));
    notifyListeners();
  }

  void _handleSos({
    required String id,
    required String senderName,
    required String? senderKeyHex,
    required int? channelIndex,
    required SosFix fix,
    required String via,
    String? info,
    String? sessionRef,
    SosRadio? radio,
  }) {
    final key = IncomingSos.keyFor(senderName, id);
    final now = _now();
    var alert = _incoming.where((a) => a.key == key).firstOrNull;
    final isNew = alert == null;
    if (alert != null) {
      final existing = alert;
      existing
        ..lastSeen = now
        ..receivedCount += 1
        ..senderKeyHex ??= senderKeyHex
        ..channelIndex ??= channelIndex
        ..sessionRef = sessionRef ?? existing.sessionRef
        ..senderRadio = radio ?? existing.senderRadio;
      if (fix.hasPosition || !existing.fix.hasPosition) existing.fix = fix;
      if (info != null) existing.info = info;
      // Dismissed without answering: the sender is still calling, so it comes
      // back. One already acknowledged stays put aside until Show again.
      if (existing.dismissed && !existing.ackSent) existing.dismissed = false;
    } else {
      alert = IncomingSos(
        id: id,
        senderName: senderName,
        senderKeyHex: senderKeyHex,
        channelIndex: channelIndex,
        firstSeen: now,
        lastSeen: now,
        fix: fix,
        info: info,
        sessionRef: sessionRef,
        senderRadio: radio,
      );
      _incoming.insert(0, alert);
      _trimIncoming();
    }
    if (_pendingRoutes.remove(key) case final pending?) {
      final routes = alert.routes;
      pending.routes.forEach((route, count) {
        routes[route] = (routes[route] ?? 0) + count;
      });
    }
    _recordHeard(alert, now, fix, via, info);

    // A repeat of a still-open alert sounds again, unless it sounded moments
    // ago: then the alarm is still going, and sounding it again would stop it.
    final last = _lastSounded[key];
    final sound =
        alert.isOpen &&
        (isNew || last == null || now.difference(last) >= resoundGap);
    if (sound) {
      _lastSounded[key] = now;
      _alerter?.alert(alert);
    }
    appLogger.info(
      'SOS #$id from $senderName by $via: '
      '${isNew ? 'new alert' : 'repeat ${alert.receivedCount}'}, '
      '${sound ? 'alarm sounded' : (alert.isOpen ? 'alarm already sounding, not re-sounded' : 'acknowledged or dismissed')}'
      '${info != null ? ', info "$info"' : ''}',
      tag: 'SOS',
    );
    unawaited(_store.saveIncoming(_incoming));
    notifyListeners();
  }

  // ---------------------------------------------------------------------
  // History
  // ---------------------------------------------------------------------

  String? get _selfKeyHex => _transport.selfPublicKey
      ?.map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();

  SosHistoryRecord? _sentRecord(String id) => _history
      .where((r) => r.direction == SosHistoryDirection.sent && r.id == id)
      .firstOrNull;

  /// The live record of [alert]; a new alert after one ended gets its own.
  SosHistoryRecord? _receivedRecord(IncomingSos alert) => _history
      .where(
        (r) =>
            r.direction == SosHistoryDirection.received &&
            r.isOngoing &&
            r.id == alert.id &&
            r.senderName == alert.senderName,
      )
      .firstOrNull;

  void _recordHeard(
    IncomingSos alert,
    DateTime now,
    SosFix fix,
    String via,
    String? info,
  ) {
    var record = _receivedRecord(alert);
    if (record == null) {
      record = SosHistoryRecord(
        direction: SosHistoryDirection.received,
        id: alert.id,
        senderName: alert.senderName,
        startedAt: now,
        lastAt: now,
      );
      _history.insert(0, record);
    }
    record
      ..lastAt = now
      ..count += 1
      ..senderKeyHex ??= alert.senderKeyHex
      ..heardVia.add(via)
      ..addPosition(now, fix);
    if (info != null) record.info = info;
    _saveHistory();
  }

  void _saveHistory() => unawaited(_store.saveHistory(_history));

  Future<void> deleteHistory(SosHistoryRecord record) async {
    _history.remove(record);
    notifyListeners();
    await _store.saveHistory(_history);
  }

  /// Deletes every finished record; live ones stay until they end.
  Future<void> deleteFinishedHistory() async {
    _history.removeWhere((r) => !r.isOngoing);
    notifyListeners();
    await _store.saveHistory(_history);
  }

  void _clearAlarm(IncomingSos alert, String reason) {
    _lastSounded.remove(alert.key);
    _alerter?.clear(alert);
    appLogger.info(
      'SOS #${alert.id} from ${alert.senderName}: alarm cleared ($reason)',
      tag: 'SOS',
    );
  }

  /// Drops the oldest acknowledged alerts; open ones are never dropped.
  void _trimIncoming() {
    for (
      var i = _incoming.length - 1;
      i >= 0 && _incoming.length > _maxIncoming;
      i--
    ) {
      if (!_incoming[i].isOpen) _incoming.removeAt(i);
    }
  }

  /// Deletes alerts not heard for [alertExpiry], positions included.
  @visibleForTesting
  void purgeExpired() {
    final cutoff = _now().subtract(alertExpiry);
    final expired = _incoming
        .where((a) => a.lastSeen.isBefore(cutoff))
        .toList();
    if (expired.isEmpty) return;
    for (final alert in expired) {
      _incoming.remove(alert);
      _clearAlarm(alert, 'expired');
      _receivedRecord(alert)?.end(
        alert.dismissed
            ? SosHistoryOutcome.dismissed
            : SosHistoryOutcome.expired,
        _now(),
      );
      _saveHistory();
    }
    unawaited(_store.saveIncoming(_incoming));
    notifyListeners();
  }

  /// Replies on the channel the alert arrived on, and by DM when the sender
  /// is a known contact. Does nothing while disconnected, so the alert is
  /// never marked answered when no ACK could go out. The alert stays (so the
  /// responder keeps the position) until cancelled or expired.
  Future<void> acknowledge(IncomingSos alert) async {
    if (!_transport.isConnected) return;
    alert.ackSent = true;
    _clearAlarm(alert, 'acknowledged');
    _receivedRecord(alert)?.ackSentAt ??= _now();
    _saveHistory();
    notifyListeners();
    await _store.saveIncoming(_incoming);
    await _sendAck(alert);
  }

  /// Sends the ACK again for each acknowledged alert not heard for
  /// [quietCheckAfter], then at most once per that period. A sender who
  /// cancelled answers with the cancellation this phone missed; one still
  /// sending just hears the same ACK again.
  @visibleForTesting
  void checkQuietAlerts() {
    if (!_transport.isConnected) return;
    final now = _now();
    for (final alert in _incoming) {
      if (!alert.ackSent) continue;
      final asked = _lastQuietCheck[alert.key];
      final since = asked != null && asked.isAfter(alert.lastSeen)
          ? asked
          : alert.lastSeen;
      if (now.difference(since) < quietCheckAfter) continue;
      _lastQuietCheck[alert.key] = now;
      appLogger.info(
        'SOS ${alert.id} from ${alert.senderName}: nothing heard for '
        '${now.difference(alert.lastSeen).inMinutes} min, sending the ACK '
        'again to check it is still open',
        tag: 'SOS',
      );
      unawaited(_sendAck(alert));
    }
  }

  /// Before messaging an SOS sender: the network ACK again, as it is what
  /// carries this phone's key. A radio that missed it can't read a message
  /// from a phone it doesn't know: the message arrives but never shows.
  /// Only for an acknowledged alert, and at most every [reintroduceEvery].
  Future<void> reintroduceBeforeMessage(IncomingSos alert) async {
    if (!_transport.isConnected || !alert.ackSent) return;
    final now = _now();
    final last = _lastReintroduced[alert.key];
    if (last != null && now.difference(last) < reintroduceEvery) return;
    _lastReintroduced[alert.key] = now;
    appLogger.info(
      'SOS ${alert.id} from ${alert.senderName}: sending the ACK again before '
      'a message, so the sender knows this phone',
      tag: 'SOS',
    );
    await _sendNetworkAck(alert);
  }

  Future<void> _sendAck(IncomingSos alert) async {
    await _sendNetworkAck(alert);
    final contact = _transport.contacts
        .where((c) => c.publicKeyHex == alert.senderKeyHex)
        .firstOrNull;
    if (contact != null) {
      await _sendDirect(contact, SosCodec.encodeAck(alert.id));
    }
  }

  /// The ACK on the channel the alert arrived on, with this phone's key.
  Future<void> _sendNetworkAck(IncomingSos alert) async {
    final channelIndex = alert.channelIndex;
    final channel = channelIndex == null
        ? (alert.senderKeyHex == null ? sosChannel : null)
        : _transport.allChannels
              .where((c) => c.index == channelIndex)
              .firstOrNull;
    if (channel != null && _transport.supportsChannelData) {
      final wire = _wire(
        _packet(SosPacketKind.ack, alert.id, withKey: true),
        _alertSession(alert),
      );
      if (wire == null) return;
      try {
        await _transport.sendChannelData(channel, wire);
      } catch (e) {
        appLogger.warn('SOS ACK channel send failed: $e', tag: 'SOS');
      }
    }
  }

  /// Puts the alert aside without replying: the alarm stops and it leaves the
  /// screen, but it's kept (with its position, acknowledgement and Locate) so
  /// [showAgain] brings it straight back, rather than waiting for the sender's
  /// next repeat, which can be 5 minutes away. It's deleted when the sender
  /// cancels or it expires, as any alert is.
  Future<void> dismiss(IncomingSos alert) async {
    alert.dismissed = true;
    _clearAlarm(alert, 'dismissed');
    notifyListeners();
    await _store.saveIncoming(_incoming);
  }

  /// Brings a dismissed alert back, as it was.
  Future<void> showAgain(IncomingSos alert) async {
    if (!alert.dismissed) return;
    alert.dismissed = false;
    appLogger.info(
      'SOS #${alert.id} from ${alert.senderName}: shown again',
      tag: 'SOS',
    );
    notifyListeners();
    await _store.saveIncoming(_incoming);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _cancelTimer?.cancel();
    _expiryTimer?.cancel();
    _beaconTimer?.cancel();
    _locateTimer?.cancel();
    for (final t in _stopTimers) {
      t.cancel();
    }
    _transport.removeListener(_onTransportChanged);
    _settings.removeListener(_syncNetwork);
    _transport.sosTextListener = null;
    _transport.sosDataListener = null;
    _transport.sosAckListener = null;
    _transport.sosRepeatListener = null;
    _transport.sosRouteListener = null;
    super.dispose();
  }
}

/// One beacon heard from the radio being searched for.
class SosBeaconSample {
  final DateTime at;
  final double snrDb;
  final int? rssiDbm;
  final int? seq;

  /// The power the beacon was sent at, when its radio says (MeshCore SOS
  /// firmware 1.6.1); null from a phone app or an older radio.
  final int? beaconPower;

  const SosBeaconSample({
    required this.at,
    required this.snrDb,
    this.rssiDbm,
    this.seq,
    this.beaconPower,
  });

  /// The strength the meter shows: RSSI when known (it tracks distance more
  /// smoothly), otherwise SNR.
  double get strength => rssiDbm?.toDouble() ?? snrDb;
}

/// A searcher on the shared map: their readings, newest last.
class SosSearcher {
  final String who;
  String name;
  final bool mine;
  final List<SosSearchReading> readings = [];

  SosSearcher({required this.who, required this.name, this.mine = false});

  SosSearchReading? get latest => readings.isEmpty ? null : readings.last;
}

/// A responder's search for the radio that sent an SOS: the beacons heard,
/// newest last, and whether the signal is getting stronger.
class SosLocatorSession {
  final String alertKey;
  final String id;
  final List<SosBeaconSample> samples = [];
  DateTime? lastRequestAt;
  int requests = 0;

  SosLocatorSession({required this.alertKey, required this.id});

  static const int _keep = 120;

  /// The beacons' power as the latest beacon says (null: its radio doesn't
  /// say, so it can't be changed), whether that is the radio's own, and who
  /// last set it.
  int? beaconPower;
  bool beaconFull = false;
  String setBy = '';

  /// A power this searcher asked for that no beacon has confirmed yet.
  int? askedPower;
  DateTime? askedAt;

  /// Every searcher's readings (this one's too), by key prefix: where they
  /// were and what they heard, for the shared map.
  final Map<String, SosSearcher> searchers = {};

  static const int _readingsKept = 12;

  void addReading(
    String who,
    String name,
    SosReading r,
    DateTime at, {
    bool mine = false,
  }) {
    final s = searchers.putIfAbsent(
      who,
      () => SosSearcher(who: who, name: name, mine: mine),
    );
    s.name = name.isEmpty ? s.name : name;
    s.readings.add(
      SosSearchReading(
        who: who,
        latitude: r.latitude,
        longitude: r.longitude,
        rssiDbm: r.rssiDbm,
        beaconPower: r.beaconPower,
        at: at,
      ),
    );
    if (s.readings.length > _readingsKept) s.readings.removeAt(0);
  }

  /// All searchers' readings together.
  List<SosSearchReading> get readings => [
    for (final s in searchers.values) ...s.readings,
  ];

  /// Where the readings agree the radio is, once they come from two places.
  SosSearchEstimate? estimate({DateTime? now}) =>
      SosSearch.estimate(readings, now: now);

  void add(SosBeaconSample sample) {
    samples.add(sample);
    if (samples.length > _keep) samples.removeAt(0);
  }

  SosBeaconSample? get latest => samples.isEmpty ? null : samples.last;

  /// Stronger (positive) or weaker (negative) than a short while ago: the
  /// mean of the last three beacons against the three before them, so one
  /// odd reading doesn't swing it. Null until there are enough.
  double? get trend {
    if (samples.length < 4) return null;
    final n = samples.length;
    final recent = samples.sublist(n - 3);
    final before = samples.sublist(n >= 6 ? n - 6 : 0, n - 3);
    double mean(List<SosBeaconSample> s) =>
        s.map((e) => e.strength).reduce((a, b) => a + b) / s.length;
    return mean(recent) - mean(before);
  }
}
