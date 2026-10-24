import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../helpers/sos_codec.dart';
import '../helpers/sos_network_code.dart';
import '../models/channel.dart';
import '../models/contact.dart';
import '../models/sos_alert.dart';
import '../models/sos_history.dart';
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
    void Function(int channelIndex, Uint8List payload)? listener,
  );
  set sosAckListener(void Function(int ackHash)? listener);

  Future<void> sendChannelData(Channel channel, Uint8List payload);

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
    void Function(int channelIndex, Uint8List payload)? listener,
  ) => connector.sosDataListener = listener;
  @override
  set sosAckListener(void Function(int ackHash)? listener) =>
      connector.sosAckListener = listener;
  @override
  Future<void> sendChannelData(Channel channel, Uint8List payload) =>
      connector.sendSosChannelData(channel.index, payload);
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

  OutgoingSos? _active;
  SosCancellation? _cancellation;
  final List<IncomingSos> _incoming = [];
  bool _wasConnected;
  Timer? _timer;
  Timer? _cancelTimer;
  Timer? _expiryTimer;
  bool _broadcasting = false;
  bool _sendingCancel = false;

  /// ACK hash of each SOS direct message sent, mapped to its recipient.
  final Map<int, String> _dmAckHashes = {};

  /// The same for direct copies of the cancellation.
  final Map<int, String> _cancelAckHashes = {};

  /// When a cancellation was last sent again, by SOS ID and responder name.
  final Map<String, DateTime> _lateCancelSentAt = {};

  /// When each quiet acknowledged alert was last asked about, by key.
  final Map<String, DateTime> _lastQuietCheck = {};

  SosService({
    required SosTransport transport,
    required AppSettingsService settings,
    PhoneLocationProvider? phoneLocation,
    SosAlerter? alerter,
    SosStore? store,
    DateTime Function()? now,
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
        !_transport.channelsReady ||
        sosChannel != null) {
      return;
    }
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
    final net = SosNetworkCode(
      role: SosNetworkRole.responder,
      key: SosNetworkCode.generateKey(),
      name: name,
    );
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
  }) => SosPacket(
    kind: kind,
    id: id,
    senderPrefix: _transport.selfPublicKey ?? Uint8List(0),
    senderName: _transport.selfName ?? '',
    time: _now(),
    fix: fix ?? const SosFix.none(),
    senderKey: withKey ? _transport.selfPublicKey : null,
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

  Future<void> _sendChannelPacket(SosPacket packet) async {
    if (network == null || !await _waitForChannels()) return;
    final channel = sosChannel;
    if (channel == null || !_transport.supportsChannelData) return;
    try {
      await _transport.sendChannelData(channel, packet.encode());
    } catch (e) {
      appLogger.warn('SOS channel send failed: $e', tag: 'SOS');
    }
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
  void handleInboundData(int channelIndex, Uint8List data) {
    // Only the network's own channel carries alerts.
    final networkIndex = _transport.channelsReady
        ? sosChannel?.index
        : _knownSosChannelIndex;
    if (networkIndex != channelIndex) return;
    final packet = SosPacket.decode(data);
    if (packet == null) return;
    // Members only hear ACKs for their own SOS.
    if (!isResponder && packet.kind != SosPacketKind.ack) return;
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
        );
      case SosPacketKind.ack:
        _handleAck(packet.id, packet.senderName, senderKeyHex);
      case SosPacketKind.cancel:
        _handleCancel(packet.id, packet.senderName, senderKeyHex);
    }
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
        ..channelIndex ??= channelIndex;
      if (fix.hasPosition || !existing.fix.hasPosition) existing.fix = fix;
      if (info != null) existing.info = info;
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
      );
      _incoming.insert(0, alert);
      _trimIncoming();
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
      '${sound ? 'alarm sounded' : (alert.isOpen ? 'alarm already sounding, not re-sounded' : 'already acknowledged')}'
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
      _receivedRecord(alert)?.end(SosHistoryOutcome.expired, _now());
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

  Future<void> _sendAck(IncomingSos alert) async {
    final channelIndex = alert.channelIndex;
    final channel = channelIndex == null
        ? (alert.senderKeyHex == null ? sosChannel : null)
        : _transport.allChannels
              .where((c) => c.index == channelIndex)
              .firstOrNull;
    if (channel != null && _transport.supportsChannelData) {
      try {
        await _transport.sendChannelData(
          channel,
          _packet(SosPacketKind.ack, alert.id, withKey: true).encode(),
        );
      } catch (e) {
        appLogger.warn('SOS ACK channel send failed: $e', tag: 'SOS');
      }
    }
    final contact = _transport.contacts
        .where((c) => c.publicKeyHex == alert.senderKeyHex)
        .firstOrNull;
    if (contact != null) {
      await _sendDirect(contact, SosCodec.encodeAck(alert.id));
    }
  }

  /// Deletes the alert and its position from this phone without replying.
  Future<void> dismiss(IncomingSos alert) async {
    _incoming.remove(alert);
    _clearAlarm(alert, 'dismissed');
    _receivedRecord(alert)?.end(SosHistoryOutcome.dismissed, _now());
    _saveHistory();
    notifyListeners();
    await _store.saveIncoming(_incoming);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _cancelTimer?.cancel();
    _expiryTimer?.cancel();
    _transport.removeListener(_onTransportChanged);
    _settings.removeListener(_syncNetwork);
    _transport.sosTextListener = null;
    _transport.sosDataListener = null;
    _transport.sosAckListener = null;
    super.dispose();
  }
}
