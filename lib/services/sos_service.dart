import 'dart:async';

import 'package:flutter/foundation.dart';

import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../helpers/sos_codec.dart';
import '../models/channel.dart';
import '../models/contact.dart';
import '../models/sos_alert.dart';
import '../storage/sos_store.dart';
import '../utils/app_logger.dart';
import 'app_settings_service.dart';

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
}

class ConnectorSosTransport implements SosTransport {
  final MeshCoreConnector connector;

  ConnectorSosTransport(this.connector);

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
  void addListener(VoidCallback listener) => connector.addListener(listener);
  @override
  void removeListener(VoidCallback listener) =>
      connector.removeListener(listener);
}

class SosService extends ChangeNotifier {
  static const int _maxIncoming = 50;

  final SosTransport _transport;
  final AppSettingsService _settings;
  final SosStore _store;
  final DateTime Function() _now;

  OutgoingSos? _active;
  final List<IncomingSos> _incoming = [];
  bool _wasConnected;

  SosService({
    required SosTransport transport,
    required AppSettingsService settings,
    SosStore? store,
    DateTime Function()? now,
  }) : _transport = transport,
       _settings = settings,
       _store = store ?? SosStore(),
       _now = now ?? DateTime.now,
       _wasConnected = transport.isConnected {
    _transport.sosTextListener = handleInbound;
    _transport.addListener(_onTransportChanged);
  }

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
    _incoming
      ..clear()
      ..addAll(_store.loadIncoming());
    notifyListeners();
  }

  void _onTransportChanged() {
    final connected = _transport.isConnected;
    if (connected == _wasConnected) return;
    _wasConnected = connected;
    notifyListeners();
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

  /// The radio's position, then the stored location.
  Future<SosFix> resolveFix() async {
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
    if (_transport.isConnected) await _broadcast(sos);
  }

  Future<void> cancel() async {
    if (_active == null) return;
    _active = null;
    notifyListeners();
    await _store.saveOutgoing(null);
  }

  Future<void> _broadcast(OutgoingSos sos) async {
    final fix = await resolveFix();
    // Cancelled while waiting for a fix.
    if (!identical(sos, _active)) return;
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
      if (sos.isContactAcknowledged(contact.publicKeyHex, contact.name)) {
        continue;
      }
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
        sos.acks.add(
          SosAck(
            senderName: inbound.senderName,
            senderKeyHex: inbound.senderKeyHex,
            receivedAt: _now(),
          ),
        );
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

  void _handleSos(SosPayload payload, SosInboundText inbound) {
    final senderName = inbound.senderName.isNotEmpty
        ? inbound.senderName
        : (payload.node ?? '');
    final key = IncomingSos.keyFor(senderName, payload.id);
    final now = _now();
    final existing = _incoming.where((a) => a.key == key).firstOrNull;
    if (existing != null) {
      existing
        ..lastSeen = now
        ..receivedCount += 1
        ..senderKeyHex ??= inbound.senderKeyHex
        ..channelIndex ??= inbound.channelIndex;
      if (payload.fix.hasPosition || !existing.fix.hasPosition) {
        existing.fix = payload.fix;
      }
    } else {
      _incoming.insert(
        0,
        IncomingSos(
          id: payload.id,
          senderName: senderName,
          senderKeyHex: inbound.senderKeyHex,
          channelIndex: inbound.channelIndex,
          firstSeen: now,
          lastSeen: now,
          fix: payload.fix,
        ),
      );
      _trimIncoming();
    }
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
    notifyListeners();
    await _store.saveIncoming(_incoming);
  }

  @override
  void dispose() {
    _transport.removeListener(_onTransportChanged);
    _transport.sosTextListener = null;
    super.dispose();
  }
}
