// lib/features/calling/domain/call_model.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:telemedicine/features/calling/domain/call_status.dart';

/// Authoritative Voice Call Model satisfying Section 8 requirements.
class VoiceCallModel {
  final String callId;
  final String callerId;
  final String callerName;
  final String callerRole; // 'doctor' or 'patient'
  final String? callerImage;
  final String receiverId;
  final String receiverName;
  final String receiverRole; // 'doctor' or 'patient'
  final String? receiverImage;
  final String callType; // 'audio'
  final String roomId;
  final String status;
  final DateTime createdAt;
  final DateTime? acceptedAt;
  final DateTime? connectedAt;
  final DateTime? endedAt;
  final int duration; // in seconds
  final String? endReason;
  final bool missedCall;
  final String? rejectedBy;
  final String? callerDeviceId;
  final String? receiverDeviceId;

  const VoiceCallModel({
    required this.callId,
    required this.callerId,
    required this.callerName,
    required this.callerRole,
    this.callerImage,
    required this.receiverId,
    required this.receiverName,
    required this.receiverRole,
    this.receiverImage,
    this.callType = 'audio',
    required this.roomId,
    required this.status,
    required this.createdAt,
    this.acceptedAt,
    this.connectedAt,
    this.endedAt,
    this.duration = 0,
    this.endReason,
    this.missedCall = false,
    this.rejectedBy,
    this.callerDeviceId,
    this.receiverDeviceId,
  });

  // Backward compatibility getters
  String get id => callId;
  String get channelId => roomId;
  String get callStatus => status;
  DateTime get startTime => createdAt;

  bool get isTerminal => CallingStatus.isTerminal(status);
  bool get isRinging => CallingStatus.isRinging(status);
  bool get isConnected => CallingStatus.isConnected(status);
  bool get isLive => CallingStatus.isLive(status);

  Map<String, dynamic> toMap() {
    return {
      'callId': callId,
      'id': callId,
      'callerId': callerId,
      'callerName': callerName,
      'callerRole': callerRole,
      'callerType': callerRole,
      'callerImage': callerImage,
      'callerAvatar': callerImage,
      'receiverId': receiverId,
      'receiverName': receiverName,
      'receiverRole': receiverRole,
      'receiverType': receiverRole,
      'receiverImage': receiverImage,
      'callType': callType,
      'roomId': roomId,
      'channelId': roomId,
      'status': status,
      'callStatus': status,
      'createdAt': Timestamp.fromDate(createdAt.toUtc()),
      'startTime': Timestamp.fromDate(createdAt.toUtc()),
      'startTimeIso': createdAt.toUtc().toIso8601String(),
      if (acceptedAt != null)
        'acceptedAt': Timestamp.fromDate(acceptedAt!.toUtc()),
      if (connectedAt != null)
        'connectedAt': Timestamp.fromDate(connectedAt!.toUtc()),
      if (endedAt != null)
        'endedAt': Timestamp.fromDate(endedAt!.toUtc()),
      'duration': duration,
      'endReason': endReason,
      'missedCall': missedCall,
      'rejectedBy': rejectedBy,
      'callerDeviceId': callerDeviceId,
      'receiverDeviceId': receiverDeviceId,
    };
  }

  factory VoiceCallModel.fromMap(Map<String, dynamic> map, [String? docId]) {
    final id = (map['callId'] ?? map['id'] ?? docId ?? '').toString();
    final rId = (map['roomId'] ?? map['channelId'] ?? id).toString();
    final cRole = (map['callerRole'] ?? map['callerType'] ?? 'doctor').toString();
    final rRole = (map['receiverRole'] ?? map['receiverType'] ?? 'patient').toString();
    final st = (map['status'] ?? map['callStatus'] ?? CallingStatus.calling).toString();

    return VoiceCallModel(
      callId: id,
      callerId: (map['callerId'] ?? map['callerUid'] ?? '').toString(),
      callerName: (map['callerName'] ?? map['caller'] ?? 'Unknown').toString(),
      callerRole: cRole,
      callerImage: map['callerImage']?.toString() ?? map['callerAvatar']?.toString(),
      receiverId: (map['receiverId'] ?? '').toString(),
      receiverName: (map['receiverName'] ?? 'Unknown').toString(),
      receiverRole: rRole,
      receiverImage: map['receiverImage']?.toString(),
      callType: (map['callType'] ?? 'audio').toString(),
      roomId: rId,
      status: st,
      createdAt: _parseTime(
        map['createdAt'] ?? map['startTime'] ?? map['startTimeIso'],
      ),
      acceptedAt: _parseNullableTime(map['acceptedAt']),
      connectedAt: _parseNullableTime(map['connectedAt']),
      endedAt: _parseNullableTime(map['endedAt']),
      duration: (map['duration'] is int)
          ? map['duration'] as int
          : int.tryParse(map['duration']?.toString() ?? '0') ?? 0,
      endReason: map['endReason']?.toString(),
      missedCall: map['missedCall'] == true,
      rejectedBy: map['rejectedBy']?.toString(),
      callerDeviceId: map['callerDeviceId']?.toString(),
      receiverDeviceId: map['receiverDeviceId']?.toString(),
    );
  }

  VoiceCallModel copyWith({
    String? status,
    DateTime? acceptedAt,
    DateTime? connectedAt,
    DateTime? endedAt,
    int? duration,
    String? endReason,
    bool? missedCall,
    String? rejectedBy,
  }) {
    return VoiceCallModel(
      callId: callId,
      callerId: callerId,
      callerName: callerName,
      callerRole: callerRole,
      callerImage: callerImage,
      receiverId: receiverId,
      receiverName: receiverName,
      receiverRole: receiverRole,
      receiverImage: receiverImage,
      callType: callType,
      roomId: roomId,
      status: status ?? this.status,
      createdAt: createdAt,
      acceptedAt: acceptedAt ?? this.acceptedAt,
      connectedAt: connectedAt ?? this.connectedAt,
      endedAt: endedAt ?? this.endedAt,
      duration: duration ?? this.duration,
      endReason: endReason ?? this.endReason,
      missedCall: missedCall ?? this.missedCall,
      rejectedBy: rejectedBy ?? this.rejectedBy,
      callerDeviceId: callerDeviceId,
      receiverDeviceId: receiverDeviceId,
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

