import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/data/models/doctor_rating_model.dart';
import 'package:telemedicine/data/models/prescription_model.dart';

final doctorRatingControllerProvider = Provider<DoctorRatingController>(
  (ref) => DoctorRatingController(),
);

/// Realtime rating of this doctor by this patient for this prescription, or
/// null while unrated. Used by the prescription card in the chat, so the card
/// automatically switches to "Your Rating" after a submission without the
/// chat being reloaded.
final prescriptionRatingProvider = StreamProvider.autoDispose
    .family<
      DoctorRatingModel?,
      ({String doctorId, String patientId, String prescriptionId})
    >((ref, args) {
      return ref
          .read(doctorRatingControllerProvider)
          .watchRating(
            doctorId: args.doctorId,
            patientId: args.patientId,
            prescriptionId: args.prescriptionId,
          );
    });

/// Average rating + total count for a doctor, for their profile.
final doctorRatingSummaryProvider = StreamProvider.autoDispose
    .family<DoctorRatingSummary, String>((ref, doctorId) {
      return ref.read(doctorRatingControllerProvider).watchSummary(doctorId);
    });

/// Why a rating submission was refused.
enum RatingFailure {
  notSignedIn,
  notThePatient,
  prescriptionMissing,
  prescriptionMismatch,
  alreadyRated,
  invalidRating,
  writeFailed,
}

class RatingResult {
  final DoctorRatingModel? rating;
  final RatingFailure? failure;

  const RatingResult.success(this.rating) : failure = null;
  const RatingResult.failed(this.failure) : rating = null;

  bool get isSuccess => failure == null;
}

/// Internal signal thrown inside the transaction when the rating slot is taken.
class _AlreadyRatedException implements Exception {
  const _AlreadyRatedException();
}

/// Firestore access for doctor ratings.
///
/// Design notes:
///  * One rating per `doctorId + patientId + prescriptionId`, enforced by a
///    deterministic document id — a duplicate cannot be stored.
///  * Queries deliberately use a single equality filter so they run off
///    Firestore's automatic single-field indexes and never require a manually
///    deployed composite index. Ordering/aggregation is done in Dart.
///  * Every write re-validates the prescription ownership server-side-ish (by
///    re-reading the document) so a patient cannot rate a doctor that is not
///    actually connected to the prescription they quote.
class DoctorRatingController {
  final FirebaseFirestore _firestore;

  DoctorRatingController({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _collection =>
      _firestore.collection(FirestoreCollections.doctorRatings);

  DocumentReference<Map<String, dynamic>> _docFor({
    required String doctorId,
    required String patientId,
    required String prescriptionId,
  }) {
    return _collection.doc(
      DoctorRatingModel.buildId(
        doctorId: doctorId,
        patientId: patientId,
        prescriptionId: prescriptionId,
      ),
    );
  }

  /// Realtime rating for this exact doctor + patient + prescription, or `null`
  /// when the patient has not rated yet.
  ///
  /// Served from the Firestore local cache when offline, so the card still
  /// shows "Your Rating" after going offline.
  Stream<DoctorRatingModel?> watchRating({
    required String doctorId,
    required String patientId,
    required String prescriptionId,
  }) {
    return _docFor(
      doctorId: doctorId,
      patientId: patientId,
      prescriptionId: prescriptionId,
    ).snapshots().map((snapshot) {
      if (!snapshot.exists) return null;
      return DoctorRatingModel.fromMap(
        snapshot.id,
        Map<String, dynamic>.from(snapshot.data() ?? const {}),
      );
    });
  }

  /// Average rating and total count for a doctor.
  Stream<DoctorRatingSummary> watchSummary(String doctorId) {
    if (doctorId.isEmpty) return Stream.value(DoctorRatingSummary.empty);
    return _collection
        .where('doctorId', isEqualTo: doctorId)
        .limit(500)
        .snapshots()
        .map((snapshot) => _aggregate(snapshot.docs));
  }

  /// The ONE place the average is computed. Both the live read and the
  /// projection onto the doctor document go through this, so the two can never
  /// disagree.
  DoctorRatingSummary _aggregate(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    var total = 0;
    var sum = 0;
    for (final doc in docs) {
      final value = doc.data()['rating'];
      if (value is num && value >= 1 && value <= 5) {
        sum += value.toInt();
        total++;
      }
    }
    return DoctorRatingSummary(
      average: total == 0 ? 0 : sum / total,
      total: total,
    );
  }

  /// Copies a doctor's current average and count onto the doctor document as
  /// `averageRating` / `totalRatings`.
  ///
  /// This is a projection of [watchSummary] onto the doctor profile, not a
  /// second calculation and not a second collection. It exists so every
  /// patient-side doctor card can read the numbers straight off the doctor
  /// document it already loads, instead of firing its own rating query.
  Future<DoctorRatingSummary> projectOntoDoctor(String doctorId) async {
    if (doctorId.isEmpty) return DoctorRatingSummary.empty;
    try {
      final snapshot = await _collection
          .where('doctorId', isEqualTo: doctorId)
          .limit(500)
          .get();
      final summary = _aggregate(snapshot.docs);

      await _firestore
          .collection(FirestoreCollections.doctors)
          .doc(doctorId)
          .set({
            'averageRating': summary.average,
            'totalRatings': summary.total,
          }, SetOptions(merge: true));
      return summary;
    } catch (e) {
      return DoctorRatingSummary.empty;
    }
  }

  /// Backfills `averageRating` / `totalRatings` for doctors that already have
  /// ratings, so existing data shows up on the doctor cards immediately.
  Future<int> backfillAllProjections() async {
    try {
      final snapshot = await _collection.get();
      final doctorIds = <String>{};
      for (final doc in snapshot.docs) {
        final id = (doc.data()?['doctorId'] ?? '').toString();
        if (id.isNotEmpty) doctorIds.add(id);
      }
      var done = 0;
      for (final doctorId in doctorIds) {
        await projectOntoDoctor(doctorId);
        done++;
      }
      return done;
    } catch (e) {
      return 0;
    }
  }

  /// Submits a rating after validating the whole relationship.
  ///
  /// `currentUserId` must be the patient the prescription was issued to, and
  /// `doctorId` must be the doctor who issued it — both are re-checked against
  /// the stored prescription, so quoting someone else's `prescriptionId`
  /// fails instead of writing a mis-attributed rating.
  Future<RatingResult> submit({
    required String currentUserId,
    required String doctorId,
    required String patientId,
    required String patientName,
    required String prescriptionId,
    required int rating,
  }) async {
    if (rating < 1 || rating > 5) {
      return const RatingResult.failed(RatingFailure.invalidRating);
    }
    if (currentUserId.isEmpty) {
      return const RatingResult.failed(RatingFailure.notSignedIn);
    }
    // The signed-in user must be the patient being rated.
    if (currentUserId != patientId) {
      return const RatingResult.failed(RatingFailure.notThePatient);
    }

    // Re-read the prescription and verify the doctor/patient/chat relationship.
    final prescription = await _loadPrescription(prescriptionId);
    if (prescription == null) {
      return const RatingResult.failed(RatingFailure.prescriptionMissing);
    }
    if (prescription.doctorId != doctorId ||
        prescription.patientId != patientId) {
      return const RatingResult.failed(RatingFailure.prescriptionMismatch);
    }

    final doc = _docFor(
      doctorId: doctorId,
      patientId: patientId,
      prescriptionId: prescriptionId,
    );

    // Quick pre-check so the common "already rated" case avoids a transaction.
    if ((await doc.get()).exists) {
      return const RatingResult.failed(RatingFailure.alreadyRated);
    }

    final model = DoctorRatingModel(
      ratingId: doc.id,
      doctorId: doctorId,
      doctorName: prescription.doctorName,
      patientId: patientId,
      patientName: patientName,
      prescriptionId: prescriptionId,
      rating: rating,
      createdAt: DateTime.now(),
    );

    try {
      // Read-then-write inside a transaction makes the insert atomic, so two
      // simultaneous taps cannot both store a rating for the same
      // prescription: the loser sees the existing doc and is rejected.
      await _firestore.runTransaction((txn) async {
        final existing = await txn.get(doc);
        if (existing.exists) {
          throw const _AlreadyRatedException();
        }
        txn.set(doc, model.toMap());
      });

      // The rating itself is saved at this point, so the submission is already
      // a success. Refresh the doctor's profile projection separately and
      // never let a projection hiccup turn a saved rating into a failure.
      unawaited(projectOntoDoctor(doctorId));

      return RatingResult.success(model);
    } on _AlreadyRatedException {
      return const RatingResult.failed(RatingFailure.alreadyRated);
    } catch (e) {
      return const RatingResult.failed(RatingFailure.writeFailed);
    }
  }

  Future<PrescriptionModel?> _loadPrescription(String prescriptionId) async {
    if (prescriptionId.isEmpty) return null;
    try {
      final doc = await _firestore
          .collection(FirestoreCollections.prescriptions)
          .doc(prescriptionId)
          .get();
      if (!doc.exists) return null;
      return PrescriptionModel.fromMap(
        doc.id,
        Map<String, dynamic>.from(doc.data() ?? const {}),
      );
    } catch (e) {
      return null;
    }
  }
}
