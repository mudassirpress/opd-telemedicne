// lib/admin_portal/models/doctor_online_history_model.dart
import 'package:cloud_firestore/cloud_firestore.dart';

class DoctorOnlineSession {
  final String id;
  final String doctorId;
  final String doctorName;
  final DateTime startTime;
  final DateTime? endTime;
  final Duration duration;
  final bool isActive;

  DoctorOnlineSession({
    required this.id,
    required this.doctorId,
    required this.doctorName,
    required this.startTime,
    this.endTime,
    required this.duration,
    required this.isActive,
  });

  Map<String, dynamic> toMap() {
    return {
      'doctorId': doctorId,
      'doctorName': doctorName,
      'startTime': Timestamp.fromDate(startTime),
      'endTime': endTime != null ? Timestamp.fromDate(endTime!) : null,
      'durationInSeconds': duration.inSeconds,
      'isActive': isActive,
      'createdAt': Timestamp.fromDate(startTime),
    };
  }

  factory DoctorOnlineSession.fromMap(String id, Map<String, dynamic> map) {
    final startTime = (map['startTime'] as Timestamp).toDate();
    final endTime = map['endTime'] != null
        ? (map['endTime'] as Timestamp).toDate()
        : null;

    return DoctorOnlineSession(
      id: id,
      doctorId: map['doctorId'] ?? '',
      doctorName: map['doctorName'] ?? '',
      startTime: startTime,
      endTime: endTime,
      duration: Duration(seconds: map['durationInSeconds'] ?? 0),
      isActive: map['isActive'] ?? false,
    );
  }
}

class DoctorDailyStats {
  final String doctorId;
  final String doctorName;
  final DateTime date;
  final Duration totalOnlineDuration;
  final int sessionsCount;

  DoctorDailyStats({
    required this.doctorId,
    required this.doctorName,
    required this.date,
    required this.totalOnlineDuration,
    required this.sessionsCount,
  });

  Map<String, dynamic> toMap() {
    return {
      'doctorId': doctorId,
      'doctorName': doctorName,
      'date': Timestamp.fromDate(DateTime(date.year, date.month, date.day)),
      'totalDurationInSeconds': totalOnlineDuration.inSeconds,
      'sessionsCount': sessionsCount,
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }

  factory DoctorDailyStats.fromMap(Map<String, dynamic> map) {
    return DoctorDailyStats(
      doctorId: map['doctorId'] ?? '',
      doctorName: map['doctorName'] ?? '',
      date: (map['date'] as Timestamp).toDate(),
      totalOnlineDuration: Duration(
        seconds: map['totalDurationInSeconds'] ?? 0,
      ),
      sessionsCount: map['sessionsCount'] ?? 0,
    );
  }
}
