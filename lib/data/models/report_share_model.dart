import 'package:cloud_firestore/cloud_firestore.dart';

/// A single "report shared with a doctor" record in the `report_shares`
/// collection.
///
/// Document id is deterministic: `{reportId}_{doctorId}` — this keeps a
/// share idempotent (re-sharing updates the same doc instead of creating a
/// duplicate) and makes revoke a simple `status` flip.
class SharedReportModel {
  static const String statusShared = 'shared';
  static const String statusRevoked = 'revoked';

  final String id;
  final String reportId;
  final String patientId;
  final String patientName;
  final String doctorId;
  final String doctorName;

  /// Report type display name (kept denormalized so the doctor never needs to
  /// read the patient's `reports` document).
  final String reportName;
  final String description;

  /// Reuses the existing Cloudinary URL stored on the original report — no
  /// duplicate file is created.
  final String reportUrl;
  final DateTime reportDate;
  final DateTime reportUploadDate;
  final DateTime sharedAt;

  /// The patient uid who initiated the share (same as [patientId]).
  final String sharedBy;
  final String status;
  final DateTime? revokedAt;

  const SharedReportModel({
    required this.id,
    required this.reportId,
    required this.patientId,
    required this.patientName,
    required this.doctorId,
    required this.doctorName,
    required this.reportName,
    required this.description,
    required this.reportUrl,
    required this.reportDate,
    required this.reportUploadDate,
    required this.sharedAt,
    required this.sharedBy,
    required this.status,
    this.revokedAt,
  });

  bool get isShared => status == statusShared;

  factory SharedReportModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>? ?? {};
    return SharedReportModel(
      id: doc.id,
      reportId: data['reportId'] ?? '',
      patientId: data['patientId'] ?? '',
      patientName: data['patientName'] ?? '',
      doctorId: data['doctorId'] ?? '',
      doctorName: data['doctorName'] ?? '',
      reportName: data['reportName'] ?? '',
      description: data['description'] ?? '',
      reportUrl: data['reportUrl'] ?? '',
      reportDate:
          (data['reportDate'] as Timestamp?)?.toDate() ?? DateTime.now(),
      reportUploadDate:
          (data['reportUploadDate'] as Timestamp?)?.toDate() ?? DateTime.now(),
      sharedAt: (data['sharedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      sharedBy: data['sharedBy'] ?? '',
      status: data['status'] ?? statusShared,
      revokedAt: (data['revokedAt'] as Timestamp?)?.toDate(),
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'reportId': reportId,
      'patientId': patientId,
      'patientName': patientName,
      'doctorId': doctorId,
      'doctorName': doctorName,
      'reportName': reportName,
      'description': description,
      'reportUrl': reportUrl,
      'reportDate': Timestamp.fromDate(reportDate),
      'reportUploadDate': Timestamp.fromDate(reportUploadDate),
      'sharedAt': Timestamp.fromDate(sharedAt),
      'sharedBy': sharedBy,
      'status': status,
      'revokedAt': revokedAt != null ? Timestamp.fromDate(revokedAt!) : null,
    };
  }
}
