// lib/features/calling/data/repositories/call_repository.dart

import 'dart:async';
import 'package:telemedicine/features/calling/data/datasources/call_local_datasource.dart';
import 'package:telemedicine/features/calling/data/datasources/call_remote_datasource.dart';
import 'package:telemedicine/features/calling/domain/call_model.dart';

class CallRepository {
  final CallRemoteDataSource remote;
  final CallLocalDataSource local;

  CallRepository({
    CallRemoteDataSource? remoteDataSource,
    CallLocalDataSource? localDataSource,
  })  : remote = remoteDataSource ?? FirestoreCallRemoteDataSource(),
        local = localDataSource ?? HiveCallLocalDataSource();

  Future<void> createCall(VoiceCallModel call) async {
    await remote.createCall(call);
    await local.saveCall(call);
  }

  Future<VoiceCallModel?> getCall(String callId) => remote.getCall(callId);

  Stream<VoiceCallModel?> watchCall(String callId) => remote.watchCall(callId);

  Stream<List<VoiceCallModel>> watchUserCallHistory(String userId) =>
      remote.watchUserCallHistory(userId);

  List<VoiceCallModel> getOfflineCallHistory(String userId) =>
      local.getCallHistory(userId);

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
    final remoteSuccess = await remote.updateCallStatus(
      callId: callId,
      status: status,
      acceptedAt: acceptedAt,
      connectedAt: connectedAt,
      endedAt: endedAt,
      duration: duration,
      endReason: endReason,
      missedCall: missedCall,
      rejectedBy: rejectedBy,
    );

    await local.updateCallStatus(
      callId: callId,
      status: status,
      endTime: endedAt,
      duration: duration,
    );

    return remoteSuccess;
  }

  Future<bool> acceptCall(String callId) async {
    final ok = await remote.acceptCallSafely(callId);
    if (ok) {
      await local.updateCallStatus(
        callId: callId,
        status: 'accepted',
      );
    }
    return ok;
  }

  Future<bool> rejectCall(String callId, {String? rejectedBy}) async {
    final ok = await remote.rejectCallSafely(callId, rejectedBy: rejectedBy);
    if (ok) {
      await local.updateCallStatus(
        callId: callId,
        status: 'rejected',
        endTime: DateTime.now(),
      );
    }
    return ok;
  }

  Future<bool> cancelCall(String callId) async {
    final ok = await remote.cancelCallSafely(callId);
    if (ok) {
      await local.updateCallStatus(
        callId: callId,
        status: 'cancelled',
        endTime: DateTime.now(),
      );
    }
    return ok;
  }

  Future<bool> endCall({
    required String callId,
    required int duration,
    String? endReason,
  }) async {
    final ok = await remote.endCallSafely(
      callId: callId,
      duration: duration,
      endReason: endReason,
    );
    await local.updateCallStatus(
      callId: callId,
      status: 'ended',
      endTime: DateTime.now(),
      duration: duration,
    );
    return ok;
  }

  Future<bool> isUserBusy(String userId) => remote.isUserBusy(userId);
}

