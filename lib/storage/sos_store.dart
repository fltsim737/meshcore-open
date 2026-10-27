import 'dart:convert';

import '../models/sos_alert.dart';
import '../models/sos_history.dart';
import '../utils/app_logger.dart';
import 'prefs_manager.dart';

/// Persists the active outgoing SOS and incoming alerts so both survive an
/// app restart. Global rather than per-radio: an SOS belongs to the person
/// holding the phone, whichever radio is attached.
class SosStore {
  static const String _outgoingKey = 'sos_outgoing';
  static const String _incomingKey = 'sos_incoming';
  static const String _pendingCancelKey = 'sos_pending_cancel';
  static const String _cancellationKey = 'sos_cancellation';
  static const String _historyKey = 'sos_history';
  static const String _sessionsKey = 'sos_sessions';

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

  /// A cancellation still being sent. Older versions stored only the ID of
  /// one not yet sent; that is read as a cancellation with no copies out.
  SosCancellation? loadCancellation() {
    final prefs = PrefsManager.instance;
    final raw = prefs.getString(_cancellationKey);
    if (raw != null) {
      try {
        return SosCancellation.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
      } catch (e) {
        appLogger.warn(
          'Discarding unreadable SOS cancellation: $e',
          tag: 'SOS',
        );
      }
    }
    final legacyId = prefs.getString(_pendingCancelKey);
    if (legacyId == null) return null;
    return SosCancellation(id: legacyId, cancelledAt: DateTime.now());
  }

  Future<void> saveCancellation(SosCancellation? cancellation) async {
    final prefs = PrefsManager.instance;
    await prefs.remove(_pendingCancelKey);
    if (cancellation == null) {
      await prefs.remove(_cancellationKey);
    } else {
      await prefs.setString(
        _cancellationKey,
        jsonEncode(cancellation.toJson()),
      );
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

  /// Records of past and live alerts, newest first; kept until deleted.
  List<SosHistoryRecord> loadHistory() {
    final raw = PrefsManager.instance.getString(_historyKey);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List<dynamic>)
          .map(
            (e) =>
                SosHistoryRecord.fromJson(Map<String, dynamic>.from(e as Map)),
          )
          .toList();
    } catch (e) {
      appLogger.warn('Discarding unreadable SOS history: $e', tag: 'SOS');
      return [];
    }
  }

  Future<void> saveHistory(List<SosHistoryRecord> records) =>
      PrefsManager.instance.setString(
        _historyKey,
        jsonEncode(records.map((r) => r.toJson()).toList()),
      );

  /// The SOS2 keys this phone knows (see [SosSessionBook]).
  Object? loadSessions() {
    final raw = PrefsManager.instance.getString(_sessionsKey);
    if (raw == null) return null;
    try {
      return jsonDecode(raw);
    } catch (e) {
      appLogger.warn('Discarding unreadable SOS keys: $e', tag: 'SOS');
      return null;
    }
  }

  Future<void> saveSessions(List<Map<String, dynamic>> sessions) =>
      PrefsManager.instance.setString(_sessionsKey, jsonEncode(sessions));

  Future<void> saveIncoming(List<IncomingSos> alerts) =>
      PrefsManager.instance.setString(
        _incomingKey,
        jsonEncode(alerts.map((a) => a.toJson()).toList()),
      );
}
