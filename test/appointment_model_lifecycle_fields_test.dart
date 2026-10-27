import 'package:flutter_test/flutter_test.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/data/models/appointment_model.dart';

/// A document exactly as this feature found it: every new key absent.
Map<String, dynamic> legacyDocument() => const {
  'patientId': 'p1',
  'patientName': 'Sara',
  'doctorId': 'd1',
  'doctorName': 'Amina',
  'appointmentStatus': AppointmentStatus.confirmed,
  'scheduledDate': '2026-10-05',
  'scheduledStartTime': '10:00 AM',
  'scheduledEndTime': '10:30 AM',
};

void main() {
  group('appointment status contract', () {
    test('no-show is terminal and releases the pair', () {
      expect(AppointmentStatus.isTerminal(AppointmentStatus.noShow), isTrue);
      expect(AppointmentStatus.isOpen(AppointmentStatus.noShow), isFalse);
      expect(AppointmentStatus.all, contains(AppointmentStatus.noShow));
    });

    test('the open set is untouched by this feature', () {
      expect(AppointmentStatus.open, {
        AppointmentStatus.requested,
        AppointmentStatus.confirmed,
        AppointmentStatus.active,
      }, reason: 'functions/index.js and the booking guard both depend on it');
    });

    test(
      'every lifecycle push type routes through the appointment handler',
      () {
        const types = <String>[
          FcmMessageType.appointmentPaymentSubmitted,
          FcmMessageType.appointmentPaymentApproved,
          FcmMessageType.appointmentPaymentRejected,
          FcmMessageType.newAppointmentRequest,
          FcmMessageType.appointmentConfirmed,
          FcmMessageType.appointmentStart,
          FcmMessageType.appointmentReminder,
          FcmMessageType.appointmentJoined,
          FcmMessageType.appointmentDoctorLate,
          FcmMessageType.appointmentPatientLate,
          FcmMessageType.appointmentGraceEnding,
          FcmMessageType.appointmentCancelled,
          FcmMessageType.appointmentNoShow,
        ];
        for (final type in types) {
          expect(FcmMessageType.isAppointment(type), isTrue, reason: type);
        }
        expect(FcmMessageType.isAppointment(FcmMessageType.call), isFalse);
        expect(
          FcmMessageType.isAppointment(FcmMessageType.chatMessage),
          isFalse,
        );
      },
    );
  });

  group('backward compatibility', () {
    test('a pre-existing document reads every new field as neutral', () {
      final appointment = AppointmentModel.fromMap('a1', legacyDocument());

      expect(appointment.appointmentPhase, '');
      expect(appointment.patientJoinedAt, isNull);
      expect(appointment.doctorJoinedAt, isNull);
      expect(appointment.hasPatientJoined, isFalse);
      expect(appointment.hasDoctorJoined, isFalse);
      expect(appointment.bothJoined, isFalse);
      expect(appointment.isNoShow, isFalse);
      expect(appointment.isCancelled, isFalse);
      expect(appointment.cancelledBy, '');
      expect(appointment.noShowBy, '');
      expect(appointment.reminderSent, isEmpty);
      expect(appointment.doctorLateNoticeSent, isFalse);
      expect(appointment.graceNoticeSent, isFalse);
      expect(appointment.hasLivePhase, isFalse);
    });

    test('the legacy three reminder booleans are still honoured', () {
      final appointment = AppointmentModel.fromMap('a1', {
        ...legacyDocument(),
        'reminder24hSent': true,
      });
      expect(appointment.reminderSentFor(1440), isTrue);
      expect(appointment.reminderSentFor(60), isFalse);
      expect(appointment.reminderSentFor(10), isFalse);
    });

    test('the offset-keyed map is honoured alongside the legacy keys', () {
      final appointment = AppointmentModel.fromMap('a1', {
        ...legacyDocument(),
        'reminderSent': {'60': true, '30': true},
      });
      expect(appointment.reminderSentFor(60), isTrue);
      expect(appointment.reminderSentFor(30), isTrue);
      expect(appointment.reminderSentFor(1440), isFalse);
      expect(appointment.reminderSentFor(10), isFalse);
    });

    test('a malformed reminder map reads as nothing claimed', () {
      final appointment = AppointmentModel.fromMap('a1', {
        ...legacyDocument(),
        'reminderSent': 'nope',
      });
      expect(appointment.reminderSent, isEmpty);
      expect(appointment.reminderSentFor(60), isFalse);
    });
  });

  group('toMap round trip', () {
    test('every lifecycle field survives the write/read cycle', () {
      final joined = DateTime(2026, 10, 5, 10, 3);
      final base = AppointmentModel.fromMap('a1', legacyDocument());
      final written = base.copyWithLifecycle(
        appointmentPhase: AppointmentPhase.doctorLate,
        patientJoinedAt: joined,
        doctorJoinedAt: null,
        cancelledBy: AppointmentActors.patient,
        cancelReason: 'Plans changed',
        cancelledAt: joined,
        noShowBy: AppointmentNoShowBy.doctor,
        noShowAt: joined,
        completedAt: joined,
        reminderSent: const {'1440': true},
        doctorLateNoticeSent: true,
      );

      final back = AppointmentModel.fromMap('a1', written.toMap());

      expect(back.appointmentPhase, AppointmentPhase.doctorLate);
      expect(back.patientJoinedAt, joined);
      expect(back.doctorJoinedAt, isNull);
      expect(back.cancelledBy, AppointmentActors.patient);
      expect(back.cancelReason, 'Plans changed');
      expect(back.cancelledAt, joined);
      expect(back.noShowBy, AppointmentNoShowBy.doctor);
      expect(back.noShowAt, joined);
      expect(back.completedAt, joined);
      expect(back.reminderSent, {'1440': true});
      expect(back.doctorLateNoticeSent, isTrue);
      expect(back.patientLateNoticeSent, isFalse);
    });

    test('an untouched model writes none of the new keys', () {
      final map = AppointmentModel.fromMap('a1', legacyDocument()).toMap();
      expect(map.containsKey('patientJoinedAt'), isFalse);
      expect(map.containsKey('cancelledBy'), isFalse);
      expect(map.containsKey('noShowBy'), isFalse);
      expect(map.containsKey('completedAt'), isFalse);
      expect(map.containsKey('reminderSent'), isFalse);
      expect(map.containsKey('doctorLateNoticeSent'), isFalse);
      expect(map['appointmentPhase'], '');
    });

    test('claim flags are only written once they are true', () {
      final map = AppointmentModel.fromMap('a1', {
        ...legacyDocument(),
        'reminderSent': {'60': true},
        'graceNoticeSent': true,
      }).toMap();
      expect(map['reminderSent'], {'60': true});
      expect(map['graceNoticeSent'], isTrue);
      expect(map.containsKey('doctorLateNoticeSent'), isFalse);
    });
  });

  group('predicates', () {
    test('a no-show record is terminal everywhere it matters', () {
      final appointment = AppointmentModel.fromMap('a1', {
        ...legacyDocument(),
        'appointmentStatus': AppointmentStatus.noShow,
        'noShowBy': AppointmentNoShowBy.doctor,
        'appointmentPhase': AppointmentPhase.closed,
      });
      expect(appointment.isNoShow, isTrue);
      expect(appointment.isConfirmed, isFalse);
      expect(AppointmentStatus.isOpen(appointment.appointmentStatus), isFalse);
      expect(appointment.hasLivePhase, isFalse);
    });

    test('a live phase is recognised on an open appointment', () {
      final appointment = AppointmentModel.fromMap('a1', {
        ...legacyDocument(),
        'appointmentPhase': AppointmentPhase.inProgress,
      });
      expect(appointment.hasLivePhase, isTrue);
    });
  });
}

extension on AppointmentModel {
  /// `copyWith` for exactly the lifecycle fields, so a test can describe the
  /// state it is about to serialise without repeating the whole record.
  AppointmentModel copyWithLifecycle({
    String? appointmentPhase,
    DateTime? patientJoinedAt,
    DateTime? doctorJoinedAt,
    String? cancelledBy,
    String? cancelReason,
    DateTime? cancelledAt,
    String? noShowBy,
    DateTime? noShowAt,
    DateTime? completedAt,
    Map<String, bool>? reminderSent,
    bool? doctorLateNoticeSent,
    bool? patientLateNoticeSent,
    bool? graceNoticeSent,
  }) => AppointmentModel(
    id: id,
    patientId: patientId,
    patientName: patientName,
    patientImage: patientImage,
    doctorId: doctorId,
    doctorName: doctorName,
    doctorImage: doctorImage,
    doctorSpecialization: doctorSpecialization,
    subject: subject,
    message: message,
    price: price,
    consultationFee: consultationFee,
    discountPercentage: discountPercentage,
    discountAmount: discountAmount,
    payableAmount: payableAmount,
    videoWatched: videoWatched,
    youtubeVideoUrl: youtubeVideoUrl,
    paymentId: paymentId,
    paymentStatus: paymentStatus,
    appointmentStatus: appointmentStatus,
    requestedAt: requestedAt,
    confirmedAt: confirmedAt,
    createdAt: createdAt,
    updatedAt: updatedAt,
    scheduledDate: scheduledDate,
    scheduledStartTime: scheduledStartTime,
    scheduledEndTime: scheduledEndTime,
    scheduledStartAt: scheduledStartAt,
    scheduledEndAt: scheduledEndAt,
    appointmentStartNotificationSent: appointmentStartNotificationSent,
    doctorResponse: doctorResponse,
    pinnedMessageId: pinnedMessageId,
    appointmentPhase: appointmentPhase ?? this.appointmentPhase,
    patientJoinedAt: patientJoinedAt ?? this.patientJoinedAt,
    doctorJoinedAt: doctorJoinedAt ?? this.doctorJoinedAt,
    cancelledBy: cancelledBy ?? this.cancelledBy,
    cancelReason: cancelReason ?? this.cancelReason,
    cancelledAt: cancelledAt ?? this.cancelledAt,
    noShowBy: noShowBy ?? this.noShowBy,
    noShowAt: noShowAt ?? this.noShowAt,
    completedAt: completedAt ?? this.completedAt,
    reminderSent: reminderSent ?? this.reminderSent,
    reminder24hSent: reminder24hSent,
    reminder60mSent: reminder60mSent,
    reminder10mSent: reminder10mSent,
    doctorLateNoticeSent: doctorLateNoticeSent ?? this.doctorLateNoticeSent,
    patientLateNoticeSent: patientLateNoticeSent ?? this.patientLateNoticeSent,
    graceNoticeSent: graceNoticeSent ?? this.graceNoticeSent,
  );
}
