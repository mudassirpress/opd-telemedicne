import 'package:cloud_firestore/cloud_firestore.dart';

/// Supported payment types across the application.
abstract class PaymentType {
  PaymentType._();

  static const String accountActivation = 'account_activation';
  static const String accountReactivation = 'account_reactivation';
  static const String appointmentBooking = 'appointment_booking';

  static const Set<String> all = {
    accountActivation,
    accountReactivation,
    appointmentBooking,
  };

  static String formatLabel(String? type) {
    switch (type) {
      case accountActivation:
        return 'Account Activation';
      case accountReactivation:
        return 'Account Reactivation';
      case appointmentBooking:
        return 'Appointment Booking';
      default:
        return 'Payment';
    }
  }
}

/// Centralized, consistent Payment data model supporting account activation,
/// account reactivation, and doctor appointment booking.
class PaymentModel {
  final String paymentId;
  final String patientUid;
  final String? patientId;
  final String patientName;
  final String
  paymentType; // 'account_activation', 'account_reactivation', 'appointment_booking'
  final double amount;
  final String currency;
  final String proofReference; // URL or document reference to the proof
  final String status; // 'pending', 'approved', 'rejected', 'completed'
  final String? relatedAppointmentId;
  final String? doctorId;
  final String? doctorName;
  final DateTime createdAt;
  final DateTime? reviewedAt;
  final String? reviewedBy;
  final String? rejectionReason;
  final DateTime? updatedAt;

  const PaymentModel({
    required this.paymentId,
    required this.patientUid,
    this.patientId,
    required this.patientName,
    required this.paymentType,
    required this.amount,
    this.currency = 'PKR',
    required this.proofReference,
    required this.status,
    this.relatedAppointmentId,
    this.doctorId,
    this.doctorName,
    required this.createdAt,
    this.reviewedAt,
    this.reviewedBy,
    this.rejectionReason,
    this.updatedAt,
  });

  bool get isPending => status == 'pending';
  bool get isApproved => status == 'approved' || status == 'completed';
  bool get isRejected => status == 'rejected';

  bool get isActivation => paymentType == PaymentType.accountActivation;
  bool get isReactivation => paymentType == PaymentType.accountReactivation;
  bool get isAppointment => paymentType == PaymentType.appointmentBooking;

  Map<String, dynamic> toMap() {
    return {
      'paymentId': paymentId,
      'patientUid': patientUid,
      if (patientId != null) 'patientId': patientId,
      'patientName': patientName,
      'paymentType': paymentType,
      'amount': amount,
      'currency': currency,
      'proofReference': proofReference,
      'status': status,
      if (relatedAppointmentId != null)
        'relatedAppointmentId': relatedAppointmentId,
      if (doctorId != null) 'doctorId': doctorId,
      if (doctorName != null) 'doctorName': doctorName,
      'createdAt': Timestamp.fromDate(createdAt),
      if (reviewedAt != null) 'reviewedAt': Timestamp.fromDate(reviewedAt!),
      if (reviewedBy != null) 'reviewedBy': reviewedBy,
      if (rejectionReason != null) 'rejectionReason': rejectionReason,
      if (updatedAt != null) 'updatedAt': Timestamp.fromDate(updatedAt!),
    };
  }

  factory PaymentModel.fromMap(Map<String, dynamic> map, String id) {
    DateTime parseDate(dynamic value) {
      if (value == null) return DateTime.now();
      if (value is Timestamp) return value.toDate();
      if (value is DateTime) return value;
      if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
      if (value is String) return DateTime.tryParse(value) ?? DateTime.now();
      return DateTime.now();
    }

    return PaymentModel(
      paymentId: (map['paymentId'] ?? id).toString(),
      patientUid:
          (map['patientUid'] ?? map['patientUserId'] ?? map['userId'] ?? '')
              .toString(),
      patientId: map['patientId'] as String?,
      patientName: (map['patientName'] ?? map['fullname'] ?? 'Patient')
          .toString(),
      paymentType: (map['paymentType'] ?? PaymentType.accountActivation)
          .toString(),
      amount:
          (map['amount'] ?? map['payableAmount'] ?? map['totalPayment'] ?? 0.0)
              .toDouble(),
      currency: (map['currency'] ?? 'PKR').toString(),
      proofReference:
          (map['proofReference'] ??
                  map['paymentImage'] ??
                  map['paymentProofUrl'] ??
                  '')
              .toString(),
      status: (map['status'] ?? map['paymentStatus'] ?? 'pending').toString(),
      relatedAppointmentId:
          (map['relatedAppointmentId'] ?? map['appointmentId']) as String?,
      doctorId: map['doctorId'] as String?,
      doctorName: map['doctorName'] as String?,
      createdAt: parseDate(
        map['createdAt'] ?? map['submittedAt'] ?? map['paymentSubmittedAt'],
      ),
      reviewedAt: map['reviewedAt'] != null
          ? parseDate(map['reviewedAt'])
          : null,
      reviewedBy: map['reviewedBy'] as String?,
      rejectionReason: map['rejectionReason'] as String?,
      updatedAt: map['updatedAt'] != null ? parseDate(map['updatedAt']) : null,
    );
  }

  PaymentModel copyWith({
    String? paymentId,
    String? patientUid,
    String? patientId,
    String? patientName,
    String? paymentType,
    double? amount,
    String? currency,
    String? proofReference,
    String? status,
    String? relatedAppointmentId,
    String? doctorId,
    String? doctorName,
    DateTime? createdAt,
    DateTime? reviewedAt,
    String? reviewedBy,
    String? rejectionReason,
    DateTime? updatedAt,
  }) {
    return PaymentModel(
      paymentId: paymentId ?? this.paymentId,
      patientUid: patientUid ?? this.patientUid,
      patientId: patientId ?? this.patientId,
      patientName: patientName ?? this.patientName,
      paymentType: paymentType ?? this.paymentType,
      amount: amount ?? this.amount,
      currency: currency ?? this.currency,
      proofReference: proofReference ?? this.proofReference,
      status: status ?? this.status,
      relatedAppointmentId: relatedAppointmentId ?? this.relatedAppointmentId,
      doctorId: doctorId ?? this.doctorId,
      doctorName: doctorName ?? this.doctorName,
      createdAt: createdAt ?? this.createdAt,
      reviewedAt: reviewedAt ?? this.reviewedAt,
      reviewedBy: reviewedBy ?? this.reviewedBy,
      rejectionReason: rejectionReason ?? this.rejectionReason,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
