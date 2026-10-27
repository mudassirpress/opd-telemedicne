import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/data/models/appointment_model.dart';

// ─────────────────────────────────────────────────────────────
// APPOINTMENT LIFECYCLE — PURE DECISIONS
//
// Firestore has no clock and three different processes move an appointment:
// the foreground tick (`AppointmentLifecycleService`), a screen's own
// `initState` pass, and the scheduled Cloud Function in `functions/index.js`.
// Every one of them must reach the *same* conclusion from the same document,
// or the status flip-flops and notifications duplicate.
//
// So all of it lives here: no Firestore, no `DateTime.now()` inside a
// decision (the caller passes `now`), no side effects — just tables that unit
// tests can pin down. `functions/index.js` mirrors these exact rules with the
// same constants read from `appointment_settings/defaults`.
// ─────────────────────────────────────────────────────────────

/// The fine-grained phase of an appointment at [now].
///
/// Precedence, highest first — this order *is* the specification:
///
///  1. a non-open status, or a slot whose end already passed → [AppointmentPhase.closed]
///     (the terminal status write happens in the same pass);
///  2. no schedule at all → [AppointmentPhase.waiting];
///  3. before the start → [AppointmentPhase.scheduled] /
///     [AppointmentPhase.startingSoon];
///  4. both sides in → [AppointmentPhase.inProgress] (never downgraded, not
///     even by the grace-ending window);
///  5. inside the slot with somebody missing and the end close →
///     [AppointmentPhase.graceEnding];
///  6. otherwise the missing side's grace, measured from the *scheduled
///     start* — deliberately independent of join order, so the doctor
///     arriving late cannot silently extend the patient's deadline.
String resolveAppointmentPhase({
  required String status,
  required DateTime? startAt,
  required DateTime? endAt,
  required DateTime? patientJoinedAt,
  required DateTime? doctorJoinedAt,
  required DateTime now,
  required AppointmentConfig config,
}) {
  if (!AppointmentStatus.isOpen(status)) return AppointmentPhase.closed;
  if (startAt == null || endAt == null) return AppointmentPhase.waiting;

  if (now.isBefore(startAt)) {
    final untilStart = startAt.difference(now).inMinutes;
    return untilStart <= config.startingSoonMinutes
        ? AppointmentPhase.startingSoon
        : AppointmentPhase.scheduled;
  }

  if (!now.isBefore(endAt)) return AppointmentPhase.closed;

  final patientIn = patientJoinedAt != null;
  final doctorIn = doctorJoinedAt != null;
  if (patientIn && doctorIn) return AppointmentPhase.inProgress;

  final untilEnd = endAt.difference(now);
  if (untilEnd.inMinutes < config.graceEndingMinutes) {
    return AppointmentPhase.graceEnding;
  }

  // Grace is measured from the scheduled start for both sides.
  final doctorLateBy = now.isAfter(
    startAt.add(Duration(minutes: config.graceMinutes)),
  );
  final patientLateBy = now.isAfter(
    startAt.add(Duration(minutes: config.patientGraceMinutes)),
  );

  if (patientIn && !doctorIn) {
    return doctorLateBy
        ? AppointmentPhase.doctorLate
        : AppointmentPhase.waitingForDoctor;
  }
  if (doctorIn && !patientIn) {
    return patientLateBy
        ? AppointmentPhase.patientLate
        : AppointmentPhase.waitingForPatient;
  }
  // Nobody in yet: the doctor is expected first, so an empty slot ages into
  // `doctor_late` rather than blaming a patient who may simply be early.
  return doctorLateBy
      ? AppointmentPhase.doctorLate
      : AppointmentPhase.waitingForDoctor;
}

/// The status an open appointment takes the moment its slot ends.
///
/// The three cases, in full:
///
///  * **exactly one side joined** → [AppointmentStatus.noShow] with the
///    *absent* side in `noShowBy`. Somebody waited; the record must say so.
///  * **nobody joined** → [AppointmentStatus.expired]. No absence was
///    suffered by anyone, so no blame is assigned — this keeps every
///    historical appointment (written before join tracking existed) landing
///    exactly where it always did.
///  * **both joined** → [AppointmentStatus.completed]. The consultation
///    actually happened; only the closing write was missing.
class AppointmentOutcome {
  /// Terminal status to write.
  final String status;

  /// `AppointmentNoShowBy` value, empty unless [status] is no-show.
  final String noShowBy;

  /// `AppointmentEventTypes` value for the audit trail.
  final String event;

  const AppointmentOutcome({
    required this.status,
    required this.noShowBy,
    required this.event,
  });
}

AppointmentOutcome resolveTerminalOutcome({
  required DateTime? patientJoinedAt,
  required DateTime? doctorJoinedAt,
}) {
  final patientIn = patientJoinedAt != null;
  final doctorIn = doctorJoinedAt != null;

  if (patientIn && !doctorIn) {
    return const AppointmentOutcome(
      status: AppointmentStatus.noShow,
      noShowBy: AppointmentNoShowBy.doctor,
      event: AppointmentEventTypes.noShow,
    );
  }
  if (doctorIn && !patientIn) {
    return const AppointmentOutcome(
      status: AppointmentStatus.noShow,
      noShowBy: AppointmentNoShowBy.patient,
      event: AppointmentEventTypes.noShow,
    );
  }
  if (patientIn && doctorIn) {
    return const AppointmentOutcome(
      status: AppointmentStatus.completed,
      noShowBy: '',
      event: AppointmentEventTypes.completed,
    );
  }
  return const AppointmentOutcome(
    status: AppointmentStatus.expired,
    noShowBy: '',
    event: AppointmentEventTypes.expired,
  );
}

/// Whether the reminder for `offsetMinutes` before the scheduled start should
/// fire on this pass.
///
/// Only ever true inside `[start - offset, start)`: before the window the
/// reminder is early, at or after the start the one-shot start alarm owns the
/// moment, and once the slot is over nothing is sent at all. [alreadySent] is
/// the claim read from the document — the caller takes it inside a
/// transaction, so this predicate is the *policy*, not the concurrency.
bool isReminderDue({
  required String status,
  required DateTime? startAt,
  required DateTime? endAt,
  required bool alreadySent,
  required int offsetMinutes,
  required DateTime now,
}) {
  if (alreadySent) return false;
  if (!AppointmentStatus.isOpen(status)) return false;
  if (startAt == null || endAt == null) return false;
  if (offsetMinutes <= 0) return false;

  final dueAt = startAt.subtract(Duration(minutes: offsetMinutes));
  if (now.isBefore(dueAt)) return false;
  if (!now.isBefore(startAt)) return false;
  if (!now.isBefore(endAt)) return false;
  return true;
}

/// "in 24 hours" / "in an hour" / "in 10 minutes" — the human half of a
/// reminder, shared by both senders so the Dart push and the Cloud Function
/// push read identically.
String reminderWhenLabel(int offsetMinutes) {
  if (offsetMinutes % 1440 == 0 && offsetMinutes >= 1440) {
    final days = offsetMinutes ~/ 1440;
    return days == 1 ? 'in a day' : 'in $days days';
  }
  if (offsetMinutes % 60 == 0 && offsetMinutes >= 60) {
    final hours = offsetMinutes ~/ 60;
    return hours == 1 ? 'in an hour' : 'in $hours hours';
  }
  return 'in $offsetMinutes minutes';
}

/// The result of asking "may this appointment be cancelled, and what does
/// this cancellation cost the actor?".
class CancellationAssessment {
  /// `false` when the request must be rejected with [blockReason].
  final bool allowed;

  /// User-facing reason when [allowed] is `false`.
  final String blockReason;

  /// The actor's warning count *after* this cancellation lands.
  final int warningCountAfter;

  /// Whether reaching [warningCountAfter] must trigger a booking freeze.
  final bool freezeAfter;

  const CancellationAssessment({
    required this.allowed,
    required this.blockReason,
    required this.warningCountAfter,
    required this.freezeAfter,
  });
}

/// Policy for cancelling an appointment.
///
/// * `rejected` / `cancelled` / `completed` / `expired` / `no_show` never move
///   again — the block reason names the terminal state.
/// * a **patient** may withdraw a request (`requested`) or a slot
///   (`confirmed`/`active`); an **admin** may cancel anything open; a
///   **doctor** cancels a scheduled slot but *rejects* an unscheduled request
///   (that path has its own status and must not be conflated).
/// * only patient/doctor cancellations count towards the limit — an admin
///   cancelling on someone's behalf is a moderation action, not the user's
///   fault.
CancellationAssessment evaluateCancellation({
  required String status,
  required String actorRole,
  required int warningCount,
  required int warningLimit,
}) {
  if (!AppointmentStatus.isOpen(status)) {
    return CancellationAssessment(
      allowed: false,
      blockReason: status == AppointmentStatus.requested
          ? 'This request has already been sent.'
          : 'This appointment is already ${_statusWord(status)}.',
      warningCountAfter: warningCount,
      freezeAfter: false,
    );
  }

  final isAdmin = actorRole == AppointmentActors.admin;
  final isDoctor = actorRole == AppointmentActors.doctor;

  if (isDoctor && status == AppointmentStatus.requested) {
    return CancellationAssessment(
      allowed: false,
      blockReason: 'Use Reject to decline an unscheduled request.',
      warningCountAfter: warningCount,
      freezeAfter: false,
    );
  }

  if (isAdmin) {
    return CancellationAssessment(
      allowed: true,
      blockReason: '',
      warningCountAfter: warningCount,
      freezeAfter: false,
    );
  }

  final after = warningCount + 1;
  final limit = warningLimit < 1 ? 1 : warningLimit;
  return CancellationAssessment(
    allowed: true,
    blockReason: '',
    warningCountAfter: after,
    freezeAfter: after >= limit,
  );
}

/// When a freeze that starts at [now] would lift, or `null` when the actor
/// has not reached the limit.
DateTime? freezeUntilFor({
  required bool freezeAfter,
  required int freezeDurationDays,
  required DateTime now,
}) {
  if (!freezeAfter) return null;
  final days = freezeDurationDays < 1 ? 1 : freezeDurationDays;
  return now.add(Duration(days: days));
}

/// The block message when [frozenUntil] is in the future, else `null`.
///
/// An expired-but-never-cleared freeze reads as *not frozen*: an admin who
/// forgot to lift it must not lock the user out forever, and the next
/// lifecycle pass clears the stale fields anyway.
String? bookingFreezeMessage({
  required DateTime? frozenUntil,
  required DateTime now,
}) {
  if (frozenUntil == null) return null;
  if (!frozenUntil.isAfter(now)) return null;
  return AppointmentDefaults.bookingFrozenMessage(frozenUntil);
}

/// Whether the late/grace notices should be (re)considered on this pass.
///
/// `phase` has just become [AppointmentPhase.doctorLate] /
/// [AppointmentPhase.patientLate] / [AppointmentPhase.graceEnding] and the
/// corresponding claim flag is still free. The caller claims the flag in a
/// transaction, so this only answers "is this the moment for it?".
bool isAttendanceNoticeDue({required String phase, required bool alreadySent}) {
  if (alreadySent) return false;
  return phase == AppointmentPhase.doctorLate ||
      phase == AppointmentPhase.patientLate ||
      phase == AppointmentPhase.graceEnding;
}

String _statusWord(String status) {
  switch (status) {
    case AppointmentStatus.confirmed:
      return 'confirmed';
    case AppointmentStatus.active:
      return 'in progress';
    case AppointmentStatus.noShow:
      return 'marked as a no-show';
    case AppointmentStatus.rejected:
      return 'rejected';
    case AppointmentStatus.cancelled:
      return 'cancelled';
    case AppointmentStatus.completed:
      return 'completed';
    case AppointmentStatus.expired:
      return 'expired';
    default:
      return status;
  }
}
