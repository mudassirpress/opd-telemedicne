import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:telemedicine/core/utils/subscription_calculator.dart';

class ReactivationRequestModel {
  final String id;
  final String patientUserId;
  final String patientId;
  final String patientName;
  final String paymentProofUrl;
  final String status; // pending, approved, rejected
  final DateTime submittedAt;
  final DateTime? reviewedAt;
  final String? reviewedBy;
  final String? rejectionReason;
  final DateTime? previousExpiryDate;
  final DateTime? newExpiryDate;
  final String? subscriptionPlan; // 'one_month', 'six_months', 'one_year'
  final int? durationMonths; // 1, 6, 12

  ReactivationRequestModel({
    required this.id,
    required this.patientUserId,
    required this.patientId,
    required this.patientName,
    required this.paymentProofUrl,
    required this.status,
    required this.submittedAt,
    this.reviewedAt,
    this.reviewedBy,
    this.rejectionReason,
    this.previousExpiryDate,
    this.newExpiryDate,
    this.subscriptionPlan,
    this.durationMonths,
  });

  /// Strongly-typed subscription plan representation.
  SubscriptionPlan get plan => SubscriptionPlan.fromPlanId(subscriptionPlan);

  /// Effective duration in whole months.
  int get effectiveDurationMonths => durationMonths ?? plan.durationMonths;

  factory ReactivationRequestModel.fromMap(Map<String, dynamic> map) {
    final rawDuration = map['durationMonths'];
    final int? parsedDuration = rawDuration is int
        ? rawDuration
        : (rawDuration is num ? rawDuration.toInt() : int.tryParse(rawDuration?.toString() ?? ''));

    return ReactivationRequestModel(
      id: map['id'] ?? '',
      patientUserId: map['patientUserId'] ?? '',
      patientId: map['patientId'] ?? '',
      patientName: map['patientName'] ?? '',
      paymentProofUrl: map['paymentProofUrl'] ?? '',
      status: map['status'] ?? 'pending',
      submittedAt: map['submittedAt'] != null
          ? (map['submittedAt'] is Timestamp
              ? (map['submittedAt'] as Timestamp).toDate()
              : DateTime.tryParse(map['submittedAt'].toString()) ?? DateTime.now())
          : DateTime.now(),
      reviewedAt: map['reviewedAt'] != null
          ? (map['reviewedAt'] is Timestamp
              ? (map['reviewedAt'] as Timestamp).toDate()
              : DateTime.tryParse(map['reviewedAt'].toString()))
          : null,
      reviewedBy: map['reviewedBy'],
      rejectionReason: map['rejectionReason'],
      previousExpiryDate: map['previousExpiryDate'] != null
          ? (map['previousExpiryDate'] is Timestamp
              ? (map['previousExpiryDate'] as Timestamp).toDate()
              : DateTime.tryParse(map['previousExpiryDate'].toString()))
          : null,
      newExpiryDate: map['newExpiryDate'] != null
          ? (map['newExpiryDate'] is Timestamp
              ? (map['newExpiryDate'] as Timestamp).toDate()
              : DateTime.tryParse(map['newExpiryDate'].toString()))
          : null,
      subscriptionPlan: map['subscriptionPlan']?.toString(),
      durationMonths: parsedDuration,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'patientUserId': patientUserId,
      'patientId': patientId,
      'patientName': patientName,
      'paymentProofUrl': paymentProofUrl,
      'status': status,
      'submittedAt': Timestamp.fromDate(submittedAt),
      'reviewedAt': reviewedAt != null ? Timestamp.fromDate(reviewedAt!) : null,
      'reviewedBy': reviewedBy,
      'rejectionReason': rejectionReason,
      'previousExpiryDate': previousExpiryDate != null
          ? Timestamp.fromDate(previousExpiryDate!)
          : null,
      'newExpiryDate': newExpiryDate != null
          ? Timestamp.fromDate(newExpiryDate!)
          : null,
      if (subscriptionPlan != null) 'subscriptionPlan': subscriptionPlan,
      if (durationMonths != null) 'durationMonths': durationMonths,
    };
  }

  ReactivationRequestModel copyWith({
    String? id,
    String? patientUserId,
    String? patientId,
    String? patientName,
    String? paymentProofUrl,
    String? status,
    DateTime? submittedAt,
    DateTime? reviewedAt,
    String? reviewedBy,
    String? rejectionReason,
    DateTime? previousExpiryDate,
    DateTime? newExpiryDate,
    String? subscriptionPlan,
    int? durationMonths,
  }) {
    return ReactivationRequestModel(
      id: id ?? this.id,
      patientUserId: patientUserId ?? this.patientUserId,
      patientId: patientId ?? this.patientId,
      patientName: patientName ?? this.patientName,
      paymentProofUrl: paymentProofUrl ?? this.paymentProofUrl,
      status: status ?? this.status,
      submittedAt: submittedAt ?? this.submittedAt,
      reviewedAt: reviewedAt ?? this.reviewedAt,
      reviewedBy: reviewedBy ?? this.reviewedBy,
      rejectionReason: rejectionReason ?? this.rejectionReason,
      previousExpiryDate: previousExpiryDate ?? this.previousExpiryDate,
      newExpiryDate: newExpiryDate ?? this.newExpiryDate,
      subscriptionPlan: subscriptionPlan ?? this.subscriptionPlan,
      durationMonths: durationMonths ?? this.durationMonths,
    );
  }
}
