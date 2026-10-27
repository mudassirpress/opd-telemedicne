import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/data/models/admin_notification_model.dart';
import 'package:telemedicine/data/models/patient_notification_model.dart';
import 'package:telemedicine/data/models/payment_complaint_model.dart';

final paymentComplaintServiceProvider = Provider<PaymentComplaintService>((ref) {
  return PaymentComplaintService();
});

/// Reactive stream of unread admin notifications count for top bar badge
final adminUnreadNotificationsCountProvider = StreamProvider.autoDispose<int>((ref) {
  final service = ref.watch(paymentComplaintServiceProvider);
  return service.streamUnreadNotificationsCount();
});

/// Reactive stream of admin notifications
final adminNotificationsStreamProvider =
    StreamProvider.autoDispose<List<AdminNotificationModel>>((ref) {
  final service = ref.watch(paymentComplaintServiceProvider);
  return service.streamAdminNotifications();
});

class PaymentComplaintService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  static const String complaintsCollection = 'payment_complaints';
  static const String notificationsCollection = 'admin_notifications';

  // In-flight guard to prevent duplicate rapid submissions from the same device
  final Set<String> _inFlightSubmissions = <String>{};

  /// Submits a new payment-related complaint from a patient.
  Future<PaymentComplaintModel> submitComplaint({
    required String patientUid,
    String? patientId,
    required String patientName,
    required String category,
    required String message,
    String? paymentId,
    String? appointmentId,
    required String paymentStatusAtSubmission,
  }) async {
    final cleanMessage = message.trim();
    if (cleanMessage.isEmpty) {
      throw ArgumentError('Complaint message cannot be empty');
    }

    final submissionKey = '$patientUid:${cleanMessage.hashCode}';
    if (_inFlightSubmissions.contains(submissionKey)) {
      throw StateError('A complaint submission is already in progress.');
    }
    _inFlightSubmissions.add(submissionKey);

    try {
      final docRef = _firestore.collection(complaintsCollection).doc();
      final complaintId = docRef.id;

      final complaintData = <String, dynamic>{
        'complaintId': complaintId,
        'patientUid': patientUid,
        if (patientId != null) 'patientId': patientId,
        'patientName': patientName,
        'category': category,
        'message': cleanMessage,
        if (paymentId != null) 'paymentId': paymentId,
        if (appointmentId != null) 'appointmentId': appointmentId,
        'paymentStatusAtSubmission': paymentStatusAtSubmission,
        'status': 'open',
        'adminResponse': null,
        'adminRespondedAt': null,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      };

      // Write complaint document
      await docRef.set(complaintData);

      // Create persistent admin notification record immediately in Firestore
      // (defense in depth alongside Cloud Function trigger)
      final notificationId = 'notif_$complaintId';
      final notificationRef =
          _firestore.collection(notificationsCollection).doc(notificationId);

      final truncatedMessage = cleanMessage.length > 80
          ? '${cleanMessage.substring(0, 77)}...'
          : cleanMessage;

      await notificationRef.set({
        'notificationId': notificationId,
        'type': 'payment_complaint',
        'title': 'New Patient Complaint',
        'body': '$patientName ($category): "$truncatedMessage"',
        'complaintId': complaintId,
        'patientUid': patientUid,
        if (patientId != null) 'patientId': patientId,
        'patientName': patientName,
        if (paymentId != null) 'paymentId': paymentId,
        if (appointmentId != null) 'appointmentId': appointmentId,
        'paymentStatus': paymentStatusAtSubmission,
        'category': category,
        'isRead': false,
        'createdAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      final now = DateTime.now();
      return PaymentComplaintModel(
        complaintId: complaintId,
        patientUid: patientUid,
        patientId: patientId,
        patientName: patientName,
        category: category,
        message: cleanMessage,
        paymentId: paymentId,
        appointmentId: appointmentId,
        paymentStatusAtSubmission: paymentStatusAtSubmission,
        status: 'open',
        createdAt: now,
        updatedAt: now,
      );
    } finally {
      _inFlightSubmissions.remove(submissionKey);
    }
  }

  /// Streams complaints filed by a specific patient.
  Stream<List<PaymentComplaintModel>> streamPatientComplaints(String patientUid) {
    if (patientUid.isEmpty) return Stream.value(const []);

    return _firestore
        .collection(complaintsCollection)
        .where('patientUid', isEqualTo: patientUid)
        .snapshots()
        .map((snapshot) {
      final list = snapshot.docs
          .map((doc) => PaymentComplaintModel.fromMap(doc.data(), doc.id))
          .toList();
      // Sort client-side by createdAt descending to avoid composite index requirement
      list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return list;
    });
  }

  /// Streams all complaints for admin portal.
  Stream<List<PaymentComplaintModel>> streamAllComplaints() {
    return _firestore
        .collection(complaintsCollection)
        .snapshots()
        .map((snapshot) {
      final list = snapshot.docs
          .map((doc) => PaymentComplaintModel.fromMap(doc.data(), doc.id))
          .toList();
      list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return list;
    });
  }

  /// Streams persistent admin notifications.
  Stream<List<AdminNotificationModel>> streamAdminNotifications() {
    return _firestore
        .collection(notificationsCollection)
        .snapshots()
        .map((snapshot) {
      final list = snapshot.docs
          .map((doc) => AdminNotificationModel.fromMap(doc.data(), doc.id))
          .toList();
      list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return list;
    });
  }

  /// Streams the count of unread admin notifications.
  Stream<int> streamUnreadNotificationsCount() {
    return _firestore
        .collection(notificationsCollection)
        .where('isRead', isEqualTo: false)
        .snapshots()
        .map((snapshot) => snapshot.docs.length);
  }

  /// Marks a specific admin notification as read.
  Future<void> markNotificationAsRead(String notificationId) async {
    if (notificationId.isEmpty) return;
    try {
      await _firestore
          .collection(notificationsCollection)
          .doc(notificationId)
          .update({'isRead': true});
    } catch (e) {
      // Ignore if document not found or error
    }
  }

  /// Fetches a specific complaint by ID.
  Future<PaymentComplaintModel?> getComplaintById(String complaintId) async {
    if (complaintId.isEmpty) return null;
    try {
      final doc =
          await _firestore.collection(complaintsCollection).doc(complaintId).get();
      if (!doc.exists || doc.data() == null) return null;
      return PaymentComplaintModel.fromMap(doc.data()!, doc.id);
    } catch (e) {
      return null;
    }
  }

  /// Admin action: updates complaint status and saves optional admin response.
  Future<void> updateComplaintStatus({
    required String complaintId,
    required String status,
    String? adminResponse,
  }) async {
    final updates = <String, dynamic>{
      'status': status,
      'updatedAt': FieldValue.serverTimestamp(),
    };

    final hasResponse = adminResponse != null && adminResponse.trim().isNotEmpty;
    if (hasResponse) {
      updates['adminResponse'] = adminResponse.trim();
      updates['adminRespondedAt'] = FieldValue.serverTimestamp();
    }

    await _firestore
        .collection(complaintsCollection)
        .doc(complaintId)
        .update(updates);

    if (hasResponse) {
      try {
        final complaint = await getComplaintById(complaintId);
        if (complaint != null && complaint.patientUid.isNotEmpty) {
          final replyPreview = adminResponse.trim().length > 90
              ? '${adminResponse.trim().substring(0, 87)}...'
              : adminResponse.trim();

          final notifId = 'notif_reply_$complaintId';
          await _firestore.collection('patient_notifications').doc(notifId).set({
            'notificationId': notifId,
            'recipientUid': complaint.patientUid,
            'type': 'complaint_reply',
            'title': 'Admin Replied to Your Complaint',
            'body': replyPreview,
            'senderName': 'OPD Telemedicine Admin',
            'complaintId': complaintId,
            if (complaint.paymentId != null) 'paymentId': complaint.paymentId,
            if (complaint.appointmentId != null) 'appointmentId': complaint.appointmentId,
            'isRead': false,
            'createdAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
        }
      } catch (e) {
        // Notification write failure must not revert complaint status update
      }
    }
  }

  /// Streams persistent notifications for a specific patient.
  Stream<List<PatientNotificationModel>> streamPatientNotifications(String recipientUid) {
    if (recipientUid.isEmpty) return Stream.value(const []);

    return _firestore
        .collection('patient_notifications')
        .where('recipientUid', isEqualTo: recipientUid)
        .snapshots()
        .map((snapshot) {
      final list = snapshot.docs
          .map((doc) => PatientNotificationModel.fromMap(doc.data(), doc.id))
          .toList();
      list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return list;
    });
  }

  /// Marks a specific patient notification as read.
  Future<void> markPatientNotificationAsRead(String notificationId) async {
    if (notificationId.isEmpty) return;
    try {
      await _firestore
          .collection('patient_notifications')
          .doc(notificationId)
          .update({'isRead': true});
    } catch (_) {}
  }
}

