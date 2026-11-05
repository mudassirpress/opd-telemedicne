// lib/data/models/call_model.dart

import 'package:cloud_firestore/cloud_firestore.dart';

class CallModel {
  final String id;
  final String callerId;
  final String receiverId;
  final String callerName;
  final String receiverName;
  final String? callerImage;
  final String? receiverImage;
  final String? callerType;
  final String? receiverRole;
  final String channelId;
  final String callType; // 'audio'
  final String callStatus;
  final DateTime startTime;
  final DateTime? deliveredAt;
  final DateTime? acceptedAt;
  final DateTime? endedAt;
  final int? duration; // Duration in seconds
  final String? endReason;
  final bool missedCall;
  final String? rejectedBy;
  final String? callerDeviceId;
  final String? receiverDeviceId;

  CallModel({
    required this.id,
    required this.callerId,
    required this.receiverId,
    required this.callerName,
    required this.receiverName,
    this.callerImage,
    this.receiverImage,
    this.callerType,
    this.receiverRole,
    required this.channelId,
    required this.callType,
    required this.callStatus,
    required this.startTime,
    this.deliveredAt,
    this.acceptedAt,
    this.endedAt,
    this.duration,
    this.endReason,
    this.missedCall = false,
    this.rejectedBy,
    this.callerDeviceId,
    this.receiverDeviceId,
  });

  String get callId => id;
  String get status => callStatus;
  String get roomId => channelId;
  String get callerRole => callerType ?? 'doctor';
  DateTime get createdAt => startTime;

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'callId': id,
      'callerId': callerId,
      'receiverId': receiverId,
      'callerName': callerName,
      'receiverName': receiverName,
      'callerImage': callerImage,
      'callerAvatar': callerImage,
      'receiverImage': receiverImage,
      'callerType': callerType,
      'callerRole': callerType,
      'receiverRole': receiverRole,
      'channelId': channelId,
      'roomId': channelId,
      'callType': callType,
      'callStatus': callStatus,
      'status': callStatus,
      'startTime': Timestamp.fromDate(startTime.toUtc()),
      'createdAt': Timestamp.fromDate(startTime.toUtc()),
      'startTimeIso': startTime.toUtc().toIso8601String(),
      if (deliveredAt != null)
        'deliveredAt': Timestamp.fromDate(deliveredAt!.toUtc()),
      if (acceptedAt != null)
        'acceptedAt': Timestamp.fromDate(acceptedAt!.toUtc()),
      if (endedAt != null) 'endedAt': Timestamp.fromDate(endedAt!.toUtc()),
      'duration': duration,
      'endReason': endReason,
      'missedCall': missedCall,
      'rejectedBy': rejectedBy,
      'callerDeviceId': callerDeviceId,
      'receiverDeviceId': receiverDeviceId,
    };
  }

  factory CallModel.fromMap(Map<String, dynamic> map, [String? docId]) {
    final callId = (map['callId'] ?? map['id'] ?? docId ?? '').toString();
    final channel = (map['channelId'] ?? map['roomId'] ?? callId).toString();
    final status = (map['callStatus'] ?? map['status'] ?? 'ringing').toString();

    return CallModel(
      id: callId,
      callerId: (map['callerId'] ?? '').toString(),
      receiverId: (map['receiverId'] ?? '').toString(),
      callerName: (map['callerName'] ?? '').toString(),
      receiverName: (map['receiverName'] ?? '').toString(),
      callerImage: map['callerImage'] ?? map['callerAvatar'],
      receiverImage: map['receiverImage'],
      callerType: map['callerType'] ?? map['callerRole'],
      receiverRole: map['receiverRole'] ?? map['receiverType'],
      channelId: channel,
      callType: map['callType'] ?? 'audio',
      callStatus: status,
      startTime: _parseTime(
        map['startTime'] ?? map['createdAt'] ?? map['startTimeIso'],
      ),
      deliveredAt: _parseNullableTime(map['deliveredAt']),
      acceptedAt: _parseNullableTime(map['acceptedAt']),
      endedAt: _parseNullableTime(map['endedAt']),
      duration: map['duration'] is int
          ? map['duration'] as int
          : int.tryParse(map['duration']?.toString() ?? '0'),
      endReason: map['endReason']?.toString(),
      missedCall: map['missedCall'] == true,
      rejectedBy: map['rejectedBy']?.toString(),
      callerDeviceId: map['callerDeviceId']?.toString(),
      receiverDeviceId: map['receiverDeviceId']?.toString(),
    );
  }

  static DateTime _parseTime(dynamic value) {
    if (value == null) return DateTime.now().toUtc();
    if (value is Timestamp) return value.toDate().toUtc();
    if (value is DateTime) return value.toUtc();
    if (value is int) {
      return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
    }
    if (value is String) {
      final parsed = DateTime.tryParse(value);
      if (parsed != null) return parsed.toUtc();
    }
    return DateTime.now().toUtc();
  }

  static DateTime? _parseNullableTime(dynamic value) {
    if (value == null) return null;
    if (value is Timestamp) return value.toDate().toUtc();
    if (value is DateTime) return value.toUtc();
    if (value is int) {
      return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
    }
    if (value is String) {
      final parsed = DateTime.tryParse(value);
      if (parsed != null) return parsed.toUtc();
    }
    return null;
  }
}
