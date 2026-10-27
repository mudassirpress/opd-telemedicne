import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/auth/auth_provider/user_provider.dart';

import 'package:telemedicine/data/models/report_model.dart';
import 'package:telemedicine/core/services/firebase_storage_service.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';

final reportControllerProvider = Provider((ref) => ReportController(ref: ref));

class ReportController {
  final Ref ref;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;


  ReportController({required this.ref});

  CollectionReference get _reportsCollection =>
      _firestore.collection('reports');

  // Upload report with Cloudinary
  Future<ReportModel?> uploadReport({
    required File file,
    required String reportType,
    required String description,
    required DateTime reportDate,
  }) async {
    try {
      final currentUser = ref.read(userProvider);
      if (currentUser == null) {
        ToastService.instance.showError('User not logged in');
        return null;
      }

      // Validate file
      if (!isValidFile(file)) {
        return null;
      }

      ToastService.instance.showInfo('Uploading report...');

      final uploadResult = await FirebaseStorageService.instance
          .uploadMedicalReport(userId: currentUser.id, file: file);
      final fileUrl = uploadResult.downloadUrl;

      // Create report object
      final report = ReportModel(
        id: '',
        userId: currentUser.id,
        reportType: reportType,
        description: description,
        fileUrl: fileUrl,
        reportDate: reportDate,
        uploadDate: DateTime.now(),
      );

      // Save to Firestore
      final docRef = await _reportsCollection.add(report.toFirestore());
      final savedReport = report.copyWith(id: docRef.id);

      ToastService.instance.showSuccess('Report uploaded successfully!');
      return savedReport;
    } catch (e) {
      ToastService.instance.showError('Upload failed: ${e.toString()}');
      return null;
    }
  }

  // Get all reports for current user with error handling
  Stream<List<ReportModel>> getUserReports() {
    final currentUser = ref.read(userProvider);
    if (currentUser == null) {
      return Stream.value([]);
    }

    try {
      // Query with required composite index
      return _reportsCollection
          .where('userId', isEqualTo: currentUser.id)
          .orderBy('uploadDate', descending: true)
          .snapshots()
          .handleError((error) {
            print('Firestore Error: $error');
            if (error.toString().contains('FAILED_PRECONDITION')) {
              ToastService.instance.showError(
                'Please wait for index to build. Check Firebase Console.',
              );
            }
            // MUST rethrow: `handleError`'s callback return value is ignored,
            // so returning `Stream.value([])` here swallowed the error without
            // emitting anything — downstream (medicalHistoryProvider's merged
            // stream) never received data OR an error, and Report History
            // stayed on its loading spinner forever.
            Error.throwWithStackTrace(error, StackTrace.current);
          })
          .map((snapshot) {
            return snapshot.docs
                .map((doc) => ReportModel.fromFirestore(doc))
                .toList();
          });
    } catch (e) {
      print('Error in getUserReports: $e');
      return Stream.value([]);
    }
  }

  // Alternative: Get reports without ordering (works without index)
  Stream<List<ReportModel>> getUserReportsSimple() {
    final currentUser = ref.read(userProvider);
    if (currentUser == null) {
      return Stream.value([]);
    }

    return _reportsCollection
        .where('userId', isEqualTo: currentUser.id)
        .snapshots()
        .map((snapshot) {
          var reports = snapshot.docs
              .map((doc) => ReportModel.fromFirestore(doc))
              .toList();
          // Sort locally instead of using Firestore orderBy
          reports.sort((a, b) => b.uploadDate.compareTo(a.uploadDate));
          return reports;
        });
  }

  // Get single report by ID
  Future<ReportModel?> getReportById(String reportId) async {
    try {
      DocumentSnapshot doc = await _reportsCollection.doc(reportId).get();
      if (doc.exists) {
        return ReportModel.fromFirestore(doc);
      }
      return null;
    } catch (e) {
      print('Error getting report: $e');
      return null;
    }
  }

  // Update report
  Future<bool> updateReport({
    required String reportId,
    String? reportType,
    String? description,
    DateTime? reportDate,
    File? newFile,
  }) async {
    try {
      final currentUser = ref.read(userProvider);
      if (currentUser == null) {
        ToastService.instance.showError('User not logged in');
        return false;
      }

      final report = await getReportById(reportId);
      if (report == null || report.userId != currentUser.id) {
        ToastService.instance.showError('Report not found');
        return false;
      }

      Map<String, dynamic> updateData = {};
      if (reportType != null) updateData['reportType'] = reportType;
      if (description != null) updateData['description'] = description;
      if (reportDate != null)
        updateData['reportDate'] = Timestamp.fromDate(reportDate);

      // If new file is provided, upload to Cloudinary and update URL
      if (newFile != null) {
        if (!isValidFile(newFile)) {
          return false;
        }

        ToastService.instance.showInfo('Updating file...');
        final uploadResult = await FirebaseStorageService.instance
            .uploadMedicalReport(userId: currentUser.id, file: newFile);
        updateData['fileUrl'] = uploadResult.downloadUrl;

        // Clean up old file if it was on Firebase Storage
        if (FirebaseStorageService.isFirebaseStorageUrl(report.fileUrl)) {
          await FirebaseStorageService.instance.deleteByUrl(report.fileUrl);
        }
      }

      await _reportsCollection.doc(reportId).update(updateData);
      ToastService.instance.showSuccess('Report updated successfully');
      return true;
    } catch (e) {
      ToastService.instance.showError('Update failed: ${e.toString()}');
      return false;
    }
  }

  // Delete report
  Future<bool> deleteReport(String reportId) async {
    try {
      final currentUser = ref.read(userProvider);
      if (currentUser == null) {
        ToastService.instance.showError('User not logged in');
        return false;
      }

      final report = await getReportById(reportId);
      if (report == null || report.userId != currentUser.id) {
        ToastService.instance.showError('Report not found');
        return false;
      }

      if (FirebaseStorageService.isFirebaseStorageUrl(report.fileUrl)) {
        await FirebaseStorageService.instance.deleteByUrl(report.fileUrl);
      }

      // Delete report from Firestore
      await _reportsCollection.doc(reportId).delete();

      ToastService.instance.showSuccess('Report deleted successfully');
      return true;
    } catch (e) {
      ToastService.instance.showError('Delete failed: ${e.toString()}');
      return false;
    }
  }

  // Search reports
  Stream<List<ReportModel>> searchReports(String keyword) {
    final currentUser = ref.read(userProvider);
    if (currentUser == null || keyword.isEmpty) {
      return getUserReports();
    }

    final searchTerm = keyword.toLowerCase();
    return getUserReports().map((reports) {
      return reports.where((report) {
        return report.reportType.toLowerCase().contains(searchTerm) ||
            report.description.toLowerCase().contains(searchTerm);
      }).toList();
    });
  }

  // Get reports by date range
  Stream<List<ReportModel>> getReportsByDateRange({
    required DateTime startDate,
    required DateTime endDate,
  }) {
    final currentUser = ref.read(userProvider);
    if (currentUser == null) {
      return Stream.value([]);
    }

    return _reportsCollection
        .where('userId', isEqualTo: currentUser.id)
        .where(
          'reportDate',
          isGreaterThanOrEqualTo: Timestamp.fromDate(startDate),
        )
        .where('reportDate', isLessThanOrEqualTo: Timestamp.fromDate(endDate))
        .orderBy('reportDate', descending: true)
        .snapshots()
        .map((snapshot) {
          return snapshot.docs
              .map((doc) => ReportModel.fromFirestore(doc))
              .toList();
        });
  }

  // Get report statistics
  Future<Map<String, dynamic>> getReportStatistics() async {
    final currentUser = ref.read(userProvider);
    if (currentUser == null) {
      return {};
    }

    try {
      final reports = await _reportsCollection
          .where('userId', isEqualTo: currentUser.id)
          .get();

      final totalReports = reports.docs.length;
      final reviewedReports = reports.docs.where((doc) {
        final data = doc.data() as Map<String, dynamic>;
        return data['reviewedAt'] != null;
      }).length;

      // Group by report type
      Map<String, int> reportsByType = {};
      for (var doc in reports.docs) {
        final data = doc.data() as Map<String, dynamic>;
        final type = data['reportType'] ?? 'Other';
        reportsByType[type] = (reportsByType[type] ?? 0) + 1;
      }

      return {
        'totalReports': totalReports,
        'reviewedReports': reviewedReports,
        'pendingReports': totalReports - reviewedReports,
        'reportsByType': reportsByType,
      };
    } catch (e) {
      print('Error getting statistics: $e');
      return {};
    }
  }

  // Validate file
  bool isValidFile(File file, {int maxSizeMB = 10}) {
    final maxSizeBytes = maxSizeMB * 1024 * 1024;
    if (file.lengthSync() > maxSizeBytes) {
      ToastService.instance.showError(
        'File size must be less than $maxSizeMB MB',
      );
      return false;
    }

    final extension = file.path.split('.').last.toLowerCase();
    final allowedExtensions = ['jpg', 'jpeg', 'png', 'gif', 'webp', 'pdf'];
    if (!allowedExtensions.contains(extension)) {
      ToastService.instance.showError(
        'Invalid file type. Allowed: ${allowedExtensions.join(', ')}',
      );
      return false;
    }

    return true;
  }
}
