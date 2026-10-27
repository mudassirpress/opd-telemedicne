import 'package:flutter_test/flutter_test.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/data/models/appointment_model.dart';
import 'package:telemedicine/features/appointments/presentation/appointment_lifecycle_logic.dart';

/// Builds the phase inputs with sane schedule defaults: the slot runs
/// 10:00–10:30 on 2026-10-05 in the test's local zone.
({DateTime start, DateTime end}) slot() {
  final start = DateTime(2026, 10, 5, 10, 0);
  return (start: start, end: start.add(const Duration(minutes: 30)));
}

String phase({
  String status = AppointmentStatus.active,
  DateTime? startAt,
  DateTime? endAt,
  DateTime? patientJoinedAt,
  DateTime? doctorJoinedAt,
  required DateTime now,
  AppointmentConfig? config,
}) {
  final s = slot();
  return resolveAppointmentPhase(
    status: status,
    startAt: startAt ?? s.start,
    endAt: endAt ?? s.end,
    patientJoinedAt: patientJoinedAt,
    doctorJoinedAt: doctorJoinedAt,
    now: now,
    config: config ?? AppointmentConfig.defaults(),
  );
}

void main() {
  group('resolveAppointmentPhase', () {
    final s = slot();

    test('a terminal status is always closed, whatever the clock says', () {
      for (final status in AppointmentStatus.terminal) {
        expect(
          phase(status: status, now: s.start.add(const Duration(minutes: 5))),
          AppointmentPhase.closed,
          reason: status,
        );
      }
    });
    test('an unscheduled request waits — there is no slot to reason about', () {
      final s = slot();
      expect(
        resolveAppointmentPhase(
          status: AppointmentStatus.requested,
          startAt: null,
          endAt: null,
          patientJoinedAt: null,
          doctorJoinedAt: null,
          now: DateTime(2026, 10, 5),
          config: AppointmentConfig.defaults(),
        ),
        AppointmentPhase.waiting,
      );
      // A malformed schedule (one boundary unreadable) waits too, rather than
      // pretending a slot exists.
      expect(
        resolveAppointmentPhase(
          status: AppointmentStatus.confirmed,
          startAt: s.start,
          endAt: null,
          patientJoinedAt: null,
          doctorJoinedAt: null,
          now: s.start.add(const Duration(minutes: 5)),
          config: AppointmentConfig.defaults(),
        ),
        AppointmentPhase.waiting,
      );
    });

    test(
      'before the start: scheduled, then starting_soon inside the window',
      () {
        expect(
          phase(now: s.start.subtract(const Duration(minutes: 90))),
          AppointmentPhase.scheduled,
        );
        expect(
          phase(now: s.start.subtract(const Duration(minutes: 60))),
          AppointmentPhase.startingSoon,
        );
        expect(
          phase(now: s.start.subtract(const Duration(minutes: 2))),
          AppointmentPhase.startingSoon,
        );
      },
    );

    test('the start boundary itself is no longer "before the start"', () {
      expect(phase(now: s.start), isNot(AppointmentPhase.scheduled));
      expect(phase(now: s.start), isNot(AppointmentPhase.startingSoon));
    });

    test(
      'inside the slot with nobody in: waiting for the doctor, then late',
      () {
        expect(
          phase(now: s.start.add(const Duration(minutes: 5))),
          AppointmentPhase.waitingForDoctor,
        );
        expect(
          phase(now: s.start.add(const Duration(minutes: 15))),
          AppointmentPhase.waitingForDoctor,
          reason: 'grace is strictly greater than 15 minutes',
        );
        expect(
          phase(now: s.start.add(const Duration(minutes: 16))),
          AppointmentPhase.doctorLate,
        );
      },
    );

    test('the doctor is in, the patient has their own grace window', () {
      final doctorIn = s.start.add(const Duration(minutes: 1));
      expect(
        phase(
          now: s.start.add(const Duration(minutes: 10)),
          doctorJoinedAt: doctorIn,
        ),
        AppointmentPhase.waitingForPatient,
      );
      expect(
        phase(
          now: s.start.add(const Duration(minutes: 16)),
          doctorJoinedAt: doctorIn,
        ),
        AppointmentPhase.patientLate,
      );
    });

    test('the patient is in alone and the doctor is late', () {
      final patientIn = s.start.add(const Duration(minutes: 1));
      expect(
        phase(
          now: s.start.add(const Duration(minutes: 5)),
          patientJoinedAt: patientIn,
        ),
        AppointmentPhase.waitingForDoctor,
      );
      expect(
        phase(
          now: s.start.add(const Duration(minutes: 20)),
          patientJoinedAt: patientIn,
        ),
        AppointmentPhase.doctorLate,
      );
    });

    test('a doctor arriving late does not extend the patient\'s deadline', () {
      // The doctor joins at minute 20 — long after the patient's 15-minute
      // grace from the *scheduled start* had already elapsed.
      final doctorIn = s.start.add(const Duration(minutes: 20));
      expect(
        phase(
          now: s.start.add(const Duration(minutes: 21)),
          doctorJoinedAt: doctorIn,
        ),
        AppointmentPhase.patientLate,
      );
    });

    test('both sides in is in_progress and never downgraded', () {
      final patientIn = s.start;
      final doctorIn = s.start;
      expect(
        phase(
          now: s.start.add(const Duration(minutes: 20)),
          patientJoinedAt: patientIn,
          doctorJoinedAt: doctorIn,
        ),
        AppointmentPhase.inProgress,
      );
      expect(
        phase(
          now: s.end.subtract(const Duration(minutes: 1)),
          patientJoinedAt: patientIn,
          doctorJoinedAt: doctorIn,
        ),
        AppointmentPhase.inProgress,
        reason:
            'the grace-ending window only matters while someone is '
            'missing',
      );
    });

    test('the last minutes of an unfinished slot become grace_ending', () {
      expect(
        phase(now: s.end.subtract(const Duration(minutes: 3))),
        AppointmentPhase.graceEnding,
      );
      expect(
        phase(now: s.end.subtract(const Duration(minutes: 5))),
        isNot(AppointmentPhase.graceEnding),
        reason: 'the window is strictly under graceEndingMinutes',
      );
    });

    test('a slot whose end has passed is closed even if the write lagged', () {
      expect(
        phase(now: s.end.add(const Duration(minutes: 1))),
        AppointmentPhase.closed,
      );
    });

    test('admin overrides are honoured', () {
      final config = AppointmentConfig.fromMap(const {
        'graceMinutes': 2,
        'patientGraceMinutes': 3,
        'startingSoonMinutes': 10,
        'graceEndingMinutes': 1,
      });
      expect(
        phase(now: s.start.add(const Duration(minutes: 3)), config: config),
        AppointmentPhase.doctorLate,
      );
      expect(
        phase(
          now: s.start.subtract(const Duration(minutes: 20)),
          config: config,
        ),
        AppointmentPhase.scheduled,
        reason: 'the default 60-minute window would have said starting_soon',
      );
      expect(
        phase(
          now: s.start.subtract(const Duration(minutes: 9)),
          config: config,
        ),
        AppointmentPhase.startingSoon,
      );
      expect(
        phase(now: s.end.subtract(const Duration(seconds: 90)), config: config),
        isNot(AppointmentPhase.graceEnding),
        reason:
            'the override is 1 minute, so 90 seconds left is outside it '
            '— the 5-minute default would have said grace_ending',
      );
      expect(
        phase(now: s.end.subtract(const Duration(seconds: 30)), config: config),
        AppointmentPhase.graceEnding,
      );
    });
  });

  group('resolveTerminalOutcome', () {
    final t0 = DateTime(2026, 10, 5, 10, 0);

    test('a patient who waited with no doctor produces a doctor no-show', () {
      final outcome = resolveTerminalOutcome(
        patientJoinedAt: t0,
        doctorJoinedAt: null,
      );
      expect(outcome.status, AppointmentStatus.noShow);
      expect(outcome.noShowBy, AppointmentNoShowBy.doctor);
      expect(outcome.event, AppointmentEventTypes.noShow);
    });

    test('a doctor who waited with no patient produces a patient no-show', () {
      final outcome = resolveTerminalOutcome(
        patientJoinedAt: null,
        doctorJoinedAt: t0,
      );
      expect(outcome.status, AppointmentStatus.noShow);
      expect(outcome.noShowBy, AppointmentNoShowBy.patient);
    });

    test('nobody joined at all stays expired — no blame is assigned', () {
      final outcome = resolveTerminalOutcome(
        patientJoinedAt: null,
        doctorJoinedAt: null,
      );
      expect(outcome.status, AppointmentStatus.expired);
      expect(outcome.noShowBy, '');
      expect(outcome.event, AppointmentEventTypes.expired);
    });

    test('both sides joined, so the consultation completed', () {
      final outcome = resolveTerminalOutcome(
        patientJoinedAt: t0,
        doctorJoinedAt: t0.add(const Duration(minutes: 2)),
      );
      expect(outcome.status, AppointmentStatus.completed);
      expect(outcome.noShowBy, '');
      expect(outcome.event, AppointmentEventTypes.completed);
    });
  });

  group('isReminderDue', () {
    final start = DateTime(2026, 10, 5, 10, 0);
    final end = start.add(const Duration(minutes: 30));

    bool due({
      required DateTime now,
      int offset = 60,
      bool sent = false,
      String status = AppointmentStatus.confirmed,
    }) => isReminderDue(
      status: status,
      startAt: start,
      endAt: end,
      alreadySent: sent,
      offsetMinutes: offset,
      now: now,
    );

    test('fires inside the window and nowhere else', () {
      expect(due(now: start.subtract(const Duration(minutes: 61))), isFalse);
      expect(due(now: start.subtract(const Duration(minutes: 60))), isTrue);
      expect(due(now: start.subtract(const Duration(minutes: 1))), isTrue);
      expect(due(now: start), isFalse, reason: 'the start alarm owns now');
      expect(due(now: start.add(const Duration(minutes: 1))), isFalse);
      expect(due(now: end), isFalse);
    });

    test(
      'never fires twice, or for a terminal appointment, or for offset 0',
      () {
        expect(
          due(now: start.subtract(const Duration(minutes: 10)), sent: true),
          isFalse,
        );
        expect(
          due(
            now: start.subtract(const Duration(minutes: 10)),
            status: AppointmentStatus.cancelled,
          ),
          isFalse,
        );
        expect(
          due(now: start.subtract(const Duration(minutes: 10)), offset: 0),
          isFalse,
        );
        expect(
          due(now: start.subtract(const Duration(minutes: 10)), offset: -5),
          isFalse,
        );
      },
    );

    test('a request without a schedule never reminds', () {
      expect(
        isReminderDue(
          status: AppointmentStatus.requested,
          startAt: null,
          endAt: null,
          alreadySent: false,
          offsetMinutes: 60,
          now: start,
        ),
        isFalse,
      );
    });
  });

  group('reminderWhenLabel', () {
    test('reads naturally at every shape of offset', () {
      expect(reminderWhenLabel(1440), 'in a day');
      expect(reminderWhenLabel(2880), 'in 2 days');
      expect(reminderWhenLabel(60), 'in an hour');
      expect(reminderWhenLabel(120), 'in 2 hours');
      expect(reminderWhenLabel(10), 'in 10 minutes');
      expect(reminderWhenLabel(90), 'in 90 minutes');
    });
  });

  group('evaluateCancellation', () {
    test('every terminal status is refused with a readable reason', () {
      for (final status in AppointmentStatus.terminal) {
        final result = evaluateCancellation(
          status: status,
          actorRole: AppointmentActors.patient,
          warningCount: 0,
          warningLimit: 2,
        );
        expect(result.allowed, isFalse, reason: status);
        expect(result.blockReason, isNotEmpty);
        expect(result.warningCountAfter, 0);
      }
    });

    test(
      'a doctor rejects an unscheduled request instead of cancelling it',
      () {
        final result = evaluateCancellation(
          status: AppointmentStatus.requested,
          actorRole: AppointmentActors.doctor,
          warningCount: 0,
          warningLimit: 2,
        );
        expect(result.allowed, isFalse);
        expect(result.blockReason, contains('Reject'));
      },
    );

    test('the first patient cancellation warns but does not freeze', () {
      final result = evaluateCancellation(
        status: AppointmentStatus.confirmed,
        actorRole: AppointmentActors.patient,
        warningCount: 0,
        warningLimit: 2,
      );
      expect(result.allowed, isTrue);
      expect(result.warningCountAfter, 1);
      expect(result.freezeAfter, isFalse);
    });

    test('the second patient cancellation reaches the limit and freezes', () {
      final result = evaluateCancellation(
        status: AppointmentStatus.confirmed,
        actorRole: AppointmentActors.patient,
        warningCount: 1,
        warningLimit: 2,
      );
      expect(result.allowed, isTrue);
      expect(result.warningCountAfter, 2);
      expect(result.freezeAfter, isTrue);
    });

    test('a doctor cancelling a scheduled slot counts against the doctor', () {
      final result = evaluateCancellation(
        status: AppointmentStatus.active,
        actorRole: AppointmentActors.doctor,
        warningCount: 1,
        warningLimit: 2,
      );
      expect(result.allowed, isTrue);
      expect(result.warningCountAfter, 2);
      expect(result.freezeAfter, isTrue);
    });

    test('an admin cancellation never counts against anybody', () {
      final result = evaluateCancellation(
        status: AppointmentStatus.active,
        actorRole: AppointmentActors.admin,
        warningCount: 5,
        warningLimit: 2,
      );
      expect(result.allowed, isTrue);
      expect(result.warningCountAfter, 5, reason: 'unchanged');
      expect(result.freezeAfter, isFalse);
    });

    test('a malformed limit degrades to at least one, never to zero', () {
      final result = evaluateCancellation(
        status: AppointmentStatus.requested,
        actorRole: AppointmentActors.patient,
        warningCount: 0,
        warningLimit: 0,
      );
      expect(result.allowed, isTrue);
      expect(result.warningCountAfter, 1);
      expect(result.freezeAfter, isTrue);
    });
  });

  group('freeze helpers', () {
    final now = DateTime(2026, 10, 5, 10, 0);

    test('the freeze lifts exactly freezeDurationDays after it started', () {
      final until = freezeUntilFor(
        freezeAfter: true,
        freezeDurationDays: 7,
        now: now,
      );
      expect(until, now.add(const Duration(days: 7)));
    });

    test('no freeze means no date', () {
      expect(
        freezeUntilFor(freezeAfter: false, freezeDurationDays: 7, now: now),
        isNull,
      );
    });

    test('only a freeze still in the future blocks a booking', () {
      expect(bookingFreezeMessage(frozenUntil: null, now: now), isNull);
      expect(
        bookingFreezeMessage(frozenUntil: now, now: now),
        isNull,
        reason: 'a freeze that ends now has ended',
      );
      expect(
        bookingFreezeMessage(
          frozenUntil: now.add(const Duration(days: 3)),
          now: now,
        ),
        isNotNull,
      );
    });
  });

  group('AppointmentConfig', () {
    test('a missing document is the defaults', () {
      final config = AppointmentConfig.fromMap(null);
      expect(config.graceMinutes, AppointmentDefaults.graceMinutes);
      expect(
        config.cancellationWarningLimit,
        AppointmentDefaults.cancellationWarningLimit,
      );
      expect(
        config.reminderOffsetsMinutes,
        AppointmentDefaults.reminderOffsetsMinutes,
      );
      expect(config.refundableOnPatientCancel, isFalse);
    });

    test('every malformed value falls back independently', () {
      final config = AppointmentConfig.fromMap(const {
        'graceMinutes': 'soon',
        'patientGraceMinutes': -4,
        'startingSoonMinutes': 0,
        'graceEndingMinutes': 99999,
        'cancellationWarningLimit': null,
        'freezeDurationDays': 0,
        'reminderOffsetsMinutes': 'nope',
        'refundPolicyPatientCancel': 'whatever',
      });
      final fallback = AppointmentConfig.defaults();
      expect(config.graceMinutes, fallback.graceMinutes);
      expect(config.patientGraceMinutes, fallback.patientGraceMinutes);
      expect(config.startingSoonMinutes, fallback.startingSoonMinutes);
      expect(config.graceEndingMinutes, fallback.graceEndingMinutes);
      expect(
        config.cancellationWarningLimit,
        fallback.cancellationWarningLimit,
      );
      expect(config.freezeDurationDays, fallback.freezeDurationDays);
      expect(config.reminderOffsetsMinutes, fallback.reminderOffsetsMinutes);
      expect(config.refundableOnPatientCancel, isFalse);
    });

    test('good values are kept', () {
      final config = AppointmentConfig.fromMap(const {
        'graceMinutes': 20,
        'cancellationWarningLimit': 3,
        'refundPolicyPatientCancel': 'refundable',
      });
      expect(config.graceMinutes, 20);
      expect(config.cancellationWarningLimit, 3);
      expect(config.refundableOnPatientCancel, isTrue);
      expect(config.refundPolicyLabel, 'Your payment will be refunded.');
    });

    test('reminder offsets are cleaned: unique, positive, ascending', () {
      final config = AppointmentConfig.fromMap(const {
        'reminderOffsetsMinutes': [30, 30, -5, 0, 1440, '60', 100000],
      });
      expect(config.reminderOffsetsMinutes, [30, 60, 1440]);
    });

    test('an empty offsets array degrades to the defaults', () {
      final config = AppointmentConfig.fromMap(const {
        'reminderOffsetsMinutes': <dynamic>[],
      });
      expect(
        config.reminderOffsetsMinutes,
        AppointmentDefaults.reminderOffsetsMinutes,
      );
    });

    test('toMap round-trips through fromMap', () {
      final config = AppointmentConfig.fromMap(const {'graceMinutes': 25});
      final back = AppointmentConfig.fromMap(config.toMap());
      expect(back.graceMinutes, 25);
      expect(back.reminderOffsetsMinutes, config.reminderOffsetsMinutes);
    });
  });
}
