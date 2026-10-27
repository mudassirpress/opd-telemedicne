import 'package:cloud_firestore/cloud_firestore.dart';

/// A patient's rating of the doctor who issued a specific prescription.
///
/// Exactly one rating may exist per
/// `doctorId + patientId + prescriptionId` combination. The Firestore document
/// id is derived from that triple, which makes a duplicate physically
/// impossible to store even if two submissions race.
class DoctorRatingModel {
  final String ratingId;
  final String doctorId;
  final String doctorName;
  final String patientId;
  final String patientName;

  /// The prescription this rating belongs to. A doctor sending a second
  /// prescription produces a new id, so it gets its own independent rating.
  final String prescriptionId;

  /// 1 to 5 stars.
  final int rating;

  final DateTime createdAt;

  const DoctorRatingModel({
    required this.ratingId,
    required this.doctorId,
    required this.doctorName,
    required this.patientId,
    required this.patientName,
    required this.prescriptionId,
    required this.rating,
    required this.createdAt,
  });

  /// Deterministic id: one slot per doctor + patient + prescription.
  static String buildId({
    required String doctorId,
    required String patientId,
    required String prescriptionId,
  }) =>
      '${doctorId}_${patientId}_$prescriptionId';

  factory DoctorRatingModel.fromMap(
    String id,
    Map<String, dynamic> map,
  ) {
    return DoctorRatingModel(
      ratingId: (map['ratingId'] ?? id).toString(),
      doctorId: (map['doctorId'] ?? '').toString(),
      doctorName: (map['doctorName'] ?? '').toString(),
      patientId: (map['patientId'] ?? '').toString(),
      patientName: (map['patientName'] ?? '').toString(),
      prescriptionId: (map['prescriptionId'] ?? '').toString(),
      rating: (map['rating'] as num?)?.toInt() ?? 0,
      createdAt: (map['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toMap() => {
        'ratingId': ratingId,
        'doctorId': doctorId,
        'doctorName': doctorName,
        'patientId': patientId,
        'patientName': patientName,
        'prescriptionId': prescriptionId,
        'rating': rating,
        'createdAt': Timestamp.fromDate(createdAt),
      };
}

/// Aggregate rating shown on a doctor's profile.
class DoctorRatingSummary {
  final double average;
  final int total;

  const DoctorRatingSummary({required this.average, required this.total});

  static const empty = DoctorRatingSummary(average: 0, total: 0);

  bool get hasRatings => total > 0;
}
