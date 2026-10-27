import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/core/utils/firestore_time.dart';

/// Resolves the video-discount percentage that applies to a doctor.
///
/// A doctor may override the default through `discountPercentage`; anything
/// outside `(0, 100]` falls back to the app default so a malformed record can
/// never produce a negative or free consultation.
double appointmentDiscountPercentFor(num? raw) {
  final value = raw == null ? null : raw.toDouble();
  if (value == null || value <= 0 || value > 100) {
    return AppointmentDefaults.videoDiscountPercent;
  }
  return value;
}

/// Result of applying the video discount to a consultation fee.
class AppointmentPricing {
  final double consultationFee;
  final double discountPercent;
  final bool videoWatched;

  const AppointmentPricing({
    required this.consultationFee,
    required this.discountPercent,
    required this.videoWatched,
  });

  /// The discount is only granted once the required video step completed.
  bool get discountApplied =>
      videoWatched && discountPercent > 0 && consultationFee > 0;

  double get discountAmount =>
      discountApplied ? (consultationFee * discountPercent / 100) : 0;

  double get payableAmount =>
      discountApplied ? consultationFee - discountAmount : consultationFee;

  String get currency => AppointmentDefaults.currency;

  String format(double value) => '$currency ${value.toStringAsFixed(0)}';

  /// `PKR 1,500`, or `Not set` while the doctor has not chosen a price.
  ///
  /// A document written before the `price` field existed resolves to `0`
  /// through `UserModel` / `AppointmentController.priceOf`; rendering that as
  /// "PKR 0" would look like a free consultation instead of an unset one.
  String get feeLabel =>
      consultationFee > 0 ? format(consultationFee) : 'Not set';

  String get discountLabel =>
      discountApplied ? '- ${format(discountAmount)}' : '- ${format(0)}';

  String get payableLabel =>
      consultationFee > 0 ? format(payableAmount) : 'Not set';

  String get discountTitle =>
      'Video Discount (${discountPercent.toStringAsFixed(0)}%)';
}

/// A patient's appointment payment attempt.
///
/// One payment record per appointment — never one per patient/doctor pair, so
/// an old payment can never be reused for a new booking.
///
/// Doc id: the payment's own `paymentId` (a fresh uuid per booking attempt),
/// and every record stores its own `appointmentId` once the appointment is
/// created. Legacy docs used the deterministic `{patientId}_{doctorId}` id;
/// [AppointmentPaymentModel.fromMap] keeps reading them unchanged.
class AppointmentPaymentModel {
  final String id;
  final String patientId;
  final String patientName;
  final String patientImage;
  final String patientPhone;
  final String doctorId;
  final String doctorName;
  final String doctorImage;
  final String doctorSpecialization;
  final bool videoWatched;
  final double consultationFee;
  final double discountPercentage;
  final double discountAmount;
  final double payableAmount;
  final String paymentStatus;
  final String? paymentImage;
  final String? paymentId;

  /// The appointment this payment belongs to. Empty until the patient sends
  /// the appointment request; written once, never rewritten.
  final String appointmentId;
  final String? rejectionReason;
  final DateTime? submittedAt;
  final DateTime? reviewedAt;
  final DateTime? updatedAt;
  final bool appointmentCreated;

  const AppointmentPaymentModel({
    required this.id,
    required this.patientId,
    required this.patientName,
    this.patientImage = '',
    this.patientPhone = '',
    required this.doctorId,
    required this.doctorName,
    this.doctorImage = '',
    this.doctorSpecialization = '',
    this.videoWatched = false,
    this.consultationFee = 0,
    this.discountPercentage = 0,
    this.discountAmount = 0,
    this.payableAmount = 0,
    this.paymentStatus = PaymentStatus.pending,
    this.paymentImage,
    this.paymentId,
    this.appointmentId = '',
    this.rejectionReason,
    this.submittedAt,
    this.reviewedAt,
    this.updatedAt,
    this.appointmentCreated = false,
  });

  bool get isPending => paymentStatus == PaymentStatus.pending;
  bool get isApproved => paymentStatus == PaymentStatus.approved;
  bool get isRejected => paymentStatus == PaymentStatus.rejected;

  AppointmentPricing get pricing => AppointmentPricing(
    consultationFee: consultationFee,
    discountPercent: discountPercentage,
    videoWatched: videoWatched,
  );

  factory AppointmentPaymentModel.fromMap(String id, Map<String, dynamic> map) {
    return AppointmentPaymentModel(
      id: id,
      patientId: map['patientId'] ?? '',
      patientName: map['patientName'] ?? '',
      patientImage: map['patientImage'] ?? '',
      patientPhone: map['patientPhone'] ?? '',
      doctorId: map['doctorId'] ?? '',
      doctorName: map['doctorName'] ?? '',
      doctorImage: map['doctorImage'] ?? '',
      doctorSpecialization: map['doctorSpecialization'] ?? '',
      videoWatched: map['videoWatched'] ?? false,
      consultationFee: _toDouble(map['consultationFee']) ?? 0,
      discountPercentage: _toDouble(map['discountPercentage']) ?? 0,
      discountAmount: _toDouble(map['discountAmount']) ?? 0,
      payableAmount: _toDouble(map['payableAmount']) ?? 0,
      paymentStatus: map['paymentStatus'] ?? PaymentStatus.pending,
      paymentImage: map['paymentImage'],
      paymentId: map['paymentId'],
      appointmentId: map['appointmentId'] ?? '',
      rejectionReason: map['rejectionReason'],
      submittedAt: parseFirestoreTimestamp(map['submittedAt']),
      reviewedAt: parseFirestoreTimestamp(map['reviewedAt']),
      updatedAt: parseFirestoreTimestamp(map['updatedAt']),
      appointmentCreated: map['appointmentCreated'] ?? false,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'patientId': patientId,
      'patientName': patientName,
      'patientImage': patientImage,
      'patientPhone': patientPhone,
      'doctorId': doctorId,
      'doctorName': doctorName,
      'doctorImage': doctorImage,
      'doctorSpecialization': doctorSpecialization,
      'videoWatched': videoWatched,
      'consultationFee': consultationFee,
      'discountPercentage': discountPercentage,
      'discountAmount': discountAmount,
      'payableAmount': payableAmount,
      'paymentStatus': paymentStatus,
      'paymentImage': paymentImage,
      'paymentId': paymentId,
      'appointmentId': appointmentId,
      'rejectionReason': rejectionReason,
      'appointmentCreated': appointmentCreated,
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }
}

/// One appointment record, created only after the payment was approved.
///
/// Doc id: `{patientId}_{doctorId}_{paymentId}` — tied to the approved payment,
/// so tapping *Send Appointment Request* twice reuses the same document.
class AppointmentModel {
  final String id;
  final String patientId;
  final String patientName;
  final String patientImage;
  final String doctorId;
  final String doctorName;
  final String doctorImage;
  final String doctorSpecialization;
  final String subject;
  final String message;

  /// The doctor's consultation price captured when this appointment was
  /// booked. Copied from the doctor document at booking time so a later price
  /// change cannot rewrite history. `0` on records written before the field
  /// existed; [consultationFee] always carries the charged amount either way.
  final double price;
  final double consultationFee;
  final double discountPercentage;
  final double discountAmount;
  final double payableAmount;
  final bool videoWatched;
  final String youtubeVideoUrl;
  final String paymentId;
  final String paymentStatus;
  final String appointmentStatus;
  final DateTime? requestedAt;
  final DateTime? confirmedAt;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// `yyyy-MM-dd`, kept as a string so it sorts and formats identically on
  /// every device.
  final String scheduledDate;
  final String scheduledStartTime;
  final String scheduledEndTime;

  /// Absolute start instant derived from the schedule. Used to decide when the
  /// appointment turns `active` and when the one-shot start alarm fires.
  final DateTime? scheduledStartAt;

  /// Absolute end instant derived from the schedule. Used to decide when the
  /// appointment flips to `expired` and the chat message is unpinned.
  final DateTime? scheduledEndAt;

  /// One-shot guard for the start alarm.
  ///
  /// Claimed inside a transaction before the FCM push goes out, so the
  /// foreground watcher, a second device and the scheduled Cloud Function all
  /// collapse to exactly one notification for
  /// `appointmentId + scheduledStartDateTime`.
  final bool appointmentStartNotificationSent;

  final String doctorResponse;
  final String? pinnedMessageId;

  // ─────────────────────────────────────────────────────────────
  // ATTENDANCE / LIFECYCLE EXTENSIONS
  //
  // Every field below is absent on documents written before this feature
  // existed, so [fromMap] gives each one a neutral default and no screen or
  // lifecycle pass ever has to special-case an old record. Server timestamps
  // are used for every instant that must agree across devices.
  // ─────────────────────────────────────────────────────────────

  /// Fine-grained state (`AppointmentPhase`). `''` on legacy records and on
  /// terminal appointments, whose phase is cleared rather than left stale.
  final String appointmentPhase;

  /// When each side pressed Join. First tap wins: a later tap on a field that
  /// is already set changes nothing, so a flaky connection can never move a
  /// user's arrival backwards.
  final DateTime? patientJoinedAt;
  final DateTime? doctorJoinedAt;

  /// Who cancelled — `AppointmentActors` value. Only set when the status is
  /// [AppointmentStatus.cancelled].
  final String cancelledBy;
  final String cancelReason;
  final DateTime? cancelledAt;

  /// Which side failed to show — `AppointmentNoShowBy`. Only set when the
  /// status is [AppointmentStatus.noShow].
  final String noShowBy;
  final DateTime? noShowAt;

  final DateTime? completedAt;

  /// One-shot claim flags for the reminder pushes (24h / 1h / 10m before the
  /// scheduled start, offsets configurable through
  /// `appointment_settings/defaults.reminderOffsetsMinutes`). Claimed inside a
  /// transaction exactly like [appointmentStartNotificationSent], so the
  /// foreground clock, a second device, a screen's own pass and the scheduled
  /// Cloud Function collapse to one push per offset per appointment.
  ///
  /// Keyed by the offset in minutes (`"1440"`, `"60"`, `"10"`) rather than
  /// fixed fields so the admin may add an offset without a schema change.
  final Map<String, bool> reminderSent;

  /// Legacy fixed claim fields written before the map existed; still honoured
  /// by [reminderSentFor] so an older document is never reminded twice.
  final bool reminder24hSent;
  final bool reminder60mSent;
  final bool reminder10mSent;

  /// One-shot claims for the attendance notices: doctor-late, patient-late
  /// and the grace-ending last call.
  final bool doctorLateNoticeSent;
  final bool patientLateNoticeSent;
  final bool graceNoticeSent;

  const AppointmentModel({
    required this.id,
    required this.patientId,
    required this.patientName,
    this.patientImage = '',
    required this.doctorId,
    required this.doctorName,
    this.doctorImage = '',
    this.doctorSpecialization = '',
    this.subject = '',
    this.message = '',
    this.price = 0,
    this.consultationFee = 0,
    this.discountPercentage = 0,
    this.discountAmount = 0,
    this.payableAmount = 0,
    this.videoWatched = false,
    this.youtubeVideoUrl = '',
    this.paymentId = '',
    this.paymentStatus = PaymentStatus.approved,
    this.appointmentStatus = AppointmentStatus.requested,
    this.requestedAt,
    this.confirmedAt,
    this.createdAt,
    this.updatedAt,
    this.scheduledDate = '',
    this.scheduledStartTime = '',
    this.scheduledEndTime = '',
    this.scheduledStartAt,
    this.scheduledEndAt,
    this.appointmentStartNotificationSent = false,
    this.doctorResponse = '',
    this.pinnedMessageId,
    this.appointmentPhase = '',
    this.patientJoinedAt,
    this.doctorJoinedAt,
    this.cancelledBy = '',
    this.cancelReason = '',
    this.cancelledAt,
    this.noShowBy = '',
    this.noShowAt,
    this.completedAt,
    this.reminderSent = const <String, bool>{},
    this.reminder24hSent = false,
    this.reminder60mSent = false,
    this.reminder10mSent = false,
    this.doctorLateNoticeSent = false,
    this.patientLateNoticeSent = false,
    this.graceNoticeSent = false,
  });

  bool get isRequested => appointmentStatus == AppointmentStatus.requested;

  /// `appointment_confirmed` and `appointment_active` are the same live
  /// appointment seen from two sides of its schedule, so every screen that
  /// used to ask "is this confirmed?" keeps working once the record turns
  /// active.
  bool get isConfirmed =>
      appointmentStatus == AppointmentStatus.confirmed ||
      appointmentStatus == AppointmentStatus.active;

  bool get isCompleted => appointmentStatus == AppointmentStatus.completed;
  bool get isExpired => appointmentStatus == AppointmentStatus.expired;
  bool get isApproved => paymentStatus == PaymentStatus.approved;
  bool get isRejected =>
      appointmentStatus == AppointmentStatus.rejected ||
      appointmentStatus == AppointmentStatus.cancelled;

  /// Explicit new predicates for the lifecycle statuses, so no screen has to
  /// compare raw strings.
  bool get isCancelled => appointmentStatus == AppointmentStatus.cancelled;

  bool get isNoShow => appointmentStatus == AppointmentStatus.noShow;

  bool get hasPatientJoined => patientJoinedAt != null;
  bool get hasDoctorJoined => doctorJoinedAt != null;

  /// Both sides are in — the consultation actually started.
  bool get bothJoined => hasPatientJoined && hasDoctorJoined;

  /// The appointment is in a phase that can still change without an explicit
  /// user action.
  bool get hasLivePhase => AppointmentPhase.isLive(appointmentPhase);

  /// Whether the reminder for [offsetMinutes] before the start already went
  /// out. Also returns `true` for the three legacy boolean keys, so an
  /// appointment whose claim was written by an older build is never reminded
  /// a second time.
  bool reminderSentFor(int offsetMinutes) {
    if (reminderSent[offsetMinutes.toString()] == true) return true;
    switch (offsetMinutes) {
      case 1440:
        return reminder24hSent;
      case 60:
        return reminder60mSent;
      case 10:
        return reminder10mSent;
    }
    return false;
  }

  /// Whether the schedule's end instant has already elapsed.
  ///
  /// The stored `scheduledEndDateTime` is authoritative. A record written
  /// before it existed is resolved from `scheduledDate` + `scheduledEndTime`,
  /// falling back to the end of the calendar day — never to whatever the UI
  /// happens to call "completed".
  bool hasEndedAt(DateTime now) {
    final end = endAt;
    if (end == null) return false;
    return !end.isAfter(now);
  }

  /// Whether the schedule's start instant has already elapsed. `false` when
  /// the start cannot be resolved, so an unreadable record never fires an
  /// alarm at a made-up moment.
  bool hasStartedAt(DateTime now) {
    final start = startAt;
    if (start == null) return false;
    return !start.isAfter(now);
  }

  /// Live right now: confirmed, scheduled, and inside the start/end window.
  bool isActiveAt(DateTime now) =>
      isConfirmed && hasSchedule && !hasEndedAt(now);

  /// A confirmed appointment whose scheduled end has not elapsed yet.
  bool get isUpcoming =>
      isConfirmed && hasSchedule && !hasEndedAt(DateTime.now());

  bool get hasSchedule => scheduledDate.isNotEmpty;

  /// Absolute start instant: the stored `scheduledStartDateTime`, or one
  /// derived from the doctor's picked date + start time for records written
  /// before the timestamp existed.
  DateTime? get startAt =>
      scheduledStartAt ?? _instantFromLabels(scheduledDate, scheduledStartTime);

  /// Absolute end instant, same fallback rule as [startAt]. A record whose end
  /// label cannot be parsed falls back to the end of the scheduled day so it
  /// still expires instead of blocking the pair forever.
  DateTime? get endAt {
    final stored = scheduledEndAt;
    if (stored != null) return stored;
    final derived = _instantFromLabels(scheduledDate, scheduledEndTime);
    if (derived != null) return derived;
    final day = _dateOnly(scheduledDate);
    return day?.add(const Duration(days: 1));
  }

  factory AppointmentModel.fromMap(String id, Map<String, dynamic> map) {
    return AppointmentModel(
      id: id,
      patientId: map['patientId'] ?? '',
      patientName: map['patientName'] ?? '',
      patientImage: map['patientImage'] ?? '',
      doctorId: map['doctorId'] ?? '',
      doctorName: map['doctorName'] ?? '',
      doctorImage: map['doctorImage'] ?? '',
      doctorSpecialization: map['doctorSpecialization'] ?? '',
      subject: map['subject'] ?? '',
      message: map['message'] ?? '',
      price: _toDouble(map['price']) ?? _toDouble(map['consultationFee']) ?? 0,
      consultationFee: _toDouble(map['consultationFee']) ?? 0,
      discountPercentage: _toDouble(map['discountPercentage']) ?? 0,
      discountAmount: _toDouble(map['discountAmount']) ?? 0,
      payableAmount: _toDouble(map['payableAmount']) ?? 0,
      videoWatched: map['videoWatched'] ?? false,
      youtubeVideoUrl: map['youtubeVideoUrl'] ?? '',
      paymentId: map['paymentId'] ?? '',
      paymentStatus: map['paymentStatus'] ?? PaymentStatus.approved,
      appointmentStatus:
          map['appointmentStatus'] ?? AppointmentStatus.requested,
      requestedAt: parseFirestoreTimestamp(map['requestedAt']),
      confirmedAt: parseFirestoreTimestamp(map['confirmedAt']),
      createdAt: parseFirestoreTimestamp(map['createdAt']),
      updatedAt: parseFirestoreTimestamp(map['updatedAt']),
      scheduledDate: map['scheduledDate'] ?? '',
      scheduledStartTime: map['scheduledStartTime'] ?? '',
      scheduledEndTime: map['scheduledEndTime'] ?? '',
      // Canonical key first; `scheduledStartAt` / `scheduledEndAt` are the
      // legacy spellings of the same instant written by older clients.
      scheduledStartAt: parseFirestoreTimestamp(
        map['scheduledStartDateTime'] ?? map['scheduledStartAt'],
      ),
      scheduledEndAt: parseFirestoreTimestamp(
        map['scheduledEndDateTime'] ?? map['scheduledEndAt'],
      ),
      appointmentStartNotificationSent:
          map['appointmentStartNotificationSent'] ?? false,
      doctorResponse: map['doctorResponse'] ?? '',
      pinnedMessageId: map['pinnedMessageId'],
      appointmentPhase: map['appointmentPhase'] ?? '',
      patientJoinedAt: parseFirestoreTimestamp(map['patientJoinedAt']),
      doctorJoinedAt: parseFirestoreTimestamp(map['doctorJoinedAt']),
      cancelledBy: map['cancelledBy'] ?? '',
      cancelReason: map['cancelReason'] ?? '',
      cancelledAt: parseFirestoreTimestamp(map['cancelledAt']),
      noShowBy: map['noShowBy'] ?? '',
      noShowAt: parseFirestoreTimestamp(map['noShowAt']),
      completedAt: parseFirestoreTimestamp(map['completedAt']),
      reminderSent: _boolMap(map['reminderSent']),
      reminder24hSent: map['reminder24hSent'] ?? false,
      reminder60mSent: map['reminder60mSent'] ?? false,
      reminder10mSent: map['reminder10mSent'] ?? false,
      doctorLateNoticeSent: map['doctorLateNoticeSent'] ?? false,
      patientLateNoticeSent: map['patientLateNoticeSent'] ?? false,
      graceNoticeSent: map['graceNoticeSent'] ?? false,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'appointmentId': id,
      'patientId': patientId,
      'patientName': patientName,
      'patientImage': patientImage,
      'doctorId': doctorId,
      'doctorName': doctorName,
      'doctorImage': doctorImage,
      'doctorSpecialization': doctorSpecialization,
      'subject': subject,
      'message': message,
      'price': price,
      'consultationFee': consultationFee,
      'discountPercentage': discountPercentage,
      'discountAmount': discountAmount,
      'payableAmount': payableAmount,
      'videoWatched': videoWatched,
      'youtubeVideoUrl': youtubeVideoUrl,
      'paymentId': paymentId,
      'paymentStatus': paymentStatus,
      'appointmentStatus': appointmentStatus,
      'requestedAt': requestedAt == null
          ? FieldValue.serverTimestamp()
          : Timestamp.fromDate(requestedAt!),
      if (confirmedAt != null) 'confirmedAt': Timestamp.fromDate(confirmedAt!),
      'scheduledDate': scheduledDate,
      'scheduledStartTime': scheduledStartTime,
      'scheduledEndTime': scheduledEndTime,
      // One Firebase Timestamp per instant, under the canonical name.
      if (startAt != null)
        'scheduledStartDateTime': Timestamp.fromDate(startAt!),
      if (endAt != null) 'scheduledEndDateTime': Timestamp.fromDate(endAt!),
      // Legacy spellings kept in sync so an older client reading only
      // `scheduledEndAt` still expires the appointment on time.
      if (startAt != null) 'scheduledStartAt': Timestamp.fromDate(startAt!),
      if (endAt != null) 'scheduledEndAt': Timestamp.fromDate(endAt!),
      'appointmentStartNotificationSent': appointmentStartNotificationSent,
      'doctorResponse': doctorResponse,
      'pinnedMessageId': pinnedMessageId,
      // Lifecycle extensions: absent keys read back as their neutral default
      // in `fromMap`, so a legacy document is never polluted with nulls.
      'appointmentPhase': appointmentPhase,
      if (patientJoinedAt != null)
        'patientJoinedAt': Timestamp.fromDate(patientJoinedAt!),
      if (doctorJoinedAt != null)
        'doctorJoinedAt': Timestamp.fromDate(doctorJoinedAt!),
      if (cancelledBy.isNotEmpty) 'cancelledBy': cancelledBy,
      if (cancelReason.isNotEmpty) 'cancelReason': cancelReason,
      if (cancelledAt != null) 'cancelledAt': Timestamp.fromDate(cancelledAt!),
      if (noShowBy.isNotEmpty) 'noShowBy': noShowBy,
      if (noShowAt != null) 'noShowAt': Timestamp.fromDate(noShowAt!),
      if (completedAt != null) 'completedAt': Timestamp.fromDate(completedAt!),
      if (reminderSent.isNotEmpty) 'reminderSent': reminderSent,
      if (reminder24hSent) 'reminder24hSent': true,
      if (reminder60mSent) 'reminder60mSent': true,
      if (reminder10mSent) 'reminder10mSent': true,
      if (doctorLateNoticeSent) 'doctorLateNoticeSent': true,
      if (patientLateNoticeSent) 'patientLateNoticeSent': true,
      if (graceNoticeSent) 'graceNoticeSent': true,
      'createdAt': createdAt == null
          ? FieldValue.serverTimestamp()
          : Timestamp.fromDate(createdAt!),
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }

  /// Deterministic id — one appointment per approved payment, so repeated
  /// taps on the request button can never create a second document.
  static String buildId({
    required String patientId,
    required String doctorId,
    required String paymentId,
  }) => '${patientId}_${doctorId}_$paymentId';

  /// Same id as [buildId] with an occurrence suffix, used when the pair
  /// already has an appointment that reached a terminal state and wants a new
  /// one. Occurrence 1 keeps the original unsuffixed id so every id that
  /// already exists in the field stays valid.
  static String buildOccurrenceId({
    required String patientId,
    required String doctorId,
    required String paymentId,
    required int occurrence,
  }) {
    final base = buildId(
      patientId: patientId,
      doctorId: doctorId,
      paymentId: paymentId,
    );
    return occurrence <= 1 ? base : '${base}_$occurrence';
  }
}

/// One append-only entry of `appointments/{appointmentId}/events`.
///
/// The timeline shown on the admin detail screen and (for entries that belong
/// to them) on the patient/doctor detail screens. Entries are never updated
/// or deleted — `at` is a server timestamp, so three writers on three devices
/// order identically regardless of their local clocks.
class AppointmentEvent {
  final String id;

  /// `AppointmentEventTypes` value.
  final String type;

  /// Who did it: the patient/doctor/admin document id, empty for the clock.
  final String actorId;

  /// `AppointmentActors` value, `''` for automatic transitions.
  final String actorRole;

  /// Short human-readable note, e.g. `"offset=60"` or a cancellation reason.
  final String detail;

  final DateTime? at;

  const AppointmentEvent({
    required this.id,
    required this.type,
    this.actorId = '',
    this.actorRole = '',
    this.detail = '',
    this.at,
  });

  bool get isAutomatic => actorId.isEmpty && actorRole.isEmpty;

  factory AppointmentEvent.fromMap(String id, Map<String, dynamic> map) {
    return AppointmentEvent(
      id: id,
      type: map['type'] ?? '',
      actorId: map['actorId'] ?? '',
      actorRole: map['actorRole'] ?? '',
      detail: map['detail'] ?? '',
      at: parseFirestoreTimestamp(map['at'] ?? map['createdAt']),
    );
  }

  Map<String, dynamic> toMap() => {
    'type': type,
    'actorId': actorId,
    'actorRole': actorRole,
    'detail': detail,
    if (at != null) 'at': Timestamp.fromDate(at!),
  };
}

/// A Firestore map of `{"60": true}` → `Map<String, bool>`; anything else
/// reads as "nothing claimed yet".
Map<String, bool> _boolMap(dynamic raw) {
  if (raw is! Map) return const <String, bool>{};
  final result = <String, bool>{};
  raw.forEach((key, value) {
    if (value == true) result[key.toString()] = true;
  });
  return result;
}

double? _toDouble(dynamic value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.trim());
  return null;
}

/// Admin-tunable lifecycle settings, backed by the single document
/// `appointment_settings/defaults`.
///
/// A missing document, a missing key and a malformed value all resolve to the
/// same [AppointmentDefaults] fallback, so a partially written document can
/// never stop the clock — and the Dart side and `functions/index.js` (which
/// parses the identical document) always agree, because both derive their
/// defaults from the one constant block.
class AppointmentConfig {
  /// Document id inside `appointment_settings`.
  static const String docId = 'defaults';

  final int graceMinutes;
  final int patientGraceMinutes;
  final int startingSoonMinutes;
  final int graceEndingMinutes;
  final int cancellationWarningLimit;
  final int freezeDurationDays;

  /// Minute-offsets before the scheduled start that each fire exactly one
  /// reminder. Always ascending, always positive, never empty.
  final List<int> reminderOffsetsMinutes;

  /// `non_refundable` (default) or `refundable` — shown verbatim to the
  /// patient in the cancellation confirmation dialog.
  final String refundPolicyPatientCancel;

  const AppointmentConfig({
    required this.graceMinutes,
    required this.patientGraceMinutes,
    required this.startingSoonMinutes,
    required this.graceEndingMinutes,
    required this.cancellationWarningLimit,
    required this.freezeDurationDays,
    required this.reminderOffsetsMinutes,
    required this.refundPolicyPatientCancel,
  });

  AppointmentConfig.defaults()
    : graceMinutes = AppointmentDefaults.graceMinutes,
      patientGraceMinutes = AppointmentDefaults.patientGraceMinutes,
      startingSoonMinutes = AppointmentDefaults.startingSoonMinutes,
      graceEndingMinutes = AppointmentDefaults.graceEndingMinutes,
      cancellationWarningLimit = AppointmentDefaults.cancellationWarningLimit,
      freezeDurationDays = AppointmentDefaults.freezeDurationDays,
      reminderOffsetsMinutes = AppointmentDefaults.reminderOffsetsMinutes,
      refundPolicyPatientCancel =
          AppointmentDefaults.defaultRefundPolicyPatientCancel;

  bool get refundableOnPatientCancel =>
      refundPolicyPatientCancel == AppointmentDefaults.refundPolicyRefundable;

  /// The exact wording shown under the cancel button, so the dialog and the
  /// policy the backend applies can never read differently.
  String get refundPolicyLabel => refundableOnPatientCancel
      ? 'Your payment will be refunded.'
      : 'Your payment will not be refunded.';

  factory AppointmentConfig.fromMap(Map<String, dynamic>? map) {
    final fallback = AppointmentConfig.defaults();
    if (map == null) return fallback;
    return AppointmentConfig(
      graceMinutes: _intOr(
        map['graceMinutes'],
        fallback.graceMinutes,
        min: 1,
        max: 240,
      ),
      patientGraceMinutes: _intOr(
        map['patientGraceMinutes'],
        fallback.patientGraceMinutes,
        min: 1,
        max: 240,
      ),
      startingSoonMinutes: _intOr(
        map['startingSoonMinutes'],
        fallback.startingSoonMinutes,
        min: 1,
        max: 7 * 24 * 60,
      ),
      graceEndingMinutes: _intOr(
        map['graceEndingMinutes'],
        fallback.graceEndingMinutes,
        min: 1,
        max: 240,
      ),
      cancellationWarningLimit: _intOr(
        map['cancellationWarningLimit'],
        fallback.cancellationWarningLimit,
        min: 1,
        max: 20,
      ),
      freezeDurationDays: _intOr(
        map['freezeDurationDays'],
        fallback.freezeDurationDays,
        min: 1,
        max: 365,
      ),
      reminderOffsetsMinutes: _offsetsOr(
        map['reminderOffsetsMinutes'],
        fallback,
      ),
      refundPolicyPatientCancel:
          map['refundPolicyPatientCancel']?.toString().trim() ==
              AppointmentDefaults.refundPolicyRefundable
          ? AppointmentDefaults.refundPolicyRefundable
          : AppointmentDefaults.refundPolicyNonRefundable,
    );
  }

  Map<String, dynamic> toMap() => {
    'graceMinutes': graceMinutes,
    'patientGraceMinutes': patientGraceMinutes,
    'startingSoonMinutes': startingSoonMinutes,
    'graceEndingMinutes': graceEndingMinutes,
    'cancellationWarningLimit': cancellationWarningLimit,
    'freezeDurationDays': freezeDurationDays,
    'reminderOffsetsMinutes': reminderOffsetsMinutes,
    'refundPolicyPatientCancel': refundPolicyPatientCancel,
    'updatedAt': FieldValue.serverTimestamp(),
  };
}

/// A missing, non-numeric or out-of-range value falls straight back to the
/// default — an admin typo must never be able to disable the lifecycle.
int _intOr(dynamic raw, int fallback, {required int min, required int max}) {
  int? value;
  if (raw is int) {
    value = raw;
  } else if (raw is num) {
    value = raw.toInt();
  } else if (raw is String) {
    value = int.tryParse(raw.trim());
  }
  if (value == null || value < min || value > max) return fallback;
  return value;
}

/// Reminder offsets are sanitized into a small, ascending, de-duplicated list
/// of positive values — a garbage array degrades to the defaults rather than
/// silencing every reminder.
List<int> _offsetsOr(dynamic raw, AppointmentConfig fallback) {
  if (raw is! List) return List<int>.from(fallback.reminderOffsetsMinutes);
  final parsed = <int>{};
  for (final value in raw) {
    final minutes = value is int
        ? value
        : value is num
        ? value.toInt()
        : int.tryParse('${value ?? ''}'.trim());
    if (minutes == null || minutes <= 0 || minutes > 7 * 24 * 60) continue;
    parsed.add(minutes);
  }
  if (parsed.isEmpty) return List<int>.from(fallback.reminderOffsetsMinutes);
  return parsed.toList()..sort();
}

/// `yyyy-MM-dd` → local midnight, or `null` when the string is malformed.
DateTime? _dateOnly(String raw) {
  final parts = raw.trim().split('-');
  if (parts.length != 3) return null;
  final year = int.tryParse(parts[0]);
  final month = int.tryParse(parts[1]);
  final day = int.tryParse(parts[2]);
  if (year == null || month == null || day == null) return null;
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  return DateTime(year, month, day);
}

/// `9:00 AM` / `21:05` → minutes since midnight, or `null`.
int? _timeToMinutes(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return null;
  final match = RegExp(
    r'^(\d{1,2}):(\d{2})\s*(AM|PM)?$',
    caseSensitive: false,
  ).firstMatch(value);
  if (match == null) return null;
  final hour = int.parse(match.group(1)!);
  final minute = int.parse(match.group(2)!);
  final meridiem = match.group(3)?.toUpperCase();
  if (minute > 59) return null;
  if (meridiem != null) {
    if (hour < 1 || hour > 12) return null;
    final h = hour % 12 + (meridiem == 'PM' ? 12 : 0);
    return h * 60 + minute;
  }
  if (hour > 23) return null;
  return hour * 60 + minute;
}

/// Combines the scheduled day with a `9:00 AM`-style label into one instant
/// in the device's local zone, mirroring how the doctor's pick was entered.
DateTime? _instantFromLabels(String date, String time) {
  final day = _dateOnly(date);
  if (day == null) return null;
  final minutes = _timeToMinutes(time);
  if (minutes == null) return null;
  return day.add(Duration(minutes: minutes));
}
