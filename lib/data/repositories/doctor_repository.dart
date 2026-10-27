import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/core/services/soft_delete_service.dart';

class DoctorRepository {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  Future<bool> isDoctorIdExists(String doctorId) async {
    final snapshot = await _firestore
        .collection(FirestoreCollections.doctors)
        .where('doctorId', isEqualTo: doctorId)
        .where('isActive', isEqualTo: true)
        .get();
    return snapshot.docs.isNotEmpty;
  }

  Future<void> updatePresence(String doctorId, bool isOnline) async {
    final updateData = <String, dynamic>{
      'isOnline': isOnline,
      'lastSeen': FieldValue.serverTimestamp(),
    };
    if (isOnline) {
      updateData['lastHeartbeat'] = FieldValue.serverTimestamp();
    }
    await _firestore
        .collection(FirestoreCollections.doctors)
        .doc(doctorId)
        .update(updateData);
  }

  Future<void> sendHeartbeat(String doctorId) async {
    await _firestore
        .collection(FirestoreCollections.doctors)
        .doc(doctorId)
        .update({
      'lastSeen': FieldValue.serverTimestamp(),
      'lastHeartbeat': FieldValue.serverTimestamp(),
    });
  }

  Future<DocumentSnapshot?> getDoctorDocByDoctorId(String doctorId) async {
    final snapshot = await _firestore
        .collection(FirestoreCollections.doctors)
        .where('doctorId', isEqualTo: doctorId)
        .where('isActive', isEqualTo: true)
        .get();
    if (snapshot.docs.isEmpty) return null;
    return snapshot.docs.first;
  }

  Future<DocumentSnapshot?> getDoctorDocById(String id) async {
    final doc = await _firestore.collection(FirestoreCollections.doctors).doc(id).get();
    return doc.exists ? doc : null;
  }

  Future<void> saveFcmToken(String doctorId, String fcmToken) async {
    await _firestore.collection(FirestoreCollections.doctors).doc(doctorId).update({
      'fcmToken': fcmToken,
      'tokenUpdatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<String?> getFcmToken(String doctorId) async {
    final doc = await _firestore.collection(FirestoreCollections.doctors).doc(doctorId).get();
    if (doc.exists) {
      return doc.data()?['fcmToken'] as String?;
    }
    return null;
  }

  Future<String> getAccountStatus(String doctorId) async {
    final doc = await _firestore.collection(FirestoreCollections.doctors).doc(doctorId).get();
    if (doc.exists) {
      return doc.data()?['accountStatus'] ?? 'Active';
    }
    return 'Active';
  }

  Future<void> updateAccountStatus(String doctorId, String status) async {
    await _firestore.collection(FirestoreCollections.doctors).doc(doctorId).update({
      'accountStatus': status,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> recordLogin(String doctorId, String doctorName) async {
    await _firestore.collection(FirestoreCollections.doctorActivityLogs).add({
      'doctorId': doctorId,
      'doctorName': doctorName,
      'event': 'login',
      'timestamp': FieldValue.serverTimestamp(),
    });
    await _firestore.collection(FirestoreCollections.doctors).doc(doctorId).update({
      'loginStatus': 'Online',
      'lastLogin': FieldValue.serverTimestamp(),
      'lastSeen': FieldValue.serverTimestamp(),
    });
  }

  Future<void> recordLogout(String doctorId, String doctorName) async {
    await _firestore.collection(FirestoreCollections.doctorActivityLogs).add({
      'doctorId': doctorId,
      'doctorName': doctorName,
      'event': 'logout',
      'timestamp': FieldValue.serverTimestamp(),
    });
    await _firestore.collection(FirestoreCollections.doctors).doc(doctorId).update({
      'loginStatus': 'Offline',
      'lastLogout': FieldValue.serverTimestamp(),
      'lastSeen': FieldValue.serverTimestamp(),
      'isOnline': false,
    });
  }

  Stream<List<Map<String, dynamic>>> getAllDoctorActivityLogs() {
    return _firestore
        .collection(FirestoreCollections.doctorActivityLogs)
        .orderBy('timestamp', descending: true)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs.map((doc) {
        final data = doc.data();
        data['id'] = doc.id;
        return data;
      }).toList();
    });
  }

  /// ADMIN VIEW — unfiltered, so the admin can open a deleted doctor's full
  /// preserved record. The Active/Deleted toggle is applied in the UI.
  Future<List<Map<String, dynamic>>> getAllDoctorsWithStatus() async {
    final querySnapshot = await _firestore.collection(FirestoreCollections.doctors).get();
    return querySnapshot.docs.map((doc) {
      final data = doc.data();
      data['id'] = doc.id;
      return data;
    }).toList();
  }

  /// ADMIN VIEW — unfiltered, same reasoning as
  /// [getAllDoctorsWithStatus].
  Stream<List<Map<String, dynamic>>> streamAllDoctorsWithStatus() {
    return _firestore
        .collection(FirestoreCollections.doctors)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs.map((doc) {
        final data = doc.data();
        data['id'] = doc.id;
        return data;
      }).toList();
    });
  }
  
  Future<bool> doesDoctorNameExist(String fullname) async {
    final existingDoctor = await _firestore
          .collection(FirestoreCollections.doctors)
          .where('fullname', isEqualTo: fullname)
          .where('isActive', isEqualTo: true)
          .get();
    return existingDoctor.docs.isNotEmpty;
  }
  
  Future<String> createDoctorProfile(Map<String, dynamic> doctorProfile, String? sharedAccountId) async {
     final doctorRef = _firestore.collection(FirestoreCollections.doctors).doc();
     doctorProfile['id'] = doctorRef.id;
     // Price + description are part of the doctor document from creation. A
     // caller that does not pass them still gets the keys, so readers never
     // have to distinguish "field missing" from "field empty" for new records.
     final price = (doctorProfile['price'] ?? doctorProfile['consultationFee']) ?? 0.0;
     doctorProfile['price'] = price;
     doctorProfile['consultationFee'] = price;
     doctorProfile['description'] = doctorProfile['description'] ?? '';
     await doctorRef.set(doctorProfile);
     
     if(sharedAccountId != null) {
       await _firestore
          .collection(FirestoreCollections.patients)
          .doc(sharedAccountId)
          .collection('doctor_profiles')
          .doc(doctorRef.id)
          .set({
            'profileId': doctorRef.id,
            'doctorId': doctorProfile['doctorId'],
            'fullname': doctorProfile['fullname'],
            'createdAt': FieldValue.serverTimestamp(),
            'imageUrl': doctorProfile['imageUrl'] ?? '',
            'isActive': true,
          });
     }
     
     return doctorRef.id;
  }
  
  /// Active doctor profiles for patient-facing listings.
  ///
  /// The `isActive` clause plus the Dart-side `activeOnly` pass together: the
  /// server clause keeps the query small, and the shared predicate closes any
  /// gap (including for records predating the soft-delete migration, where a
  /// server-side `isDeleted == false` would wrongly exclude them).
  Future<List<Map<String, dynamic>>> getAllDoctorProfiles() async {
    final querySnapshot = await _firestore
          .collection(FirestoreCollections.doctors)
          .where('isActive', isEqualTo: true)
          .get();
    return SoftDeleteService.activeOnly(
      querySnapshot.docs.map((doc) {
        final data = doc.data();
        data['id'] = doc.id;
        return data;
      }).toList(),
      (doctor) => doctor,
    );
  }
  
  /// REMOVED — hard delete of a doctor and its related collections.
  ///
  /// This method destroyed the doctor document and then cascaded through
  /// `doctorOnlineSessions`, `doctorDailyStats` and `doctorChats`. Deleting a
  /// doctor must never remove records, so the operation is gone entirely
  /// rather than merely re-pointed: use [softDeleteDoctor] instead.
  ///
  /// ```dart
  /// await repository.softDeleteDoctor(doctorId, performedBy: adminId);
  /// ```
  @Deprecated(
    'Hard delete is permanently disabled. Use softDeleteDoctor() — the '
    'doctor record and all of its history are preserved by design.',
  )
  Future<void> hardDeleteDoctor(String doctorId) async {
    throw UnsupportedError(
      'Hard delete of a doctor is disabled. Use softDeleteDoctor() so the '
      'doctor profile, chats, prescriptions, reports and payment history '
      'are preserved.',
    );
  }

  /// Deactivates a doctor without removing the record or any of its history.
  ///
  /// Writes the soft-delete field set (see `SoftDeleteService`) plus an
  /// append-only audit entry. `deletedAt` is a server timestamp.
  Future<void> softDeleteDoctor(
    String doctorId, {
    String performedBy = 'admin',
    String reason = 'Deleted by administrator',
  }) async {
    final success = await SoftDeleteService.softDeleteDoctor(
      doctorId: doctorId,
      performedBy: performedBy,
      reason: reason,
    );
    if (!success) {
      throw StateError('Failed to soft-delete doctor $doctorId');
    }
  }

  /// Restores a soft-deleted doctor in place (same document, no duplicate).
  Future<void> restoreDoctor(
    String doctorId, {
    String performedBy = 'admin',
  }) async {
    final success = await SoftDeleteService.restoreDoctor(
      doctorId: doctorId,
      performedBy: performedBy,
    );
    if (!success) {
      throw StateError('Failed to restore doctor $doctorId');
    }
  }
  
  /// Active doctors only. Feeds booking / consultation pickers, so a
  /// soft-deleted doctor must never appear here.
  Stream<QuerySnapshot> streamActiveDoctors() {
    return _firestore
        .collection(FirestoreCollections.doctors)
        .where('isActive', isEqualTo: true)
        .snapshots();
  }
  
  Stream<DocumentSnapshot> streamDoctor(String doctorId) {
    return _firestore
        .collection(FirestoreCollections.doctors)
        .doc(doctorId)
        .snapshots();
  }
}

final doctorRepositoryProvider = Provider((ref) => DoctorRepository());
