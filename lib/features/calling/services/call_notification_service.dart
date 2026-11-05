// lib/features/calling/services/call_notification_service.dart

import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/core/services/fcm_token_service.dart';

class CallNotificationService {
  CallNotificationService._();
  static final CallNotificationService instance = CallNotificationService._();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FCMServiceV2 _fcmService = FCMServiceV2();

  /// Resolves device registration token for receiver from Firestore.
  Future<String?> resolveReceiverToken(
    String receiverId, {
    String? preferredRole,
  }) async {
    final cleanId = receiverId.trim();
    if (cleanId.isEmpty) return null;

    final collections = <String>[
      if (preferredRole == 'doctor') FirestoreCollections.doctors,
      if (preferredRole == 'patient') FirestoreCollections.patients,
      if (preferredRole != 'doctor') FirestoreCollections.doctors,
      if (preferredRole != 'patient') FirestoreCollections.patients,
    ];

    for (final collection in collections) {
      try {
        final doc = await _firestore.collection(collection).doc(cleanId).get();
        if (doc.exists && doc.data() != null) {
          final token = doc.data()!['fcmToken']?.toString().trim();
          if (token != null && token.isNotEmpty) {
            return token;
          }
        }
      } catch (e) {
        debugPrint(
          '⚠️ [CallNotificationService] Token lookup failed in $collection: $e',
        );
      }
    }
    return null;
  }

  /// Sends incoming voice call push notification to the recipient.
  Future<bool> sendIncomingCallPush({
    required String receiverToken,
    required String callId,
    required String roomId,
    required String callerId,
    required String callerName,
    required String callerRole,
    String? callerImage,
    required String receiverId,
    required String receiverRole,
    int ringTimeoutSeconds = 45,
  }) async {
    final expiresAt =
        DateTime.now().millisecondsSinceEpoch + (ringTimeoutSeconds * 1000);

    return await _fcmService.sendCallNotification(
      receiverToken: receiverToken,
      callerName: callerName,
      callType: 'audio',
      callId: callId,
      channelId: roomId,
      callerImage: callerImage,
      callerId: callerId,
      callerType: callerRole,
      receiverId: receiverId,
      receiverType: receiverRole,
      targetModule: 'opd_telemedicine',
      expiresAtMillis: expiresAt,
    );
  }

  /// Sends a missed call notification.
  Future<bool> sendMissedCallPush({
    required String receiverToken,
    required String callId,
    required String callerName,
    String? callerImage,
    String? callerId,
  }) async {
    return await _fcmService.sendMissedCallNotification(
      receiverToken: receiverToken,
      callerName: callerName,
      callType: 'audio',
      callId: callId,
      callerImage: callerImage,
      callerId: callerId,
    );
  }

  /// Sends a high-priority call cancellation push to stop the recipient's phone ringing immediately.
  Future<bool> sendCallCancelPush({
    required String receiverToken,
    required String callId,
  }) async {
    return await _fcmService.sendCallCancelNotification(
      receiverToken: receiverToken,
      callId: callId,
    );
  }
}

