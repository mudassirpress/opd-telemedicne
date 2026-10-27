import 'package:hive/hive.dart';

import 'hive_db_service.dart';
import 'models/offline_call_record.dart';

/// Provides offline-first storage for call history using a Hive box as the
/// local cache. Call records remain available without internet access.
class OfflineCallService {
  OfflineCallService._();

  static final OfflineCallService instance = OfflineCallService._();

  Box<OfflineCallRecord>? get _box => HiveDBService.callHistoryBox;

  bool get _ready => HiveDBService.callBoxReady;

  /// Save (upsert) a call record locally, keyed by callId.
  Future<bool> saveCall(OfflineCallRecord record) async {
    if (!_ready) return false;
    await _box!.put(record.callId, record);
    return true;
  }

  /// Retrieve all locally cached call records involving [userId],
  /// sorted descending by start time (most recent first).
  List<OfflineCallRecord> getCallHistory(String userId) {
    if (!_ready) return const [];
    final results = _box!.values
        .where((c) => c.callerId == userId || c.receiverId == userId)
        .toList();
    results.sort((a, b) => b.startTime.compareTo(a.startTime));
    return results;
  }

  /// Get a single call record by id.
  OfflineCallRecord? getCall(String callId) {
    if (!_ready) return null;
    return _box!.get(callId);
  }

  /// Update status/end details of an existing call, or add it if missing.
  Future<bool> updateCallStatus({
    required String callId,
    required String callStatus,
    DateTime? endTime,
    int? duration,
    bool synced = false,
  }) async {
    if (!_ready) return false;
    final existing = _box!.get(callId);
    if (existing == null) return false;
    await _box!.put(
      callId,
      existing.copyWith(
        callStatus: callStatus,
        endTime: endTime,
        duration: duration,
        synced: synced,
      ),
    );
    return true;
  }

  /// Merge a list of server call records into the local cache, de-duplicating
  /// by callId. Server data wins for the same call since it is authoritative.
  Future<int> mergeServerCalls(List<OfflineCallRecord> serverCalls) async {
    if (serverCalls.isEmpty) return 0;
    if (!_ready) return 0;
    await _box!.putAll({for (final c in serverCalls) c.callId: c});
    return serverCalls.length;
  }

  /// Delete a call record from the local cache.
  Future<bool> deleteCall(String callId) async {
    if (!_ready) return false;
    await _box!.delete(callId);
    return true;
  }

  /// Clear all cached call history.
  Future<void> clearAll() async {
    if (!_ready) return;
    await _box!.clear();
  }
}
