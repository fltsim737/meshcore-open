import 'dart:async';

import 'package:flutter/foundation.dart';

import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../helpers/sos_codec.dart';
import '../models/channel.dart';
import '../models/contact.dart';
import '../models/message.dart';
import '../models/sos_alert.dart';
import '../storage/sos_store.dart';
import '../utils/app_logger.dart';
import 'app_settings_service.dart';
import 'message_retry_service.dart';
import 'notification_service.dart';
import 'sos_location_service.dart';

/// The parts of the connector the SOS feature uses, so it can be faked.
/// Notifies when connection state or message delivery may have changed.
abstract class SosTransport implements Listenable {
  bool get isConnected;
  String? get selfName;
  double? get selfLatitude;
  double? get selfLongitude;
  List<Channel> get channels;
  List<Contact> get contacts;
  set sosTextListener(void Function(SosInboundText inbound)? listener);
  Future<void> sendChannelText(Channel channel, String text);
  Future<void> sendDirectText(Contact contact, String text);

  /// Whether the contact's radio confirmed any DM of SOS [sosId].
  bool hasDeliveredSos(Contact contact, String sosId);

  /// Whether a DM of SOS [sosId] to the contact is still being retried.
  bool hasPendingSos(Contact contact, String sosId);

  /// Stops retrying every queued or in-flight DM of SOS [sosId].
  void abandonPendingSos(String sosId);
}

class ConnectorSosTransport implements SosTransport {
  final MeshCoreConnector connector;
  final MessageRetryService retryService;

  ConnectorSosTransport(this.connector, this.retryService);

  @override
  bool get isConnected => connector.isConnected;
  @override
  String? get selfName => connector.selfName;
  @override
  double? get selfLatitude => connector.selfLatitude;
  @override
  double? get selfLongitude => connector.selfLongitude;
  @override
  List<Channel> get channels => connector.channels;
  @override
  List<Contact> get contacts => connector.contacts;
  @override
  set sosTextListener(void Function(SosInboundText inbound)? listener) =>
      connector.sosTextListener = listener;
  @override
  Future<void> sendChannelText(Channel channel, String text) =>
      connector.sendChannelMessage(channel, text);
  @override
  Future<void> sendDirectText(Contact contact, String text) =>
      connector.sendMessage(contact, text);
  @override
  bool hasDeliveredSos(Contact contact, String sosId) =>
      _hasSos(contact, sosId, const {MessageStatus.delivered});
  @override
  bool hasPendingSos(Contact contact, String sosId) => _hasSos(
    contact,
    sosId,
    const {MessageStatus.pending, MessageStatus.sent},
  );

  @override
  void abandonPendingSos(String sosId) => retryService.failPendingWhere(
    (m) =>
        m.text.startsWith(SosCodec.header) &&
        SosCodec.parseSos(m.text)?.id == sosId,
  );

  bool _hasSos(Contact contact, String sosId, Set<MessageStatus> statuses) =>
      connector
          .getMessages(contact)
          .any(
            (m) =>
                m.isOutgoing &&
                statuses.contains(m.status) &&
                m.text.startsWith(SosCodec.header) &&
                SosCodec.parseSos(m.text)?.id == sosId,
          );
  @override
  void addListener(VoidCallback listener) => connector.addListener(listener);
  @override
  void removeListener(VoidCallback listener) =>
      connector.removeListener(listener);
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

  /// How long the first broadcast waits for a phone fix; repeats wait longer.
  static const Duration firstFixTimeout = Duration(seconds: 8);
  static const Duration repeatFixTimeout = Duration(seconds: 20);

  /// Retry delay for a due broadcast while the radio is disconnected.
  static const Duration disconnectedRetry = Duration(seconds: 30);

  final SosTransport _transport;
  final AppSettingsService _settings;
  final PhoneLocationProvider? _phoneLocation;
  final SosAlerter? _alerter;
  final SosStore _store;
  final DateTime Function() _now;

  OutgoingSos? _active;
  String? _pendingCancelId;
  final List<IncomingSos> _incoming = [];
  bool _wasConnected;
  Timer? _timer;
  bool _broadcasting = false;

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
    _transport.addListener(_onTransportChanged);
  }

  PhoneLocationProvider? get phoneLocation => _phoneLocation;

  OutgoingSos? get active => _active;
  bool get isActive => _active != null;

  /// Whether ACKs and broadcasts can go out right now.
  bool get isConnected => _transport.isConnected;

  /// Newest first.
  List<IncomingSos> get incoming => List.unmodifiable(_incoming);
  List<IncomingSos> get openIncoming =>
      _incoming.where((alert) => alert.isOpen).toList();

  void load() {
    _active = _store.loadOutgoing();
    _pendingCancelId = _store.loadPendingCancel();
    _incoming
      ..clear()
      ..addAll(_store.loadIncoming());
    notifyListeners();
    _schedule();
  }

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
  void onAppResumed() => unawaited(broadcastIfDue());

  void _onTransportChanged() {
    final connected = _transport.isConnected;
    if (connected != _wasConnected) {
      _wasConnected = connected;
      notifyListeners();
      // Anything that fell due while disconnected goes out right away.
      if (connected) {
        unawaited(_sendPendingCancel());
        unawaited(broadcastIfDue());
      }
    }
    _refreshDeliveries();
  }

  void _refreshDeliveries() {
    final sos = _active;
    if (sos == null) return;
    var changed = false;
    for (final contact in emergencyContacts) {
      final key = contact.publicKeyHex;
      if (!sos.deliveredContactKeys.contains(key) &&
          _transport.hasDeliveredSos(contact, sos.id)) {
        sos.deliveredContactKeys.add(key);
        changed = true;
      }
    }
    if (changed) {
      unawaited(_store.saveOutgoing(sos));
      notifyListeners();
    }
  }

  /// The configured SOS channel, falling back to the first channel when the
  /// configured slot no longer exists on this radio.
  Channel? get sosChannel {
    final channels = _transport.channels;
    if (channels.isEmpty) return null;
    final index = _settings.settings.sosChannelIndex;
    return channels.where((c) => c.index == index).firstOrNull ??
        channels.first;
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

  Future<void> activate() async {
    if (_active != null) return;
    final sos = OutgoingSos(id: SosCodec.newId(), startedAt: _now());
    _active = sos;
    notifyListeners();
    await _store.saveOutgoing(sos);
    await broadcastIfDue();
  }

  /// Stops the SOS at once, withdraws any SOS DMs still queued or retrying,
  /// and tells responders it was cancelled (when the radio next connects, if
  /// it is not connected now).
  Future<void> cancel() async {
    final sos = _active;
    if (sos == null) return;
    _timer?.cancel();
    _timer = null;
    _active = null;
    _pendingCancelId = sos.id;
    notifyListeners();
    _transport.abandonPendingSos(sos.id);
    await _store.saveOutgoing(null);
    await _store.savePendingCancel(sos.id);
    await _sendPendingCancel();
  }

  /// The ID of a cancellation still waiting for the radio, if any.
  String? get pendingCancelId => _pendingCancelId;

  Future<void> _sendPendingCancel() async {
    final id = _pendingCancelId;
    if (id == null || !_transport.isConnected) return;
    _pendingCancelId = null;
    notifyListeners();
    await _store.savePendingCancel(null);

    final text = SosCodec.encodeCancel(id, _now());
    final channel = sosChannel;
    if (channel != null) {
      try {
        await _transport.sendChannelText(channel, text);
      } catch (e) {
        appLogger.warn('SOS cancel channel send failed: $e', tag: 'SOS');
      }
    }
    // Everyone who may have heard the SOS, including those who acknowledged.
    for (final contact in emergencyContacts) {
      try {
        await _transport.sendDirectText(contact, text);
      } catch (e) {
        appLogger.warn('SOS cancel DM failed: $e', tag: 'SOS');
      }
    }
  }

  Future<void> _broadcast(OutgoingSos sos) async {
    final fix = await resolveFix(
      timeout: sos.broadcastCount == 0 ? firstFixTimeout : repeatFixTimeout,
    );
    // Cancelled while waiting for a fix.
    if (!identical(sos, _active)) return;
    _refreshDeliveries();
    final now = _now();
    sos
      ..lastFix = fix
      ..lastBroadcastAt = now
      ..broadcastCount += 1;
    notifyListeners();
    await _store.saveOutgoing(sos);

    final channel = sosChannel;
    if (channel != null) {
      try {
        await _transport.sendChannelText(
          channel,
          SosCodec.encodeSos(id: sos.id, time: now, fix: fix),
        );
        // Cancelled while the channel send was in progress: send no DMs.
        if (!identical(sos, _active)) return;
      } catch (e) {
        appLogger.warn('SOS channel send failed: $e', tag: 'SOS');
      }
    }

    final dmText = SosCodec.encodeSos(
      id: sos.id,
      time: now,
      fix: fix,
      node: _transport.selfName,
      maxBytes: maxTextPayloadBytesAfterFullLengthAttempts,
    );
    for (final contact in emergencyContacts) {
      if (!identical(sos, _active)) return;
      if (sos.isContactAcknowledged(contact.publicKeyHex, contact.name)) {
        continue;
      }
      // The retry service is still working on the last one; queueing
      // another would only stack up airtime behind it.
      if (_transport.hasPendingSos(contact, sos.id)) continue;
      try {
        await _transport.sendDirectText(contact, dmText);
      } catch (e) {
        appLogger.warn('SOS DM to ${contact.name} failed: $e', tag: 'SOS');
      }
    }
  }

  @visibleForTesting
  void handleInbound(SosInboundText inbound) {
    final ackId = SosCodec.parseAck(inbound.text);
    if (ackId != null) {
      _handleAck(ackId, inbound);
      return;
    }
    final cancelId = SosCodec.parseCancel(inbound.text);
    if (cancelId != null) {
      _handleCancel(cancelId, inbound);
      return;
    }
    final payload = SosCodec.parseSos(inbound.text);
    if (payload != null) _handleSos(payload, inbound);
  }

  void _handleAck(String id, SosInboundText inbound) {
    var changed = false;
    final sos = _active;
    if (sos != null && sos.id == id) {
      // The same responder often ACKs on the channel and by DM.
      final index = sos.acks.indexWhere(
        (ack) => ack.senderName == inbound.senderName,
      );
      if (index == -1) {
        final ack = SosAck(
          senderName: inbound.senderName,
          senderKeyHex: inbound.senderKeyHex,
          receivedAt: _now(),
        );
        sos.acks.add(ack);
        _alerter?.acknowledged(sos, ack);
        changed = true;
      } else if (sos.acks[index].senderKeyHex == null &&
          inbound.senderKeyHex != null) {
        final known = sos.acks[index];
        sos.acks[index] = SosAck(
          senderName: known.senderName,
          senderKeyHex: inbound.senderKeyHex,
          receivedAt: known.receivedAt,
        );
        changed = true;
      }
      if (changed) unawaited(_store.saveOutgoing(sos));
    }
    var incomingChanged = false;
    for (final alert in _incoming) {
      if (alert.id == id && alert.ackedBy.add(inbound.senderName)) {
        incomingChanged = true;
      }
    }
    if (incomingChanged) unawaited(_store.saveIncoming(_incoming));
    if (changed || incomingChanged) notifyListeners();
  }

  void _handleCancel(String id, SosInboundText inbound) {
    final alert = _incoming
        .where(
          (a) =>
              a.id == id &&
              !a.cancelled &&
              (a.senderName == inbound.senderName ||
                  (inbound.senderKeyHex != null &&
                      a.senderKeyHex == inbound.senderKeyHex)),
        )
        .firstOrNull;
    if (alert == null) return;
    final wasOpen = alert.isOpen;
    alert.cancelled = true;
    if (wasOpen) _alerter?.clear(alert);
    _alerter?.cancelled(alert);
    unawaited(_store.saveIncoming(_incoming));
    notifyListeners();
  }

  void _handleSos(SosPayload payload, SosInboundText inbound) {
    final senderName = inbound.senderName.isNotEmpty
        ? inbound.senderName
        : (payload.node ?? '');
    final key = IncomingSos.keyFor(senderName, payload.id);
    final now = _now();
    var alert = _incoming.where((a) => a.key == key).firstOrNull;
    if (alert != null) {
      final existing = alert;
      existing
        ..lastSeen = now
        ..receivedCount += 1
        ..senderKeyHex ??= inbound.senderKeyHex
        ..channelIndex ??= inbound.channelIndex;
      if (payload.fix.hasPosition || !existing.fix.hasPosition) {
        existing.fix = payload.fix;
      }
    } else {
      alert = IncomingSos(
        id: payload.id,
        senderName: senderName,
        senderKeyHex: inbound.senderKeyHex,
        channelIndex: inbound.channelIndex,
        firstSeen: now,
        lastSeen: now,
        fix: payload.fix,
      );
      _incoming.insert(0, alert);
      _trimIncoming();
    }
    // Every repeat of a still-open alert sounds again.
    if (alert.isOpen) _alerter?.alert(alert);
    unawaited(_store.saveIncoming(_incoming));
    notifyListeners();
  }

  /// Drops the oldest resolved alerts; open ones are never dropped.
  void _trimIncoming() {
    for (
      var i = _incoming.length - 1;
      i >= 0 && _incoming.length > _maxIncoming;
      i--
    ) {
      if (!_incoming[i].isOpen) _incoming.removeAt(i);
    }
  }

  /// Replies ACK on the channel the alert arrived on, and by DM when the
  /// sender is a known contact. Does nothing while disconnected, so the
  /// alert is never marked answered when no ACK could go out.
  Future<void> acknowledge(IncomingSos alert) async {
    if (!_transport.isConnected) return;
    alert.ackSent = true;
    _alerter?.clear(alert);
    notifyListeners();
    await _store.saveIncoming(_incoming);

    final text = SosCodec.encodeAck(alert.id);
    final channel = alert.channelIndex == null
        ? (alert.senderKeyHex == null ? sosChannel : null)
        : _transport.channels
              .where((c) => c.index == alert.channelIndex)
              .firstOrNull;
    if (channel != null) {
      try {
        await _transport.sendChannelText(channel, text);
      } catch (e) {
        appLogger.warn('SOS ACK channel send failed: $e', tag: 'SOS');
      }
    }
    final contact = _transport.contacts
        .where((c) => c.publicKeyHex == alert.senderKeyHex)
        .firstOrNull;
    if (contact != null) {
      try {
        await _transport.sendDirectText(contact, text);
      } catch (e) {
        appLogger.warn('SOS ACK DM failed: $e', tag: 'SOS');
      }
    }
  }

  Future<void> dismiss(IncomingSos alert) async {
    alert.dismissed = true;
    _alerter?.clear(alert);
    notifyListeners();
    await _store.saveIncoming(_incoming);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _transport.removeListener(_onTransportChanged);
    _transport.sosTextListener = null;
    super.dispose();
  }
}
