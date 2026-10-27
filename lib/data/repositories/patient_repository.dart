import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/features/auth/data/services/patient_password_reset_service.dart';

class PatientRepository {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  Stream<bool> getPatientOnlineStatusStream(String patientId) {
    return _firestore
        .collection(FirestoreCollections.patients)
        .doc(patientId)
        .snapshots()
        .map((doc) {
          if (!doc.exists) return false;
          final data = doc.data();
          final isOnline = data?['isOnline'] ?? false;
          final lastHeartbeat = data?['lastHeartbeat'] as Timestamp?;
          final lastSeen = data?['lastSeen'] as Timestamp?;

          if (!isOnline) return false;

          final reference = lastHeartbeat ?? lastSeen;
          if (reference == null) return false;

          final diff = DateTime.now().difference(reference.toDate());
          return diff.inSeconds < 45;
        });
  }

  Future<void> updatePatientOnlineStatus(String patientId, bool isOnline) async {
    final updateData = <String, dynamic>{
      'isOnline': isOnline,
      'lastSeen': isOnline ? null : FieldValue.serverTimestamp(),
    };
    if (isOnline) {
      updateData['lastHeartbeat'] = FieldValue.serverTimestamp();
    }
    await _firestore
        .collection(FirestoreCollections.patients)
        .doc(patientId)
        .update(updateData);
  }

  Future<void> sendHeartbeat(String patientId) async {
    await _firestore
        .collection(FirestoreCollections.patients)
        .doc(patientId)
        .update({
          'lastSeen': FieldValue.serverTimestamp(),
          'lastHeartbeat': FieldValue.serverTimestamp(),
        });
  }

  Future<DocumentSnapshot?> getPatientByPhone(String phoneNumber) async {
    final variants = PatientPasswordResetService.phoneLookupVariants(phoneNumber);
    final docCheck = await _firestore
        .collection(FirestoreCollections.patients)
        .where('phoneNumber', whereIn: variants)
        .limit(1)
        .get();
    
    if (docCheck.docs.isEmpty) return null;
    return docCheck.docs.first;
  }

  Future<DocumentSnapshot?> getPatientById(String id) async {
    final doc = await _firestore.collection(FirestoreCollections.patients).doc(id).get();
    if (!doc.exists) return null;
    return doc;
  }

  Future<void> updateDeviceId(String docId, String deviceId) async {
    await _firestore
        .collection(FirestoreCollections.patients)
        .doc(docId)
        .update({'deviceId': deviceId});
  }

  Future<void> updateToken(String docId, String token) async {
    await _firestore
        .collection(FirestoreCollections.patients)
        .doc(docId)
        .update({
          'fcmToken': token,
          'token': token,
          'lastTokenUpdate': FieldValue.serverTimestamp(),
        });
  }

  Future<DocumentSnapshot?> getPatientIdDocument(String patientIdVal) async {
    final pidSnapshot = await _firestore
        .collection(FirestoreCollections.patientIds)
        .where('patientId', isEqualTo: patientIdVal)
        .limit(1)
        .get();
    if (pidSnapshot.docs.isEmpty) return null;
    return pidSnapshot.docs.first;
  }

  Future<void> savePatient(Map<String, dynamic> userMap) async {
    await _firestore
        .collection(FirestoreCollections.patients)
        .doc(userMap['id'])
        .set(userMap);
  }

  Future<List<DocumentSnapshot>> getAllPatients() async {
    final query = await _firestore.collection(FirestoreCollections.patients).get();
    return query.docs;
  }
}

final patientRepositoryProvider = Provider((ref) => PatientRepository());
