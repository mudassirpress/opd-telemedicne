import 'package:cloud_firestore/cloud_firestore.dart';

/// Model representing a persistent patient notification in Firestore.
/// Stored in `patient_notifications/{notificationId}`.
class PatientNotificationModel {
  final String notificationId;
  final String recipientUid;
  final String
  type; // 'payment_approved', 'payment_rejected', 'complaint_reply', etc.
  final String title;
  final String body;
  final String senderName; // 'OPD Telemedicine Admin'
  final String? paymentId;
  final String?
  paymentType; // 'account_activation', 'account_reactivation', 'appointment_booking'
  final String? complaintId;
  final String? appointmentId;
  final bool isRead;
  final DateTime createdAt;

  const PatientNotificationModel({
    required this.notificationId,
    required this.recipientUid,
    required this.type,
    required this.title,
    required this.body,
    this.senderName = 'OPD Telemedicine Admin',
    this.paymentId,
    this.paymentType,
    this.complaintId,
    this.appointmentId,
    this.isRead = false,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'notificationId': notificationId,
      'recipientUid': recipientUid,
      'type': type,
      'title': title,
      'body': body,
      'senderName': senderName,
      if (paymentId != null) 'paymentId': paymentId,
      if (paymentType != null) 'paymentType': paymentType,
      if (complaintId != null) 'complaintId': complaintId,
      if (appointmentId != null) 'appointmentId': appointmentId,
      'isRead': isRead,
      'createdAt': Timestamp.fromDate(createdAt),
    };
  }

  factory PatientNotificationModel.fromMap(
    Map<String, dynamic> map,
    String id,
  ) {
    DateTime parseDate(dynamic value) {
      if (value is Timestamp) return value.toDate();
      if (value is DateTime) return value;
      if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
      if (value is String) return DateTime.tryParse(value) ?? DateTime.now();
      return DateTime.now();
    }

    return PatientNotificationModel(
      notificationId: (map['notificationId'] ?? id).toString(),
      recipientUid: (map['recipientUid'] ?? '').toString(),
      type: (map['type'] ?? 'payment_approved').toString(),
      title: (map['title'] ?? 'Notification').toString(),
      body: (map['body'] ?? '').toString(),
      senderName: (map['senderName'] ?? 'OPD Telemedicine Admin').toString(),
      paymentId: map['paymentId'] as String?,
      paymentType: map['paymentType'] as String?,
      complaintId: map['complaintId'] as String?,
      appointmentId: map['appointmentId'] as String?,
      isRead: map['isRead'] == true,
      createdAt: parseDate(map['createdAt']),
    );
  }

  PatientNotificationModel copyWith({
    String? notificationId,
    String? recipientUid,
    String? type,
    String? title,
    String? body,
    String? senderName,
    String? paymentId,
    String? paymentType,
    String? complaintId,
    String? appointmentId,
    bool? isRead,
    DateTime? createdAt,
  }) {
    return PatientNotificationModel(
      notificationId: notificationId ?? this.notificationId,
      recipientUid: recipientUid ?? this.recipientUid,
      type: type ?? this.type,
      title: title ?? this.title,
      body: body ?? this.body,
      senderName: senderName ?? this.senderName,
      paymentId: paymentId ?? this.paymentId,
      paymentType: paymentType ?? this.paymentType,
      complaintId: complaintId ?? this.complaintId,
      appointmentId: appointmentId ?? this.appointmentId,
      isRead: isRead ?? this.isRead,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}
