import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:telemedicine/core/constants/app_constants.dart';

/// Clean, secure token-management service for Firebase Cloud Messaging (FCM).
///
/// Responsible ONLY for client-side device registration, token updates, and token
/// invalidation upon logout.
///
/// NOTE: Push notification dispatching is handled strictly server-side by
/// Firebase Cloud Functions (see `functions/index.js` and `notification_dispatcher.dart`).
/// Client-side privileged FCM HTTP sending and embedded service account credentials
/// have been permanently removed for security.
class FcmTokenService {
  static final FcmTokenService _instance = FcmTokenService._internal();
  factory FcmTokenService() => _instance;
  FcmTokenService._internal();

  FirebaseMessaging get _fcm => FirebaseMessaging.instance;
  FirebaseFirestore get _firestore => FirebaseFirestore.instance;

  Function(Map<String, dynamic>)? onCallReceived;
  Function(Map<String, dynamic>)? onMessageReceived;

  String? _cachedToken;
  StreamSubscription<String>? _tokenRefreshSub;

  /// Retrieves the current device FCM registration token.
  Future<String?> getToken() async {
    try {
      final token = await _fcm.getToken();
      if (token != null && token.isNotEmpty) {
        _cachedToken = token;
      }
      return token;
    } catch (e) {
      debugPrint('⚠️ [FCM] Error obtaining FCM registration token: $e');
      return _cachedToken;
    }
  }

  /// Persists this device's registration token to Firestore so that backend Cloud
  /// Functions can deliver notifications to the active device.
  ///
  /// Updates `telemedicine_doctors` or `telemedicine_patient` based on [userType].
  Future<void> updateToken(String userId, String userType) async {
    final cleanId = userId.trim();
    if (cleanId.isEmpty) {
      debugPrint('⚠️ [FCM] Cannot update token: empty userId');
      return;
    }

    try {
      final token = await getToken();
      if (token == null || token.trim().isEmpty) {
        debugPrint('⚠️ [FCM] No valid registration token available to update for $cleanId');
        return;
      }

      final collection = userType.toLowerCase() == 'doctor'
          ? FirestoreCollections.doctors
          : FirestoreCollections.patients;

      await _firestore.collection(collection).doc(cleanId).set({
        'fcmToken': token.trim(),
        'lastTokenUpdate': FieldValue.serverTimestamp(),
        'role': userType.toLowerCase(),
      }, SetOptions(merge: true));

      debugPrint('✅ [FCM] Token updated for $userType ($cleanId)');
    } catch (e, s) {
      debugPrint('❌ [FCM] Error updating token for $userType ($cleanId): $e\n$s');
    }
  }

  /// Removes the device token from Firestore upon explicit user logout.
  ///
  /// CRITICAL: Safely invalidates the token ONLY if the token on the user's
  /// document matches this device's token, preventing accidental erasure of a
  /// token that belongs to another active device.
  Future<void> deleteToken(String userId, String userType) async {
    final cleanId = userId.trim();
    if (cleanId.isEmpty) return;

    try {
      final currentToken = await getToken();
      final collection = userType.toLowerCase() == 'doctor'
          ? FirestoreCollections.doctors
          : FirestoreCollections.patients;

      final docRef = _firestore.collection(collection).doc(cleanId);
      final docSnap = await docRef.get();

      if (docSnap.exists) {
        final data = docSnap.data() ?? {};
        final storedToken = data['fcmToken'] as String?;

        // Only clear if the stored token matches this device's token, or if there is no token
        if (storedToken == null || storedToken.isEmpty || storedToken == currentToken) {
          await docRef.update({
            'fcmToken': FieldValue.delete(),
            'lastTokenClearedAt': FieldValue.serverTimestamp(),
          });
          debugPrint('🗑️ [FCM] Device token cleared on logout for $cleanId');
        } else {
          debugPrint(
            'ℹ️ [FCM] Device token not deleted on logout: token belongs to another active device session',
          );
        }
      }
    } catch (e) {
      debugPrint('⚠️ [FCM] Error clearing token on logout: $e');
    }
  }

  /// Listens to periodic FCM token rotations and persists the fresh token if a user session is active.
  void setupTokenRefreshListener({
    required Future<({String? userId, String? role})> Function() getActiveUser,
  }) {
    _tokenRefreshSub?.cancel();
    _tokenRefreshSub = _fcm.onTokenRefresh.listen((newToken) async {
      _cachedToken = newToken;
      debugPrint('🔁 [FCM] Token refreshed by platform');
      try {
        final activeUser = await getActiveUser();
        if (activeUser.userId != null && activeUser.userId!.isNotEmpty) {
          await updateToken(activeUser.userId!, activeUser.role ?? 'patient');
        }
      } catch (e) {
        debugPrint('⚠️ [FCM] Error updating refreshed token: $e');
      }
    });
  }

  /// Disposes active token listeners.
  void dispose() {
    _tokenRefreshSub?.cancel();
    _tokenRefreshSub = null;
  }
}

/// Backward compatibility alias
typedef FCMServiceV2 = FcmTokenService;
