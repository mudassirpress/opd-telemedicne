import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/features/auth/presentation/providers/user_provider.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/features/chat/presentation/controllers/chat_controller.dart';
import 'package:telemedicine/core/services/notification_dispatcher.dart';
import 'package:telemedicine/core/services/soft_delete_service.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/data/models/report_model.dart';
import 'package:telemedicine/data/models/report_share_model.dart';

final reportShareControllerProvider = Provider(
  (ref) => ReportShareController(ref: ref),
);

class ReportShareController {
  final Ref ref;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  ReportShareController({required this.ref});

  CollectionReference get _sharesCollection =>
      _firestore.collection(FirestoreCollections.reportShares);

  /// Deterministic document id for a (report, doctor) pair so shares are
  /// idempotent: sharing again reactivates the same doc, never a duplicate.
  String _shareDocId(String reportId, String doctorId) =>
      '${reportId}_$doctorId';

  /// Shares a report with a doctor.
  ///
  /// Reuses the existing report file URL (no duplicate file), denormalizes the
  /// metadata both parties need, and pushes an FCM notification to the doctor.
  Future<bool> shareReportWithDoctor({
    required ReportModel report,
    required String doctorId,
    required String doctorName,
  }) async {
    final user = ref.read(userProvider);
    if (user == null) {
      ToastService.instance.showError('User not logged in');
      return false;
    }
    if (report.id.isEmpty || doctorId.isEmpty) {
      ToastService.instance.showError('Invalid report or doctor');
      return false;
    }

    // SOFT DELETE — sharing a report is a new business action with the doctor.
    // The doctor list the picker reads is already filtered, but the live
    // Firestore state is re-checked so a doctor deactivated while the screen
    // was open still cannot receive new work.
    final blockedReason = await SoftDeleteService.newBusinessBlockedReason(
      doctorId,
    );
    if (blockedReason != null) {
      ToastService.instance.showError(blockedReason);
      return false;
    }

    try {
      final now = DateTime.now();
      final share = SharedReportModel(
        id: _shareDocId(report.id, doctorId),
        reportId: report.id,
        patientId: user.id,
        patientName: user.fullname.isEmpty ? 'Patient' : user.fullname,
        doctorId: doctorId,
        doctorName: doctorName,
        reportName: report.reportType,
        description: report.description,
        reportUrl: report.fileUrl,
        reportDate: report.reportDate,
        reportUploadDate: report.uploadDate,
        sharedAt: now,
        sharedBy: user.id,
        status: SharedReportModel.statusShared,
        revokedAt: null,
      );

      await _sharesCollection
          .doc(_shareDocId(report.id, doctorId))
          .set(share.toFirestore(), SetOptions(merge: true));

      unawaitedSendNotification(
        doctorId: doctorId,
        patientId: user.id,
        patientName: user.fullname.isEmpty ? 'Patient' : user.fullname,
        reportId: report.id,
        reportName: report.reportType,
      );

      // Also forward to chat. The share itself already succeeded at this
      // point, so a chat failure must not roll it back — but it used to be
      // swallowed with an empty catch, leaving the patient believing the
      // doctor had received a chat message they never got.
      try {
        await ChatController().sendMessage(
          senderId: user.id,
          receiverId: doctorId,
          message: report.reportType,
          messageType: 'forwarded_report',
          mediaUrl: report.fileUrl,
          fileName: report.fileUrl.split('/').last.split('?').first,
          receiverRole: 'doctor',
          callData: {
            'reportId': report.id,
            'reportType': report.reportType,
            'uploadDate': report.uploadDate.toIso8601String(),
          },
        );
      } catch (e) {
        ToastService.instance.showWarning(
          'Report shared, but the chat message could not be sent.',
        );
      }

      return true;
    } catch (e) {
      ToastService.instance.showError(
        'Failed to share report: ${e.toString()}',
      );
      return false;
    }
  }

  /// Revokes a doctor's access to a report. The share doc stays (kept for the
  /// patient's audit trail) but its status flips to `revoked`, which removes
  /// it from the doctor's realtime shared-report stream.
  Future<bool> revokeReportAccess({
    required String reportId,
    required String doctorId,
  }) async {
    final user = ref.read(userProvider);
    if (user == null) {
      ToastService.instance.showError('User not logged in');
      return false;
    }

    try {
      final docRef = _sharesCollection.doc(_shareDocId(reportId, doctorId));
      final snapshot = await docRef.get();
      if (!snapshot.exists) {
        ToastService.instance.showError('Access not found');
        return false;
      }
      final data = snapshot.data() as Map<String, dynamic>;
      if (data['patientId'] != user.id) {
        ToastService.instance.showError('You can only revoke your own shares');
        return false;
      }

      await docRef.update({
        'status': SharedReportModel.statusRevoked,
        'revokedAt': FieldValue.serverTimestamp(),
      });
      return true;
    } catch (e) {
      ToastService.instance.showError(
        'Failed to revoke access: ${e.toString()}',
      );
      return false;
    }
  }

  /// All shares belonging to a patient (shared + revoked), for the patient's
  /// manage/revoke screen. Single-field filter avoids extra composite indexes.
  Stream<List<SharedReportModel>> streamPatientShares(String patientId) {
    return _sharesCollection
        .where('patientId', isEqualTo: patientId)
        .snapshots()
        .map((snapshot) {
          final shares = snapshot.docs
              .map((doc) => SharedReportModel.fromFirestore(doc))
              .toList();
          shares.sort((a, b) => b.sharedAt.compareTo(a.sharedAt));
          return shares;
        });
  }

  /// Active shares for one report (used by the Share screen + history badges).
  Stream<List<SharedReportModel>> streamActiveSharesForReport(String reportId) {
    return _sharesCollection
        .where('reportId', isEqualTo: reportId)
        .snapshots()
        .map((snapshot) {
          final shares = snapshot.docs
              .map((doc) => SharedReportModel.fromFirestore(doc))
              .where((s) => s.isShared)
              .toList();
          shares.sort((a, b) => b.sharedAt.compareTo(a.sharedAt));
          return shares;
        });
  }

  /// Reports shared with a doctor. Only status == 'shared' docs are emitted,
  /// so revoking instantly removes the report from this doctor's view.
  Stream<List<SharedReportModel>> streamDoctorSharedReports(String doctorId) {
    return _sharesCollection
        .where('doctorId', isEqualTo: doctorId)
        .snapshots()
        .map((snapshot) {
          final shares = snapshot.docs
              .map((doc) => SharedReportModel.fromFirestore(doc))
              .where((s) => s.isShared)
              .toList();
          shares.sort((a, b) => b.sharedAt.compareTo(a.sharedAt));
          return shares;
        });
  }

  void unawaitedSendNotification({
    required String doctorId,
    required String patientId,
    required String patientName,
    required String reportId,
    required String reportName,
  }) {
    _sendNotification(
      doctorId: doctorId,
      patientId: patientId,
      patientName: patientName,
      reportId: reportId,
      reportName: reportName,
    );
  }

  Future<void> _sendNotification({
    required String doctorId,
    required String patientId,
    required String patientName,
    required String reportId,
    required String reportName,
  }) async {
    try {
      await NotificationDispatcher().sendReportNotification(
        toUserId: doctorId,
        patientId: patientId,
        patientName: patientName,
        reportId: reportId,
        reportName: reportName,
        doctorId: doctorId,
      );
    } catch (e) {
      print('Error sending report notification: $e');
    }
  }
}
