import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:telemedicine/core/utils/subscription_calculator.dart';

class PatientIdModel {
  final String id;
  final String patientId;
  final String status; // Available, Assigned, Blocked
  final String batchNumber;
  final DateTime generatedAt;
  final DateTime? assignedAt;
  final DateTime? startDate;
  final DateTime? expiryDate;
  final String? patientUserId;
  final bool isActive;
  final String subscriptionPlan; // 'one_month', 'six_months', 'one_year'
  final int durationMonths; // 1, 6, 12

  PatientIdModel({
    required this.id,
    required this.patientId,
    required this.status,
    required this.batchNumber,
    required this.generatedAt,
    this.assignedAt,
    this.startDate,
    this.expiryDate,
    this.patientUserId,
    this.isActive = true,
    this.subscriptionPlan = 'six_months',
    this.durationMonths = 6,
  });

  /// The strongly-typed [SubscriptionPlan] representation.
  SubscriptionPlan get plan => SubscriptionPlan.fromPlanId(subscriptionPlan);

  factory PatientIdModel.fromMap(Map<String, dynamic> map) {
    final rawDuration = map['durationMonths'];
    final int? parsedDuration = rawDuration is int
        ? rawDuration
        : (rawDuration is num
              ? rawDuration.toInt()
              : int.tryParse(rawDuration?.toString() ?? ''));

    final rawPlan = map['subscriptionPlan']?.toString();
    final String resolvedPlan = rawPlan != null && rawPlan.isNotEmpty
        ? rawPlan
        : (parsedDuration == 1
              ? 'one_month'
              : (parsedDuration == 12 ? 'one_year' : 'six_months'));

    final int resolvedDuration =
        parsedDuration ??
        (resolvedPlan == 'one_month'
            ? 1
            : (resolvedPlan == 'one_year' ? 12 : 6));

    return PatientIdModel(
      id: map['id'] ?? '',
      patientId: map['patientId'] ?? '',
      status: map['status'] ?? 'Available',
      batchNumber: map['batchNumber'] ?? '',
      generatedAt: map['generatedAt'] != null
          ? (map['generatedAt'] is Timestamp
                ? (map['generatedAt'] as Timestamp).toDate()
                : DateTime.tryParse(map['generatedAt'].toString()) ??
                      DateTime.now())
          : DateTime.now(),
      assignedAt: map['assignedAt'] != null
          ? (map['assignedAt'] is Timestamp
                ? (map['assignedAt'] as Timestamp).toDate()
                : DateTime.tryParse(map['assignedAt'].toString()))
          : null,
      startDate: map['startDate'] != null
          ? (map['startDate'] is Timestamp
                ? (map['startDate'] as Timestamp).toDate()
                : DateTime.tryParse(map['startDate'].toString()))
          : (map['assignedAt'] != null
                ? (map['assignedAt'] is Timestamp
                      ? (map['assignedAt'] as Timestamp).toDate()
                      : DateTime.tryParse(map['assignedAt'].toString()))
                : null),
      expiryDate: map['expiryDate'] != null
          ? (map['expiryDate'] is Timestamp
                ? (map['expiryDate'] as Timestamp).toDate()
                : DateTime.tryParse(map['expiryDate'].toString()))
          : null,
      patientUserId: map['patientUserId'],
      isActive: map['isActive'] ?? true,
      subscriptionPlan: resolvedPlan,
      durationMonths: resolvedDuration,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'patientId': patientId,
      'status': status,
      'batchNumber': batchNumber,
      'generatedAt': Timestamp.fromDate(generatedAt),
      'assignedAt': assignedAt != null ? Timestamp.fromDate(assignedAt!) : null,
      'startDate': startDate != null
          ? Timestamp.fromDate(startDate!)
          : (assignedAt != null ? Timestamp.fromDate(assignedAt!) : null),
      'expiryDate': expiryDate != null ? Timestamp.fromDate(expiryDate!) : null,
      'patientUserId': patientUserId,
      'isActive': isActive,
      'subscriptionPlan': subscriptionPlan,
      'durationMonths': durationMonths,
    };
  }

  /// Whether this Patient ID has passed its expiry date.
  bool get isExpired {
    if (expiryDate == null) return false;
    return DateTime.now().isAfter(expiryDate!);
  }

  PatientIdModel copyWith({
    String? id,
    String? patientId,
    String? status,
    String? batchNumber,
    DateTime? generatedAt,
    DateTime? assignedAt,
    DateTime? startDate,
    DateTime? expiryDate,
    String? patientUserId,
    bool? isActive,
    String? subscriptionPlan,
    int? durationMonths,
  }) {
    return PatientIdModel(
      id: id ?? this.id,
      patientId: patientId ?? this.patientId,
      status: status ?? this.status,
      batchNumber: batchNumber ?? this.batchNumber,
      generatedAt: generatedAt ?? this.generatedAt,
      assignedAt: assignedAt ?? this.assignedAt,
      startDate: startDate ?? this.startDate,
      expiryDate: expiryDate ?? this.expiryDate,
      patientUserId: patientUserId ?? this.patientUserId,
      isActive: isActive ?? this.isActive,
      subscriptionPlan: subscriptionPlan ?? this.subscriptionPlan,
      durationMonths: durationMonths ?? this.durationMonths,
    );
  }
}
