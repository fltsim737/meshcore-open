import 'dart:convert';

import '../models/sos_alert.dart';
import '../utils/app_logger.dart';
import 'prefs_manager.dart';

/// Persists the active outgoing SOS and incoming alerts so both survive an
/// app restart. Global rather than per-radio: an SOS belongs to the person
/// holding the phone, whichever radio is attached.
class SosStore {
  static const String _outgoingKey = 'sos_outgoing';
  static const String _incomingKey = 'sos_incoming';
  static const String _pendingCancelKey = 'sos_pending_cancel';

  /// Unreadable state is discarded rather than allowed to block startup.
  OutgoingSos? loadOutgoing() {
    final raw = PrefsManager.instance.getString(_outgoingKey);
    if (raw == null) return null;
    try {
      return OutgoingSos.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (e) {
      appLogger.warn('Discarding unreadable SOS state: $e', tag: 'SOS');
      return null;
    }
  }

  Future<void> saveOutgoing(OutgoingSos? sos) async {
    final prefs = PrefsManager.instance;
    if (sos == null) {
      await prefs.remove(_outgoingKey);
    } else {
      await prefs.setString(_outgoingKey, jsonEncode(sos.toJson()));
    }
  }

  /// ID of a cancelled SOS whose cancellation notice has not gone out yet.
  String? loadPendingCancel() =>
      PrefsManager.instance.getString(_pendingCancelKey);

  Future<void> savePendingCancel(String? id) async {
    final prefs = PrefsManager.instance;
    if (id == null) {
      await prefs.remove(_pendingCancelKey);
    } else {
      await prefs.setString(_pendingCancelKey, id);
    }
  }

  List<IncomingSos> loadIncoming() {
    final raw = PrefsManager.instance.getString(_incomingKey);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List<dynamic>)
          .map((e) => IncomingSos.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (e) {
      appLogger.warn('Discarding unreadable SOS alerts: $e', tag: 'SOS');
      return [];
    }
  }

  Future<void> saveIncoming(List<IncomingSos> alerts) =>
      PrefsManager.instance.setString(
        _incomingKey,
        jsonEncode(alerts.map((a) => a.toJson()).toList()),
      );
}
