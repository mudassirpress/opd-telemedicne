// lib/data/models/call_model.dart
class CallModel {
  final String id;
  final String callerId;
  final String receiverId;
  final String callerName;
  final String receiverName;
  final String? callerImage;
  final String? receiverImage;
  final String? callerType;
  final String channelId;
  final String callType; // 'audio', 'video'
  final String
  callStatus; // 'calling', 'ringing', 'accepted', 'connected', 'rejected', 'missed', 'ended', 'cancelled', 'failed'
  final DateTime startTime;
  final DateTime? acceptedAt;
  final DateTime? endedAt;
  final int? duration; // Duration in seconds

  CallModel({
    required this.id,
    required this.callerId,
    required this.receiverId,
    required this.callerName,
    required this.receiverName,
    this.callerImage,
    this.receiverImage,
    this.callerType,
    required this.channelId,
    required this.callType,
    required this.callStatus,
    required this.startTime,
    this.acceptedAt,
    this.endedAt,
    this.duration,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'callerId': callerId,
      'receiverId': receiverId,
      'callerName': callerName,
      'receiverName': receiverName,
      'callerImage': callerImage,
      'receiverImage': receiverImage,
      'callerType': callerType,
      'channelId': channelId,
      'callType': callType,
      'callStatus': callStatus,
      'startTime': startTime.toIso8601String(),
      if (acceptedAt != null) 'acceptedAt': acceptedAt!.toIso8601String(),
      if (endedAt != null) 'endedAt': endedAt!.toIso8601String(),
      'duration': duration,
    };
  }

  factory CallModel.fromMap(Map<String, dynamic> map) {
    return CallModel(
      id: map['id'] ?? '',
      callerId: map['callerId'] ?? '',
      receiverId: map['receiverId'] ?? '',
      callerName: map['callerName'] ?? '',
      receiverName: map['receiverName'] ?? '',
      callerImage: map['callerImage'],
      receiverImage: map['receiverImage'],
      callerType: map['callerType'],
      channelId: map['channelId'] ?? '',
      callType: map['callType'] ?? 'audio',
      callStatus: map['callStatus'] ?? 'ringing',
      startTime: _parseTime(map['startTime']),
      acceptedAt: _parseTime(map['acceptedAt']),
      endedAt: _parseTime(map['endedAt']),
      duration: map['duration'],
    );
  }

  static DateTime _parseTime(dynamic value) {
    if (value == null) return DateTime.now();
    if (value is DateTime) return value;
    if (value is String) {
      final parsed = DateTime.tryParse(value);
      if (parsed != null) return parsed;
    }
    return DateTime.now();
  }
}
