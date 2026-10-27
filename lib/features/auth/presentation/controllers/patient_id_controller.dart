import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:telemedicine/data/models/patient_id_model.dart';
import 'package:telemedicine/core/utils/subscription_calculator.dart';

/// Tracks the progress of a bulk Patient ID generation operation.
class GenerationProgress {
  final int totalRequested;
  final int generated;
  final int failed;
  final int currentBatch;
  final int totalBatches;
  final String batchNumber;
  final bool isComplete;
  final List<int> failedBatchIndices;

  const GenerationProgress({
    required this.totalRequested,
    required this.generated,
    required this.failed,
    required this.currentBatch,
    required this.totalBatches,
    required this.batchNumber,
    this.isComplete = false,
    this.failedBatchIndices = const [],
  });

  double get percentage =>
      totalRequested > 0 ? (generated / totalRequested) * 100 : 0;

  int get successCount => generated - failed;
}

class PatientIdController extends ChangeNotifier {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  bool _isLoading = false;
  String _errorMessage = '';
  List<PatientIdModel> _patientIds = [];

  /// Firestore batch write limit (500 operations per batch).
  static const int _firestoreBatchLimit = 500;

  bool get isLoading => _isLoading;
  String get errorMessage => _errorMessage;
  List<PatientIdModel> get patientIds => _patientIds;

  /// Generate a unique 12-digit numeric Patient ID.
  /// Format: 100000000000 to 999999999999
  String _generate12DigitId(Random random) {
    final firstDigit = random.nextInt(9) + 1;
    final remaining = List<int>.generate(11, (_) => random.nextInt(10));
    return '$firstDigit${remaining.join()}';
  }

  /// Generate a set of unique 12-digit IDs in memory.
  /// Uses a Set for O(1) duplicate detection within the generated set.
  Set<String> _generateUniqueIdsInMemory(int count) {
    final ids = <String>{};
    final random = Random();
    // Allow extra attempts to handle birthday-problem collisions
    final maxAttempts = count * 3;
    int attempts = 0;

    while (ids.length < count && attempts < maxAttempts) {
      attempts++;
      ids.add(_generate12DigitId(random));
    }
    return ids;
  }

  /// Fetch all existing patient IDs from Firestore in a single read.
  /// Returns a Set for O(1) lookup during deduplication.
  Future<Set<String>> _fetchAllExistingIds() async {
    // Fetch in pages of 10,000 to stay under Firestore document limits.
    // For most use cases a single page suffices.
    final existingIds = <String>{};
    DocumentSnapshot? lastDoc;
    const int pageSize = 10000;

    while (true) {
      Query query = _firestore
          .collection('patient_ids')
          .orderBy('patientId')
          .limit(pageSize);

      if (lastDoc != null) {
        query = query.startAfterDocument(lastDoc);
      }

      final snapshot = await query.get();
      for (final doc in snapshot.docs) {
        final data = doc.data() as Map<String, dynamic>?;
        if (data == null) continue;
        final pid = data['patientId'] as String?;
        if (pid != null && pid.isNotEmpty) {
          existingIds.add(pid);
        }
      }

      if (snapshot.docs.length < pageSize) break;
      lastDoc = snapshot.docs.last;
    }

    return existingIds;
  }

  /// Optimized batch generation for up to 10,000 Patient IDs.
  ///
  /// Flow:
  /// 1. Fetch all existing IDs from Firestore (single bulk read).
  /// 2. Generate unique IDs in memory, filtering against existing set.
  /// 3. Split into Firestore batches of 500 and commit.
  /// 4. Report progress via [onProgress] callback.
  /// 5. Track failed batches for retry.
  ///
  /// Returns a [GenerationProgress] with final counts.
  Future<GenerationProgress> generateBatchOptimized({
    required int quantity,
    required String batchNumber,
    SubscriptionPlan plan = SubscriptionPlan.sixMonths,
    void Function(GenerationProgress)? onProgress,
  }) async {
    _setLoading(true);
    _clearError();

    // Guard: prevent duplicate generation
    if (_isGenerating) {
      _errorMessage = 'A generation is already in progress.';
      _setLoading(false);
      return const GenerationProgress(
        totalRequested: 0,
        generated: 0,
        failed: 0,
        currentBatch: 0,
        totalBatches: 0,
        batchNumber: '',
      );
    }

    _isGenerating = true;

    try {
      // ── Step 1: Fetch existing IDs in bulk ────────────────────────────
      final existingIds = await _fetchAllExistingIds();

      // ── Step 2: Generate unique IDs in memory ─────────────────────────
      final candidateIds = _generateUniqueIdsInMemory(quantity + 1000);
      // Remove any that already exist in the database
      final uniqueNewIds = <String>[];
      for (final id in candidateIds) {
        if (!existingIds.contains(id)) {
          uniqueNewIds.add(id);
          if (uniqueNewIds.length >= quantity) break;
        }
      }

      if (uniqueNewIds.length < quantity) {
        _errorMessage =
            'Could only generate ${uniqueNewIds.length} out of $quantity unique IDs. '
            'The ID space may be saturated.';
        _setLoading(false);
        _isGenerating = false;
        return GenerationProgress(
          totalRequested: quantity,
          generated: uniqueNewIds.length,
          failed: 0,
          currentBatch: 0,
          totalBatches: 0,
          batchNumber: batchNumber,
        );
      }

      // ── Step 3: Prepare Firestore documents ───────────────────────────
      final docs = <Map<String, dynamic>>[];
      for (final pid in uniqueNewIds) {
        docs.add({
          'patientId': pid,
          'status': 'Available',
          'batchNumber': batchNumber,
          'subscriptionPlan': plan.planId,
          'durationMonths': plan.durationMonths,
          'generatedAt': FieldValue.serverTimestamp(),
          'assignedAt': null,
          'startDate': null,
          'expiryDate': null,
          'patientUserId': null,
          'isActive': true,
        });
      }

      // ── Step 4: Split into Firestore batches and commit ───────────────
      final totalBatches =
          (docs.length / _firestoreBatchLimit).ceil();
      int generatedCount = 0;
      int failedCount = 0;
      final failedBatchIndices = <int>[];

      for (int batchIdx = 0; batchIdx < totalBatches; batchIdx++) {
        final start = batchIdx * _firestoreBatchLimit;
        final end = min(start + _firestoreBatchLimit, docs.length);
        final chunk = docs.sublist(start, end);

        final writeBatch = _firestore.batch();
        for (final idData in chunk) {
          final docRef = _firestore.collection('patient_ids').doc();
          writeBatch.set(docRef, idData);
        }

        try {
          await writeBatch.commit();
          generatedCount += chunk.length;
        } catch (e) {
          failedCount += chunk.length;
          failedBatchIndices.add(batchIdx);
          debugPrint('Batch $batchIdx failed: $e');
        }

        // Report progress
        final progress = GenerationProgress(
          totalRequested: quantity,
          generated: generatedCount,
          failed: failedCount,
          currentBatch: batchIdx + 1,
          totalBatches: totalBatches,
          batchNumber: batchNumber,
          failedBatchIndices: failedBatchIndices,
        );
        onProgress?.call(progress);
        notifyListeners();

        // Yield to the event loop between batches to keep UI responsive
        await Future<void>.delayed(Duration.zero);
      }

      _setLoading(false);
      _isGenerating = false;

      return GenerationProgress(
        totalRequested: quantity,
        generated: generatedCount,
        failed: failedCount,
        currentBatch: totalBatches,
        totalBatches: totalBatches,
        batchNumber: batchNumber,
        isComplete: true,
        failedBatchIndices: failedBatchIndices,
      );
    } catch (e) {
      _errorMessage = 'Failed to generate IDs: ${e.toString()}';
      _setLoading(false);
      _isGenerating = false;
      return GenerationProgress(
        totalRequested: quantity,
        generated: 0,
        failed: 0,
        currentBatch: 0,
        totalBatches: 0,
        batchNumber: batchNumber,
      );
    }
  }

  // ── Generation lock ──────────────────────────────────────────────────
  bool _isGenerating = false;
  bool get isGenerating => _isGenerating;

  /// Retry failed batches from a previous generation attempt.
  ///
  /// [failedDocs] – the document data maps that failed in the original attempt.
  /// [batchNumber] – the batch number to assign.
  /// [onProgress] – progress callback.
  Future<GenerationProgress> retryFailedIds({
    required List<Map<String, dynamic>> failedDocs,
    required String batchNumber,
    void Function(GenerationProgress)? onProgress,
  }) async {
    if (failedDocs.isEmpty) {
      return GenerationProgress(
        totalRequested: 0,
        generated: 0,
        failed: 0,
        currentBatch: 0,
        totalBatches: 0,
        batchNumber: batchNumber,
        isComplete: true,
      );
    }

    _setLoading(true);
    _clearError();

    try {
      final totalBatches =
          (failedDocs.length / _firestoreBatchLimit).ceil();
      int generatedCount = 0;
      int failedCount = 0;
      final failedBatchIndices = <int>[];

      for (int batchIdx = 0; batchIdx < totalBatches; batchIdx++) {
        final start = batchIdx * _firestoreBatchLimit;
        final end = min(start + _firestoreBatchLimit, failedDocs.length);
        final chunk = failedDocs.sublist(start, end);

        final writeBatch = _firestore.batch();
        for (final idData in chunk) {
          final docRef = _firestore.collection('patient_ids').doc();
          writeBatch.set(docRef, idData);
        }

        try {
          await writeBatch.commit();
          generatedCount += chunk.length;
        } catch (e) {
          failedCount += chunk.length;
          failedBatchIndices.add(batchIdx);
          debugPrint('Retry batch $batchIdx failed: $e');
        }

        onProgress?.call(GenerationProgress(
          totalRequested: failedDocs.length,
          generated: generatedCount,
          failed: failedCount,
          currentBatch: batchIdx + 1,
          totalBatches: totalBatches,
          batchNumber: batchNumber,
          failedBatchIndices: failedBatchIndices,
        ));
        notifyListeners();

        await Future<void>.delayed(Duration.zero);
      }

      _setLoading(false);
      return GenerationProgress(
        totalRequested: failedDocs.length,
        generated: generatedCount,
        failed: failedCount,
        currentBatch: totalBatches,
        totalBatches: totalBatches,
        batchNumber: batchNumber,
        isComplete: true,
        failedBatchIndices: failedBatchIndices,
      );
    } catch (e) {
      _errorMessage = 'Retry failed: ${e.toString()}';
      _setLoading(false);
      return GenerationProgress(
        totalRequested: failedDocs.length,
        generated: 0,
        failed: failedDocs.length,
        currentBatch: 0,
        totalBatches: 0,
        batchNumber: batchNumber,
      );
    }
  }

  /// Check if a patient ID already exists in the database.
  Future<bool> _patientIdExists(String patientId) async {
    final snapshot = await _firestore
        .collection('patient_ids')
        .where('patientId', isEqualTo: patientId)
        .limit(1)
        .get();
    return snapshot.docs.isNotEmpty;
  }

  /// Legacy batch generation (kept for backward compatibility).
  /// For new code, use [generateBatchOptimized] instead.
  Future<bool> generateBatch({
    required int quantity,
    required String batchNumber,
    SubscriptionPlan plan = SubscriptionPlan.sixMonths,
  }) async {
    _setLoading(true);
    _clearError();

    try {
      final List<Map<String, dynamic>> batch = [];
      final Set<String> generatedIds = {};
      int attempts = 0;
      final int maxAttempts = quantity * 3;

      while (batch.length < quantity && attempts < maxAttempts) {
        attempts++;
        String patientId = _generate12DigitId(Random());

        if (generatedIds.contains(patientId)) continue;
        if (await _patientIdExists(patientId)) continue;

        generatedIds.add(patientId);
        batch.add({
          'patientId': patientId,
          'status': 'Available',
          'batchNumber': batchNumber,
          'subscriptionPlan': plan.planId,
          'durationMonths': plan.durationMonths,
          'generatedAt': FieldValue.serverTimestamp(),
          'assignedAt': null,
          'startDate': null,
          'expiryDate': null,
          'patientUserId': null,
          'isActive': true,
        });
      }

      if (batch.length < quantity) {
        _errorMessage =
            'Could only generate ${batch.length} out of $quantity unique IDs.';
        _setLoading(false);
        notifyListeners();
        return false;
      }

      const int chunkSize = 500;
      for (int i = 0; i < batch.length; i += chunkSize) {
        final end = min(i + chunkSize, batch.length);
        final chunk = batch.sublist(i, end);
        final writeBatch = _firestore.batch();

        for (final idData in chunk) {
          final docRef = _firestore.collection('patient_ids').doc();
          idData['id'] = docRef.id;
          writeBatch.set(docRef, idData);
        }

        await writeBatch.commit();
      }

      _setLoading(false);
      notifyListeners();
      return true;
    } catch (e) {
      _errorMessage = 'Failed to generate IDs: ${e.toString()}';
      _setLoading(false);
      notifyListeners();
      return false;
    }
  }

  /// Verify a patient ID exists and is Available.
  Future<PatientIdModel?> verifyPatientId(String patientId) async {
    try {
      final snapshot = await _firestore
          .collection('patient_ids')
          .where('patientId', isEqualTo: patientId)
          .where('isActive', isEqualTo: true)
          .limit(1)
          .get();

      if (snapshot.docs.isEmpty) {
        _errorMessage = 'Patient ID not found';
        notifyListeners();
        return null;
      }

      final patientIdData = PatientIdModel.fromMap({
        ...snapshot.docs.first.data(),
        'id': snapshot.docs.first.id,
      });

      if (patientIdData.status != 'Available') {
        _errorMessage = 'This Patient ID is already ${patientIdData.status}';
        notifyListeners();
        return null;
      }

      _clearError();
      notifyListeners();
      return patientIdData;
    } catch (e) {
      _errorMessage = 'Error verifying Patient ID: ${e.toString()}';
      notifyListeners();
      return null;
    }
  }

  /// Assign a Patient ID to a user (mark as Assigned) with calendar-safe expiry according to plan.
  Future<bool> assignPatientId({
    required String patientIdDocId,
    required String patientUserId,
    SubscriptionPlan? plan,
    int? durationMonths,
  }) async {
    try {
      String? planId = plan?.planId;
      int? months = durationMonths ?? plan?.durationMonths;

      if (planId == null || months == null) {
        final doc = await _firestore.collection('patient_ids').doc(patientIdDocId).get();
        if (doc.exists) {
          final data = doc.data() ?? {};
          planId ??= data['subscriptionPlan']?.toString();
          months ??= data['durationMonths'] is int ? data['durationMonths'] as int : null;
        }
      }

      final effectivePlan = SubscriptionPlan.fromPlanId(planId);
      final effectiveDuration = months ?? effectivePlan.durationMonths;

      final now = DateTime.now();
      final expiry = SubscriptionCalculator.calculateExpiry(
        now,
        durationMonths: effectiveDuration,
      );

      await _firestore.collection('patient_ids').doc(patientIdDocId).update({
        'status': 'Assigned',
        'assignedAt': FieldValue.serverTimestamp(),
        'startDate': FieldValue.serverTimestamp(),
        'expiryDate': Timestamp.fromDate(expiry),
        'patientUserId': patientUserId,
        'subscriptionPlan': effectivePlan.planId,
        'durationMonths': effectiveDuration,
      });

      notifyListeners();
      return true;
    } catch (e) {
      _errorMessage = 'Failed to assign Patient ID: ${e.toString()}';
      notifyListeners();
      return false;
    }
  }

  /// Check if a Patient ID document is expired based on its expiryDate field.
  static bool isPatientIdExpired(Map<String, dynamic> patientIdData) {
    final expiryDate = patientIdData['expiryDate'];
    if (expiryDate == null) return false;

    DateTime expiry;
    if (expiryDate is Timestamp) {
      expiry = expiryDate.toDate();
    } else if (expiryDate is String) {
      expiry = DateTime.tryParse(expiryDate) ?? DateTime.now();
    } else {
      return false;
    }

    return DateTime.now().isAfter(expiry);
  }

  /// Get the expiry date for a patient user by looking up their patient_ids document.
  Future<DateTime?> getPatientExpiryDate(String patientUserId) async {
    try {
      final snapshot = await _firestore
          .collection('patient_ids')
          .where('patientUserId', isEqualTo: patientUserId)
          .limit(1)
          .get();

      if (snapshot.docs.isEmpty) return null;

      final data = snapshot.docs.first.data();
      final expiryDate = data['expiryDate'];
      if (expiryDate == null) return null;

      if (expiryDate is Timestamp) {
        return expiryDate.toDate();
      } else if (expiryDate is String) {
        return DateTime.tryParse(expiryDate);
      }
      return null;
    } catch (e) {
      print('Error getting patient expiry date: $e');
      return null;
    }
  }

  /// Block a patient ID.
  Future<bool> blockPatientId(String patientIdDocId) async {
    try {
      await _firestore.collection('patient_ids').doc(patientIdDocId).update({
        'status': 'Blocked',
      });
      notifyListeners();
      return true;
    } catch (e) {
      _errorMessage = 'Failed to block Patient ID: ${e.toString()}';
      notifyListeners();
      return false;
    }
  }

  /// Unblock a patient ID (set back to Available).
  Future<bool> unblockPatientId(String patientIdDocId) async {
    try {
      await _firestore.collection('patient_ids').doc(patientIdDocId).update({
        'status': 'Available',
      });
      notifyListeners();
      return true;
    } catch (e) {
      _errorMessage = 'Failed to unblock Patient ID: ${e.toString()}';
      notifyListeners();
      return false;
    }
  }

  /// Get ID statistics: Total, Available, Assigned, Blocked.
  Future<Map<String, int>> getIdStats() async {
    try {
      final snapshot = await _firestore
          .collection('patient_ids')
          .where('isActive', isEqualTo: true)
          .get();

      int total = 0;
      int available = 0;
      int assigned = 0;
      int blocked = 0;

      for (final doc in snapshot.docs) {
        total++;
        final status = doc.data()['status'] ?? 'Available';
        switch (status) {
          case 'Available':
            available++;
            break;
          case 'Assigned':
            assigned++;
            break;
          case 'Blocked':
            blocked++;
            break;
        }
      }

      return {
        'total': total,
        'available': available,
        'assigned': assigned,
        'blocked': blocked,
      };
    } catch (e) {
      print('Error getting ID stats: $e');
      // Rethrow instead of returning all zeros: the admin screen cannot tell
      // a failed read from a genuinely empty ID database, and an offline
      // admin used to see a plausible-looking 0/0/0/0 dashboard.
      rethrow;
    }
  }

  /// Get all patient IDs (for admin view).
  Future<List<PatientIdModel>> getAllPatientIds() async {
    try {
      final snapshot = await _firestore
          .collection('patient_ids')
          .where('isActive', isEqualTo: true)
          .orderBy('generatedAt', descending: true)
          .get();

      return snapshot.docs
          .map((doc) => PatientIdModel.fromMap({...doc.data(), 'id': doc.id}))
          .toList();
    } catch (e) {
      print('Error getting all patient IDs: $e');
      return [];
    }
  }

  /// Get all patient IDs for a specific batch number.
  Future<List<PatientIdModel>> getPatientIdsByBatch(String batchNumber) async {
    try {
      final results = <PatientIdModel>[];
      DocumentSnapshot? lastDoc;
      const int pageSize = 10000;

      while (true) {
        Query query = _firestore
            .collection('patient_ids')
            .where('batchNumber', isEqualTo: batchNumber)
            .limit(pageSize);

        if (lastDoc != null) {
          query = query.startAfterDocument(lastDoc);
        }

        final snapshot = await query.get();
        for (final doc in snapshot.docs) {
          final data = doc.data() as Map<String, dynamic>?;
          if (data == null) continue;
          if (data['isActive'] == true) {
            results.add(
                PatientIdModel.fromMap({...data, 'id': doc.id}));
          }
        }

        if (snapshot.docs.length < pageSize) break;
        lastDoc = snapshot.docs.last;
      }

      results.sort((a, b) => b.generatedAt.compareTo(a.generatedAt));
      return results;
    } catch (e) {
      print('Error getting patient IDs by batch: $e');
      _errorMessage = 'Failed to fetch batch IDs: ${e.toString()}';
      notifyListeners();
      return [];
    }
  }

  /// Stream patient IDs for real-time updates.
  Stream<List<PatientIdModel>> streamPatientIds() {
    return _firestore
        .collection('patient_ids')
        .where('isActive', isEqualTo: true)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) =>
                PatientIdModel.fromMap({...doc.data(), 'id': doc.id}))
            .toList());
  }

  /// Generate a unique batch number.
  String generateBatchNumber() {
    final now = DateTime.now();
    final datePart =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
    final timePart =
        '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
    final random = Random().nextInt(9000) + 1000;
    return 'BATCH-$datePart-$timePart-$random';
  }

  void _setLoading(bool loading) {
    _isLoading = loading;
    notifyListeners();
  }

  void _clearError() {
    _errorMessage = '';
  }
}
