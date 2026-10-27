export 'package:telemedicine/core/utils/subscription_calculator.dart';

/// Centralized Firestore collection names.
/// Using constants ensures consistency and avoids typos.
abstract class FirestoreCollections {
  FirestoreCollections._();

  static const String patients = 'telemedicine_patient';
  static const String doctors = 'telemedicine_doctors';
  static const String patientIds = 'patient_ids';
  static const String chats = 'chats';
  static const String userChats = 'user_chats';
  static const String calls = 'calls';
  static const String doctorActivityLogs = 'doctor_activity_logs';
  static const String doctorOnlineSessions = 'doctor_online_sessions';
  static const String doctorDailyStats = 'doctor_daily_stats';
  static const String doctorChats = 'doctor_chats';
  static const String reports = 'reports';

  /// Cross-user document permissions that gate who can read reports.
  static const String reportShares = 'report_shares';

  /// Prescriptions issued by a doctor to a patient.
  static const String prescriptions = 'prescriptions';

  /// Patient ratings given to a doctor, one per prescription.
  static const String doctorRatings = 'doctor_ratings';

  /// Subcollection path for chat messages: `chats/{chatId}/messages`
  static const String chatMessages = 'messages';

  /// Append-only trail of every soft-delete / restore / activation.
  ///
  /// Records are never modified or removed, so the who/when/why of a deletion
  /// survives even after the account is restored (which clears the top-level
  /// `deletedAt` / `deletedBy` fields).
  static const String accountAuditLog = 'account_audit_log';

  /// Appointment requests raised by a patient for a specific doctor.
  /// Doc id is deterministic: `{patientId}_{doctorId}_{paymentId}`.
  static const String appointments = 'appointments';

  /// One payment record per appointment — a payment can never be reused for a
  /// new appointment. Doc id is the payment's own `paymentId` uuid; legacy docs
  /// used `{patientId}_{doctorId}`.
  static const String appointmentPayments = 'appointment_payments';

  /// Whether the required educational video step was completed for a given
  /// patient/doctor pair. Doc id: `{patientId}_{doctorId}`.
  static const String appointmentVideoWatches = 'appointment_video_watches';

  /// Admin-tunable lifecycle settings. Single document: `appointment_settings/
  /// defaults`, read by the app clock and the scheduled Cloud Function alike.
  static const String appointmentSettings = 'appointment_settings';

  /// Subcollection name for the append-only appointment audit trail:
  /// `appointments/{appointmentId}/events`.
  static const String appointmentEvents = 'events';

  /// One introduction video per doctor. Doc id: `{doctorId}`.
  static const String doctorVideos = 'doctor_videos';

  /// Whether the patient finished watching a doctor's assigned video.
  /// Doc id: `{patientId}_{doctorId}`.
  static const String doctorVideoWatches = 'doctor_video_watches';
}

/// Field names shared by the doctor and patient soft-delete contracts.
///
/// Kept in one place because the same six fields are read by the query layer,
/// written by the controllers and asserted by the booking/chat guards.
abstract class SoftDeleteFields {
  SoftDeleteFields._();

  static const String isDeleted = 'isDeleted';
  static const String isActive = 'isActive';
  static const String deletedAt = 'deletedAt';
  static const String deletedBy = 'deletedBy';
  static const String deletedReason = 'deletedReason';
}

/// `action` values written to [FirestoreCollections.accountAuditLog].
abstract class AuditActions {
  AuditActions._();

  static const String doctorSoftDeleted = 'doctor_soft_deleted';
  static const String doctorRestored = 'doctor_restored';
  static const String patientSoftDeleted = 'patient_soft_deleted';
  static const String patientRestored = 'patient_restored';
  static const String patientSelfDeleted = 'patient_self_deleted';

  /// Booking freezes raised by the cancellation policy or by an admin.
  static const String doctorBookingFrozen = 'doctor_booking_frozen';
  static const String doctorBookingUnfrozen = 'doctor_booking_unfrozen';
  static const String patientBookingFrozen = 'patient_booking_frozen';
  static const String patientBookingUnfrozen = 'patient_booking_unfrozen';

  /// The cancellation warning counter was cleared by an admin.
  static const String doctorWarningsReset = 'doctor_warnings_reset';
  static const String patientWarningsReset = 'patient_warnings_reset';
}

/// Which collection a soft-deleted record belongs to.
enum SoftDeleteEntity { doctor, patient }

/// Centralized notification channel IDs.
///
/// These values are part of the FCM contract: the `channel_id` /
/// `channelId` in every outgoing payload MUST match one of the channels the
/// app registers at bootstrap. A mismatch makes Android fall back to the
/// default channel (or drop the heads-up entirely on some OEMs), which is why
/// both the sender and the receiver read them from here.
abstract class NotificationChannels {
  NotificationChannels._();

  static const String chat = 'chat_notifications_channel';
  static const String call = 'call_notifications_channel';
  static const String incomingCalls = 'incoming_calls';
  static const String general = 'general_notifications';
  static const String passwordReset = 'password_reset_notifications';

  /// IDs used by older builds / not-yet-redeployed Cloud Functions. They are
  /// deleted once during the channel migration so a device cannot keep posting
  /// to a stale channel with frozen (lower) importance.
  static const String legacyChat = 'chat_notifications';
  static const String legacyCall = 'call_notifications';
}

/// Zego configuration constants.
abstract class ZegoConfig {
  ZegoConfig._();

  static const int appId = 1368028170;
  static const String appSign =
      'ff91b4090d669ea3ec9919a526c06fb63e1c14902e84fa585db07f423bb0dcf8';
}

/// App-wide timeout and limit constants.
abstract class AppLimits {
  AppLimits._();

  static const int onlineThresholdSeconds = 45;
  static const int recentOfflineThresholdMinutes = 2;
  static const int ringTimeoutSeconds = 45;
  static const int maxDoctorIdAttempts = 10;
  static const int cacheDurationSeconds = 5;
  static const Duration heartbeatInterval = Duration(seconds: 30);
  static const Duration presenceCheckInterval = Duration(seconds: 45);
}

/// Patient account validity and the expiry-warning window.
///
/// Patient IDs now support 3 subscription plans:
/// - 1 Month: 1 calendar month validity
/// - 6 Months: 6 calendar months validity (legacy default)
/// - 1 Year: 12 calendar months validity
abstract class AccountExpiry {
  AccountExpiry._();

  /// Default validity granted when an account is activated or reactivated under legacy flow.
  static const int validityMonths = 6;

  /// Warning opens after this many months for legacy 6-month plans.
  static const int warningAfterMonths = 5;

  /// Plan ID constants matching Firestore storage values.
  static const String planOneMonth = 'one_month';
  static const String planSixMonths = 'six_months';
  static const String planOneYear = 'one_year';

  /// The patient-facing warning message. Single source so the banner and the
  /// one-time heads-up toast can never drift apart.
  static const String warningMessage =
      'Your account will expire soon. Please reactivate your account by '
      'submitting a new payment proof.';

  /// SharedPreferences key holding the warning period the user has already been
  /// notified for. The stored value embeds both the user id and the expiry
  /// date, so a reactivation automatically re-arms the warning for the new
  /// period without any manual reset.
  static const String warnedPeriodKey = 'patient_expiry_warned_period';
}

/// User roles used across the application.
abstract class UserRoles {
  UserRoles._();

  static const String patient = 'patient';
  static const String doctor = 'doctor';
  static const String admin = 'admin';
}

/// Canonical call lifecycle states plus the legal transitions between them.
///
/// Every incoming-call path (FCM foreground push, FCM background/terminated
/// push, notification body tap, notification Accept/Decline actions and the
/// Firestore recovery watcher) funnels through
/// `IncomingCallCoordinator`, which uses this table to decide whether a
/// transition may happen at all. A call can therefore never be both accepted
/// and declined, and a stale duplicate push can never resurrect a call that
/// has already reached a terminal state.
abstract class CallStatus {
  CallStatus._();

  /// Push has been received but the callee has not been told yet.
  static const String incoming = 'incoming';

  /// Callee's device is ringing.
  static const String ringing = 'ringing';

  /// Callee answered. Both peers are now in the media room.
  static const String accepted = 'accepted';

  /// Media is actually flowing between the two peers.
  static const String connected = 'connected';

  /// Callee actively declined while the call was still ringing.
  static const String declined = 'declined';

  /// Legacy alias of [declined] that older records still carry.
  static const String rejected = 'rejected';

  /// Nobody answered before the ring timeout elapsed.
  static const String missed = 'missed';

  /// Call finished normally (hang-up after it connected).
  static const String ended = 'ended';

  /// Caller hung up before the callee answered.
  static const String cancelled = 'cancelled';

  /// Callee could not take the call (e.g. already busy).
  static const String busy = 'busy';

  /// States from which no further transition is allowed.
  static const Set<String> terminal = <String>{
    declined,
    rejected,
    missed,
    ended,
    cancelled,
    busy,
  };

  /// States in which the call is still waiting for an answer.
  static const Set<String> ringing_ = <String>{incoming, ringing};

  /// States in which the call is live on both devices.
  static const Set<String> active = <String>{accepted, connected};

  static bool isTerminal(String? state) =>
      state != null && terminal.contains(state);

  static bool isRinging(String? state) =>
      state != null && ringing_.contains(state);

  static bool isActive(String? state) =>
      state != null && active.contains(state);

  /// Whether a call currently in [from] may move to [to].
  ///
  /// A `null` [from] means "unknown yet" (e.g. the push arrived before the
  /// Firestore read resolved) and is treated as [ringing], which is the state
  /// the caller writes before the push is sent.
  static bool canTransition(String? from, String to) {
    if (from == to) return false;
    if (isTerminal(from)) return false;
    final source = from ?? ringing;
    return _allowedTransitions[source]?.contains(to) ?? false;
  }

  /// Only a still-ringing call may be answered.
  ///
  /// A `null` [state] means the authoritative read failed (offline, permission,
  /// timeout). The caller writes `ringing` before it sends the push, so an
  /// unknown status must be treated as ringing — otherwise a transient network
  /// error silently swallows a real call.
  static bool canAccept(String? state) => state == null || isRinging(state);

  /// Only a still-ringing call may be declined. Same `null` handling as
  /// [canAccept].
  static bool canDecline(String? state) => state == null || isRinging(state);

  static const Map<String, Set<String>> _allowedTransitions =
      <String, Set<String>>{
        incoming: <String>{
          ringing,
          accepted,
          declined,
          rejected,
          missed,
          cancelled,
          ended,
          busy,
        },
        ringing: <String>{
          accepted,
          declined,
          rejected,
          missed,
          cancelled,
          ended,
          busy,
        },
        accepted: <String>{connected, ended, cancelled},
        connected: <String>{ended},
        // A call that reached a terminal state never moves again; the map has
        // no entry for them and `canTransition` returns false.
      };
}

/// Payment statuses used across the application.
abstract class PaymentStatus {
  PaymentStatus._();

  static const String pending = 'pending';
  static const String approved = 'approved';
  static const String rejected = 'rejected';
}

/// Lifecycle of a single `appointments` document.
abstract class AppointmentStatus {
  AppointmentStatus._();

  /// Patient paid and sent the request; the doctor has not scheduled it yet.
  static const String requested = 'appointment_requested';

  /// Doctor picked date + start/end time and confirmed it.
  static const String confirmed = 'appointment_confirmed';

  /// The scheduled start time has passed but the end has not — the
  /// consultation is live right now. Derived from
  /// `scheduledStartDateTime` / `scheduledEndDateTime`, so a device that was
  /// offline at the exact start instant still resolves to `active`.
  static const String active = 'appointment_active';

  /// The scheduled end time has passed and the record was closed.
  static const String completed = 'appointment_completed';

  /// The scheduled end time passed, so the pair may book again. The document
  /// is kept forever as history — it is never deleted.
  static const String expired = 'appointment_expired';

  /// The doctor declined the request without scheduling it.
  static const String rejected = 'appointment_rejected';

  /// The patient withdrew the request before it was confirmed.
  static const String cancelled = 'appointment_cancelled';

  /// The slot ended while one side was waiting and the other side never
  /// joined. Recorded instead of [expired] only when somebody actually
  /// waited: a slot where nobody joined at all stays [expired], because no
  /// absence was suffered by anyone.
  static const String noShow = 'appointment_no_show';

  static const Set<String> all = <String>{
    requested,
    confirmed,
    active,
    completed,
    expired,
    rejected,
    cancelled,
    noShow,
  };

  /// Statuses that still occupy the patient/doctor pair: while one of these is
  /// current, no second appointment may be created for the same doctor.
  static const Set<String> open = <String>{requested, confirmed, active};

  /// Statuses that can never move again.
  static const Set<String> terminal = <String>{
    rejected,
    cancelled,
    completed,
    expired,
    noShow,
  };

  static bool isValid(String? status) => status != null && all.contains(status);

  static bool isOpen(String? status) => status != null && open.contains(status);

  static bool isTerminal(String? status) =>
      status != null && terminal.contains(status);
}

/// The fine-grained, time-and-attendance driven state of an appointment.
///
/// [AppointmentStatus] stays coarse on purpose — the existing `in` query in
/// `functions/index.js`, the pair-occupancy guard and every screen that asks
/// `isConfirmed` keep working untouched. This field is the *display* and
/// *notification* layer on top of it: it is derived, never asserted, and is
/// rewritten by whichever lifecycle pass runs first (foreground clock,
/// scheduled Cloud Function, or a screen's own `initState` pass).
///
/// Resolution order lives in one pure function
/// (`resolveAppointmentPhase` in `appointment_lifecycle_logic.dart`) so the
/// Dart side and `functions/index.js` can never disagree about it.
abstract class AppointmentPhase {
  AppointmentPhase._();

  /// Requested but not scheduled yet — no slot exists to reason about.
  static const String waiting = 'waiting';

  /// Scheduled, and its start is still comfortably ahead.
  static const String scheduled = 'scheduled';

  /// Scheduled and close enough to warrant the upcoming-appointment nudge.
  static const String startingSoon = 'starting_soon';

  /// Inside the slot, nobody has joined yet and the doctor is still within
  /// their grace window.
  static const String waitingForDoctor = 'waiting_for_doctor';

  /// Inside the slot, the doctor is in and the patient is still within their
  /// grace window.
  static const String waitingForPatient = 'waiting_for_patient';

  /// The doctor has not joined within the grace window — the patient is
  /// waiting and has been told once.
  static const String doctorLate = 'doctor_late';

  /// The doctor is in and the patient has not joined within the grace window.
  static const String patientLate = 'patient_late';

  /// The slot is about to close with somebody still missing — the last-chance
  /// window before [AppointmentStatus.noShow] fires at the end.
  static const String graceEnding = 'grace_ending';

  /// Both sides are in. The consultation is genuinely under way.
  static const String inProgress = 'in_progress';

  /// The appointment reached a terminal status; the phase field is cleared.
  static const String closed = 'closed';

  static const Set<String> all = <String>{
    waiting,
    scheduled,
    startingSoon,
    waitingForDoctor,
    waitingForPatient,
    doctorLate,
    patientLate,
    graceEnding,
    inProgress,
    closed,
  };

  static bool isValid(String? phase) => phase != null && all.contains(phase);

  /// Phases that only exist while the slot is actually running.
  static const Set<String> live = <String>{
    waitingForDoctor,
    waitingForPatient,
    doctorLate,
    patientLate,
    graceEnding,
    inProgress,
  };

  static bool isLive(String? phase) => phase != null && live.contains(phase);

  /// "Someone is late" — drives the late banners and pushes.
  static const Set<String> late = <String>{doctorLate, patientLate};

  static bool isLate(String? phase) => phase != null && late.contains(phase);
}

/// Who acted on an appointment. Stored as `cancelledBy` / `noShowBy` / the
/// `actorRole` of an audit event so the timeline can name a side exactly.
abstract class AppointmentActors {
  AppointmentActors._();

  static const String patient = 'patient';
  static const String doctor = 'doctor';
  static const String admin = 'admin';

  static const Set<String> all = <String>{patient, doctor, admin};

  static bool isValid(String? actor) => actor != null && all.contains(actor);
}

/// Which side failed to show, for [AppointmentStatus.noShow].
abstract class AppointmentNoShowBy {
  AppointmentNoShowBy._();

  static const String patient = AppointmentActors.patient;
  static const String doctor = AppointmentActors.doctor;

  /// Recorded only by an explicit admin override — the automatic path never
  /// assigns `both`, because a slot where nobody joined at all is simply
  /// expired.
  static const String both = 'both';

  static const Set<String> all = <String>{patient, doctor, both};

  static bool isValid(String? value) => value != null && all.contains(value);
}

/// `type` values written to `appointments/{appointmentId}/events`.
///
/// Append-only: each entry carries `at` (server timestamp), `type`,
/// `actorId`, `actorRole` and a short `detail`. The admin timeline and the
/// patient/doctor detail screens render this one list, so every side sees the
/// same history of what happened to the appointment.
abstract class AppointmentEventTypes {
  AppointmentEventTypes._();

  static const String created = 'created';
  static const String confirmed = 'confirmed';
  static const String rescheduled = 'rescheduled';
  static const String activated = 'activated';
  static const String patientJoined = 'patient_joined';
  static const String doctorJoined = 'doctor_joined';
  static const String reminderSent = 'reminder_sent';
  static const String doctorLate = 'doctor_late';
  static const String patientLate = 'patient_late';
  static const String graceEnding = 'grace_ending';
  static const String cancelled = 'cancelled';
  static const String warningIssued = 'warning_issued';
  static const String freezeApplied = 'freeze_applied';
  static const String freezeLifted = 'freeze_lifted';
  static const String expired = 'expired';
  static const String completed = 'completed';
  static const String noShow = 'no_show';
  static const String adminAction = 'admin_action';

  static const Set<String> all = <String>{
    created,
    confirmed,
    rescheduled,
    activated,
    patientJoined,
    doctorJoined,
    reminderSent,
    doctorLate,
    patientLate,
    graceEnding,
    cancelled,
    warningIssued,
    freezeApplied,
    freezeLifted,
    expired,
    completed,
    noShow,
    adminAction,
  };
}

/// Business defaults for the appointment booking flow.
abstract class AppointmentDefaults {
  AppointmentDefaults._();

  /// Discount applied to the consultation fee once the required educational
  /// video has been watched. Overridable per doctor through
  /// `telemedicine_doctors.discountPercentage`.
  static const double videoDiscountPercent = 30.0;

  /// Currency shown next to every appointment price.
  static const String currency = 'PKR';

  /// Shown when the patient tries to book a doctor they already have an open
  /// appointment with. Single source so the UI guard, the button guard and the
  /// Firestore write guard can never drift apart.
  static const String activeAppointmentMessage =
      'You already have an active appointment with this doctor. You can book '
      'another appointment after your current appointment expires.';

  /// Title of the one-shot alarm fired when an appointment's scheduled start
  /// arrives. The scheduled Cloud Function mirrors this string so a push sent
  /// from the app and one sent from the backend read identically.
  static const String appointmentStartTitle = 'Appointment Starting';

  /// Body of the start alarm, addressed to whichever side is reading it —
  /// `counterpartName` is the doctor for the patient and the patient for the
  /// doctor.
  static String appointmentStartBody(String counterpartName) =>
      'Your appointment with $counterpartName starts now. '
      'Tap to open the chat.';

  // ─────────────────────────────────────────────────────────────
  // LIFECYCLE DEFAULTS
  //
  // Every number here is the *fallback* of `appointment_settings/defaults`:
  // the admin config document may override all of them, and an absent,
  // malformed or partially-written document resolves back to these values on
  // both the Dart and the Cloud Function side. Single source so the clock in
  // the app, the scheduled function and the admin editor can never drift.
  // ─────────────────────────────────────────────────────────────

  /// Minutes a doctor may be absent from a running slot before the phase
  /// flips to `doctor_late` and the patient is told once.
  static const int graceMinutes = 15;

  /// Minutes a patient may be absent after the doctor joined before the phase
  /// flips to `patient_late`.
  static const int patientGraceMinutes = 15;

  /// Minutes before the scheduled start when `scheduled` becomes
  /// `starting_soon` (and the upcoming reminder window opens).
  static const int startingSoonMinutes = 60;

  /// Minutes before the scheduled end when an unresolved absence becomes
  /// `grace_ending` — the last chance before no-show fires.
  static const int graceEndingMinutes = 5;

  /// Cancellations allowed per user before a booking freeze is applied.
  static const int cancellationWarningLimit = 2;

  /// How long a booking freeze lasts, in days, once the limit is reached.
  static const int freezeDurationDays = 7;

  /// Minutes before the scheduled start for each reminder push, ascending so
  /// the list reads soonest-first: `10` = 10 minutes, `60` = 1 hour,
  /// `1440` = 24 hours. Every lifecycle pass walks them in this order.
  static const List<int> reminderOffsetsMinutes = <int>[10, 60, 1440];

  /// Refund policy for a patient-initiated cancellation. Configurable through
  /// `appointment_settings/defaults.refundPolicyPatientCancel`; shown verbatim
  /// in the confirmation dialog so the patient reads it before tapping.
  static const String refundPolicyNonRefundable = 'non_refundable';
  static const String refundPolicyRefundable = 'refundable';
  static const String defaultRefundPolicyPatientCancel =
      refundPolicyNonRefundable;

  /// Shown when a user tries to book while a cancellation freeze is active.
  static String bookingFrozenMessage(DateTime until) =>
      'Your booking is temporarily paused after repeated cancellations. '
      'You can book again after ${until.day} ${_monthName(until.month)} '
      '${until.year}.';

  static String _monthName(int month) {
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
    return months[month - 1];
  }

  // ─────────────────────────────────────────────────────────────
  // LIFECYCLE NOTIFICATION COPY
  //
  // Mirrored verbatim by `functions/index.js` so a push sent while the app is
  // closed reads exactly like one sent from the open app.
  // ─────────────────────────────────────────────────────────────

  static const String reminderTitle = 'Appointment Reminder';
  static String reminderBody(String counterpartName, String when) =>
      'Your appointment with $counterpartName $when. Tap to open the chat.';

  static const String joinedTitle = 'Appointment Joined';
  static String joinedBody(String joinerName) =>
      '$joinerName has joined your appointment. Tap to open the chat.';

  static const String lateTitle = 'Appointment Late';
  static String lateBody(String absentName, int minutes) =>
      '$absentName has not joined yet ($minutes min late). Tap to open '
      'the chat.';

  /// The same notice, addressed to the absent side itself — "Dr. X has not
  /// joined" would read as an accusation when the recipient *is* Dr. X.
  static String lateSelfBody(String counterpartName, int minutes) =>
      'You have not joined your appointment with $counterpartName '
      '($minutes min late). Tap to open the chat.';

  static const String graceEndingTitle = 'Appointment Ending Soon';
  static String graceEndingBody(String counterpartName) =>
      'Your appointment with $counterpartName ends in a few minutes. '
      'Tap to open the chat.';

  static const String cancelledTitle = 'Appointment Cancelled';
  static String cancelledBody(String actorName) =>
      'The appointment was cancelled by $actorName.';

  static const String noShowTitle = 'Appointment No-Show';
  static String noShowBody(String absentName) =>
      '$absentName did not join the appointment.';

  static const String frozenTitle = 'Booking Paused';
  static String frozenBody(int count, int limit) =>
      'You have cancelled $count of $limit appointments. Further bookings '
      'are paused until an admin lifts the pause.';
}

/// `messageType` of the system message written into the Room Chat when a
/// doctor confirms an appointment.
abstract class ChatMessageTypes {
  ChatMessageTypes._();

  static const String appointment = 'appointment';
}

/// The languages a doctor can declare on their profile.
///
/// Persisted on `telemedicine_doctors.languages` as a `List<String>`. Both the
/// doctor's own edit screens and the patient-facing contact card read that one
/// field, so the two sides can never disagree. The list is a *suggestion set*,
/// not a whitelist: [parse] keeps any non-empty value it finds, so
/// a doctor can hold a language that is not listed here and a listed language
/// can be added later without invalidating existing records.
abstract class DoctorLanguages {
  DoctorLanguages._();

  /// The Firestore field name. Singular `language` is read as a legacy
  /// fallback by [parseLanguageList] for records written before the list field
  /// existed.
  static const String field = 'languages';
  static const String legacyField = 'language';

  static const List<String> options = <String>[
    'English',
    'Hindi',
    'Urdu',
    'Punjabi',
    'Bengali',
    'Tamil',
    'Telugu',
    'Marathi',
    'Gujarati',
    'Kannada',
    'Malayalam',
    'Odia',
    'Assamese',
    'Nepali',
    'Arabic',
    'French',
    'German',
    'Spanish',
  ];

  /// Normalises whatever Firestore holds into a clean, de-duplicated list.
  ///
  /// Doctor records predate this field, and the value has been seen in three
  /// shapes across clients: absent, a `List<String>`, and a single comma
  /// separated `String` (the singular legacy field). All three must resolve
  /// without throwing, because this runs inside `UserModel.fromMap` — a throw
  /// here would take down every screen that touches a doctor profile.
  /// Matching is case-insensitive and matched against [options] so that
  /// `"english"` and `"English"` collapse to the one canonical spelling rather
  /// than rendering as duplicate chips. Values outside [options] are preserved
  /// with their original casing so nothing is silently dropped.
  static List<String> parse(dynamic raw) {
    if (raw == null) return const <String>[];

    final values = <String>[];
    if (raw is String) {
      values.addAll(raw.split(','));
    } else if (raw is Iterable) {
      values.addAll(raw.map((e) => e.toString()));
    } else {
      values.add(raw.toString());
    }

    // Canonical spelling lookup, so "english" and "English" are one value.
    final byLowerName = <String, String>{
      for (final option in options) option.toLowerCase(): option,
    };

    final seen = <String>{};
    final result = <String>[];
    for (final value in values) {
      final trimmed = value.trim();
      if (trimmed.isEmpty) continue;
      final key = trimmed.toLowerCase();
      if (!seen.add(key)) continue;
      result.add(byLowerName[key] ?? trimmed);
    }
    return List<String>.unmodifiable(result);
  }
}

/// Discriminator carried in the FCM `data.type` field.
///
/// Every value here is part of a cross-process contract: the sender (this app
/// or `functions/index.js`) writes it, the receiver
/// (`NotificationService._handleMessageNavigationFromPayload`) routes on it.
abstract class FcmMessageType {
  FcmMessageType._();

  /// Incoming voice/video call. Carries a full [IncomingCallPayload].
  static const String call = 'call';

  /// New chat message.
  static const String chatMessage = 'chat_message';

  /// Legacy chat discriminator still written by older clients.
  static const String chat = 'chat';

  /// A patient shared a report with a doctor.
  static const String reportShared = 'report_shared';

  /// Legacy payment-proof push. Superseded by [paymentSubmitted] but still
  /// routed so notifications already in flight keep working.
  static const String paymentProof = 'payment_proof';

  /// Patient submitted a payment proof → every admin.
  static const String paymentSubmitted = 'payment_submitted';

  /// Patient submitted a payment complaint / inquiry → every admin.
  static const String paymentComplaint = 'payment_complaint';

  /// Admin replied to a patient complaint → patient only.
  static const String complaintReply = 'complaint_reply';

  /// Standard payment proof submission event type.
  static const String paymentProofSubmitted = 'payment_proof_submitted';

  /// Admin approved the payment → patient only.
  static const String paymentApproved = 'payment_approved';

  /// Admin rejected the payment → patient only.
  static const String paymentRejected = 'payment_rejected';

  /// Patient submitted an *appointment* payment proof → every admin.
  static const String appointmentPaymentSubmitted =
      'appointment_payment_submitted';

  /// Admin approved the appointment payment → patient only.
  static const String appointmentPaymentApproved =
      'appointment_payment_approved';

  /// Admin rejected the appointment payment → patient only.
  static const String appointmentPaymentRejected =
      'appointment_payment_rejected';

  /// Patient sent an appointment request → the selected doctor only.
  static const String newAppointmentRequest = 'new_appointment_request';

  /// Doctor confirmed the date/time → patient only.
  static const String appointmentConfirmed = 'appointment_confirmed';

  /// The appointment reached its scheduled start time → patient and doctor.
  ///
  /// Carries `appointmentId`, `patientId`, `doctorId` and `chatId` so the tap
  /// handler can open the exact conversation without going through the Room
  /// Chat list.
  static const String appointmentStart = 'appointment_start';

  /// Time-to-start reminder (24h / 1h / 10m) → patient and doctor.
  static const String appointmentReminder = 'appointment_reminder';

  /// The counterpart pressed Join → the other side.
  static const String appointmentJoined = 'appointment_joined';

  /// One side has not joined within the grace window → the waiting side (and
  /// the absent side, so both know the clock is running).
  static const String appointmentDoctorLate = 'appointment_doctor_late';
  static const String appointmentPatientLate = 'appointment_patient_late';

  /// The slot is about to close with somebody still missing.
  static const String appointmentGraceEnding = 'appointment_grace_ending';

  /// The appointment was cancelled by patient/doctor/admin → the other side
  /// and the admins.
  static const String appointmentCancelled = 'appointment_cancelled';

  /// The slot ended with one side waiting in vain → both sides and admins.
  static const String appointmentNoShow = 'appointment_no_show';

  /// A user's bookings were paused after repeated cancellations (policy or
  /// admin) → that user and every admin.
  static const String bookingFrozen = 'booking_frozen';

  static bool isPayment(String? type) =>
      type == paymentProof ||
      type == paymentSubmitted ||
      type == paymentProofSubmitted ||
      type == paymentComplaint ||
      type == complaintReply ||
      type == paymentApproved ||
      type == paymentRejected;

  static bool isAppointment(String? type) =>
      type == appointmentPaymentSubmitted ||
      type == appointmentPaymentApproved ||
      type == appointmentPaymentRejected ||
      type == newAppointmentRequest ||
      type == appointmentConfirmed ||
      type == appointmentStart ||
      type == appointmentReminder ||
      type == appointmentJoined ||
      type == appointmentDoctorLate ||
      type == appointmentPatientLate ||
      type == appointmentGraceEnding ||
      type == appointmentCancelled ||
      type == appointmentNoShow ||
      type == bookingFrozen;

  static bool isCall(String? type) => type == call;
}

/// Keys of the `appointment_start` FCM `data` payload.
///
/// The sender (the foreground lifecycle watcher *and* the scheduled Cloud
/// Function) writes exactly these names and the receiver
/// (`NotificationService._handleAppointmentNotificationTap`) reads them, so
/// the alarm can open the right conversation whichever process sent it.
abstract class AppointmentPayloadKeys {
  AppointmentPayloadKeys._();

  static const String type = 'type';
  static const String appointmentId = 'appointmentId';
  static const String patientId = 'patientId';
  static const String doctorId = 'doctorId';
  static const String chatId = 'chatId';
  static const String patientName = 'patientName';
  static const String doctorName = 'doctorName';
  static const String patientImage = 'patientImage';
  static const String doctorImage = 'doctorImage';

  /// Epoch millis of the scheduled start. Part of the one-shot identity: the
  /// same appointment rescheduled to a new slot gets a new id here.
  static const String scheduledStartAt = 'scheduledStartAt';

  /// Ready-to-render title/body for *this* recipient, so every display path
  /// (foreground local notification, OS-rendered background notification)
  /// shows the same words.
  static const String title = 'title';
  static const String body = 'body';

  static const String notificationId = 'notificationId';

  // ── lifecycle notification extras ────────────────────────────
  // Carried by the reminder / joined / late / cancelled / no-show / freeze
  // payloads. Names shared by the Dart sender, `functions/index.js` and the
  // receiver, exactly like the keys above.

  /// Which side acted: `AppointmentActors` value.
  static const String actorRole = 'actorRole';
  static const String actorId = 'actorId';
  static const String actorName = 'actorName';

  /// `AppointmentPhase` of the appointment when the push went out.
  static const String phase = 'phase';

  /// Minutes late / minutes remaining, rendered into the body by the sender
  /// but also available to a custom renderer.
  static const String minutes = 'minutes';

  /// Reminder offset in minutes that produced this push (`1440`/`60`/`10`),
  /// part of the one-shot identity for `appointment_reminder`.
  static const String offsetMinutes = 'offsetMinutes';

  /// `AppointmentNoShowBy` value.
  static const String noShowBy = 'noShowBy';

  /// Cancellation warning count and the freeze limit that produced it.
  static const String warningCount = 'warningCount';
  static const String warningLimit = 'warningLimit';

  /// Epoch millis until which bookings are frozen (`bookingFrozenUntil`).
  static const String frozenUntil = 'frozenUntil';
}

/// Keys of the standardized incoming-call FCM `data` payload.
///
/// The Cloud Function that sends the call push, the background isolate, the
/// foreground handler, the notification body tap and the notification
/// Accept/Decline actions all read exactly these names, so a payload can never
/// be half-understood by one path and fully understood by another.
abstract class CallPayloadKeys {
  CallPayloadKeys._();

  static const String schemaVersion = 'schemaVersion';
  static const String type = 'type';
  static const String callId = 'callId';
  static const String callerId = 'callerId';
  static const String callerName = 'callerName';
  static const String callerImage = 'callerImage';
  static const String callerType = 'callerType';
  static const String receiverId = 'receiverId';
  static const String recipientId = 'recipientId';
  static const String callType = 'callType';
  static const String channelId = 'channelId';
  static const String roomId = 'roomId';
  static const String callStatus = 'callStatus';
  static const String expiresAt = 'expiresAt';
  static const String sentAt = 'sentAt';
  static const String timestamp = 'timestamp';
}

/// Notification action ids used by the incoming-call notification.
///
/// The very same ids are consumed by [IncomingCallCoordinator] from both the
/// OS notification and the app's own Incoming Call screen, so there is exactly
/// one accept implementation and one decline implementation.
abstract class CallActionIds {
  CallActionIds._();

  static const String accept = 'accept_call';
  static const String decline = 'decline_call';

  /// Body tap (no action button).
  static const String open = 'open_call';
}

/// Account statuses used across the application.
abstract class AccountStatus {
  AccountStatus._();

  static const String active = 'Active';
  static const String inactive = 'Inactive';
  static const String suspended = 'Suspended';
}
