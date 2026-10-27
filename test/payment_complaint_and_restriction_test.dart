import 'package:flutter_test/flutter_test.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/core/services/payment_complaint_visibility_service.dart';
import 'package:telemedicine/data/models/admin_notification_model.dart';
import 'package:telemedicine/data/models/patient_notification_model.dart';
import 'package:telemedicine/data/models/payment_complaint_model.dart';
import 'package:telemedicine/data/models/payment_model.dart';
import 'package:telemedicine/data/models/user_model.dart';
import 'package:telemedicine/core/services/auth_routing_service.dart';

void main() {
  group('PaymentComplaintModel tests', () {
    test('Serializes and deserializes properly', () {
      final now = DateTime(2026, 10, 25, 11, 0, 0);
      final complaint = PaymentComplaintModel(
        complaintId: 'comp_123',
        patientUid: 'uid_abc',
        patientId: 'PT-998877',
        patientName: 'Mudassir',
        category: 'Payment proof submitted but approval pending',
        message:
            'I submitted my payment proof but it has not been approved yet.',
        paymentId: 'pay_456',
        paymentStatusAtSubmission: 'pending',
        status: 'open',
        adminResponse: null,
        createdAt: now,
        updatedAt: now,
      );

      final map = complaint.toMap();
      expect(map['complaintId'], 'comp_123');
      expect(map['patientUid'], 'uid_abc');
      expect(map['patientId'], 'PT-998877');
      expect(map['patientName'], 'Mudassir');
      expect(map['category'], 'Payment proof submitted but approval pending');
      expect(
        map['message'],
        'I submitted my payment proof but it has not been approved yet.',
      );
      expect(map['paymentId'], 'pay_456');
      expect(map['paymentStatusAtSubmission'], 'pending');
      expect(map['status'], 'open');
      expect(map['adminResponse'], isNull);

      final parsed = PaymentComplaintModel.fromMap(map, 'comp_123');
      expect(parsed.complaintId, 'comp_123');
      expect(parsed.patientUid, 'uid_abc');
      expect(parsed.patientName, 'Mudassir');
      expect(parsed.status, 'open');
      expect(parsed.isOpen, isTrue);
      expect(parsed.isResolved, isFalse);

      final updated = parsed.copyWith(
        status: 'in_progress',
        adminResponse: 'Under review by finance team.',
      );
      expect(updated.status, 'in_progress');
      expect(updated.isInProgress, isTrue);
      expect(updated.adminResponse, 'Under review by finance team.');
    });
  });

  group('AdminNotificationModel tests', () {
    test('Serializes and deserializes properly', () {
      final now = DateTime(2026, 10, 25, 11, 5, 0);
      final notif = AdminNotificationModel(
        notificationId: 'notif_comp_123',
        type: 'payment_complaint',
        title: 'New Patient Complaint',
        body: 'Mudassir submitted a payment approval complaint',
        complaintId: 'comp_123',
        patientUid: 'uid_abc',
        patientId: 'PT-998877',
        patientName: 'Mudassir',
        paymentId: 'pay_456',
        paymentStatus: 'pending',
        category: 'Payment proof submitted but approval pending',
        isRead: false,
        createdAt: now,
      );

      final map = notif.toMap();
      expect(map['notificationId'], 'notif_comp_123');
      expect(map['type'], 'payment_complaint');
      expect(map['isRead'], isFalse);

      final parsed = AdminNotificationModel.fromMap(map, 'notif_comp_123');
      expect(parsed.isComplaint, isTrue);
      expect(parsed.isRead, isFalse);

      final readNotif = parsed.copyWith(isRead: true);
      expect(readNotif.isRead, isTrue);
    });
  });

  group('Patient Routing & Restricted Mode tests', () {
    test(
      'Unpaid or pending patient routes to PatientPortalWrapper with restricted access',
      () {
        final unpaidPatient = UserModel(
          id: 'patient_1',
          fullname: 'Unpaid Patient',
          deviceId: 'dev_1',
          idcard: '12345',
          password: 'pass',
          token: 'tok',
          role: 'patient',
          phoneNumber: '+923001234567',
          ispayment: false,
          totalPayment: 0.0,
          paymentStatus: 'not_submitted',
        );

        final destination = AuthRoutingService.evaluatePatientDestination(
          unpaidPatient,
        );
        // Destination must not force PaymentScreen repeatedly on start; routes to dashboard
        expect(destination, PatientAuthDestination.chatRoom);

        final pendingPatient = unpaidPatient.copyWith(paymentStatus: 'pending');
        final pendingDestination =
            AuthRoutingService.evaluatePatientDestination(pendingPatient);
        expect(pendingDestination, PatientAuthDestination.chatRoom);

        final rejectedPatient = unpaidPatient.copyWith(
          paymentStatus: 'rejected',
          rejectionReason: 'Blurry screenshot',
        );
        final rejectedDestination =
            AuthRoutingService.evaluatePatientDestination(rejectedPatient);
        expect(rejectedDestination, PatientAuthDestination.chatRoom);

        final approvedPatient = unpaidPatient.copyWith(
          ispayment: true,
          paymentStatus: 'approved',
        );
        final approvedDestination =
            AuthRoutingService.evaluatePatientDestination(approvedPatient);
        expect(approvedDestination, PatientAuthDestination.chatRoom);
      },
    );

    test(
      'Patient card user routes directly to Room Chat bypassing payment gate',
      () {
        final cardPatient = UserModel(
          id: 'patient_card',
          fullname: 'Card Patient',
          deviceId: 'dev_2',
          idcard: '54321',
          password: 'pass',
          token: 'tok',
          role: 'patient',
          phoneNumber: '+923007654321',
          ispayment: false,
          totalPayment: 0.0,
          loginType: 'patientId',
          patientId: 'PT-123456789012',
        );

        expect(cardPatient.isPatientCard, isTrue);
        final dest = AuthRoutingService.evaluatePatientDestination(cardPatient);
        expect(dest, PatientAuthDestination.chatRoom);
      },
    );
  });

  group('PaymentModel 3 Types tests', () {
    test('Type A: Account Activation payment model test', () {
      final now = DateTime(2026, 10, 25, 12, 0, 0);
      final payment = PaymentModel(
        paymentId: 'pay_act_001',
        patientUid: 'uid_act_001',
        patientId: 'PT-111111',
        patientName: 'Activation Patient',
        paymentType: PaymentType.accountActivation,
        amount: 300.0,
        currency: 'PKR',
        proofReference: 'https://cloudinary.com/proof_act.jpg',
        status: PaymentStatus.pending,
        createdAt: now,
        updatedAt: now,
      );

      final map = payment.toMap();
      expect(map['paymentType'], 'account_activation');
      expect(map['status'], 'pending');

      final parsed = PaymentModel.fromMap(map, 'pay_act_001');
      expect(parsed.paymentType, PaymentType.accountActivation);
      expect(parsed.isPending, isTrue);
      expect(parsed.isApproved, isFalse);
    });

    test('Type B: Account Reactivation payment model test', () {
      final now = DateTime(2026, 10, 25, 12, 5, 0);
      final payment = PaymentModel(
        paymentId: 'pay_react_002',
        patientUid: 'uid_react_002',
        patientId: 'PT-222222',
        patientName: 'Reactivation Patient',
        paymentType: PaymentType.accountReactivation,
        amount: 1000.0,
        currency: 'PKR',
        proofReference: 'https://cloudinary.com/proof_react.jpg',
        status: PaymentStatus.approved,
        createdAt: now,
        reviewedAt: now,
        reviewedBy: 'admin_master',
      );

      final map = payment.toMap();
      expect(map['paymentType'], 'account_reactivation');
      expect(map['status'], 'approved');

      final parsed = PaymentModel.fromMap(map, 'pay_react_002');
      expect(parsed.paymentType, PaymentType.accountReactivation);
      expect(parsed.isApproved, isTrue);
    });

    test('Type C: Appointment Booking payment model test', () {
      final now = DateTime(2026, 10, 25, 12, 10, 0);
      final payment = PaymentModel(
        paymentId: 'pay_appt_003',
        patientUid: 'uid_appt_003',
        patientId: 'PT-333333',
        patientName: 'Booking Patient',
        paymentType: PaymentType.appointmentBooking,
        amount: 1500.0,
        currency: 'PKR',
        proofReference: 'https://cloudinary.com/proof_appt.jpg',
        status: PaymentStatus.pending,
        relatedAppointmentId: 'appt_999',
        doctorId: 'doc_555',
        doctorName: 'Dr. Ayesha',
        createdAt: now,
        updatedAt: now,
      );

      final map = payment.toMap();
      expect(map['paymentType'], 'appointment_booking');
      expect(map['relatedAppointmentId'], 'appt_999');
      expect(map['doctorId'], 'doc_555');
      expect(map['doctorName'], 'Dr. Ayesha');

      final parsed = PaymentModel.fromMap(map, 'pay_appt_003');
      expect(parsed.paymentType, PaymentType.appointmentBooking);
      expect(parsed.relatedAppointmentId, 'appt_999');
      expect(parsed.doctorName, 'Dr. Ayesha');
    });
  });

  group('PatientNotificationModel tests', () {
    test('Serializes and deserializes patient notification properly', () {
      final now = DateTime(2026, 10, 25, 12, 15, 0);
      final notif = PatientNotificationModel(
        notificationId: 'pnotif_001',
        recipientUid: 'uid_pat_001',
        type: 'payment_approved',
        title: 'Account Activation Approved',
        body: 'Your account activation payment has been approved.',
        senderName: 'OPD Telemedicine Admin',
        paymentId: 'pay_act_001',
        paymentType: 'account_activation',
        isRead: false,
        createdAt: now,
      );

      final map = notif.toMap();
      expect(map['notificationId'], 'pnotif_001');
      expect(map['type'], 'payment_approved');
      expect(map['isRead'], isFalse);

      final parsed = PatientNotificationModel.fromMap(map, 'pnotif_001');
      expect(parsed.notificationId, 'pnotif_001');
      expect(parsed.recipientUid, 'uid_pat_001');
      expect(parsed.title, 'Account Activation Approved');
      expect(parsed.isRead, isFalse);

      final updated = parsed.copyWith(isRead: true);
      expect(updated.isRead, isTrue);
    });
  });

  group('PaymentComplaintVisibility tests', () {
    test('Shows complaint button when payment is pending', () {
      final user = UserModel(
        id: 'pat_pending',
        fullname: 'Pending Patient',
        deviceId: 'd1',
        idcard: 'c1',
        password: 'p1',
        token: 't1',
        role: 'patient',
        phoneNumber: '+923001111111',
        ispayment: false,
        totalPayment: 300.0,
        paymentStatus: 'pending',
      );

      expect(PaymentComplaintVisibility.shouldShow(user), isTrue);
      expect(
        PaymentComplaintVisibility.isAccountPaymentApprovedAndValid(user),
        isFalse,
      );
    });

    test('Shows complaint button when payment is rejected', () {
      final user = UserModel(
        id: 'pat_rejected',
        fullname: 'Rejected Patient',
        deviceId: 'd2',
        idcard: 'c2',
        password: 'p2',
        token: 't2',
        role: 'patient',
        phoneNumber: '+923002222222',
        ispayment: false,
        totalPayment: 300.0,
        paymentStatus: 'rejected',
        rejectionReason: 'Invalid screenshot',
      );

      expect(PaymentComplaintVisibility.shouldShow(user), isTrue);
      expect(
        PaymentComplaintVisibility.isAccountPaymentApprovedAndValid(user),
        isFalse,
      );
    });

    test('Shows complaint button when payment has not been submitted yet', () {
      final user = UserModel(
        id: 'pat_unsubmitted',
        fullname: 'Unsubmitted Patient',
        deviceId: 'd3',
        idcard: 'c3',
        password: 'p3',
        token: 't3',
        role: 'patient',
        phoneNumber: '+923003333333',
        ispayment: false,
        totalPayment: 0.0,
        paymentStatus: null,
      );

      expect(PaymentComplaintVisibility.shouldShow(user), isTrue);
      expect(
        PaymentComplaintVisibility.isAccountPaymentApprovedAndValid(user),
        isFalse,
      );
    });

    test(
      'Hides complaint button when payment is approved and account is valid',
      () {
        final user = UserModel(
          id: 'pat_approved',
          fullname: 'Approved Patient',
          deviceId: 'd4',
          idcard: 'c4',
          password: 'p4',
          token: 't4',
          role: 'patient',
          phoneNumber: '+923004444444',
          ispayment: true,
          totalPayment: 300.0,
          paymentStatus: 'approved',
          expiryDate: DateTime.now().add(const Duration(days: 30)),
        );

        expect(PaymentComplaintVisibility.shouldShow(user), isFalse);
        expect(
          PaymentComplaintVisibility.isAccountPaymentApprovedAndValid(user),
          isTrue,
        );
      },
    );

    test('Shows complaint button again when account validity expires', () {
      final user = UserModel(
        id: 'pat_expired',
        fullname: 'Expired Patient',
        deviceId: 'd5',
        idcard: 'c5',
        password: 'p5',
        token: 't5',
        role: 'patient',
        phoneNumber: '+923005555555',
        ispayment: true,
        totalPayment: 300.0,
        paymentStatus: 'approved',
        expiryDate: DateTime.now().subtract(const Duration(days: 2)),
      );

      expect(user.isExpired, isTrue);
      // Even though payment was approved in the past, validity expired -> complaint button must show!
      expect(PaymentComplaintVisibility.shouldShow(user), isTrue);
      expect(
        PaymentComplaintVisibility.isAccountPaymentApprovedAndValid(user),
        isFalse,
      );
    });

    test('Hides complaint button for active valid Patient ID (Card) user', () {
      final user = UserModel(
        id: 'pat_card_active',
        fullname: 'Card Active Patient',
        deviceId: 'd6',
        idcard: 'c6',
        password: 'p6',
        token: 't6',
        role: 'patient',
        phoneNumber: '+923006666666',
        ispayment: false,
        totalPayment: 0.0,
        loginType: 'patientId',
        patientId: 'PT-999888777666',
        expiryDate: DateTime.now().add(const Duration(days: 60)),
      );

      expect(user.isPatientCard, isTrue);
      expect(user.isExpired, isFalse);
      expect(PaymentComplaintVisibility.shouldShow(user), isFalse);
    });

    test(
      'Shows complaint button for expired Patient ID user needing reactivation',
      () {
        final user = UserModel(
          id: 'pat_card_expired',
          fullname: 'Card Expired Patient',
          deviceId: 'd7',
          idcard: 'c7',
          password: 'p7',
          token: 't7',
          role: 'patient',
          phoneNumber: '+923007777777',
          ispayment: false,
          totalPayment: 0.0,
          loginType: 'patientId',
          patientId: 'PT-111222333444',
          expiryDate: DateTime.now().subtract(const Duration(days: 5)),
        );

        expect(user.isExpired, isTrue);
        expect(PaymentComplaintVisibility.shouldShow(user), isTrue);
      },
    );

    test('Hides complaint button for doctors and guests', () {
      final doctor = UserModel(
        id: 'doc_1',
        fullname: 'Dr. Test',
        deviceId: 'd8',
        idcard: 'c8',
        password: 'p8',
        token: 't8',
        role: 'doctor',
        phoneNumber: '+923008888888',
        ispayment: false,
        totalPayment: 0.0,
      );
      expect(PaymentComplaintVisibility.shouldShow(doctor), isFalse);

      final guest = UserModel.guest();
      expect(PaymentComplaintVisibility.shouldShow(guest), isFalse);
    });
  });
}
