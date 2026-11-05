// lib/features/calling/data/datasources/call_remote_datasource.dart

import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/features/calling/domain/call_model.dart';
import 'package:telemedicine/features/calling/domain/call_status.dart';

abstract class CallRemoteDataSource {
  Future<void> createCall(VoiceCallModel call);
  Future<VoiceCallModel?> getCall(String callId);
  Stream<VoiceCallModel?> watchCall(String callId);
  Stream<List<VoiceCallModel>> watchUserCallHistory(String userId);
  Future<bool> updateCallStatus({
    required String callId,
    required String status,
    DateTime? acceptedAt,
    DateTime? connectedAt,
    DateTime? endedAt,
    int? duration,
    String? endReason,
    bool? missedCall,
    String? rejectedBy,
  });
  Future<bool> acceptCallSafely(String callId);
  Future<bool> rejectCallSafely(String callId, {String? rejectedBy});
  Future<bool> cancelCallSafely(String callId);
  Future<bool> endCallSafely({
    required String callId,
    required int duration,
    String? endReason,
  });
  Future<bool> isUserBusy(String userId);
}

class FirestoreCallRemoteDataSource implements CallRemoteDataSource {
  final FirebaseFirestore _firestore;

  FirestoreCallRemoteDataSource({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _callsCollection =>
      _firestore.collection(FirestoreCollections.calls);

  @override
  Future<void> createCall(VoiceCallModel call) async {
    await _callsCollection.doc(call.callId).set(call.toMap());
  }

  @override
  Future<VoiceCallModel?> getCall(String callId) async {
    final doc = await _callsCollection.doc(callId).get();
    if (!doc.exists || doc.data() == null) return null;
    return VoiceCallModel.fromMap(doc.data()!, doc.id);
  }

  @override
  Stream<VoiceCallModel?> watchCall(String callId) {
    return _callsCollection.doc(callId).snapshots().map((doc) {
      if (!doc.exists || doc.data() == null) return null;
      return VoiceCallModel.fromMap(doc.data()!, doc.id);
    });
  }

  @override
  Stream<List<VoiceCallModel>> watchUserCallHistory(String userId) {
    // Watch calls where user is caller or receiver
    final cleanId = userId.trim();
    return _callsCollection
        .where('callerId', isEqualTo: cleanId)
        .limit(40)
        .snapshots()
        .asyncMap((callerSnap) async {
      final callerCalls = callerSnap.docs
          .map((d) => VoiceCallModel.fromMap(d.data(), d.id))
          .toList();

      try {
        final receiverSnap = await _callsCollection
            .where('receiverId', isEqualTo: cleanId)
            .limit(40)
            .get();
        final receiverCalls = receiverSnap.docs
            .map((d) => VoiceCallModel.fromMap(d.data(), d.id))
            .toList();

        final all = [...callerCalls, ...receiverCalls];
        final seen = <String>{};
        final unique = <VoiceCallModel>[];
        for (final c in all) {
          if (seen.add(c.callId)) unique.add(c);
        }
        unique.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        return unique;
      } catch (e) {
        debugPrint('⚠️ Error fetching receiver calls: $e');
        callerCalls.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        return callerCalls;
      }
    });
  }

  @override
  Future<bool> updateCallStatus({
    required String callId,
    required String status,
    DateTime? acceptedAt,
    DateTime? connectedAt,
    DateTime? endedAt,
    int? duration,
    String? endReason,
    bool? missedCall,
    String? rejectedBy,
  }) async {
    try {
      final Map<String, dynamic> updates = {
        'status': status,
        'callStatus': status,
      };

      if (acceptedAt != null) {
        updates['acceptedAt'] = FieldValue.serverTimestamp();
      }
      if (connectedAt != null) {
        updates['connectedAt'] = FieldValue.serverTimestamp();
      }
      if (endedAt != null) {
        updates['endedAt'] = FieldValue.serverTimestamp();
      }
      if (duration != null) {
        updates['duration'] = duration;
      }
      if (endReason != null) {
        updates['endReason'] = endReason;
      }
      if (missedCall != null) {
        updates['missedCall'] = missedCall;
      }
      if (rejectedBy != null) {
        updates['rejectedBy'] = rejectedBy;
      }

      await _callsCollection.doc(callId).update(updates);
      return true;
    } catch (e) {
      debugPrint('⚠️ [CallRemoteDataSource] updateCallStatus error: $e');
      return false;
    }
  }

  @override
  Future<bool> acceptCallSafely(String callId) async {
    try {
      final docRef = _callsCollection.doc(callId);
      final doc = await docRef.get();
      if (!doc.exists || doc.data() == null) return false;

      final current = doc.data()!['callStatus'] ?? doc.data()!['status'];
      if (!CallingStatus.canAccept(current?.toString())) {
        debugPrint(
          '⚠️ [CallRemoteDataSource] Cannot accept call $callId with status $current',
        );
        return false;
      }

      await docRef.update({
        'status': CallingStatus.accepted,
        'callStatus': CallingStatus.accepted,
        'acceptedAt': FieldValue.serverTimestamp(),
      });
      return true;
    } catch (e) {
      debugPrint('❌ [CallRemoteDataSource] acceptCallSafely failed: $e');
      return false;
    }
  }

  @override
  Future<bool> rejectCallSafely(String callId, {String? rejectedBy}) async {
    try {
      final docRef = _callsCollection.doc(callId);
      final doc = await docRef.get();
      if (!doc.exists || doc.data() == null) return false;

      final current = doc.data()!['callStatus'] ?? doc.data()!['status'];
      if (!CallingStatus.canDecline(current?.toString())) {
        debugPrint(
          '⚠️ [CallRemoteDataSource] Cannot reject call $callId with status $current',
        );
        return false;
      }

      await docRef.update({
        'status': CallingStatus.rejected,
        'callStatus': CallingStatus.rejected,
        'endedAt': FieldValue.serverTimestamp(),
        'endReason': 'rejected',
        if (rejectedBy != null) 'rejectedBy': rejectedBy,
      });
      return true;
    } catch (e) {
      debugPrint('❌ [CallRemoteDataSource] rejectCallSafely failed: $e');
      return false;
    }
  }

  @override
  Future<bool> cancelCallSafely(String callId) async {
    try {
      final docRef = _callsCollection.doc(callId);
      final doc = await docRef.get();
      if (!doc.exists || doc.data() == null) return false;

      final current = doc.data()!['callStatus'] ?? doc.data()!['status'];
      if (!CallingStatus.isRinging(current?.toString())) {
        debugPrint(
          '⚠️ [CallRemoteDataSource] Cannot cancel call $callId with status $current',
        );
        return false;
      }

      await docRef.update({
        'status': CallingStatus.cancelled,
        'callStatus': CallingStatus.cancelled,
        'endedAt': FieldValue.serverTimestamp(),
        'endReason': 'cancelled_by_caller',
      });
      return true;
    } catch (e) {
      debugPrint('❌ [CallRemoteDataSource] cancelCallSafely failed: $e');
      return false;
    }
  }

  @override
  Future<bool> endCallSafely({
    required String callId,
    required int duration,
    String? endReason,
  }) async {
    try {
      await _callsCollection.doc(callId).update({
        'status': CallingStatus.ended,
        'callStatus': CallingStatus.ended,
        'endedAt': FieldValue.serverTimestamp(),
        'duration': duration,
        'endReason': endReason ?? 'normal_hangup',
      });
      return true;
    } catch (e) {
      debugPrint('❌ [CallRemoteDataSource] endCallSafely failed: $e');
      return false;
    }
  }

  @override
  Future<bool> isUserBusy(String userId) async {
    final cleanId = userId.trim();
    if (cleanId.isEmpty) return false;

    try {
      final now = DateTime.now();

      // Check caller side
      final callerQuery = await _callsCollection
          .where('callerId', isEqualTo: cleanId)
          .limit(5)
          .get();

      for (final doc in callerQuery.docs) {
        final data = doc.data();
        final status = (data['callStatus'] ?? data['status'])?.toString();
        if (status != null && !CallingStatus.isTerminal(status)) {
          final started = _parseDate(data['startTime'] ?? data['createdAt']);
          if (started != null && now.difference(started).inSeconds < 120) {
            return true;
          }
        }
      }

      // Check receiver side
      final receiverQuery = await _callsCollection
          .where('receiverId', isEqualTo: cleanId)
          .limit(5)
          .get();

      for (final doc in receiverQuery.docs) {
        final data = doc.data();
        final status = (data['callStatus'] ?? data['status'])?.toString();
        if (status != null && !CallingStatus.isTerminal(status)) {
          final started = _parseDate(data['startTime'] ?? data['createdAt']);
          if (started != null && now.difference(started).inSeconds < 120) {
            return true;
          }
        }
      }

      return false;
    } catch (e) {
      debugPrint('⚠️ [CallRemoteDataSource] isUserBusy query failed: $e');
      return false;
    }
  }

  DateTime? _parseDate(dynamic value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
    if (value is String) return DateTime.tryParse(value);
    return null;
  }
}

