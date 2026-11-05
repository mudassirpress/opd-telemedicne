import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/core/services/firebase_storage_service.dart';
import 'package:telemedicine/data/models/prescription_model.dart';
import 'package:telemedicine/features/prescriptions/services/prescription_pdf_service.dart';

final prescriptionControllerProvider = Provider<PrescriptionController>(
  (ref) => PrescriptionController(),
);

/// Firestore access for prescriptions issued inside a chat or consultation.
///
/// Single equality filters only — no composite index needed.
class PrescriptionController {
  final FirebaseFirestore _firestore;

  PrescriptionController({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _collection =>
      _firestore.collection(FirestoreCollections.prescriptions);

  /// Creates a prescription and returns it, including its generated id and PDF URL.
  Future<PrescriptionModel> create({
    required String chatId,
    required String doctorId,
    required String doctorName,
    String doctorQualification = '',
    String doctorSpecialty = '',
    required String patientId,
    required String patientName,
    String patientAge = '',
    String patientGender = '',
    String note = '',
    List<PrescriptionMedicine> medicines = const [],
    String advice = '',
    String followUp = '',
    String appointmentId = '',
  }) async {
    // Dynamically fetch doctor info if qualifications/specialty not supplied
    var effectiveDegree = doctorQualification.trim();
    var effectiveSpecialty = doctorSpecialty.trim();
    if (effectiveDegree.isEmpty || effectiveSpecialty.isEmpty) {
      final docInfo = await fetchDoctorInfo(doctorId);
      if (effectiveDegree.isEmpty) {
        effectiveDegree = docInfo['degree'] ?? '';
      }
      if (effectiveSpecialty.isEmpty) {
        effectiveSpecialty = docInfo['specialty'] ?? '';
      }
    }

    // Dynamically fetch patient info if age/gender not supplied
    var effectiveAge = patientAge.trim();
    var effectiveGender = patientGender.trim();
    if (effectiveAge.isEmpty || effectiveGender.isEmpty) {
      final patientInfo = await fetchPatientInfo(patientId);
      if (effectiveAge.isEmpty) {
        effectiveAge = patientInfo['age'] ?? '';
      }
      if (effectiveGender.isEmpty) {
        effectiveGender = patientInfo['gender'] ?? '';
      }
    }

    final doc = _collection.doc();
    var prescription = PrescriptionModel(
      prescriptionId: doc.id,
      doctorId: doctorId,
      doctorName: doctorName.trim(),
      doctorQualification: effectiveDegree,
      doctorSpecialty: effectiveSpecialty,
      patientId: patientId,
      patientName: patientName.trim(),
      patientAge: effectiveAge,
      patientGender: effectiveGender,
      note: note.trim(),
      medicines: medicines.where((m) => m.isNotEmpty).toList(),
      advice: advice.trim(),
      followUp: followUp.trim(),
      createdAt: DateTime.now(),
      chatId: chatId,
      appointmentId: appointmentId,
    );

    // Save initial document immediately so record is not lost
    await doc.set(prescription.toMap());

    // Generate high-resolution PNG prescription page images as the Single Source of Truth
    try {
      final pdfBytes = await PrescriptionPdfService.instance.generatePdf(
        prescription,
      );

      // Generate all page images as high-res PNG (200 DPI)
      var pageImages = await PrescriptionPdfService.instance
          .generatePrescriptionPageImages(pdfBytes);
      if (pageImages.isEmpty) {
        final single = await PrescriptionPdfService.instance
            .generatePreviewImage(pdfBytes);
        if (single != null && single.isNotEmpty) {
          pageImages = [single];
        }
      }

      // Upload each page image to Firebase Storage
      final pageImageUrls = <String>[];
      final imageStoragePaths = <String>[];
      for (int i = 0; i < pageImages.length; i++) {
        try {
          final res = await FirebaseStorageService.instance
              .uploadPrescriptionPageImage(
                patientId: patientId,
                prescriptionId: doc.id,
                pageIndex: i,
                pngBytes: pageImages[i],
                customMetadata: {
                  'prescriptionId': doc.id,
                  'doctorId': doctorId,
                  'patientId': patientId,
                  'reference': prescription.reference,
                },
              );
          if (res.downloadUrl.isNotEmpty) {
            pageImageUrls.add(res.downloadUrl);
            imageStoragePaths.add(res.storagePath);
          }
        } catch (e) {
          debugPrint(
            '⚠️ [PrescriptionController] Page ${i + 1} image upload error: $e',
          );
        }
      }

      // Also upload PDF document for archive/native print fallback
      String pdfUrl = '';
      try {
        final pdfResult = await FirebaseStorageService.instance
            .uploadPrescriptionPdf(
              patientId: patientId,
              prescriptionId: doc.id,
              pdfBytes: pdfBytes,
              customMetadata: {
                'prescriptionId': doc.id,
                'doctorId': doctorId,
                'patientId': patientId,
                'reference': prescription.reference,
              },
            );
        pdfUrl = pdfResult.downloadUrl;
      } catch (e) {
        debugPrint('⚠️ [PrescriptionController] PDF upload error: $e');
      }

      final primaryImg =
          pageImageUrls.isNotEmpty ? pageImageUrls.first : '';

      final updateData = <String, dynamic>{
        if (pdfUrl.isNotEmpty) 'pdfUrl': pdfUrl,
        if (primaryImg.isNotEmpty) 'previewImageUrl': primaryImg,
        if (primaryImg.isNotEmpty) 'imageUrl': primaryImg,
        if (pageImageUrls.isNotEmpty) 'pageImageUrls': pageImageUrls,
        if (imageStoragePaths.isNotEmpty)
          'imageStoragePaths': imageStoragePaths,
        'pageCount':
            pageImages.isNotEmpty ? pageImages.length : 1,
        'updatedAt': Timestamp.now(),
      };

      if (updateData.length > 1) {
        await doc.update(updateData);
        prescription = prescription.copyWith(
          pdfUrl: pdfUrl.isNotEmpty ? pdfUrl : null,
          previewImageUrl: primaryImg.isNotEmpty ? primaryImg : null,
          pageImageUrls: pageImageUrls,
          imageStoragePaths: imageStoragePaths,
          pageCount: pageImages.isNotEmpty ? pageImages.length : 1,
          updatedAt: DateTime.now(),
        );
      }
    } catch (e) {
      debugPrint(
        '⚠️ [PrescriptionController] Prescription image generation/upload error (continuing): $e',
      );
    }

    return prescription;
  }

  /// Realtime prescriptions for a single conversation, newest first.
  Stream<List<PrescriptionModel>> streamForChat(String chatId) {
    if (chatId.isEmpty) return Stream.value(const []);
    return _collection.where('chatId', isEqualTo: chatId).snapshots().map((
      snapshot,
    ) {
      final models = _toModels(snapshot.docs);
      models.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return models;
    });
  }

  /// Every prescription issued to a patient, across all conversations, newest first.
  Stream<List<PrescriptionModel>> streamForPatient(String patientId) {
    if (patientId.isEmpty) return Stream.value(const []);
    return _collection.where('patientId', isEqualTo: patientId).snapshots().map(
      (snapshot) {
        final models = _toModels(snapshot.docs);
        models.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        return models;
      },
    );
  }

  /// Every prescription written by a doctor, newest first.
  Stream<List<PrescriptionModel>> streamForDoctor(String doctorId) {
    if (doctorId.isEmpty) return Stream.value(const []);
    return _collection.where('doctorId', isEqualTo: doctorId).snapshots().map((
      snapshot,
    ) {
      final models = _toModels(snapshot.docs);
      models.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return models;
    });
  }

  /// Reads specific prescriptions by id.
  Future<List<PrescriptionModel>> fetchByIds(List<String> ids) async {
    if (ids.isEmpty) return const [];
    final snapshots = await Future.wait(
      ids.map((id) => _collection.doc(id).get()),
    );
    return snapshots
        .where((doc) => doc.exists)
        .map(
          (doc) => PrescriptionModel.fromMap(
            doc.id,
            Map<String, dynamic>.from(doc.data() ?? const {}),
          ),
        )
        .toList();
  }

  Future<PrescriptionModel?> fetchById(String id) async {
    if (id.isEmpty) return null;
    final doc = await _collection.doc(id).get();
    if (!doc.exists) return null;
    return PrescriptionModel.fromMap(
      doc.id,
      Map<String, dynamic>.from(doc.data() ?? const {}),
    );
  }

  /// Fetches doctor's full name, highest degree/qualification and specialization.
  Future<Map<String, String>> fetchDoctorInfo(String doctorId) async {
    if (doctorId.isEmpty) return {};
    try {
      final doc = await _firestore
          .collection(FirestoreCollections.doctors)
          .doc(doctorId)
          .get();
      if (!doc.exists) return {};
      final data = doc.data() ?? {};
      return {
        'name': (data['fullname'] ?? '').toString().trim(),
        'degree': (data['highestDegree'] ?? data['qualification'] ?? '')
            .toString()
            .trim(),
        'specialty':
            (data['specialization'] ??
                    data['specialty'] ??
                    data['designation'] ??
                    '')
                .toString()
                .trim(),
      };
    } catch (_) {
      return {};
    }
  }

  /// Fetches patient's full name, age, and gender.
  Future<Map<String, String>> fetchPatientInfo(String patientId) async {
    if (patientId.isEmpty) return {};
    try {
      final doc = await _firestore
          .collection(FirestoreCollections.patients)
          .doc(patientId)
          .get();
      if (!doc.exists) return {};
      final data = doc.data() ?? {};
      return {
        'name': (data['fullname'] ?? '').toString().trim(),
        'age': (data['age'] ?? '').toString().trim(),
        'gender': (data['gender'] ?? '').toString().trim(),
      };
    } catch (_) {
      return {};
    }
  }

  /// Reads the patient's current age.
  Future<String> fetchPatientAge(String patientId) async {
    final info = await fetchPatientInfo(patientId);
    return info['age'] ?? '';
  }

  /// Updates the PDF download URL on an existing prescription document.
  Future<void> updatePdfUrl(String prescriptionId, String pdfUrl) async {
    if (prescriptionId.isEmpty || pdfUrl.isEmpty) return;
    await _collection.doc(prescriptionId).update({
      'pdfUrl': pdfUrl,
      'updatedAt': Timestamp.now(),
    });
  }

  List<PrescriptionModel> _toModels(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    return docs
        .map(
          (doc) => PrescriptionModel.fromMap(
            doc.id,
            Map<String, dynamic>.from(doc.data()),
          ),
        )
        .toList();
  }

  Future<void> delete(String prescriptionId) async {
    await _collection.doc(prescriptionId).delete();
  }
}
