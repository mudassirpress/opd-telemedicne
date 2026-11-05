// lib/features/calling/data/datasources/call_local_datasource.dart

import 'package:telemedicine/data/local/models/offline_call_record.dart';
import 'package:telemedicine/data/local/offline_call_service.dart';
import 'package:telemedicine/features/calling/domain/call_model.dart';

abstract class CallLocalDataSource {
  Future<bool> saveCall(VoiceCallModel call);
  Future<bool> updateCallStatus({
    required String callId,
    required String status,
    DateTime? endTime,
    int? duration,
  });
  List<VoiceCallModel> getCallHistory(String userId);
}

class HiveCallLocalDataSource implements CallLocalDataSource {
  final OfflineCallService _offlineService;

  HiveCallLocalDataSource({OfflineCallService? offlineService})
      : _offlineService = offlineService ?? OfflineCallService.instance;

  @override
  Future<bool> saveCall(VoiceCallModel call) async {
    final record = OfflineCallRecord(
      callId: call.callId,
      callerId: call.callerId,
      receiverId: call.receiverId,
      callType: call.callType,
      startTime: call.createdAt,
      endTime: call.endedAt,
      duration: call.duration,
      callStatus: call.status,
      callerName: call.callerName,
      receiverName: call.receiverName,
      callerImage: call.callerImage,
      receiverImage: call.receiverImage,
      channelId: call.roomId,
      synced: true,
    );
    return await _offlineService.saveCall(record);
  }

  @override
  Future<bool> updateCallStatus({
    required String callId,
    required String status,
    DateTime? endTime,
    int? duration,
  }) async {
    return await _offlineService.updateCallStatus(
      callId: callId,
      callStatus: status,
      endTime: endTime,
      duration: duration,
      synced: true,
    );
  }

  @override
  List<VoiceCallModel> getCallHistory(String userId) {
    final records = _offlineService.getCallHistory(userId);
    return records.map((r) {
      return VoiceCallModel(
        callId: r.callId,
        callerId: r.callerId,
        callerName: r.callerName ?? 'Unknown',
        callerRole: 'patient',
        callerImage: r.callerImage,
        receiverId: r.receiverId,
        receiverName: r.receiverName ?? 'Unknown',
        receiverRole: 'doctor',
        receiverImage: r.receiverImage,
        callType: r.callType,
        roomId: r.channelId,
        status: r.callStatus,
        createdAt: r.startTime,
        endedAt: r.endTime,
        duration: r.duration ?? 0,
      );
    }).toList();
  }
}

