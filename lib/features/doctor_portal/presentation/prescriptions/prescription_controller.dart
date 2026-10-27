import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/data/models/prescription_model.dart';

final prescriptionControllerProvider =
    Provider<PrescriptionController>((ref) => PrescriptionController());

/// Firestore access for prescriptions issued inside a chat.
///
/// ## Why there is no composite index requirement
///
/// The obvious query for this list is
/// `where('chatId', ==).orderBy('createdAt', desc)`. Firestore treats that as
/// a *composite* query (equality on one field + ordering by another) and
/// demands a manually deployed composite index, so the list fails with
/// `FAILED_PRECONDITION / missing-indexes` until someone runs
/// `firebase deploy --only firestore:indexes`.
///
/// A single equality filter needs no manual index at all — Firestore serves it
/// from the automatically managed single-field index. So [streamForChat] asks
/// the server for "the prescriptions in this chat" only, and applies the
/// `createdAt` ordering client-side. Results, ordering and realtime behaviour
/// are identical; the only difference is that the query works immediately on
/// any project, deployed or not.
class PrescriptionController {
  final FirebaseFirestore _firestore;

  PrescriptionController({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _collection =>
      _firestore.collection(FirestoreCollections.prescriptions);

  /// Creates a prescription and returns it, including its generated id.
  ///
  /// The document id doubles as the `prescriptionId`, so a chat message only
  /// needs to store that id to reference the full prescription.
  Future<PrescriptionModel> create({
    required String chatId,
    required String doctorId,
    required String doctorName,
    required String patientId,
    required String patientName,
    required String note,
    String patientAge = '',
  }) async {
    final doc = _collection.doc();
    final prescription = PrescriptionModel(
      prescriptionId: doc.id,
      doctorId: doctorId,
      doctorName: doctorName,
      patientId: patientId,
      patientName: patientName,
      patientAge: patientAge,
      note: note.trim(),
      createdAt: DateTime.now(),
      chatId: chatId,
    );
    await doc.set(prescription.toMap());
    return prescription;
  }

  /// Realtime prescriptions for a single conversation, newest first.
  ///
  /// Single equality filter only — no composite index needed. Sorted by
  /// `createdAt` descending in Dart (see the class docs for why).
  Stream<List<PrescriptionModel>> streamForChat(String chatId) {
    if (chatId.isEmpty) return Stream.value(const []);
    return _collection
        .where('chatId', isEqualTo: chatId)
        .snapshots()
        .map((snapshot) {
      final models = _toModels(snapshot.docs);
      models.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return models;
    });
  }

  /// Every prescription issued to a patient, across all of their conversations
  /// and from all their doctors, newest first.
  ///
  /// This is the patient's side of the record: Report History merges this with
  /// the patient's uploaded reports so a prescription appears there without the
  /// doctor having to do anything beyond saving it.
  ///
  /// Reads the `prescriptions` collection directly rather than deriving from
  /// chat messages, which is what guarantees no duplicate entry — the
  /// prescription document is the single source of truth and this only ever
  /// projects it into a list. Single equality filter, no composite index
  /// needed, sorted in Dart for the same reason as [streamForChat].
  Stream<List<PrescriptionModel>> streamForPatient(String patientId) {
    if (patientId.isEmpty) return Stream.value(const []);
    return _collection
        .where('patientId', isEqualTo: patientId)
        .snapshots()
        .map((snapshot) {
      final models = _toModels(snapshot.docs);
      models.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return models;
    });
  }

  /// Reads specific prescriptions by id. Used by the chat card and the detail
  /// page, which only ever pass ids that appeared inside the current
  /// conversation, so a prescription from another patient can never be shown.
  Future<List<PrescriptionModel>> fetchByIds(List<String> ids) async {
    if (ids.isEmpty) return const [];
    final snapshots = await Future.wait(
      ids.map((id) => _collection.doc(id).get()),
    );
    return snapshots
        .where((doc) => doc.exists)
        .map((doc) => PrescriptionModel.fromMap(
              doc.id,
              Map<String, dynamic>.from(doc.data() ?? const {}),
            ))
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

  /// Reads the patient's current age so it can be snapshotted onto the
  /// prescription. Returns an empty string when it cannot be resolved.
  Future<String> fetchPatientAge(String patientId) async {
    try {
      final doc = await _firestore
          .collection(FirestoreCollections.patients)
          .doc(patientId)
          .get();
      final age = doc.data()?['age'];
      if (age == null || age.toString().trim().isEmpty) return '';
      return age.toString().trim();
    } catch (e) {
      return '';
    }
  }

  List<PrescriptionModel> _toModels(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    return docs
        .map((doc) => PrescriptionModel.fromMap(
              doc.id,
              Map<String, dynamic>.from(doc.data()),
            ))
        .toList();
  }

  Future<void> delete(String prescriptionId) async {
    await _collection.doc(prescriptionId).delete();
  }
}
