import 'package:cloud_firestore/cloud_firestore.dart';

/// Model representing a persistent admin notification in Firestore.
class AdminNotificationModel {
  final String notificationId;
  final String type; // 'payment_complaint', 'payment_submitted', etc.
  final String title;
  final String body;
  final String complaintId;
  final String patientUid;
  final String? patientId;
  final String patientName;
  final String? paymentId;
  final String? paymentStatus;
  final String? category;
  final bool isRead;
  final DateTime createdAt;

  bool get isComplaint => type == 'payment_complaint';

  const AdminNotificationModel({
    required this.notificationId,
    this.type = 'payment_complaint',
    required this.title,
    required this.body,
    required this.complaintId,
    required this.patientUid,
    this.patientId,
    required this.patientName,
    this.paymentId,
    this.paymentStatus,
    this.category,
    this.isRead = false,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'notificationId': notificationId,
      'type': type,
      'title': title,
      'body': body,
      'complaintId': complaintId,
      'patientUid': patientUid,
      'patientId': patientId,
      'patientName': patientName,
      'paymentId': paymentId,
      'paymentStatus': paymentStatus,
      'category': category,
      'isRead': isRead,
      'createdAt': Timestamp.fromDate(createdAt),
    };
  }

  factory AdminNotificationModel.fromMap(Map<String, dynamic> map, String id) {
    DateTime parseDate(dynamic value) {
      if (value is Timestamp) return value.toDate();
      if (value is DateTime) return value;
      if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
      if (value is String) return DateTime.tryParse(value) ?? DateTime.now();
      return DateTime.now();
    }

    return AdminNotificationModel(
      notificationId: (map['notificationId'] ?? id).toString(),
      type: (map['type'] ?? 'payment_complaint').toString(),
      title: (map['title'] ?? 'Notification').toString(),
      body: (map['body'] ?? '').toString(),
      complaintId: (map['complaintId'] ?? '').toString(),
      patientUid: (map['patientUid'] ?? '').toString(),
      patientId: map['patientId'] as String?,
      patientName: (map['patientName'] ?? 'Patient').toString(),
      paymentId: map['paymentId'] as String?,
      paymentStatus: map['paymentStatus'] as String?,
      category: map['category'] as String?,
      isRead: map['isRead'] == true,
      createdAt: parseDate(map['createdAt']),
    );
  }

  AdminNotificationModel copyWith({
    String? notificationId,
    String? type,
    String? title,
    String? body,
    String? complaintId,
    String? patientUid,
    String? patientId,
    String? patientName,
    String? paymentId,
    String? paymentStatus,
    String? category,
    bool? isRead,
    DateTime? createdAt,
  }) {
    return AdminNotificationModel(
      notificationId: notificationId ?? this.notificationId,
      type: type ?? this.type,
      title: title ?? this.title,
      body: body ?? this.body,
      complaintId: complaintId ?? this.complaintId,
      patientUid: patientUid ?? this.patientUid,
      patientId: patientId ?? this.patientId,
      patientName: patientName ?? this.patientName,
      paymentId: paymentId ?? this.paymentId,
      paymentStatus: paymentStatus ?? this.paymentStatus,
      category: category ?? this.category,
      isRead: isRead ?? this.isRead,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}
