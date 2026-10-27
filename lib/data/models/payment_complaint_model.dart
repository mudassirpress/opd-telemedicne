import 'package:cloud_firestore/cloud_firestore.dart';

/// Represents a patient complaint submitted regarding payments or account restrictions.
class PaymentComplaintModel {
  final String complaintId;
  final String patientUid;
  final String? patientId;
  final String patientName;
  final String category;
  final String message;
  final String? paymentId;
  final String? appointmentId;
  final String paymentStatusAtSubmission;
  final String status; // 'open', 'in_progress', 'resolved'
  final String? adminResponse;
  final DateTime? adminRespondedAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  const PaymentComplaintModel({
    required this.complaintId,
    required this.patientUid,
    this.patientId,
    required this.patientName,
    required this.category,
    required this.message,
    this.paymentId,
    this.appointmentId,
    required this.paymentStatusAtSubmission,
    this.status = 'open',
    this.adminResponse,
    this.adminRespondedAt,
    required this.createdAt,
    required this.updatedAt,
  });

  bool get isOpen => status == 'open';
  bool get isInProgress => status == 'in_progress';
  bool get isResolved => status == 'resolved';

  Map<String, dynamic> toMap() {
    return {
      'complaintId': complaintId,
      'patientUid': patientUid,
      if (patientId != null) 'patientId': patientId,
      'patientName': patientName,
      'category': category,
      'message': message,
      if (paymentId != null) 'paymentId': paymentId,
      if (appointmentId != null) 'appointmentId': appointmentId,
      'paymentStatusAtSubmission': paymentStatusAtSubmission,
      'status': status,
      if (adminResponse != null) 'adminResponse': adminResponse,
      'adminRespondedAt': adminRespondedAt != null
          ? Timestamp.fromDate(adminRespondedAt!)
          : null,
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': Timestamp.fromDate(updatedAt),
    };
  }

  factory PaymentComplaintModel.fromMap(Map<String, dynamic> map, String id) {
    DateTime parseDate(dynamic value) {
      if (value is Timestamp) return value.toDate();
      if (value is DateTime) return value;
      if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
      if (value is String) return DateTime.tryParse(value) ?? DateTime.now();
      return DateTime.now();
    }

    return PaymentComplaintModel(
      complaintId: (map['complaintId'] ?? id).toString(),
      patientUid: (map['patientUid'] ?? '').toString(),
      patientId: map['patientId'] as String?,
      patientName: (map['patientName'] ?? 'Unknown Patient').toString(),
      category: (map['category'] ?? 'Other payment-related issue').toString(),
      message: (map['message'] ?? '').toString(),
      paymentId: map['paymentId'] as String?,
      appointmentId: map['appointmentId'] as String?,
      paymentStatusAtSubmission:
          (map['paymentStatusAtSubmission'] ?? 'not_submitted').toString(),
      status: (map['status'] ?? 'open').toString(),
      adminResponse: map['adminResponse'] as String?,
      adminRespondedAt: map['adminRespondedAt'] != null
          ? parseDate(map['adminRespondedAt'])
          : null,
      createdAt: parseDate(map['createdAt']),
      updatedAt: parseDate(map['updatedAt']),
    );
  }

  PaymentComplaintModel copyWith({
    String? complaintId,
    String? patientUid,
    String? patientId,
    String? patientName,
    String? category,
    String? message,
    String? paymentId,
    String? appointmentId,
    String? paymentStatusAtSubmission,
    String? status,
    String? adminResponse,
    DateTime? adminRespondedAt,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return PaymentComplaintModel(
      complaintId: complaintId ?? this.complaintId,
      patientUid: patientUid ?? this.patientUid,
      patientId: patientId ?? this.patientId,
      patientName: patientName ?? this.patientName,
      category: category ?? this.category,
      message: message ?? this.message,
      paymentId: paymentId ?? this.paymentId,
      appointmentId: appointmentId ?? this.appointmentId,
      paymentStatusAtSubmission:
          paymentStatusAtSubmission ?? this.paymentStatusAtSubmission,
      status: status ?? this.status,
      adminResponse: adminResponse ?? this.adminResponse,
      adminRespondedAt: adminRespondedAt ?? this.adminRespondedAt,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
