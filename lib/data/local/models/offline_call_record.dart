import 'package:hive/hive.dart';

part 'offline_call_record.g.dart';

@HiveType(typeId: 2)
class OfflineCallRecord {
  @HiveField(0)
  final String callId;

  @HiveField(1)
  final String callerId;

  @HiveField(2)
  final String receiverId;

  @HiveField(3)
  final String callType; // audio, video

  @HiveField(4)
  final DateTime startTime;

  @HiveField(5)
  final DateTime? endTime;

  @HiveField(6)
  final int? duration; // seconds

  @HiveField(7)
  final String callStatus; // ringing, ongoing, ended, missed, rejected

  @HiveField(8)
  final String? callerName;

  @HiveField(9)
  final String? receiverName;

  @HiveField(10)
  final String? callerImage;

  @HiveField(11)
  final String? receiverImage;

  @HiveField(12)
  final String channelId;

  @HiveField(13)
  final bool synced;

  OfflineCallRecord({
    required this.callId,
    required this.callerId,
    required this.receiverId,
    required this.callType,
    required this.startTime,
    this.endTime,
    this.duration,
    required this.callStatus,
    this.callerName,
    this.receiverName,
    this.callerImage,
    this.receiverImage,
    this.channelId = '',
    this.synced = false,
  });

  OfflineCallRecord copyWith({
    String? callStatus,
    DateTime? endTime,
    int? duration,
    bool? synced,
  }) {
    return OfflineCallRecord(
      callId: callId,
      callerId: callerId,
      receiverId: receiverId,
      callType: callType,
      startTime: startTime,
      endTime: endTime ?? this.endTime,
      duration: duration ?? this.duration,
      callStatus: callStatus ?? this.callStatus,
      callerName: callerName,
      receiverName: receiverName,
      callerImage: callerImage,
      receiverImage: receiverImage,
      channelId: channelId,
      synced: synced ?? this.synced,
    );
  }
}
