import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/features/auth/presentation/providers/user_provider.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/core/services/firebase_storage_service.dart';
import 'package:telemedicine/core/services/notification_dispatcher.dart';
import 'package:telemedicine/core/utils/firestore_time.dart';
import 'package:telemedicine/data/models/appointment_model.dart';
import 'package:telemedicine/data/models/chat_model.dart';
import 'package:telemedicine/data/models/user_model.dart';
import 'package:telemedicine/features/appointments/presentation/appointment_lifecycle_logic.dart';
import 'package:telemedicine/features/chat/presentation/controllers/chat_controller.dart';
import 'package:uuid/uuid.dart';

/// Single entry point for every appointment-booking write.
///
/// The class is stateless: all live state comes from the Firestore streams the
/// providers below expose, so an admin decision or a doctor's confirmation
/// reaches the other side without any manual refresh.
class AppointmentController {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final NotificationDispatcher _fcm = NotificationDispatcher();
  final ChatController _chat = ChatController();

  CollectionReference<Map<String, dynamic>> get _payments =>
      _firestore.collection(FirestoreCollections.appointmentPayments);

  CollectionReference<Map<String, dynamic>> get _appointments =>
      _firestore.collection(FirestoreCollections.appointments);

  CollectionReference<Map<String, dynamic>> get _videoWatches =>
      _firestore.collection(FirestoreCollections.appointmentVideoWatches);

  CollectionReference<Map<String, dynamic>> get _settings =>
      _firestore.collection(FirestoreCollections.appointmentSettings);

  CollectionReference<Map<String, dynamic>> get _patients =>
      _firestore.collection(FirestoreCollections.patients);

  CollectionReference<Map<String, dynamic>> get _doctors =>
      _firestore.collection(FirestoreCollections.doctors);

  /// When a start-alarm push may be attempted again, per appointment.
  ///
  /// Static because the clock keeps its own `AppointmentController` instance
  /// and a failed attempt must stay suppressed across passes, not just across
  /// the one object that happened to make it.
  static final Map<String, DateTime> _alarmRetryAfter = {};
  static const Duration _alarmRetryDelay = Duration(minutes: 1);

  /// Same backoff table for the reminder and attendance pushes, keyed by
  /// `appointmentId:claimField` — one unreachable device must not turn a
  /// claim/release pair into a write on every 15-second tick.
  static final Map<String, DateTime> _noticeRetryAfter = {};

  /// Admin config, cached for [configCacheTtl] so a lifecycle pass over a few
  /// dozen appointments costs one document read instead of one per record.
  ///
  /// Static for the same reason as the retry tables: every screen and the
  /// clock share the cache, and the TTL is short enough that an admin's edit
  /// is picked up within minutes.
  static AppointmentConfig _configCache = AppointmentConfig.defaults();
  static DateTime _configFetchedAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration configCacheTtl = Duration(minutes: 5);

  /// The lifecycle settings, from `appointment_settings/defaults`.
  ///
  /// A missing document or a failed read resolves to the defaults rather than
  /// throwing: housekeeping must keep running with or without the config.
  Future<AppointmentConfig> config({bool forceRefresh = false}) async {
    if (!forceRefresh &&
        DateTime.now().difference(_configFetchedAt) < configCacheTtl) {
      return _configCache;
    }
    try {
      final snap = await _settings.doc(AppointmentConfig.docId).get();
      _configCache = AppointmentConfig.fromMap(snap.data());
    } catch (_) {
      // Keep whatever is already cached — the defaults if nothing ever loaded.
    }
    _configFetchedAt = DateTime.now();
    return _configCache;
  }

  static String videoWatchId({
    required String patientId,
    required String doctorId,
  }) => '${patientId}_$doctorId';

  // Deterministic pair id kept only so legacy payment documents (written
  // before payments became per-appointment) can still be recognised in
  // [watchPayment]. New payments use a fresh uuid as their document id.
  static String legacyPaymentIdFor({
    required String patientId,
    required String doctorId,
  }) => '${patientId}_$doctorId';

  // ─────────────────────────────────────────────────────────────
  // SAME-DOCTOR ACTIVE-APPOINTMENT GUARD
  //
  // One appointment at a time per patient/doctor pair. The pair is released
  // only when the scheduled end passes, which is exactly when the lifecycle
  // pass below flips the record to `expired`.
  // ─────────────────────────────────────────────────────────────

  /// Every appointment between this patient and this doctor.
  ///
  /// Only `patientId` is used as the Firestore filter — an equality filter the
  /// app already ships with — and `doctorId` is matched in memory, so this
  /// never depends on a composite index that may not be deployed yet.
  Future<List<AppointmentModel>> appointmentsForPair({
    required String patientId,
    required String doctorId,
  }) async {
    if (patientId.isEmpty || doctorId.isEmpty)
      return const <AppointmentModel>[];
    final snap = await _appointments
        .where('patientId', isEqualTo: patientId)
        .get();
    return snap.docs
        .map((d) => AppointmentModel.fromMap(d.id, d.data()))
        .where((a) => a.doctorId == doctorId)
        .toList();
  }

  /// The appointment that still occupies this pair, if any.
  ///
  /// A `confirmed`/`active` record whose scheduled end already passed is
  /// stale — the lifecycle pass is about to rewrite it to `expired` — so it
  /// must not lock the patient out of rebooking. An unscheduled `requested`
  /// record has no end instant and always holds the pair.
  AppointmentModel? openAppointmentForPair(
    Iterable<AppointmentModel> appointments,
    DateTime now,
  ) {
    for (final appointment in appointments) {
      if (!AppointmentStatus.isOpen(appointment.appointmentStatus)) continue;
      if (appointment.hasEndedAt(now)) continue;
      return appointment;
    }
    return null;
  }

  /// Blocking message for a booking attempt, or `null` when the pair is free.
  ///
  /// Two independent reasons can block: an appointment that still occupies the
  /// pair, and a cancellation freeze on either side. Both are looked up
  /// separately so a frozen *doctor* cannot be booked even by a patient who
  /// has never cancelled anything.
  ///
  /// A failed lookup returns `null`: a network hiccup must not lock the
  /// patient out of booking, and the write path below re-checks anyway.
  Future<String?> bookingBlockMessageFor({
    required String patientId,
    required String doctorId,
  }) async {
    try {
      final patientFreeze = await bookingFreezeMessageFor(
        collection: FirestoreCollections.patients,
        userId: patientId,
      );
      if (patientFreeze != null) return patientFreeze;

      final doctorFreeze = await bookingFreezeMessageFor(
        collection: FirestoreCollections.doctors,
        userId: doctorId,
      );
      if (doctorFreeze != null) return doctorFreeze;

      final blocking = openAppointmentForPair(
        await appointmentsForPair(patientId: patientId, doctorId: doctorId),
        DateTime.now(),
      );
      return blocking == null
          ? null
          : AppointmentDefaults.activeAppointmentMessage;
    } catch (_) {
      return null;
    }
  }

  /// The freeze message for one user, or `null` when they are free to book.
  ///
  /// An expired `bookingFrozenUntil` reads as *not* frozen — an admin who
  /// forgot to lift a freeze must never lock somebody out forever — and the
  /// write path clears the stale fields the next time it runs.
  Future<String?> bookingFreezeMessageFor({
    required String collection,
    required String userId,
  }) async {
    if (userId.isEmpty) return null;
    try {
      final snap = await _firestore.collection(collection).doc(userId).get();
      final data = snap.data();
      if (data == null) return null;
      return bookingFreezeMessage(
        frozenUntil: parseFirestoreTimestamp(data['bookingFrozenUntil']),
        now: DateTime.now(),
      );
    } catch (_) {
      return null;
    }
  }

  // ─────────────────────────────────────────────────────────────
  // AUDIT TRAIL — `appointments/{appointmentId}/events`
  // ─────────────────────────────────────────────────────────────

  CollectionReference<Map<String, dynamic>> _eventsOf(String appointmentId) =>
      _appointments
          .doc(appointmentId)
          .collection(FirestoreCollections.appointmentEvents);

  /// Appends one entry to the appointment's timeline.
  ///
  /// Never throws and never blocks a lifecycle transition: the timeline is a
  /// record of what happened, not a precondition for it. `at` is a server
  /// timestamp so three writers on three devices order identically.
  Future<void> appendEvent({
    required String appointmentId,
    required String type,
    String actorId = '',
    String actorRole = '',
    String detail = '',
  }) async {
    if (appointmentId.isEmpty || !AppointmentEventTypes.all.contains(type)) {
      return;
    }
    try {
      await _eventsOf(appointmentId).add({
        'type': type,
        'actorId': actorId,
        'actorRole': actorRole,
        'detail': detail,
        'at': FieldValue.serverTimestamp(),
        'createdAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {
      // Audit is best-effort; the status write already happened.
    }
  }

  /// Live timeline of one appointment, newest first.
  Stream<List<AppointmentEvent>> watchEvents(String appointmentId) async* {
    if (appointmentId.isEmpty) {
      yield const <AppointmentEvent>[];
      return;
    }
    try {
      await for (final snap in _eventsOf(
        appointmentId,
      ).orderBy('at', descending: true).snapshots()) {
        yield snap.docs
            .map((d) => AppointmentEvent.fromMap(d.id, d.data()))
            .toList();
      }
    } catch (_) {
      yield const <AppointmentEvent>[];
    }
  }

  /// One appointment document, kept live — used by the chat banner and the
  /// detail screens so a phase change on the other side shows up at once.
  Stream<AppointmentModel?> watchAppointment(String appointmentId) async* {
    if (appointmentId.isEmpty) {
      yield null;
      return;
    }
    try {
      await for (final snap in _appointments.doc(appointmentId).snapshots()) {
        yield snap.exists
            ? AppointmentModel.fromMap(snap.id, snap.data()!)
            : null;
      }
    } catch (_) {
      yield null;
    }
  }

  /// Every appointment in the system, for the admin monitoring screen.
  ///
  /// Deliberately unfiltered: a composite index is a deployment step, and the
  /// admin list sorts and filters in memory anyway (same pattern as
  /// [watchAllPayments]).
  Stream<List<AppointmentModel>> watchAllAppointments() async* {
    try {
      await for (final snap in _appointments.snapshots()) {
        yield snap.docs
            .map((d) => AppointmentModel.fromMap(d.id, d.data()))
            .toList();
      }
    } catch (_) {
      yield const <AppointmentModel>[];
    }
  }

  /// The admin lifecycle settings document, live so the editor shows other
  /// admins' changes.
  Stream<AppointmentConfig> watchConfig() async* {
    try {
      await for (final snap
          in _settings.doc(AppointmentConfig.docId).snapshots()) {
        final config = AppointmentConfig.fromMap(snap.data());
        _configCache = config;
        _configFetchedAt = DateTime.now();
        yield config;
      }
    } catch (_) {
      yield AppointmentConfig.defaults();
    }
  }

  /// Admin writes the settings; every device and the Cloud Function pick them
  /// up from the one document.
  Future<String?> saveConfig(AppointmentConfig config) async {
    try {
      await _settings
          .doc(AppointmentConfig.docId)
          .set(config.toMap(), SetOptions(merge: true));
      _configCache = config;
      _configFetchedAt = DateTime.now();
      return null;
    } catch (e) {
      return 'Could not save the settings: $e';
    }
  }

  /// First document id for this pair that nobody occupies yet.
  ///
  /// The base id (`patient_doctor_payment`) keeps holding the first
  /// appointment, so every id already written in the field stays valid. Once
  /// every appointment under it reached a terminal state the pair books again
  /// under `_2`, `_3`, … — without it, a rebooking after an expiry would land
  /// on the old document, find it already there and silently do nothing.
  String _nextAppointmentId({
    required String patientId,
    required String doctorId,
    required String paymentId,
    required Iterable<AppointmentModel> existing,
  }) {
    final base = AppointmentModel.buildId(
      patientId: patientId,
      doctorId: doctorId,
      paymentId: paymentId,
    );
    final taken = existing.map((a) => a.id).toSet();
    if (!taken.contains(base)) return base;

    var generation = 2;
    while (taken.contains(
      AppointmentModel.buildOccurrenceId(
        patientId: patientId,
        doctorId: doctorId,
        paymentId: paymentId,
        occurrence: generation,
      ),
    )) {
      generation++;
    }
    return AppointmentModel.buildOccurrenceId(
      patientId: patientId,
      doctorId: doctorId,
      paymentId: paymentId,
      occurrence: generation,
    );
  }

  // ─────────────────────────────────────────────────────────────
  // VIDEO STEP
  // ─────────────────────────────────────────────────────────────

  /// `videoWatched` is persisted rather than inferred from a button tap: the
  /// flag is written only after the patient confirms the video is finished.
  Stream<bool> watchVideoWatched({
    required String patientId,
    required String doctorId,
  }) async* {
    if (patientId.isEmpty || doctorId.isEmpty) {
      yield false;
      return;
    }
    try {
      await for (final doc
          in _videoWatches
              .doc(videoWatchId(patientId: patientId, doctorId: doctorId))
              .snapshots()) {
        yield (doc.data()?['videoWatched'] ?? false) == true;
      }
    } catch (_) {
      yield false;
    }
  }

  Future<bool> hasWatchedVideo({
    required String patientId,
    required String doctorId,
  }) async {
    if (patientId.isEmpty || doctorId.isEmpty) return false;
    try {
      final doc = await _videoWatches
          .doc(videoWatchId(patientId: patientId, doctorId: doctorId))
          .get();
      return (doc.data()?['videoWatched'] ?? false) == true;
    } catch (_) {
      return false;
    }
  }

  /// Idempotent — repeating it rewrites the same document with the same flag,
  /// so it can never produce a duplicate record.
  Future<bool> markVideoWatched({
    required String patientId,
    required String doctorId,
    required String patientName,
    required String doctorName,
    String videoAssignmentId = '',
    String youtubeVideoId = '',
  }) async {
    if (patientId.isEmpty || doctorId.isEmpty) return false;
    try {
      await _firestore
          .collection(FirestoreCollections.doctorVideoWatches)
          .doc('${patientId}_$doctorId')
          .set({
            'patientId': patientId,
            'doctorId': doctorId,
            'videoAssignmentId': videoAssignmentId,
            'youtubeVideoId': youtubeVideoId,
            'watchProgress': 1.0,
            'completed': true,
            'completedAt': FieldValue.serverTimestamp(),
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
      await _videoWatches
          .doc(videoWatchId(patientId: patientId, doctorId: doctorId))
          .set({
            'id': videoWatchId(patientId: patientId, doctorId: doctorId),
            'patientId': patientId,
            'patientName': patientName,
            'doctorId': doctorId,
            'doctorName': doctorName,
            'videoWatched': true,
            'watchedAt': FieldValue.serverTimestamp(),
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
      return true;
    } catch (_) {
      return false;
    }
  }

  // ─────────────────────────────────────────────────────────────
  // PRICE
  // ─────────────────────────────────────────────────────────────

  /// The doctor's own consultation price, straight from their document.
  ///
  /// `price` is what the profile screens write; `consultationFee` is the
  /// legacy key that older doctor documents carry instead. Missing, `null` or
  /// malformed values resolve to `0`, which every caller already renders as
  /// "Not set" — an old doctor document must never break a screen.
  static double priceOf(Map<String, dynamic> doctor) {
    final price = _asDouble(doctor['price']);
    if (price != null && price > 0) return price;
    return _asDouble(doctor['consultationFee']) ?? 0;
  }

  /// Builds the pricing every screen shows, from the doctor document plus the
  /// persisted video flag — never from a local toggle and never from a
  /// hardcoded amount.
  static AppointmentPricing pricingFor({
    required Map<String, dynamic> doctor,
    required bool videoWatched,
  }) {
    final fee = priceOf(doctor);
    final percent = appointmentDiscountPercentFor(doctor['discountPercentage']);
    return AppointmentPricing(
      consultationFee: fee,
      discountPercent: percent,
      videoWatched: videoWatched,
    );
  }

  static String youtubeUrlOf(Map<String, dynamic> doctor) =>
      (doctor['youtubeVideoUrl'] ?? '').toString().trim();

  /// Empty URLs are handled gracefully (the step is simply hidden), and only
  /// real YouTube hosts are accepted so a stray string cannot open anything.
  static bool isUsableYoutubeUrl(String url) {
    final value = url.trim();
    if (value.isEmpty) return false;
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasScheme) return false;
    final host = uri.host.toLowerCase();
    return host == 'youtube.com' ||
        host.endsWith('.youtube.com') ||
        host == 'youtu.be' ||
        host == 'youtube-nocookie.com' ||
        host.endsWith('.youtube-nocookie.com');
  }

  // ─────────────────────────────────────────────────────────────
  // PAYMENT
  // ─────────────────────────────────────────────────────────────

  /// The payment that belongs to the patient's *current* booking attempt for
  /// this doctor, or `null` when the patient is free to pay again.
  ///
  /// Every payment record is its own document (id = `paymentId`), so an old,
  /// already-consumed payment can never leak into a new booking. The current
  /// one is the newest record for the pair that is either still waiting for
  /// review, still retryable after a rejection, or approved but whose
  /// appointment never made it past the terminal states. An approved payment
  /// whose appointment completed/expired/cancelled reads as `null` — paying
  /// again is now allowed and will create a brand-new payment record.
  Stream<AppointmentPaymentModel?> watchPayment({
    required String patientId,
    required String doctorId,
  }) async* {
    if (patientId.isEmpty || doctorId.isEmpty) {
      yield null;
      return;
    }
    try {
      await for (final snap
          in _payments.where('patientId', isEqualTo: patientId).snapshots()) {
        final candidates =
            snap.docs
                .map((d) => AppointmentPaymentModel.fromMap(d.id, d.data()))
                .where((p) => p.doctorId == doctorId)
                .toList()
              ..sort((a, b) {
                final aAt = a.submittedAt ?? a.updatedAt;
                final bAt = b.submittedAt ?? b.updatedAt;
                return (bAt ?? DateTime.fromMillisecondsSinceEpoch(0))
                    .compareTo(aAt ?? DateTime.fromMillisecondsSinceEpoch(0));
              });

        AppointmentPaymentModel? current;
        for (final candidate in candidates) {
          if (candidate.isPending || candidate.isRejected) {
            current = candidate;
            break;
          }
          // Approved: only still "current" when its appointment is missing
          // (request not sent yet) or still open. A terminal appointment
          // means this payment is spent history.
          final appointments = await appointmentsForPair(
            patientId: patientId,
            doctorId: doctorId,
          );
          final linked = appointments
              .where(
                (a) =>
                    (candidate.appointmentId.isNotEmpty &&
                        a.id == candidate.appointmentId) ||
                    a.paymentId == (candidate.paymentId ?? candidate.id),
              )
              .toList();
          final isOpen = linked.any(
            (a) =>
                AppointmentStatus.isOpen(a.appointmentStatus) &&
                !a.hasEndedAt(DateTime.now()),
          );
          if (linked.isEmpty || isOpen) {
            current = candidate;
          }
          break;
        }
        yield current;
      }
    } catch (_) {
      yield null;
    }
  }

  Stream<List<AppointmentPaymentModel>> watchAllPayments() async* {
    try {
      await for (final snap
          in _payments.orderBy('submittedAt', descending: true).snapshots()) {
        yield snap.docs
            .map((d) => AppointmentPaymentModel.fromMap(d.id, d.data()))
            .toList();
      }
    } catch (_) {
      yield <AppointmentPaymentModel>[];
    }
  }

  /// Uploads the proof and writes the single payment record for this
  /// patient/doctor pair.
  ///
  /// The deterministic document id enforces "no duplicate payment records":
  /// a rejected attempt is re-submitted in place.
  Future<String?> submitAppointmentPayment({
    required UserModel patient,
    required Map<String, dynamic> doctor,
    required bool videoWatched,
    required String proofUrl,
  }) async {
    final doctorId = (doctor['id'] ?? '').toString();
    final doctorName = (doctor['fullname'] ?? '').toString();
    if (doctorId.isEmpty) return 'Doctor information is missing.';
    if (proofUrl.isEmpty) return 'Payment proof could not be uploaded.';

    // Refuse before the upload: paying for a doctor the patient already has an
    // open appointment with would strand the money on a booking that cannot be
    // created.
    final blockedByAppointment = await bookingBlockMessageFor(
      patientId: patient.id,
      doctorId: doctorId,
    );
    if (blockedByAppointment != null) return blockedByAppointment;

    // One live payment attempt per pair: a pending proof is already under
    // review, and an approved one may still be waiting for the appointment
    // request — neither may be duplicated by a second record.
    final pairPayments = await _payments
        .where('patientId', isEqualTo: patient.id)
        .get();
    final latestForDoctor =
        pairPayments.docs
            .map((d) => AppointmentPaymentModel.fromMap(d.id, d.data()))
            .where((p) => p.doctorId == doctorId)
            .toList()
          ..sort((a, b) {
            final aAt = a.submittedAt ?? a.updatedAt;
            final bAt = b.submittedAt ?? b.updatedAt;
            return (bAt ?? DateTime.fromMillisecondsSinceEpoch(0)).compareTo(
              aAt ?? DateTime.fromMillisecondsSinceEpoch(0),
            );
          });
    final live = latestForDoctor.isEmpty ? null : latestForDoctor.first;
    if (live != null && live.isPending) {
      return 'Your appointment payment is currently under review. '
          'Please wait for approval.';
    }
    if (live != null && live.isApproved && !live.appointmentCreated) {
      return 'Your previous payment for this doctor is approved. '
          'Please send the appointment request.';
    }

    final pricing = pricingFor(doctor: doctor, videoWatched: videoWatched);
    if (pricing.consultationFee <= 0) {
      return 'This doctor has not set their consultation price yet.';
    }

    // A rejected attempt is retried in place (same payment record, same
    // paymentId) — the rejected proof is replaced, never reused as approved.
    final retrying = (live != null && live.isRejected) ? live : null;
    final paymentId = retrying?.paymentId?.isNotEmpty == true
        ? retrying!.paymentId!
        : const Uuid().v4();
    final notificationId = const Uuid().v4();
    final docId = retrying != null ? retrying.id : paymentId;

    try {
      final blocked = await _firestore.runTransaction<bool>((tx) async {
        final ref = _payments.doc(docId);
        final snap = await tx.get(ref);
        if (snap.exists &&
            snap.data()?['paymentStatus'] == PaymentStatus.approved) {
          return true;
        }
        tx.set(ref, {
          'id': docId,
          'patientId': patient.id,
          'patientName': patient.fullname,
          'patientImage': patient.image ?? '',
          'patientPhone': patient.phoneNumber,
          'doctorId': doctorId,
          'doctorName': doctorName,
          'doctorImage': (doctor['imageUrl'] ?? '').toString(),
          'doctorSpecialization':
              (doctor['specialization'] ?? doctor['highestDegree'] ?? '')
                  .toString(),
          'videoWatched': pricing.videoWatched,
          // The doctor's own price, copied onto the payment so the record
          // still shows what was charged if the doctor changes it later.
          'price': pricing.consultationFee,
          'consultationFee': pricing.consultationFee,
          'discountPercentage': pricing.discountApplied
              ? pricing.discountPercent
              : 0.0,
          'discountAmount': pricing.discountAmount,
          'payableAmount': pricing.payableAmount,
          'paymentStatus': PaymentStatus.pending,
          'paymentType': 'appointment_booking',
          'paymentImage': proofUrl,
          'paymentId': paymentId,
          'notificationId': notificationId,
          'appointmentCreated': retrying?.appointmentCreated ?? false,
          if (retrying != null && retrying.appointmentId.isNotEmpty)
            'appointmentId': retrying.appointmentId,
          'rejectionReason': FieldValue.delete(),
          'reviewedAt': FieldValue.delete(),
          'submittedAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        return false;
      });

      if (blocked) return 'This appointment payment has already been approved.';

      // Save consistent record to unified payments collection
      try {
        await _firestore.collection('payments').doc(paymentId).set({
          'paymentId': paymentId,
          'patientUid': patient.id,
          'patientId': patient.patientId,
          'patientName': patient.fullname,
          'paymentType': 'appointment_booking',
          'amount': pricing.payableAmount,
          'currency': 'PKR',
          'proofReference': proofUrl,
          'status': 'pending',
          'relatedAppointmentId': retrying?.appointmentId.isNotEmpty == true
              ? retrying!.appointmentId
              : null,
          'doctorId': doctorId,
          'doctorName': doctorName,
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
      } catch (e) {
        debugPrint('Note: Error saving to payments collection: $e');
      }

      await _notifyAdminsOfAppointmentPayment(
        patient: patient,
        doctorName: doctorName,
        payableAmount: pricing.payableAmount,
        paymentId: paymentId,
        notificationId: notificationId,
      );
      return null;
    } catch (e) {
      return 'Could not submit the payment: $e';
    }
  }

  Future<String?> approveAppointmentPayment(
    AppointmentPaymentModel payment,
  ) async {
    if (payment.isApproved) return null;

    // Consistency guard: a payment whose appointment is already known must
    // point back at this exact payment, patient and doctor — an inconsistent
    // relationship is never approved.
    if (payment.appointmentId.isNotEmpty) {
      final appt = await _appointments.doc(payment.appointmentId).get();
      if (!appt.exists) {
        return 'The linked appointment no longer exists.';
      }
      final data = appt.data()!;
      if (data['patientId'] != payment.patientId ||
          data['doctorId'] != payment.doctorId ||
          data['paymentId'] != (payment.paymentId ?? payment.id)) {
        return 'This payment does not match its appointment.';
      }
    }

    await _payments.doc(payment.id).set({
      'paymentStatus': PaymentStatus.approved,
      'reviewedAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    final resolvedPid = payment.paymentId ?? payment.id;
    try {
      await _firestore.collection('payments').doc(resolvedPid).set({
        'status': 'approved',
        'reviewedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (_) {}

    // Persistent patient notification
    final notifId = const Uuid().v4();
    try {
      await _firestore.collection('patient_notifications').doc(notifId).set({
        'notificationId': notifId,
        'recipientUid': payment.patientId,
        'type': FcmMessageType.appointmentPaymentApproved,
        'title': 'Appointment Payment Approved',
        'body':
            'Your appointment payment with Dr. ${payment.doctorName} has been approved.',
        'senderName': 'OPD Telemedicine Admin',
        'paymentId': resolvedPid,
        'paymentType': 'appointment_booking',
        'appointmentId': payment.appointmentId,
        'isRead': false,
        'createdAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {}

    await _notifyPatientOfAppointmentPaymentDecision(
      patientId: payment.patientId,
      doctorName: payment.doctorName,
      paymentId: payment.paymentId ?? payment.id,
      approved: true,
    );
    return null;
  }

  Future<String?> rejectAppointmentPayment(
    AppointmentPaymentModel payment, {
    required String reason,
  }) async {
    if (payment.isApproved) return 'This payment was already approved.';
    await _payments.doc(payment.id).set({
      'paymentStatus': PaymentStatus.rejected,
      'rejectionReason': reason,
      'reviewedAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
      'notificationId': const Uuid().v4(),
    }, SetOptions(merge: true));

    final resolvedPid = payment.paymentId ?? payment.id;
    try {
      await _firestore.collection('payments').doc(resolvedPid).set({
        'status': 'rejected',
        'rejectionReason': reason,
        'reviewedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (_) {}

    // Persistent patient notification
    final notifId = const Uuid().v4();
    try {
      await _firestore.collection('patient_notifications').doc(notifId).set({
        'notificationId': notifId,
        'recipientUid': payment.patientId,
        'type': FcmMessageType.appointmentPaymentRejected,
        'title': 'Payment Proof Rejected',
        'body': reason.isNotEmpty
            ? reason
            : 'Your appointment payment with Dr. ${payment.doctorName} was rejected.',
        'senderName': 'OPD Telemedicine Admin',
        'paymentId': resolvedPid,
        'paymentType': 'appointment_booking',
        'appointmentId': payment.appointmentId,
        'isRead': false,
        'createdAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {}

    await _notifyPatientOfAppointmentPaymentDecision(
      patientId: payment.patientId,
      doctorName: payment.doctorName,
      paymentId: payment.paymentId ?? payment.id,
      approved: false,
    );
    return null;
  }

  // ─────────────────────────────────────────────────────────────
  // APPOINTMENT REQUEST
  // ─────────────────────────────────────────────────────────────

  Stream<List<AppointmentModel>> watchPatientAppointments(
    String patientId,
  ) async* {
    if (patientId.isEmpty) {
      yield const <AppointmentModel>[];
      return;
    }
    try {
      await for (final snap
          in _appointments
              .where('patientId', isEqualTo: patientId)
              .snapshots()) {
        yield snap.docs
            .map((d) => AppointmentModel.fromMap(d.id, d.data()))
            .toList();
      }
    } catch (_) {
      yield const <AppointmentModel>[];
    }
  }

  Stream<List<AppointmentModel>> watchDoctorAppointments(
    String doctorId,
  ) async* {
    if (doctorId.isEmpty) {
      yield const <AppointmentModel>[];
      return;
    }
    try {
      await for (final snap
          in _appointments.where('doctorId', isEqualTo: doctorId).snapshots()) {
        yield snap.docs
            .map((d) => AppointmentModel.fromMap(d.id, d.data()))
            .toList();
      }
    } catch (_) {
      yield const <AppointmentModel>[];
    }
  }

  /// Creates the appointment document. The transaction guarantees a single
  /// record regardless of how many times the button is tapped, and tells the
  /// caller whether *this* tap created it — only that tap may notify the
  /// doctor, which is what keeps the FCM count at one.
  Future<String?> sendAppointmentRequest({
    required UserModel patient,
    required Map<String, dynamic> doctor,
    required AppointmentPaymentModel payment,
    required String subject,
    required String message,
  }) async {
    if (!payment.isApproved) {
      return 'Your payment has not been approved yet.';
    }
    if (subject.trim().isEmpty) return 'Subject is required.';
    if (message.trim().isEmpty) return 'Message is required.';

    final doctorId = (doctor['id'] ?? payment.doctorId).toString();
    final paymentKey = payment.paymentId ?? payment.id;

    // A cancellation freeze on either side stops the request before any money
    // moves or any document is written.
    final patientFreeze = await bookingFreezeMessageFor(
      collection: FirestoreCollections.patients,
      userId: patient.id,
    );
    if (patientFreeze != null) return patientFreeze;
    final doctorFreeze = await bookingFreezeMessageFor(
      collection: FirestoreCollections.doctors,
      userId: doctorId,
    );
    if (doctorFreeze != null) return doctorFreeze;

    // Same-doctor guard. An open appointment for this pair blocks a second
    // one; the pair's own still-open request is the retry case and falls
    // through to the transaction below, which finds the document and reports
    // "already there" instead of duplicating it.
    final pair = await appointmentsForPair(
      patientId: patient.id,
      doctorId: doctorId,
    );
    final blocking = openAppointmentForPair(pair, DateTime.now());
    if (blocking != null && blocking.paymentId != paymentKey) {
      return AppointmentDefaults.activeAppointmentMessage;
    }

    final appointmentId =
        blocking?.id ??
        _nextAppointmentId(
          patientId: patient.id,
          doctorId: doctorId,
          paymentId: paymentKey,
          existing: pair,
        );

    final appointment = AppointmentModel(
      id: appointmentId,
      patientId: patient.id,
      patientName: patient.fullname,
      patientImage: patient.image ?? '',
      doctorId: doctorId,
      doctorName: (doctor['fullname'] ?? payment.doctorName).toString(),
      doctorImage: (doctor['imageUrl'] ?? payment.doctorImage).toString(),
      doctorSpecialization: payment.doctorSpecialization,
      subject: subject.trim(),
      message: message.trim(),
      price: payment.consultationFee,
      consultationFee: payment.consultationFee,
      discountPercentage: payment.discountPercentage,
      discountAmount: payment.discountAmount,
      payableAmount: payment.payableAmount,
      videoWatched: payment.videoWatched,
      youtubeVideoUrl: youtubeUrlOf(doctor),
      paymentId: payment.paymentId ?? payment.id,
      paymentStatus: PaymentStatus.approved,
      appointmentStatus: AppointmentStatus.requested,
      appointmentPhase: AppointmentPhase.waiting,
      createdAt: DateTime.now(),
    );

    try {
      final ref = _appointments.doc(appointmentId);
      final created = await _firestore.runTransaction<bool>((tx) async {
        final snap = await tx.get(ref);
        if (snap.exists) return false;
        tx.set(ref, appointment.toMap());
        return true;
      });

      if (!created) return null;

      await _payments.doc(payment.id).set({
        'appointmentCreated': true,
        'appointmentId': appointmentId,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      await appendEvent(
        appointmentId: appointmentId,
        type: AppointmentEventTypes.created,
        actorId: patient.id,
        actorRole: AppointmentActors.patient,
        detail: subject.trim(),
      );
      await _notifyDoctorOfAppointmentRequest(appointment);
      return null;
    } catch (e) {
      return 'Could not send the appointment request: $e';
    }
  }

  // ─────────────────────────────────────────────────────────────
  // DOCTOR CONFIRMS DATE / TIME
  // ─────────────────────────────────────────────────────────────

  /// Only the doctor the appointment belongs to may schedule it — checked
  /// against the stored document, not the widget's arguments.
  Future<String?> confirmAppointment({
    required AppointmentModel appointment,
    required String actingDoctorId,
    required String scheduledDate,
    required String scheduledStartTime,
    required String scheduledEndTime,
    String doctorResponse = '',
  }) async {
    if (appointment.doctorId != actingDoctorId) {
      return 'Only the selected doctor can schedule this appointment.';
    }
    if (scheduledDate.isEmpty ||
        scheduledStartTime.isEmpty ||
        scheduledEndTime.isEmpty) {
      return 'Please pick a date, start time and end time.';
    }
    // A frozen doctor may not take on new consultations either — the freeze
    // is a pause on new business, not just on the patient side.
    final freeze = await bookingFreezeMessageFor(
      collection: FirestoreCollections.doctors,
      userId: actingDoctorId,
    );
    if (freeze != null) return freeze;

    final ref = _appointments.doc(appointment.id);
    final startAt = appointmentStartInstant(scheduledDate, scheduledStartTime);
    final endAt = appointmentEndInstant(scheduledDate, scheduledEndTime);
    var changed = false;

    try {
      await _firestore.runTransaction<void>((tx) async {
        final snap = await tx.get(ref);
        if (!snap.exists) {
          throw StateError('Appointment no longer exists');
        }
        final current = snap.data()?['appointmentStatus'] as String? ?? '';
        if (current == AppointmentStatus.confirmed ||
            current == AppointmentStatus.active ||
            current == AppointmentStatus.completed) {
          return;
        }
        if (current == AppointmentStatus.expired) {
          // An expired record is history: it must be rebooked, never
          // re-dated onto a slot that has already been released.
          throw StateError('This appointment has already expired');
        }
        changed = true;
        tx.update(ref, {
          'appointmentStatus': AppointmentStatus.confirmed,
          'scheduledDate': scheduledDate,
          'scheduledStartTime': scheduledStartTime,
          'scheduledEndTime': scheduledEndTime,
          if (startAt != null)
            'scheduledStartDateTime': Timestamp.fromDate(startAt),
          if (endAt != null) 'scheduledEndDateTime': Timestamp.fromDate(endAt),
          // Same instants under the legacy names, for readers written before
          // the canonical pair existed.
          if (startAt != null) 'scheduledStartAt': Timestamp.fromDate(startAt),
          if (endAt != null) 'scheduledEndAt': Timestamp.fromDate(endAt),
          // This slot's start alarm has not fired yet — the claim belongs to
          // the start instant, and this is the first one for the record.
          'appointmentStartNotificationSent': false,
          // Re-dating a slot re-arms everything that belongs to the *old*
          // slot: attendance from a previous date must not make the new one
          // look already joined, and the new slot deserves its own reminders
          // and late notices.
          'appointmentPhase': AppointmentPhase.scheduled,
          'patientJoinedAt': FieldValue.delete(),
          'doctorJoinedAt': FieldValue.delete(),
          'reminderSent': FieldValue.delete(),
          'reminder24hSent': false,
          'reminder60mSent': false,
          'reminder10mSent': false,
          'doctorLateNoticeSent': false,
          'patientLateNoticeSent': false,
          'graceNoticeSent': false,
          if (doctorResponse.trim().isNotEmpty)
            'doctorResponse': doctorResponse.trim(),
          'confirmedAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
      });
    } catch (e) {
      if (e is StateError &&
          e.message == 'This appointment has already expired') {
        return 'This appointment has expired. Ask the patient to book a new one.';
      }
      return 'Could not confirm the appointment: $e';
    }

    // Already confirmed by a previous tap: skip the message and the push so
    // repeated taps cannot duplicate either.
    if (!changed) return null;

    await appendEvent(
      appointmentId: appointment.id,
      type: appointment.hasSchedule
          ? AppointmentEventTypes.rescheduled
          : AppointmentEventTypes.confirmed,
      actorId: actingDoctorId,
      actorRole: AppointmentActors.doctor,
      detail: '$scheduledDate • $scheduledStartTime - $scheduledEndTime',
    );

    final refreshed = await _loadAppointment(ref) ?? appointment;
    final pinnedId = await _createPinnedAppointmentMessage(
      appointment: refreshed,
      scheduledDate: scheduledDate,
      scheduledStartTime: scheduledStartTime,
      scheduledEndTime: scheduledEndTime,
    );
    if (pinnedId != null) {
      await ref.set({
        'pinnedMessageId': pinnedId,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    }

    await _notifyPatientOfConfirmation(
      appointment: refreshed,
      scheduledDate: scheduledDate,
      scheduledStartTime: scheduledStartTime,
      scheduledEndTime: scheduledEndTime,
    );
    return null;
  }

  /// Writes the system message into the existing Room Chat.
  ///
  /// It is an ordinary message document with a dedicated `messageType` and
  /// `isPinned`, so both sides pick it up through the stream they already use
  /// — no second chat mechanism is introduced. The returned doc id is stored
  /// on the appointment as `pinnedMessageId`.
  Future<String?> _createPinnedAppointmentMessage({
    required AppointmentModel appointment,
    required String scheduledDate,
    required String scheduledStartTime,
    required String scheduledEndTime,
  }) async {
    try {
      final chatId = _chat.getChatId(
        appointment.patientId,
        appointment.doctorId,
      );
      final messageId = const Uuid().v4();
      final displayDate = appointmentFormatDisplayDate(scheduledDate);
      final body =
          '📌 Appointment Scheduled\n\n'
          '${appointment.doctorName} is available for your appointment.\n\n'
          'Date: $displayDate\n'
          'Time: $scheduledStartTime - $scheduledEndTime';

      final message = ChatMessageModel(
        id: messageId,
        senderId: appointment.doctorId,
        receiverId: appointment.patientId,
        message: body,
        messageType: ChatMessageTypes.appointment,
        timestamp: DateTime.now(),
        isPinned: true,
        appointmentId: appointment.id,
      ).toMap();

      await _firestore
          .collection(FirestoreCollections.chats)
          .doc(chatId)
          .collection(FirestoreCollections.chatMessages)
          .doc(messageId)
          .set(message);

      // Refresh the conversation preview without touching unread counters —
      // a system message must not manufacture a badge.
      await _firestore.collection(FirestoreCollections.chats).doc(chatId).set({
        'lastMessage': body,
        'lastMessageTime': FieldValue.serverTimestamp(),
        'lastMessageSenderId': appointment.doctorId,
        'lastMessageId': messageId,
        'participants': [appointment.patientId, appointment.doctorId],
      }, SetOptions(merge: true));

      return messageId;
    } catch (_) {
      return null;
    }
  }

  Future<void> unpinMessage({
    required String patientId,
    required String doctorId,
    required String? messageId,
  }) async {
    if (messageId == null || messageId.isEmpty) return;
    try {
      final chatId = _chat.getChatId(patientId, doctorId);
      await _firestore
          .collection(FirestoreCollections.chats)
          .doc(chatId)
          .collection(FirestoreCollections.chatMessages)
          .doc(messageId)
          .set({'isPinned': false}, SetOptions(merge: true));
    } catch (_) {
      // Unpinning is cosmetic; it must never break the completion flow.
    }
  }

  /// One pass of the appointment lifecycle for the signed-in user.
  ///
  /// For every appointment they participate in:
  ///   * past its scheduled start → `active`, so both portals can tell the
  ///     consultation is live before anyone touches a screen;
  ///   * past its start with the claim still free → claim it in a transaction
  ///     and push the one-shot start alarm to patient and doctor;
  ///   * past its scheduled end → `expired`, with the chat message unpinned.
  ///
  /// Every write is guarded by the status or by the claim flag it is moving
  /// to, so running it twice — or from two devices while the scheduled Cloud
  /// Function runs it as well — changes nothing the second time.
  Future<void> runAppointmentLifecycle({
    required String userId,
    required bool isDoctor,
  }) async {
    if (userId.isEmpty) return;
    try {
      final query = isDoctor
          ? _appointments.where('doctorId', isEqualTo: userId)
          : _appointments.where('patientId', isEqualTo: userId);
      final snap = await query.get();
      if (snap.docs.isEmpty) return;

      await evaluateAppointments(
        snap.docs.map((d) => AppointmentModel.fromMap(d.id, d.data())).toList(),
      );
    } catch (_) {
      // Background housekeeping never surfaces an error to the UI.
    }
  }

  /// The transition half of the lifecycle, over appointments already in hand.
  ///
  /// Split out from [runAppointmentLifecycle] so a caller that already keeps a
  /// live list — the foreground clock does — can evaluate it on every tick
  /// without paying for a query the list has just answered. Every branch
  /// writes only when the stored state still has somewhere to go, so
  /// evaluating an unchanged list costs nothing but the read inside the one
  /// transaction that actually claims a push.
  ///
  /// Order of decisions for one record, mirrored exactly by
  /// `functions/index.js` (same constants, same precedence):
  ///
  ///   1. terminal        → clear a stale live phase, stop;
  ///   2. slot has ended  → close it (expired / no-show / completed);
  ///   3. not confirmed   → keep the `waiting` phase, stop;
  ///   4. otherwise       → derive the phase, send whatever reminders are due,
  ///                        activate at the start, fire the start alarm, and
  ///                        push the late / grace notices exactly once.
  Future<void> evaluateAppointments(List<AppointmentModel> appointments) async {
    if (appointments.isEmpty) return;
    final now = DateTime.now();
    final config = await this.config();

    for (final appointment in appointments) {
      try {
        final ref = _appointments.doc(appointment.id);

        if (AppointmentStatus.isTerminal(appointment.appointmentStatus)) {
          await _clearStalePhase(ref, appointment);
          continue;
        }

        // The end is the hard deadline: an appointment that is over never
        // gets a start alarm, no matter how late this pass runs.
        if (appointment.hasEndedAt(now)) {
          await _closeAppointment(ref, appointment);
          continue;
        }

        if (!appointment.isConfirmed || !appointment.hasSchedule) {
          await _writePhaseIfChanged(
            ref,
            appointment,
            AppointmentPhase.waiting,
          );
          continue;
        }

        final phase = resolveAppointmentPhase(
          status: appointment.appointmentStatus,
          startAt: appointment.startAt,
          endAt: appointment.endAt,
          patientJoinedAt: appointment.patientJoinedAt,
          doctorJoinedAt: appointment.doctorJoinedAt,
          now: now,
          config: config,
        );
        await _writePhaseIfChanged(ref, appointment, phase);

        // Reminders only exist before the start; after it the start alarm
        // owns the moment, so this loop finds nothing due.
        await _sendRemindersOnce(ref, appointment, config, now);

        if (!appointment.hasStartedAt(now)) continue;

        if (appointment.appointmentStatus == AppointmentStatus.confirmed) {
          await ref.set({
            'appointmentStatus': AppointmentStatus.active,
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
        }
        await _sendStartAlarmOnce(ref, appointment, now);
        await _sendAttendanceNoticeOnce(ref, appointment, phase, now);
      } catch (_) {
        // One bad record must not stop the rest of the pass.
      }
    }
  }

  /// Legacy name kept so the existing screen call sites stay valid — the pass
  /// now covers activation and the start alarm as well as expiry.
  Future<void> finalizeExpiredAppointments({
    required String userId,
    required bool isDoctor,
  }) => runAppointmentLifecycle(userId: userId, isDoctor: isDoctor);

  /// Closes an appointment whose scheduled end has passed.
  ///
  /// The outcome is derived from attendance, not assumed:
  ///
  ///   * one side waited and the other never joined → `appointment_no_show`
  ///     naming the absent side (somebody's time was actually wasted);
  ///   * nobody joined → `appointment_expired`, exactly as before this
  ///     feature existed (no blame, and every legacy record keeps landing
  ///     where it always did);
  ///   * both joined → `appointment_completed`, because the consultation
  ///     happened and only the closing write was missing.
  ///
  /// The chat message is unpinned in every case so the pair is released, and
  /// the whole thing is idempotent — both sides and the Cloud Function may run
  /// it concurrently.
  Future<void> _closeAppointment(
    DocumentReference<Map<String, dynamic>> ref,
    AppointmentModel appointment,
  ) async {
    if (!AppointmentStatus.isOpen(appointment.appointmentStatus)) return;

    final outcome = resolveTerminalOutcome(
      patientJoinedAt: appointment.patientJoinedAt,
      doctorJoinedAt: appointment.doctorJoinedAt,
    );

    try {
      await ref.set({
        'appointmentStatus': outcome.status,
        'appointmentPhase': AppointmentPhase.closed,
        if (outcome.noShowBy.isNotEmpty) 'noShowBy': outcome.noShowBy,
        if (outcome.status == AppointmentStatus.noShow)
          'noShowAt': FieldValue.serverTimestamp(),
        if (outcome.status == AppointmentStatus.completed)
          'completedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      await appendEvent(
        appointmentId: appointment.id,
        type: outcome.event,
        detail: outcome.status == AppointmentStatus.noShow
            ? '${outcome.noShowBy} did not join'
            : '',
      );

      await unpinMessage(
        patientId: appointment.patientId,
        doctorId: appointment.doctorId,
        messageId: appointment.pinnedMessageId,
      );

      if (outcome.status == AppointmentStatus.noShow) {
        await _notifyNoShow(appointment, outcome.noShowBy);
      }
    } catch (_) {
      // Background housekeeping never surfaces an error to the UI.
    }
  }

  /// Terminal records must not keep showing a live phase on a stale screen.
  Future<void> _clearStalePhase(
    DocumentReference<Map<String, dynamic>> ref,
    AppointmentModel appointment,
  ) async {
    final phase = appointment.appointmentPhase;
    if (phase.isEmpty || phase == AppointmentPhase.closed) return;
    await _writePhaseIfChanged(ref, appointment, AppointmentPhase.closed);
  }

  /// Writes `appointmentPhase` only when it actually moved. Silent: phase
  /// changes are displayed state, and the events worth auditing (late, grace,
  /// joined) are written by whoever pushes the notice.
  Future<void> _writePhaseIfChanged(
    DocumentReference<Map<String, dynamic>> ref,
    AppointmentModel appointment,
    String phase,
  ) async {
    if (appointment.appointmentPhase == phase) return;
    try {
      await ref.set({
        'appointmentPhase': phase,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (_) {
      // The next pass re-derives it from the same inputs.
    }
  }

  /// Fires the appointment-start alarm exactly once per appointment per start
  /// instant.
  ///
  /// The claim is taken in a transaction *before* anything is pushed, so the
  /// foreground watcher, a second signed-in device and the scheduled Cloud
  /// Function collapse to a single send. If nothing could be delivered the
  /// claim is handed back, leaving the scheduled function a chance to deliver
  /// it within the same window — and the retry is held off until
  /// [_alarmRetryDelay] has passed, so a device with no reachable token cannot
  /// turn the claim/release pair into a write loop.
  Future<void> _sendStartAlarmOnce(
    DocumentReference<Map<String, dynamic>> ref,
    AppointmentModel appointment,
    DateTime now,
  ) async {
    if (appointment.appointmentStartNotificationSent) return;
    final retryAfter = _alarmRetryAfter[appointment.id];
    if (retryAfter != null && now.isBefore(retryAfter)) return;
    final start = appointment.startAt;
    if (start == null || start.isAfter(now)) return;
    if (appointment.hasEndedAt(now)) return;

    final claimed = await _firestore.runTransaction<bool>((tx) async {
      final snap = await tx.get(ref);
      if (!snap.exists) return false;
      if (snap.data()?['appointmentStartNotificationSent'] == true) {
        return false;
      }
      tx.update(ref, {
        'appointmentStartNotificationSent': true,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      return true;
    });
    if (!claimed) return;

    final delivered = await _pushAppointmentStart(appointment, start);
    if (delivered) {
      _alarmRetryAfter.remove(appointment.id);
      return;
    }

    _alarmRetryAfter[appointment.id] = now.add(_alarmRetryDelay);
    try {
      await ref.update({'appointmentStartNotificationSent': false});
    } catch (_) {
      // Leaving the claim set is the safe direction: a missing alarm beats
      // two of them.
    }
  }

  /// Pushes the start alarm to both sides of the appointment.
  ///
  /// Returns `true` when at least one recipient was reachable. Each side gets
  /// its own `title`/`body` baked into the payload so the foreground local
  /// notification and the OS-rendered background notification show the same
  /// words without the receiver having to rebuild the copy.
  Future<bool> _pushAppointmentStart(
    AppointmentModel appointment,
    DateTime start,
  ) async {
    final chatId = _chat.getChatId(appointment.patientId, appointment.doctorId);
    final notificationId =
        'start:${appointment.id}:'
        '${start.millisecondsSinceEpoch}';

    var delivered = false;

    final patientToken = await _fcmTokenFor(
      FirestoreCollections.patients,
      appointment.patientId,
    );
    if (patientToken.isNotEmpty) {
      delivered =
          await _fcm.sendAppointmentStartNotification(
            toUserId: appointment.patientId,
            appointmentId: appointment.id,
            patientId: appointment.patientId,
            patientName: appointment.patientName,
            patientImage: appointment.patientImage,
            doctorId: appointment.doctorId,
            doctorName: appointment.doctorName,
            doctorImage: appointment.doctorImage,
            chatId: chatId,
            forPatient: true,
            scheduledStartAt: start.millisecondsSinceEpoch,
            notificationId: notificationId,
          ) ||
          delivered;
    }

    final doctorToken = await _fcmTokenFor(
      FirestoreCollections.doctors,
      appointment.doctorId,
    );
    if (doctorToken.isNotEmpty) {
      delivered =
          await _fcm.sendAppointmentStartNotification(
            toUserId: appointment.doctorId,
            appointmentId: appointment.id,
            patientId: appointment.patientId,
            patientName: appointment.patientName,
            patientImage: appointment.patientImage,
            doctorId: appointment.doctorId,
            doctorName: appointment.doctorName,
            doctorImage: appointment.doctorImage,
            chatId: chatId,
            forPatient: false,
            scheduledStartAt: start.millisecondsSinceEpoch,
            notificationId: notificationId,
          ) ||
          delivered;
    }

    return delivered;
  }

  // ─────────────────────────────────────────────────────────────
  // REMINDERS — 24h / 1h / 10m before the start, once each
  // ─────────────────────────────────────────────────────────────

  /// Sends every reminder whose window has opened and whose claim is still
  /// free.
  ///
  /// The claim is `reminderSent.{offset}` inside a transaction — the same
  /// field the Cloud Function claims — so the foreground clock, a second
  /// device, a screen's own pass and the scheduled function collapse to one
  /// push per offset per appointment.
  Future<void> _sendRemindersOnce(
    DocumentReference<Map<String, dynamic>> ref,
    AppointmentModel appointment,
    AppointmentConfig config,
    DateTime now,
  ) async {
    final start = appointment.startAt;
    final end = appointment.endAt;
    if (start == null || end == null) return;

    for (final offset in config.reminderOffsetsMinutes) {
      if (!isReminderDue(
        status: appointment.appointmentStatus,
        startAt: start,
        endAt: end,
        alreadySent: appointment.reminderSentFor(offset),
        offsetMinutes: offset,
        now: now,
      )) {
        continue;
      }

      final claimField = 'reminderSent.$offset';
      final backoffKey = '${appointment.id}:$claimField';
      final retryAfter = _noticeRetryAfter[backoffKey];
      if (retryAfter != null && now.isBefore(retryAfter)) continue;

      if (!await _claimField(ref, claimField)) continue;

      final delivered = await _pushReminder(appointment, offset);
      if (delivered) {
        _noticeRetryAfter.remove(backoffKey);
        await appendEvent(
          appointmentId: appointment.id,
          type: AppointmentEventTypes.reminderSent,
          detail: 'offset=$offset',
        );
      } else {
        // Hand the claim back so a later pass can still deliver inside this
        // window, and hold the retry off so an unreachable device cannot
        // turn claim/release into a write on every tick.
        _noticeRetryAfter[backoffKey] = now.add(_alarmRetryDelay);
        await _releaseClaim(ref, claimField);
      }
    }
  }

  Future<bool> _pushReminder(
    AppointmentModel appointment,
    int offsetMinutes,
  ) async {
    final chatId = _chat.getChatId(appointment.patientId, appointment.doctorId);
    final notificationId = 'rem:${appointment.id}:$offsetMinutes';
    final when = reminderWhenLabel(offsetMinutes);

    var delivered = false;

    final patientToken = await _fcmTokenFor(
      FirestoreCollections.patients,
      appointment.patientId,
    );
    if (patientToken.isNotEmpty) {
      delivered =
          await _fcm.sendAppointmentLifecycleNotification(
            toUserId: appointment.patientId,
            type: FcmMessageType.appointmentReminder,
            appointmentId: appointment.id,
            patientId: appointment.patientId,
            patientName: appointment.patientName,
            doctorId: appointment.doctorId,
            doctorName: appointment.doctorName,
            chatId: chatId,
            title: AppointmentDefaults.reminderTitle,
            body: AppointmentDefaults.reminderBody(
              'Dr. ${appointment.doctorName}',
              when,
            ),
            notificationId: notificationId,
            extra: {
              AppointmentPayloadKeys.offsetMinutes: offsetMinutes.toString(),
              AppointmentPayloadKeys.scheduledStartAt:
                  (appointment.startAt?.millisecondsSinceEpoch ?? 0).toString(),
            },
          ) ||
          delivered;
    }

    final doctorToken = await _fcmTokenFor(
      FirestoreCollections.doctors,
      appointment.doctorId,
    );
    if (doctorToken.isNotEmpty) {
      delivered =
          await _fcm.sendAppointmentLifecycleNotification(
            toUserId: appointment.doctorId,
            type: FcmMessageType.appointmentReminder,
            appointmentId: appointment.id,
            patientId: appointment.patientId,
            patientName: appointment.patientName,
            doctorId: appointment.doctorId,
            doctorName: appointment.doctorName,
            chatId: chatId,
            title: AppointmentDefaults.reminderTitle,
            body: AppointmentDefaults.reminderBody(
              appointment.patientName,
              when,
            ),
            notificationId: notificationId,
            extra: {
              AppointmentPayloadKeys.offsetMinutes: offsetMinutes.toString(),
              AppointmentPayloadKeys.scheduledStartAt:
                  (appointment.startAt?.millisecondsSinceEpoch ?? 0).toString(),
            },
          ) ||
          delivered;
    }

    return delivered;
  }

  // ─────────────────────────────────────────────────────────────
  // ATTENDANCE NOTICES — doctor late / patient late / grace ending
  // ─────────────────────────────────────────────────────────────

  /// Pushes the notice that belongs to [phase], once per appointment per
  /// kind.
  ///
  /// The phase alone does not decide *whether* it is due — [phase] tells us
  /// the moment has arrived, the claim flag in the document says whether it
  /// already happened, and both are re-checked inside the claim transaction.
  Future<void> _sendAttendanceNoticeOnce(
    DocumentReference<Map<String, dynamic>> ref,
    AppointmentModel appointment,
    String phase,
    DateTime now,
  ) async {
    final String claimField;
    final String eventType;
    switch (phase) {
      case AppointmentPhase.doctorLate:
        claimField = 'doctorLateNoticeSent';
        eventType = AppointmentEventTypes.doctorLate;
      case AppointmentPhase.patientLate:
        claimField = 'patientLateNoticeSent';
        eventType = AppointmentEventTypes.patientLate;
      case AppointmentPhase.graceEnding:
        claimField = 'graceNoticeSent';
        eventType = AppointmentEventTypes.graceEnding;
      default:
        return;
    }

    final alreadySent = switch (claimField) {
      'doctorLateNoticeSent' => appointment.doctorLateNoticeSent,
      'patientLateNoticeSent' => appointment.patientLateNoticeSent,
      _ => appointment.graceNoticeSent,
    };
    if (!isAttendanceNoticeDue(phase: phase, alreadySent: alreadySent)) {
      return;
    }

    final backoffKey = '${appointment.id}:$claimField';
    final retryAfter = _noticeRetryAfter[backoffKey];
    if (retryAfter != null && now.isBefore(retryAfter)) return;

    if (!await _claimField(ref, claimField)) return;

    final delivered = await _pushAttendanceNotice(appointment, phase);
    if (delivered) {
      _noticeRetryAfter.remove(backoffKey);
      await appendEvent(
        appointmentId: appointment.id,
        type: eventType,
        detail: phase == AppointmentPhase.graceEnding
            ? 'last call before the slot closes'
            : '',
      );
    } else {
      _noticeRetryAfter[backoffKey] = now.add(_alarmRetryDelay);
      await _releaseClaim(ref, claimField);
    }
  }

  Future<bool> _pushAttendanceNotice(
    AppointmentModel appointment,
    String phase,
  ) async {
    final start = appointment.startAt;
    final raw = start == null ? 0 : DateTime.now().difference(start).inMinutes;
    final minutes = raw < 0 ? 0 : (raw > 999 ? 999 : raw);

    final (type, title, patientBody, doctorBody) = switch (phase) {
      AppointmentPhase.doctorLate => (
        FcmMessageType.appointmentDoctorLate,
        AppointmentDefaults.lateTitle,
        AppointmentDefaults.lateBody('Dr. ${appointment.doctorName}', minutes),
        AppointmentDefaults.lateSelfBody(appointment.patientName, minutes),
      ),
      AppointmentPhase.patientLate => (
        FcmMessageType.appointmentPatientLate,
        AppointmentDefaults.lateTitle,
        AppointmentDefaults.lateSelfBody(
          'Dr. ${appointment.doctorName}',
          minutes,
        ),
        AppointmentDefaults.lateBody(appointment.patientName, minutes),
      ),
      _ => (
        FcmMessageType.appointmentGraceEnding,
        AppointmentDefaults.graceEndingTitle,
        AppointmentDefaults.graceEndingBody('Dr. ${appointment.doctorName}'),
        AppointmentDefaults.graceEndingBody(appointment.patientName),
      ),
    };

    return _pushToBothSides(
      appointment: appointment,
      type: type,
      title: title,
      patientBody: patientBody,
      doctorBody: doctorBody,
      notificationId: 'att:${appointment.id}:$phase',
      extra: {
        AppointmentPayloadKeys.phase: phase,
        AppointmentPayloadKeys.minutes: minutes.toString(),
      },
    );
  }

  /// One lifecycle push addressed to both sides, each with its own rendered
  /// body but the same `notificationId` — one event, one notification per
  /// device, never two.
  Future<bool> _pushToBothSides({
    required AppointmentModel appointment,
    required String type,
    required String title,
    required String patientBody,
    required String doctorBody,
    required String notificationId,
    Map<String, String> extra = const <String, String>{},
  }) async {
    final chatId = _chat.getChatId(appointment.patientId, appointment.doctorId);
    var delivered = false;

    final patientToken = await _fcmTokenFor(
      FirestoreCollections.patients,
      appointment.patientId,
    );
    if (patientToken.isNotEmpty) {
      delivered =
          await _fcm.sendAppointmentLifecycleNotification(
            toUserId: appointment.patientId,
            type: type,
            appointmentId: appointment.id,
            patientId: appointment.patientId,
            patientName: appointment.patientName,
            doctorId: appointment.doctorId,
            doctorName: appointment.doctorName,
            chatId: chatId,
            title: title,
            body: patientBody,
            notificationId: notificationId,
            extra: extra,
          ) ||
          delivered;
    }

    final doctorToken = await _fcmTokenFor(
      FirestoreCollections.doctors,
      appointment.doctorId,
    );
    if (doctorToken.isNotEmpty) {
      delivered =
          await _fcm.sendAppointmentLifecycleNotification(
            toUserId: appointment.doctorId,
            type: type,
            appointmentId: appointment.id,
            patientId: appointment.patientId,
            patientName: appointment.patientName,
            doctorId: appointment.doctorId,
            doctorName: appointment.doctorName,
            chatId: chatId,
            title: title,
            body: doctorBody,
            notificationId: notificationId,
            extra: extra,
          ) ||
          delivered;
    }

    return delivered;
  }

  // ─────────────────────────────────────────────────────────────
  // CLAIM HELPERS
  //
  // A claim is a boolean flipped to true inside a transaction *before* the
  // push goes out, and handed back only when nothing could be delivered.
  // Field paths may be dotted (`reminderSent.60`), which is why the read
  // walks the path instead of indexing the top-level map.
  // ─────────────────────────────────────────────────────────────

  Future<bool> _claimField(
    DocumentReference<Map<String, dynamic>> ref,
    String fieldPath,
  ) async {
    try {
      return await _firestore.runTransaction<bool>((tx) async {
        final snap = await tx.get(ref);
        if (!snap.exists) return false;
        if (_readFieldPath(snap.data(), fieldPath) == true) return false;
        tx.update(ref, {
          fieldPath: true,
          'updatedAt': FieldValue.serverTimestamp(),
        });
        return true;
      });
    } catch (_) {
      return false;
    }
  }

  Future<void> _releaseClaim(
    DocumentReference<Map<String, dynamic>> ref,
    String fieldPath,
  ) async {
    try {
      await ref.update({
        fieldPath: false,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {
      // Leaving the claim set is the safe direction: a missing push beats a
      // duplicate one.
    }
  }

  /// Reads a possibly dotted field path out of a Firestore map.
  static dynamic _readFieldPath(Map<String, dynamic>? data, String fieldPath) {
    dynamic current = data;
    for (final part in fieldPath.split('.')) {
      if (current is! Map) return null;
      current = current[part];
    }
    return current;
  }

  Future<String> _fcmTokenFor(String collection, String id) async {
    if (id.isEmpty) return '';
    try {
      final doc = await _firestore.collection(collection).doc(id).get();
      return (doc.data()?['fcmToken'] ?? '').toString();
    } catch (_) {
      return '';
    }
  }

  Future<AppointmentModel?> _loadAppointment(
    DocumentReference<Map<String, dynamic>> ref,
  ) async {
    try {
      final snap = await ref.get();
      if (!snap.exists) return null;
      return AppointmentModel.fromMap(snap.id, snap.data()!);
    } catch (_) {
      return null;
    }
  }

  // ─────────────────────────────────────────────────────────────
  // JOIN TRACKING
  // ─────────────────────────────────────────────────────────────

  /// Records that this side has joined the consultation.
  ///
  /// First tap wins: the timestamp is written only while it is still empty, so
  /// a flaky connection or a second device can never move an arrival
  /// backwards. Joining also promotes `confirmed` → `active`, because the
  /// consultation is demonstrably under way whatever the wall clock says.
  ///
  /// Returns `null` on success — including "you had already joined", which is
  /// success too — and a user-facing message otherwise.
  Future<String?> markAppointmentJoined({
    required AppointmentModel appointment,
    required String actorId,
    required bool asDoctor,
  }) async {
    final expectedId = asDoctor ? appointment.doctorId : appointment.patientId;
    if (actorId.isEmpty || actorId != expectedId) {
      return 'This appointment does not belong to you.';
    }
    if (appointment.appointmentStatus != AppointmentStatus.confirmed &&
        appointment.appointmentStatus != AppointmentStatus.active) {
      return 'This appointment is not running right now.';
    }
    final end = appointment.endAt;
    if (end != null && DateTime.now().isAfter(end)) {
      return 'This appointment has already ended.';
    }

    final field = asDoctor ? 'doctorJoinedAt' : 'patientJoinedAt';
    final ref = _appointments.doc(appointment.id);

    final bool joinedNow = await _firestore.runTransaction<bool>((tx) async {
      final snap = await tx.get(ref);
      if (!snap.exists) return false;
      final data = snap.data() ?? <String, dynamic>{};
      final status = (data['appointmentStatus'] ?? '').toString();
      if (status != AppointmentStatus.confirmed &&
          status != AppointmentStatus.active) {
        return false;
      }
      if (data[field] != null) return false;
      tx.update(ref, {
        field: FieldValue.serverTimestamp(),
        if (status == AppointmentStatus.confirmed)
          'appointmentStatus': AppointmentStatus.active,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      return true;
    });

    if (!joinedNow) {
      final refreshed = await _loadAppointment(ref) ?? appointment;
      final alreadyIn = asDoctor
          ? refreshed.hasDoctorJoined
          : refreshed.hasPatientJoined;
      // Already in = nothing left to do (success); anything else means the
      // appointment is no longer joinable.
      return alreadyIn ? null : 'This appointment is not running right now.';
    }

    await appendEvent(
      appointmentId: appointment.id,
      type: asDoctor
          ? AppointmentEventTypes.doctorJoined
          : AppointmentEventTypes.patientJoined,
      actorId: actorId,
      actorRole: asDoctor
          ? AppointmentActors.doctor
          : AppointmentActors.patient,
    );
    await _notifyCounterpartOfJoin(appointment, joinedAsDoctor: asDoctor);
    return null;
  }

  /// "Dr. X has joined" / "Sara has joined" → the other side only; the
  /// joiner already knows they joined.
  Future<void> _notifyCounterpartOfJoin(
    AppointmentModel appointment, {
    required bool joinedAsDoctor,
  }) async {
    try {
      final joinerName = joinedAsDoctor
          ? 'Dr. ${appointment.doctorName}'
          : appointment.patientName;
      final counterpartCollection = joinedAsDoctor
          ? FirestoreCollections.patients
          : FirestoreCollections.doctors;
      final counterpartId = joinedAsDoctor
          ? appointment.patientId
          : appointment.doctorId;
      final token = await _fcmTokenFor(counterpartCollection, counterpartId);
      if (token.isEmpty) return;

      await _fcm.sendAppointmentLifecycleNotification(
        toUserId: counterpartId,
        type: FcmMessageType.appointmentJoined,
        appointmentId: appointment.id,
        patientId: appointment.patientId,
        patientName: appointment.patientName,
        doctorId: appointment.doctorId,
        doctorName: appointment.doctorName,
        chatId: _chat.getChatId(appointment.patientId, appointment.doctorId),
        title: AppointmentDefaults.joinedTitle,
        body: AppointmentDefaults.joinedBody(joinerName),
        notificationId:
            'join:${appointment.id}:'
            '${joinedAsDoctor ? 'doctor' : 'patient'}',
        extra: {
          AppointmentPayloadKeys.actorRole: joinedAsDoctor
              ? AppointmentActors.doctor
              : AppointmentActors.patient,
          AppointmentPayloadKeys.actorName: joinerName,
        },
      );
    } catch (_) {
      // The phase on the other side's screen updates regardless.
    }
  }

  // ─────────────────────────────────────────────────────────────
  // COMPLETION
  // ─────────────────────────────────────────────────────────────

  /// Closes the appointment as completed while it is still running — the
  /// doctor's "consultation is done" action. The end-of-slot pass would
  /// otherwise have to guess from attendance alone.
  Future<String?> completeAppointment({
    required AppointmentModel appointment,
    required String actorId,
    required String actorRole,
  }) async {
    if (actorRole == AppointmentActors.doctor &&
        appointment.doctorId != actorId) {
      return 'Only the selected doctor can complete this appointment.';
    }
    if (!appointment.isConfirmed) {
      return 'This appointment is not running right now.';
    }

    final ref = _appointments.doc(appointment.id);
    var changed = false;
    try {
      await _firestore.runTransaction<void>((tx) async {
        final snap = await tx.get(ref);
        if (!snap.exists) throw StateError('Appointment no longer exists');
        final status = (snap.data()?['appointmentStatus'] ?? '').toString();
        if (status == AppointmentStatus.completed) return;
        if (!AppointmentStatus.isOpen(status)) {
          throw StateError('This appointment is already finished');
        }
        changed = true;
        tx.update(ref, {
          'appointmentStatus': AppointmentStatus.completed,
          'appointmentPhase': AppointmentPhase.closed,
          'completedAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
      });
    } catch (e) {
      if (e is StateError) return 'This appointment is already finished.';
      return 'Could not complete the appointment: $e';
    }
    if (!changed) return null;

    await appendEvent(
      appointmentId: appointment.id,
      type: AppointmentEventTypes.completed,
      actorId: actorId,
      actorRole: actorRole,
    );
    await unpinMessage(
      patientId: appointment.patientId,
      doctorId: appointment.doctorId,
      messageId: appointment.pinnedMessageId,
    );
    await _pushToBothSides(
      appointment: appointment,
      type: FcmMessageType.appointmentConfirmed,
      title: 'Appointment Completed',
      patientBody:
          'Your appointment with Dr. ${appointment.doctorName} is complete.',
      doctorBody:
          'Your appointment with ${appointment.patientName} is '
          'complete.',
      notificationId: 'done:${appointment.id}',
    );
    return null;
  }

  // ─────────────────────────────────────────────────────────────
  // CANCELLATION + WARNING / FREEZE POLICY
  // ─────────────────────────────────────────────────────────────

  /// Cancels an appointment and applies the warning/freeze policy to a
  /// patient or doctor actor (an admin cancelling never counts against
  /// anyone).
  ///
  /// The status write and the policy are deliberately *not* one transaction:
  /// the cancellation must land even if the counter write fails, and the
  /// counter must never be able to resurrect a cancellation that was
  /// refused. The live status is re-read inside the transaction, so a stale
  /// screen cannot cancel a record that has already finished.
  Future<String?> cancelAppointment({
    required AppointmentModel appointment,
    required String actorId,
    required String actorRole,
    String reason = '',
  }) async {
    final config = await this.config();
    final warningCount = actorRole == AppointmentActors.admin
        ? 0
        : await _warningCountFor(actorId, actorRole);

    final assessment = evaluateCancellation(
      status: appointment.appointmentStatus,
      actorRole: actorRole,
      warningCount: warningCount,
      warningLimit: config.cancellationWarningLimit,
    );
    if (!assessment.allowed) return assessment.blockReason;

    final ref = _appointments.doc(appointment.id);
    var changed = false;
    try {
      await _firestore.runTransaction<void>((tx) async {
        final snap = await tx.get(ref);
        if (!snap.exists) throw StateError('Appointment no longer exists');
        final status = (snap.data()?['appointmentStatus'] ?? '').toString();
        final live = evaluateCancellation(
          status: status,
          actorRole: actorRole,
          warningCount: warningCount,
          warningLimit: config.cancellationWarningLimit,
        );
        if (!live.allowed) throw StateError(live.blockReason);
        changed = true;
        tx.update(ref, {
          'appointmentStatus': AppointmentStatus.cancelled,
          'appointmentPhase': AppointmentPhase.closed,
          'cancelledBy': actorRole,
          if (reason.trim().isNotEmpty) 'cancelReason': reason.trim(),
          'cancelledAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
      });
    } catch (e) {
      if (e is StateError) return e.message;
      return 'Could not cancel the appointment: $e';
    }
    if (!changed) return null;

    await appendEvent(
      appointmentId: appointment.id,
      type: AppointmentEventTypes.cancelled,
      actorId: actorId,
      actorRole: actorRole,
      detail: reason.trim(),
    );
    await unpinMessage(
      patientId: appointment.patientId,
      doctorId: appointment.doctorId,
      messageId: appointment.pinnedMessageId,
    );
    await _notifyOfCancellation(appointment, actorRole: actorRole);

    if (actorRole != AppointmentActors.admin) {
      await _recordCancellationWarning(
        userId: actorId,
        actorRole: actorRole,
        appointment: appointment,
        config: config,
      );
    }
    return null;
  }

  /// Admin override: cancels on someone's behalf without touching any
  /// warning counter.
  Future<String?> adminCancelAppointment({
    required AppointmentModel appointment,
    required String adminId,
    String reason = '',
  }) => cancelAppointment(
    appointment: appointment,
    actorId: adminId,
    actorRole: AppointmentActors.admin,
    reason: reason,
  );

  /// Marks a finished-but-unresolved slot as a no-show, naming the absent
  /// side. Used by the admin override and available to the doctor for the
  /// "patient never arrived" case.
  Future<String?> markNoShow({
    required AppointmentModel appointment,
    required String actorId,
    required String actorRole,
    required String noShowBy,
    String reason = '',
  }) async {
    if (!AppointmentStatus.isOpen(appointment.appointmentStatus)) {
      return 'This appointment is already finished.';
    }
    if (!AppointmentNoShowBy.all.contains(noShowBy)) {
      return 'Which side failed to show must be stated.';
    }

    final ref = _appointments.doc(appointment.id);
    var changed = false;
    try {
      await _firestore.runTransaction<void>((tx) async {
        final snap = await tx.get(ref);
        if (!snap.exists) throw StateError('Appointment no longer exists');
        final status = (snap.data()?['appointmentStatus'] ?? '').toString();
        if (status == AppointmentStatus.noShow) return;
        if (!AppointmentStatus.isOpen(status)) {
          throw StateError('This appointment is already finished');
        }
        changed = true;
        tx.update(ref, {
          'appointmentStatus': AppointmentStatus.noShow,
          'appointmentPhase': AppointmentPhase.closed,
          'noShowBy': noShowBy,
          'noShowAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
      });
    } catch (e) {
      if (e is StateError) return 'This appointment is already finished.';
      return 'Could not mark the no-show: $e';
    }
    if (!changed) return null;

    await appendEvent(
      appointmentId: appointment.id,
      type: AppointmentEventTypes.noShow,
      actorId: actorId,
      actorRole: actorRole,
      detail: reason.trim().isEmpty ? '$noShowBy did not join' : reason.trim(),
    );
    await unpinMessage(
      patientId: appointment.patientId,
      doctorId: appointment.doctorId,
      messageId: appointment.pinnedMessageId,
    );
    await _notifyNoShow(appointment, noShowBy);
    return null;
  }

  /// Increments the actor's cancellation counter and freezes their bookings
  /// when the limit is reached.
  ///
  /// Runs *after* the cancellation itself: a failed counter write must never
  /// undo a cancellation that already happened, it only loses one warning.
  Future<void> _recordCancellationWarning({
    required String userId,
    required String actorRole,
    required AppointmentModel appointment,
    required AppointmentConfig config,
  }) async {
    if (userId.isEmpty) return;
    final collection = actorRole == AppointmentActors.doctor
        ? _doctors
        : _patients;
    final ref = collection.doc(userId);

    var count = 0;
    DateTime? frozenUntil;
    try {
      final result = await _firestore
          .runTransaction<({int count, DateTime? frozenUntil})>((tx) async {
            final snap = await tx.get(ref);
            final data = snap.data() ?? <String, dynamic>{};
            final current =
                (data['cancellationWarningCount'] as num?)?.round() ?? 0;
            final next = current + 1;
            final until = freezeUntilFor(
              freezeAfter: next >= config.cancellationWarningLimit,
              freezeDurationDays: config.freezeDurationDays,
              now: DateTime.now(),
            );
            tx.set(ref, {
              'cancellationWarningCount': next,
              'lastCancellationWarningAt': FieldValue.serverTimestamp(),
              if (until != null)
                'bookingFrozenUntil': Timestamp.fromDate(until),
              if (until != null)
                'bookingFrozenReason': 'Repeated appointment cancellations',
              if (until != null) 'bookingFrozenBy': userId,
              'updatedAt': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));
            return (count: next, frozenUntil: until);
          });
      count = result.count;
      frozenUntil = result.frozenUntil;
    } catch (_) {
      return;
    }

    await appendEvent(
      appointmentId: appointment.id,
      type: AppointmentEventTypes.warningIssued,
      actorId: userId,
      actorRole: actorRole,
      detail: 'warning $count of ${config.cancellationWarningLimit}',
    );

    if (frozenUntil == null) return;

    await appendEvent(
      appointmentId: appointment.id,
      type: AppointmentEventTypes.freezeApplied,
      actorId: userId,
      actorRole: actorRole,
      detail: AppointmentDefaults.bookingFrozenMessage(frozenUntil),
    );
    await _notifyUserOfFreeze(
      userId: userId,
      actorRole: actorRole,
      actorName: actorRole == AppointmentActors.doctor
          ? appointment.doctorName
          : appointment.patientName,
      count: count,
      limit: config.cancellationWarningLimit,
      frozenUntil: frozenUntil,
    );
  }

  Future<int> _warningCountFor(String userId, String actorRole) async {
    if (userId.isEmpty) return 0;
    final collection = actorRole == AppointmentActors.doctor
        ? _doctors
        : _patients;
    try {
      final snap = await collection.doc(userId).get();
      return (snap.data()?['cancellationWarningCount'] as num?)?.round() ?? 0;
    } catch (_) {
      return 0;
    }
  }

  // ─────────────────────────────────────────────────────────────
  // ADMIN — freeze / unfreeze / warnings / no-show overrides
  // ─────────────────────────────────────────────────────────────

  /// Applies a booking freeze immediately (independent of the warning
  /// counter) and records it in the shared account audit log.
  Future<String?> adminApplyFreeze({
    required String userId,
    required bool isDoctor,
    required String adminId,
    int? days,
    String reason = '',
  }) async {
    if (userId.isEmpty) return 'No user selected.';
    final config = await this.config();
    final until = DateTime.now().add(
      Duration(days: (days ?? config.freezeDurationDays).clamp(1, 365)),
    );
    final collection = isDoctor ? _doctors : _patients;
    try {
      await collection.doc(userId).set({
        'bookingFrozenUntil': Timestamp.fromDate(until),
        'bookingFrozenReason': reason.trim().isEmpty
            ? 'Paused by an admin'
            : reason.trim(),
        'bookingFrozenBy': adminId,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      await _appendAccountAudit(
        action: isDoctor
            ? AuditActions.doctorBookingFrozen
            : AuditActions.patientBookingFrozen,
        userId: userId,
        adminId: adminId,
        detail: reason.trim(),
      );
      await _notifyAdminsOfAccountAction(
        action: 'Booking paused',
        detail: reason.trim(),
      );
      return null;
    } catch (e) {
      return 'Could not pause bookings: $e';
    }
  }

  /// Lifts a freeze. Idempotent — clearing an already-clear freeze changes
  /// nothing.
  Future<String?> adminClearFreeze({
    required String userId,
    required bool isDoctor,
    required String adminId,
  }) async {
    if (userId.isEmpty) return 'No user selected.';
    final collection = isDoctor ? _doctors : _patients;
    try {
      await collection.doc(userId).set({
        'bookingFrozenUntil': FieldValue.delete(),
        'bookingFrozenReason': FieldValue.delete(),
        'bookingFrozenBy': FieldValue.delete(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      await _appendAccountAudit(
        action: isDoctor
            ? AuditActions.doctorBookingUnfrozen
            : AuditActions.patientBookingUnfrozen,
        userId: userId,
        adminId: adminId,
        detail: '',
      );
      return null;
    } catch (e) {
      return 'Could not lift the pause: $e';
    }
  }

  /// Wipes the cancellation warning counter, e.g. after a goodwill exception.
  Future<String?> adminResetWarnings({
    required String userId,
    required bool isDoctor,
    required String adminId,
  }) async {
    if (userId.isEmpty) return 'No user selected.';
    final collection = isDoctor ? _doctors : _patients;
    try {
      await collection.doc(userId).set({
        'cancellationWarningCount': 0,
        'lastCancellationWarningAt': FieldValue.delete(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      await _appendAccountAudit(
        action: isDoctor
            ? AuditActions.doctorWarningsReset
            : AuditActions.patientWarningsReset,
        userId: userId,
        adminId: adminId,
        detail: '',
      );
      return null;
    } catch (e) {
      return 'Could not reset the warnings: $e';
    }
  }

  /// Reads the live freeze + warning state of one user, for the admin
  /// detail panels and the booking guards.
  Future<({bool frozen, DateTime? until, int warnings})> userPolicyState({
    required String collection,
    required String userId,
  }) async {
    if (userId.isEmpty) return (frozen: false, until: null, warnings: 0);
    try {
      final snap = await _firestore.collection(collection).doc(userId).get();
      final data = snap.data();
      if (data == null) return (frozen: false, until: null, warnings: 0);
      final until = parseFirestoreTimestamp(data['bookingFrozenUntil']);
      return (
        frozen: until != null && until.isAfter(DateTime.now()),
        until: until,
        warnings: (data['cancellationWarningCount'] as num?)?.round() ?? 0,
      );
    } catch (_) {
      return (frozen: false, until: null, warnings: 0);
    }
  }

  Future<void> _notifyAdminsOfAccountAction({
    required String action,
    required String detail,
  }) async {
    try {
      for (final adminId in await _adminIds()) {
        await _fcm.sendAppointmentLifecycleNotification(
          toUserId: adminId,
          type: FcmMessageType.bookingFrozen,
          appointmentId: '',
          patientId: '',
          patientName: '',
          doctorId: '',
          doctorName: '',
          chatId: '',
          title: action,
          body: detail.isEmpty ? action : detail,
          notificationId: const Uuid().v4(),
        );
      }
    } catch (_) {
      // The audit entry already records the action.
    }
  }

  Future<void> _appendAccountAudit({
    required String action,
    required String userId,
    required String adminId,
    required String detail,
  }) async {
    try {
      await _firestore.collection(FirestoreCollections.accountAuditLog).add({
        'action': action,
        'userId': userId,
        'deletedBy': adminId,
        'reason': detail,
        'at': FieldValue.serverTimestamp(),
        'createdAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {
      // The audit entry is secondary to the write it describes.
    }
  }

  // ─────────────────────────────────────────────────────────────
  // PROOF UPLOAD — uses Firebase Storage
  // ─────────────────────────────────────────────────────────────

  Future<String?> uploadProof(File file, {String? appointmentId}) async {
    try {
      final apptId =
          appointmentId ?? 'appt_${DateTime.now().millisecondsSinceEpoch}';
      final result = await FirebaseStorageService.instance
          .uploadAppointmentPaymentProof(appointmentId: apptId, file: file);
      return result.downloadUrl;
    } catch (e) {
      debugPrint('[AppointmentController] uploadProof error: $e');
      return null;
    }
  }

  // ─────────────────────────────────────────────────────────────
  // FCM
  //
  // Every send carries a fresh `notificationId`; the receiver drops repeat
  // deliveries keyed on it, and each write above only reaches this section
  // after a status transition that actually happened.
  // ─────────────────────────────────────────────────────────────

  Future<void> _notifyAdminsOfAppointmentPayment({
    required UserModel patient,
    required String doctorName,
    required double payableAmount,
    required String paymentId,
    required String notificationId,
  }) async {
    // Persistent admin notification
    final adminNotifId = 'notif_$notificationId';
    try {
      await _firestore.collection('admin_notifications').doc(adminNotifId).set({
        'notificationId': adminNotifId,
        'type': 'payment_proof_submitted',
        'paymentType': 'appointment_booking',
        'title': 'New Appointment Payment',
        'body':
            '${patient.fullname} submitted payment proof for an appointment with Dr. $doctorName.',
        'patientUid': patient.id,
        'patientId': patient.patientId,
        'patientName': patient.fullname,
        'paymentId': paymentId,
        'doctorName': doctorName,
        'amount': payableAmount.toStringAsFixed(0),
        'isRead': false,
        'createdAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('Error saving admin persistent notification: $e');
    }

    try {
      final admins = await _firestore
          .collection(FirestoreCollections.patients)
          .where('role', isEqualTo: UserRoles.admin)
          .where('fcmToken', isGreaterThan: '')
          .get();

      for (final doc in admins.docs) {
        final token = (doc.data()['fcmToken'] ?? '').toString();
        if (token.isEmpty) continue;
        await _fcm.sendAppointmentPaymentSubmittedNotification(
          toUserId: doc.id,
          patientName: patient.fullname,
          patientId: patient.id,
          doctorName: doctorName,
          amount: payableAmount.toStringAsFixed(0),
          paymentId: paymentId,
          notificationId: notificationId,
        );
      }
    } catch (_) {
      // The existing notification path remains as the reliability fallback.
    }
  }

  Future<void> _notifyPatientOfAppointmentPaymentDecision({
    required String patientId,
    required String doctorName,
    required String paymentId,
    required bool approved,
  }) async {
    try {
      final doc = await _firestore
          .collection(FirestoreCollections.patients)
          .doc(patientId)
          .get();
      final token = (doc.data()?['fcmToken'] ?? '').toString();
      if (token.isEmpty) return;

      if (approved) {
        await _fcm.sendAppointmentPaymentApprovedNotification(
          toUserId: patientId,
          patientId: patientId,
          doctorName: doctorName,
          paymentId: paymentId,
          notificationId: const Uuid().v4(),
        );
      } else {
        await _fcm.sendAppointmentPaymentRejectedNotification(
          toUserId: patientId,
          patientId: patientId,
          doctorName: doctorName,
          paymentId: paymentId,
          notificationId: const Uuid().v4(),
        );
      }
    } catch (_) {
      // Firestore remains the source of truth.
    }
  }

  Future<void> _notifyDoctorOfAppointmentRequest(
    AppointmentModel appointment,
  ) async {
    try {
      final doc = await _firestore
          .collection(FirestoreCollections.doctors)
          .doc(appointment.doctorId)
          .get();
      final token = (doc.data()?['fcmToken'] ?? '').toString();
      if (token.isEmpty) return;
      await _fcm.sendNewAppointmentRequestNotification(
        toUserId: appointment.doctorId,
        doctorId: appointment.doctorId,
        patientName: appointment.patientName,
        patientId: appointment.patientId,
        appointmentId: appointment.id,
        notificationId: const Uuid().v4(),
      );
    } catch (_) {
      // Ignored.
    }
  }

  Future<void> _notifyPatientOfConfirmation({
    required AppointmentModel appointment,
    required String scheduledDate,
    required String scheduledStartTime,
    required String scheduledEndTime,
  }) async {
    try {
      final doc = await _firestore
          .collection(FirestoreCollections.patients)
          .doc(appointment.patientId)
          .get();
      final token = (doc.data()?['fcmToken'] ?? '').toString();
      if (token.isEmpty) return;
      await _fcm.sendAppointmentConfirmedNotification(
        toUserId: appointment.patientId,
        patientId: appointment.patientId,
        doctorName: appointment.doctorName,
        date: appointmentFormatDisplayDate(scheduledDate),
        time: '$scheduledStartTime - $scheduledEndTime',
        appointmentId: appointment.id,
        notificationId: const Uuid().v4(),
      );
    } catch (_) {
      // Ignored.
    }
  }

  // ─────────────────────────────────────────────────────────────
  // LIFECYCLE NOTIFICATIONS — cancellation, no-show, freeze
  //
  // Same contract as above: a deterministic `notificationId` per event (so a
  // second writer cannot produce a second push) and a title/body baked into
  // the payload so every display path shows the same words.
  // ─────────────────────────────────────────────────────────────

  /// Tokens of every admin that has one. Shared recipient list for the
  /// moderation-style pushes.
  Future<List<String>> _adminTokens() async {
    try {
      final snap = await _patients
          .where('role', isEqualTo: UserRoles.admin)
          .where('fcmToken', isGreaterThan: '')
          .get();
      return snap.docs
          .map((d) => (d.data()['fcmToken'] ?? '').toString())
          .where((token) => token.isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      return const <String>[];
    }
  }

  /// Admin *user ids* that currently have a deliverable token.
  ///
  /// Notifications are addressed by user id and the Cloud Function resolves
  /// the token itself, so the id — not the token — is what travels out of the
  /// app. The `fcmToken` predicate still filters, because it means "this admin
  /// can actually be reached".
  Future<List<String>> _adminIds() async {
    try {
      final snap = await _patients
          .where('role', isEqualTo: UserRoles.admin)
          .where('fcmToken', isGreaterThan: '')
          .get();
      return snap.docs.map((d) => d.id).toList(growable: false);
    } catch (_) {
      return const <String>[];
    }
  }

  String _actorLabel(String actorRole, AppointmentModel appointment) {
    switch (actorRole) {
      case AppointmentActors.doctor:
        return 'Dr. ${appointment.doctorName}';
      case AppointmentActors.admin:
        return 'an admin';
      default:
        return appointment.patientName.isEmpty
            ? 'the patient'
            : appointment.patientName;
    }
  }

  /// The counterpart plus every admin, so a cancellation is visible on both
  /// sides of the record and in the admin queue at once.
  Future<void> _notifyOfCancellation(
    AppointmentModel appointment, {
    required String actorRole,
  }) async {
    final actorName = _actorLabel(actorRole, appointment);
    await _pushToBothSides(
      appointment: appointment,
      type: FcmMessageType.appointmentCancelled,
      title: AppointmentDefaults.cancelledTitle,
      patientBody: AppointmentDefaults.cancelledBody(actorName),
      doctorBody: AppointmentDefaults.cancelledBody(actorName),
      notificationId: 'cancel:${appointment.id}',
      extra: {AppointmentPayloadKeys.actorRole: actorRole},
    );
    await _notifyAdmins(
      type: FcmMessageType.appointmentCancelled,
      appointment: appointment,
      title: AppointmentDefaults.cancelledTitle,
      body: AppointmentDefaults.cancelledBody(actorName),
      notificationId: 'cancel:${appointment.id}:admin',
    );
  }

  /// Both sides plus the admins: an absence is exactly the fact an admin
  /// needs in order to act on it.
  Future<void> _notifyNoShow(
    AppointmentModel appointment,
    String noShowBy,
  ) async {
    final absentName = noShowBy == AppointmentNoShowBy.doctor
        ? 'Dr. ${appointment.doctorName}'
        : appointment.patientName;
    await _pushToBothSides(
      appointment: appointment,
      type: FcmMessageType.appointmentNoShow,
      title: AppointmentDefaults.noShowTitle,
      patientBody: AppointmentDefaults.noShowBody(absentName),
      doctorBody: AppointmentDefaults.noShowBody(absentName),
      notificationId: 'noshow:${appointment.id}',
      extra: {AppointmentPayloadKeys.noShowBy: noShowBy},
    );
    await _notifyAdmins(
      type: FcmMessageType.appointmentNoShow,
      appointment: appointment,
      title: AppointmentDefaults.noShowTitle,
      body: AppointmentDefaults.noShowBody(absentName),
      notificationId: 'noshow:${appointment.id}:admin',
    );
  }

  Future<void> _notifyAdmins({
    required String type,
    required AppointmentModel appointment,
    required String title,
    required String body,
    required String notificationId,
    Map<String, String> extra = const <String, String>{},
  }) async {
    try {
      for (final adminId in await _adminIds()) {
        await _fcm.sendAppointmentLifecycleNotification(
          toUserId: adminId,
          type: type,
          appointmentId: appointment.id,
          patientId: appointment.patientId,
          patientName: appointment.patientName,
          doctorId: appointment.doctorId,
          doctorName: appointment.doctorName,
          chatId: _chat.getChatId(appointment.patientId, appointment.doctorId),
          title: title,
          body: body,
          notificationId: notificationId,
          extra: extra,
        );
      }
    } catch (_) {
      // Firestore remains the source of truth for the admin queue.
    }
  }

  /// Tells the freshly frozen user, and the other admins, how many warnings
  /// produced the pause and when it lifts.
  Future<void> _notifyUserOfFreeze({
    required String userId,
    required String actorRole,
    required String actorName,
    required int count,
    required int limit,
    required DateTime frozenUntil,
  }) async {
    try {
      final collection = actorRole == AppointmentActors.doctor
          ? FirestoreCollections.doctors
          : FirestoreCollections.patients;
      final token = await _fcmTokenFor(collection, userId);
      if (token.isNotEmpty) {
        await _fcm.sendAppointmentLifecycleNotification(
          toUserId: userId,
          type: FcmMessageType.bookingFrozen,
          appointmentId: '',
          patientId: actorRole == AppointmentActors.doctor ? '' : userId,
          patientName: actorRole == AppointmentActors.doctor ? '' : actorName,
          doctorId: actorRole == AppointmentActors.doctor ? userId : '',
          doctorName: actorRole == AppointmentActors.doctor ? actorName : '',
          chatId: '',
          title: AppointmentDefaults.frozenTitle,
          body: AppointmentDefaults.frozenBody(count, limit),
          notificationId: 'freeze:$userId:$count',
          extra: {
            AppointmentPayloadKeys.warningCount: count.toString(),
            AppointmentPayloadKeys.warningLimit: limit.toString(),
            AppointmentPayloadKeys.frozenUntil: frozenUntil
                .millisecondsSinceEpoch
                .toString(),
          },
        );
      }

      for (final adminId in await _adminIds()) {
        await _fcm.sendAppointmentLifecycleNotification(
          toUserId: adminId,
          type: FcmMessageType.bookingFrozen,
          appointmentId: '',
          patientId: actorRole == AppointmentActors.doctor ? '' : userId,
          patientName: actorRole == AppointmentActors.doctor ? '' : actorName,
          doctorId: actorRole == AppointmentActors.doctor ? userId : '',
          doctorName: actorRole == AppointmentActors.doctor ? actorName : '',
          chatId: '',
          title: AppointmentDefaults.frozenTitle,
          body: '$actorName — bookings paused after $count cancellations.',
          notificationId: 'freeze:$userId:$count:admin',
          extra: {
            AppointmentPayloadKeys.warningCount: count.toString(),
            AppointmentPayloadKeys.warningLimit: limit.toString(),
            AppointmentPayloadKeys.frozenUntil: frozenUntil
                .millisecondsSinceEpoch
                .toString(),
          },
        );
      }
    } catch (_) {
      // Ignored: the freeze itself is already written.
    }
  }
}

double? _asDouble(dynamic value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.trim());
  return null;
}

// ─────────────────────────────────────────────────────────────
// SCHEDULE HELPERS — shared by the doctor picker and both UIs
// ─────────────────────────────────────────────────────────────

/// `2026-10-05` → `5 October 2026`. Falls back to the raw input so a
/// malformed record still renders something sensible.
String appointmentFormatDisplayDate(String isoDate) {
  final parsed = DateTime.tryParse(isoDate);
  if (parsed == null) return isoDate;
  const months = <String>[
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  return '${parsed.day} ${months[parsed.month - 1]} ${parsed.year}';
}

/// Midnight (local) of the scheduled calendar day, or `null`.
DateTime? appointmentDateOnly(String isoDate) {
  final parsed = DateTime.tryParse(isoDate);
  if (parsed == null) return null;
  return DateTime(parsed.year, parsed.month, parsed.day);
}

/// Combines `2026-10-05` with `4:30 PM` into an absolute instant.
DateTime? appointmentEndInstant(String isoDate, String timeLabel) {
  final day = appointmentDateOnly(isoDate);
  if (day == null) return null;
  final minutes = _parseTimeToMinutes(timeLabel);
  if (minutes == null) return day;
  return day.add(Duration(minutes: minutes));
}

/// Same combination for the start of the slot. Returns `null` when the label
/// is missing or unreadable so the alarm never fires at a made-up moment.
DateTime? appointmentStartInstant(String isoDate, String timeLabel) {
  final day = appointmentDateOnly(isoDate);
  if (day == null) return null;
  final minutes = _parseTimeToMinutes(timeLabel);
  if (minutes == null) return null;
  return day.add(Duration(minutes: minutes));
}

int? _parseTimeToMinutes(String label) {
  final value = label.trim().toUpperCase();
  if (value.isEmpty) return null;
  final match = RegExp(r'^(\d{1,2}):(\d{2})\s*(AM|PM)?$').firstMatch(value);
  if (match == null) return null;
  var hour = int.tryParse(match.group(1) ?? '');
  final minute = int.tryParse(match.group(2) ?? '');
  final meridiem = match.group(3);
  if (hour == null || minute == null) return null;
  if (meridiem == 'PM' && hour < 12) hour += 12;
  if (meridiem == 'AM' && hour == 12) hour = 0;
  if (hour > 23 || minute > 59) return null;
  return hour * 60 + minute;
}

// ─────────────────────────────────────────────────────────────
// PROVIDERS
// ─────────────────────────────────────────────────────────────

final appointmentControllerProvider = Provider<AppointmentController>((ref) {
  return AppointmentController();
});

/// Persisted `videoWatched` flag for the signed-in patient + doctor.
final appointmentVideoWatchedProvider = StreamProvider.autoDispose
    .family<bool, String>((ref, doctorId) {
      final user = ref.watch(userProvider);
      if (user == null) return Stream<bool>.value(false);
      return ref
          .read(appointmentControllerProvider)
          .watchVideoWatched(patientId: user.id, doctorId: doctorId);
    });

/// The patient's payment record for this doctor, or `null` when none exists.
final appointmentPaymentProvider = StreamProvider.autoDispose
    .family<AppointmentPaymentModel?, String>((ref, doctorId) {
      final user = ref.watch(userProvider);
      if (user == null) return Stream<AppointmentPaymentModel?>.value(null);
      return ref
          .read(appointmentControllerProvider)
          .watchPayment(patientId: user.id, doctorId: doctorId);
    });

/// Every appointment the signed-in user participates in; which side of the
/// record is used follows the session role, so the doctor portal and the
/// patient tab share one provider.
final myAppointmentsProvider =
    StreamProvider.autoDispose<List<AppointmentModel>>((ref) {
      final user = ref.watch(userProvider);
      if (user == null) return Stream<List<AppointmentModel>>.value(const []);
      final controller = ref.read(appointmentControllerProvider);
      return user.role == UserRoles.doctor
          ? controller.watchDoctorAppointments(user.id)
          : controller.watchPatientAppointments(user.id);
    });

/// Live appointment payments for the admin review screen.
final appointmentPaymentsProvider =
    StreamProvider.autoDispose<List<AppointmentPaymentModel>>((ref) {
      return ref.read(appointmentControllerProvider).watchAllPayments();
    });

/// Every active doctor, as raw maps — the booking flow is the only place that
/// reads `price`, `consultationFee`, `description` and `youtubeVideoUrl`.
///
/// No `where` filter is applied so an older doctor document that predates the
/// `role` field still shows up; `isActive == false` is the only exclusion.
final doctorsForBookingProvider =
    StreamProvider.autoDispose<List<Map<String, dynamic>>>((ref) async* {
      // Errors are intentionally NOT swallowed: `appointment_screen.dart` has a
      // real "Could not load doctors" branch. Catching and yielding `[]` made
      // every failure (offline, permission) render as the empty state
      // "No doctors found", which is indistinguishable from a genuinely empty
      // clinic.
      await for (final snap
          in FirebaseFirestore.instance
              .collection(FirestoreCollections.doctors)
              .snapshots()) {
        final doctors = snap.docs
            .map((d) => d.data())
            .where((d) => d['isActive'] != false)
            .toList();
        doctors.sort(
          (a, b) => (a['fullname'] ?? '').toString().toLowerCase().compareTo(
            (b['fullname'] ?? '').toString().toLowerCase(),
          ),
        );
        yield doctors;
      }
    });

/// One doctor's document, kept live so a fee or video URL edited by the
/// doctor is picked up before the patient pays.
final doctorBookingProvider = StreamProvider.autoDispose
    .family<Map<String, dynamic>?, String>((ref, doctorId) async* {
      if (doctorId.isEmpty) {
        yield null;
        return;
      }
      // Errors surface to the payment screen (see its `hasError` branch): catching
      // and yielding `null` used to make a failed read render as the permanent
      // "Loading payment details…" spinner, because `null` is also the legitimate
      // value for a doctor document that does not exist.
      await for (final snap
          in FirebaseFirestore.instance
              .collection(FirestoreCollections.doctors)
              .doc(doctorId)
              .snapshots()) {
        yield snap.exists ? snap.data() : null;
      }
    });

/// Every appointment in the system, for the admin monitoring screen.
///
/// Deliberately unfiltered and sorted in memory: an equality filter plus an
/// order-by would need a composite index, and the admin list narrows by
/// status, date and name anyway.
final allAppointmentsProvider =
    StreamProvider.autoDispose<List<AppointmentModel>>((ref) {
      return ref.read(appointmentControllerProvider).watchAllAppointments();
    });

/// The lifecycle settings document, live. Screens fall back to
/// `AppointmentConfig.defaults()` while it loads, so a first run never blocks
/// on an admin having created the document.
final appointmentConfigProvider = StreamProvider.autoDispose<AppointmentConfig>(
  (ref) {
    return ref.read(appointmentControllerProvider).watchConfig();
  },
);

/// One appointment, kept live — the chat's pinned banner and the detail
/// screens watch this so a phase change written by the other side (or by the
/// Cloud Function) appears without a refresh.
final appointmentProvider = StreamProvider.autoDispose
    .family<AppointmentModel?, String>((ref, appointmentId) {
      return ref
          .read(appointmentControllerProvider)
          .watchAppointment(appointmentId);
    });

/// The append-only audit timeline of one appointment, newest first.
final appointmentEventsProvider = StreamProvider.autoDispose
    .family<List<AppointmentEvent>, String>((ref, appointmentId) {
      return ref.read(appointmentControllerProvider).watchEvents(appointmentId);
    });
