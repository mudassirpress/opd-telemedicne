// notification_dispatcher.dart
//
// Client notification request dispatcher for the OPD Telemedicine app.
//
// Security Architecture Note:
// Services that push FCM require a Firebase Admin credential (service account key).
// In accordance with Google Cloud and Firebase security standards, private keys
// must NEVER be bundled in the Flutter mobile application (APK/AAB/IPA).
//
// With Node.js Cloud Functions removed, requests are queued in the Firestore
// `notification_outbox` collection. This provides an audit log and outbox queue
// for server-side delivery by a secure, trusted backend environment (such as
// Google Cloud Run, Cloud Tasks, or serverless event triggers).
//
// In-app notifications and real-time state synchronization for active users are
// handled directly via Firestore snapshot listeners in the Flutter client.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:telemedicine/core/constants/app_constants.dart';

/// Queues one push notification request into the Firestore outbox for server delivery.
///
/// [toUserId] is a user id, never a device token: the token is looked up on the
/// server so it is never handled by, or exposed to, the client.
class NotificationDispatcher {
  static final NotificationDispatcher _instance =
      NotificationDispatcher._internal();
  factory NotificationDispatcher() => _instance;
  NotificationDispatcher._internal();

  static const String _collection = 'notification_outbox';
  static const String _defaultChannel = 'general_notifications';

  /// Queues [request] and reports whether it was accepted for delivery.
  ///
  /// `true` means the outbox entry now exists and the Cloud Function will send
  /// it. It does NOT mean the push was delivered: there is no round-trip back
  /// from the function, by design. Callers that treat "false" as "retry later"
  /// still get that behaviour, because `false` is exactly the case where
  /// nothing was queued at all.
  Future<bool> _enqueue({
    required String toUserId,
    required String type,
    required String title,
    required String body,
    required Map<String, String> data,
    String channel = _defaultChannel,
  }) async {
    if (toUserId.trim().isEmpty) {
      debugPrint('⚠️ Notification not queued ($type): empty recipient id');
      return false;
    }

    try {
      await FirebaseFirestore.instance.collection(_collection).add({
        'toUserId': toUserId,
        'type': type,
        'title': title,
        'body': body,
        // FCM data payloads must be string→string.
        'data': <String, String>{
          'type': type,
          ...data,
          'click_action': 'FLUTTER_NOTIFICATION_CLICK',
        },
        'channel': channel,
        'status': 'queued',
        'createdAt': FieldValue.serverTimestamp(),
      });
      return true;
    } catch (e) {
      // Queueing must never be a user-visible failure: the underlying action
      // (approving a payment, confirming an appointment) has already succeeded.
      debugPrint('⚠️ Could not queue $type notification: $e');
      return false;
    }
  }

  // ── Payment decisions (admin → patient) ───────────────────────────────────

  Future<bool> sendPaymentApprovedNotification({
    required String toUserId,
    required String patientId,
    String paymentId = '',
    String notificationId = '',
  }) => _enqueue(
    toUserId: toUserId,
    type: FcmMessageType.paymentApproved,
    title: 'Payment Approved',
    body: 'Your payment has been approved. You can now access the app.',
    data: {
      'patientId': patientId,
      'paymentId': paymentId,
      'notificationId': notificationId,
    },
  );

  Future<bool> sendPaymentRejectedNotification({
    required String toUserId,
    required String patientId,
    String paymentId = '',
    String notificationId = '',
  }) => _enqueue(
    toUserId: toUserId,
    type: FcmMessageType.paymentRejected,
    title: 'Payment Rejected',
    body:
        'Your payment has been rejected. '
        'Please check your payment and submit again.',
    data: {
      'patientId': patientId,
      'paymentId': paymentId,
      'notificationId': notificationId,
    },
  );

  // ── Appointment payment decisions (admin → patient) ───────────────────────

  Future<bool> sendAppointmentPaymentApprovedNotification({
    required String toUserId,
    required String patientId,
    required String doctorName,
    String paymentId = '',
    String notificationId = '',
  }) => _enqueue(
    toUserId: toUserId,
    type: FcmMessageType.appointmentPaymentApproved,
    title: 'Payment Approved',
    body: 'Your appointment payment with Dr. $doctorName has been approved.',
    data: {
      'patientId': patientId,
      'doctorName': doctorName,
      'paymentId': paymentId,
      'notificationId': notificationId,
    },
  );

  Future<bool> sendAppointmentPaymentRejectedNotification({
    required String toUserId,
    required String patientId,
    required String doctorName,
    String paymentId = '',
    String notificationId = '',
  }) => _enqueue(
    toUserId: toUserId,
    type: FcmMessageType.appointmentPaymentRejected,
    title: 'Payment Rejected',
    body: 'Your appointment payment with Dr. $doctorName was rejected.',
    data: {
      'patientId': patientId,
      'doctorName': doctorName,
      'paymentId': paymentId,
      'notificationId': notificationId,
    },
  );

  // ── Shared reports (patient → doctor) ─────────────────────────────────────

  Future<bool> sendReportNotification({
    required String toUserId,
    required String patientId,
    required String patientName,
    required String reportId,
    required String reportName,
    required String doctorId,
    String? messageBody,
  }) => _enqueue(
    toUserId: toUserId,
    type: 'report_shared',
    title: patientName,
    body: messageBody ?? 'A patient has shared a medical report with you.',
    data: {
      'reportId': reportId,
      'reportName': reportName,
      'patientId': patientId,
      'patientName': patientName,
      'doctorId': doctorId,
    },
  );

  // ── Appointment payment submitted (patient → every admin) ────────────────

  /// Patient → every admin, once an appointment payment proof is submitted.
  Future<bool> sendAppointmentPaymentSubmittedNotification({
    required String toUserId,
    required String patientName,
    required String patientId,
    required String doctorName,
    required String amount,
    String paymentId = '',
    String notificationId = '',
  }) => _enqueue(
    toUserId: toUserId,
    type: FcmMessageType.appointmentPaymentSubmitted,
    title: 'Appointment Payment Submitted',
    body:
        '$patientName submitted payment for an appointment with '
        'Dr. $doctorName.',
    data: {
      'patientId': patientId,
      'patientName': patientName,
      'doctorName': doctorName,
      'amount': amount,
      'paymentId': paymentId,
      'notificationId': notificationId,
    },
  );

  // ── Appointment booking and lifecycle ─────────────────────────────────────

  /// Patient → the doctor they addressed the request to.
  Future<bool> sendNewAppointmentRequestNotification({
    required String toUserId,
    required String doctorId,
    required String patientName,
    required String patientId,
    String appointmentId = '',
    String notificationId = '',
  }) => _enqueue(
    toUserId: toUserId,
    type: FcmMessageType.newAppointmentRequest,
    title: 'New Appointment Request',
    body: '$patientName sent you an appointment request.',
    data: {
      'doctorId': doctorId,
      'patientId': patientId,
      'patientName': patientName,
      'appointmentId': appointmentId,
      'notificationId': notificationId,
    },
  );

  /// Doctor → patient, once the date/time is confirmed.
  Future<bool> sendAppointmentConfirmedNotification({
    required String toUserId,
    required String patientId,
    required String doctorName,
    required String date,
    required String time,
    String appointmentId = '',
    String notificationId = '',
  }) => _enqueue(
    toUserId: toUserId,
    type: FcmMessageType.appointmentConfirmed,
    title: 'Appointment Confirmed',
    body: 'Dr. $doctorName confirmed your appointment for $date at $time.',
    data: {
      'patientId': patientId,
      'doctorName': doctorName,
      'date': date,
      'time': time,
      'appointmentId': appointmentId,
      'notificationId': notificationId,
    },
  );

  /// The appointment reached its scheduled start → the recipient addressed
  /// here. The other side gets its own push with its own title/body but the
  /// same `notificationId`, so one appointment produces one alarm per device
  /// rather than two.
  ///
  /// `chatId` travels in the payload on purpose: the tap handler opens that
  /// exact conversation instead of parking the user in the Room Chat list.
  Future<bool> sendAppointmentStartNotification({
    required String toUserId,
    required String appointmentId,
    required String patientId,
    required String patientName,
    required String patientImage,
    required String doctorId,
    required String doctorName,
    required String doctorImage,
    required String chatId,
    required bool forPatient,
    required int scheduledStartAt,
    required String notificationId,
  }) {
    final counterpartName = forPatient ? 'Dr. $doctorName' : patientName;
    return _enqueue(
      toUserId: toUserId,
      type: FcmMessageType.appointmentStart,
      title: AppointmentDefaults.appointmentStartTitle,
      body: AppointmentDefaults.appointmentStartBody(counterpartName),
      data: {
        AppointmentPayloadKeys.appointmentId: appointmentId,
        AppointmentPayloadKeys.patientId: patientId,
        AppointmentPayloadKeys.patientName: patientName,
        AppointmentPayloadKeys.patientImage: patientImage,
        AppointmentPayloadKeys.doctorId: doctorId,
        AppointmentPayloadKeys.doctorName: doctorName,
        AppointmentPayloadKeys.doctorImage: doctorImage,
        AppointmentPayloadKeys.chatId: chatId,
        AppointmentPayloadKeys.scheduledStartAt: scheduledStartAt.toString(),
        AppointmentPayloadKeys.title: AppointmentDefaults.appointmentStartTitle,
        AppointmentPayloadKeys.body: AppointmentDefaults.appointmentStartBody(
          counterpartName,
        ),
        AppointmentPayloadKeys.notificationId: notificationId,
      },
    );
  }

  /// Every lifecycle push that is *not* the start alarm: reminder, joined,
  /// doctor-late, patient-late, grace-ending, cancelled, no-show, booking
  /// frozen.
  ///
  /// One method on purpose — the payload shape (`type`, the appointment ids,
  /// `chatId`, baked `title`/`body`, `notificationId`) is the cross-process
  /// contract with the receiver, and a single implementation is what keeps the
  /// routing table from drifting apart as types are added. [type] is a
  /// [FcmMessageType], [extra] carries the few keys that only some of them
  /// need (`offsetMinutes`, `minutes`, `noShowBy`, `warningCount`, …).
  Future<bool> sendAppointmentLifecycleNotification({
    required String toUserId,
    required String type,
    required String appointmentId,
    required String patientId,
    required String patientName,
    required String doctorId,
    required String doctorName,
    required String chatId,
    required String title,
    required String body,
    required String notificationId,
    Map<String, String> extra = const <String, String>{},
  }) => _enqueue(
    toUserId: toUserId,
    type: type,
    title: title,
    body: body,
    data: {
      AppointmentPayloadKeys.appointmentId: appointmentId,
      AppointmentPayloadKeys.patientId: patientId,
      AppointmentPayloadKeys.patientName: patientName,
      AppointmentPayloadKeys.doctorId: doctorId,
      AppointmentPayloadKeys.doctorName: doctorName,
      AppointmentPayloadKeys.chatId: chatId,
      AppointmentPayloadKeys.title: title,
      AppointmentPayloadKeys.body: body,
      AppointmentPayloadKeys.notificationId: notificationId,
      ...extra,
    },
  );
}
