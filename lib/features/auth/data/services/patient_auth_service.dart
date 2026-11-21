import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/core/services/device_service.dart';
import 'package:telemedicine/core/services/notification_service.dart';
import 'package:telemedicine/core/services/single_device_session_service.dart';
import 'package:telemedicine/core/services/timezone_service.dart';
import 'package:telemedicine/data/models/user_model.dart';
import 'package:telemedicine/features/chat/presentation/controllers/chat_controller.dart';

/// Result returned from Patient Card ID authentication.
class PatientCardAuthResult {
  final bool success;
  final UserModel? user;
  final String? errorMessage;
  final bool isProfileComplete;

  const PatientCardAuthResult({
    required this.success,
    this.user,
    this.errorMessage,
    this.isProfileComplete = true,
  });
}

/// Authentication service managing Patient Card ID lookup, validation,
/// session initialization, and local state persistence.
class PatientAuthService {
  PatientAuthService._();
  static final PatientAuthService instance = PatientAuthService._();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Looks up a patient by their Patient Card ID / MRN, creates or updates their session,
  /// persists their credentials locally, and returns the authenticated [UserModel].
  Future<PatientCardAuthResult> signInWithPatientCardId(String enteredCardId) async {
    final cleanId = enteredCardId.trim();
    if (cleanId.isEmpty) {
      return const PatientCardAuthResult(
        success: false,
        errorMessage: 'Please enter your Patient Card ID.',
      );
    }

    try {
      debugPrint('🔍 [PatientAuthService] Looking up Patient Card ID: $cleanId');

      // Candidate collections to inspect ('telemedicine_patient' is the app's canonical FirestoreCollections.patients)
      final collectionsToSearch = <String>{
        FirestoreCollections.patients,
        'patients',
      };

      DocumentSnapshot<Map<String, dynamic>>? patientDoc;
      String? matchedCollection;

      // 1. Direct query on patients collection by patientCardId and patientId fields
      for (final collection in collectionsToSearch) {
        // Query by patientCardId
        var querySnap = await _firestore
            .collection(collection)
            .where('patientCardId', isEqualTo: cleanId)
            .limit(1)
            .get();

        if (querySnap.docs.isEmpty && cleanId.toUpperCase() != cleanId) {
          querySnap = await _firestore
              .collection(collection)
              .where('patientCardId', isEqualTo: cleanId.toUpperCase())
              .limit(1)
              .get();
        }

        // Query by patientId (existing card ID field)
        if (querySnap.docs.isEmpty) {
          querySnap = await _firestore
              .collection(collection)
              .where('patientId', isEqualTo: cleanId)
              .limit(1)
              .get();
        }

        if (querySnap.docs.isEmpty && cleanId.toUpperCase() != cleanId) {
          querySnap = await _firestore
              .collection(collection)
              .where('patientId', isEqualTo: cleanId.toUpperCase())
              .limit(1)
              .get();
        }

        // Query by cardId field if present
        if (querySnap.docs.isEmpty) {
          querySnap = await _firestore
              .collection(collection)
              .where('cardId', isEqualTo: cleanId)
              .limit(1)
              .get();
        }

        if (querySnap.docs.isNotEmpty) {
          patientDoc = querySnap.docs.first;
          matchedCollection = collection;
          break;
        }

        // Check if entered card ID is the direct document ID
        try {
          final directDoc = await _firestore.collection(collection).doc(cleanId).get();
          if (directDoc.exists) {
            patientDoc = directDoc;
            matchedCollection = collection;
            break;
          }
        } catch (_) {}
      }

      // 2. Fallback: Check if ID exists in patient_ids inventory and links to a patient user
      if (patientDoc == null) {
        final cardSnap = await _firestore
            .collection(FirestoreCollections.patientIds)
            .where('patientId', isEqualTo: cleanId)
            .limit(1)
            .get();

        if (cardSnap.docs.isNotEmpty) {
          final cardData = cardSnap.docs.first.data();
          final patientUserId = cardData['patientUserId'] as String?;

          if (patientUserId != null && patientUserId.isNotEmpty) {
            for (final collection in collectionsToSearch) {
              final userDoc = await _firestore.collection(collection).doc(patientUserId).get();
              if (userDoc.exists) {
                patientDoc = userDoc;
                matchedCollection = collection;
                break;
              }
            }
          }
        }
      }

      // If no matching patient document was found
      if (patientDoc == null || !patientDoc.exists) {
        debugPrint('⚠️ [PatientAuthService] No patient found for card ID: $cleanId');
        return const PatientCardAuthResult(
          success: false,
          errorMessage:
              'Invalid Patient Card ID. Please verify your hospital card or contact reception.',
        );
      }

      final userData = patientDoc.data() ?? {};
      final targetCollection = matchedCollection ?? FirestoreCollections.patients;

      // 3. Status and Deletion checks
      if (userData['isDeleted'] == true) {
        return const PatientCardAuthResult(
          success: false,
          errorMessage: 'This account has been deleted. Please contact support.',
        );
      }

      final accountStatus = (userData['accountStatus'] ?? '').toString().toLowerCase();
      if (accountStatus == 'blocked' || accountStatus == 'frozen') {
        return const PatientCardAuthResult(
          success: false,
          errorMessage:
              'Your account has been suspended or frozen. Please contact reception.',
        );
      }

      final cardStatus = (userData['cardStatus'] ?? '').toString().toLowerCase();
      if (cardStatus == 'blocked' || cardStatus == 'revoked') {
        return const PatientCardAuthResult(
          success: false,
          errorMessage:
              'This Patient Card has been blocked or revoked. Please contact reception.',
        );
      }

      // 4. Single-Device Session Claim
      final currentDeviceId = await DeviceService.getDeviceId();
      final claimResult = await SingleDeviceSessionService.validateAndClaimSession(
        collectionName: targetCollection,
        documentId: patientDoc.id,
        currentDeviceId: currentDeviceId,
        blockSecondLogin: false, // takeover session for valid card holder
      );

      if (!claimResult.allowed) {
        return PatientCardAuthResult(
          success: false,
          errorMessage: claimResult.errorMessage ??
              'This account is locked to another device. Please contact support.',
        );
      }

      // 5. Fetch Session Details & Update Firestore Document
      final newToken = DateTime.now().millisecondsSinceEpoch.toString();
      String? fcmToken;
      try {
        fcmToken = await NotificationService().getToken();
      } catch (_) {}

      final updatePayload = <String, dynamic>{
        'token': newToken,
        'deviceId': currentDeviceId,
        'activeDeviceId': currentDeviceId,
        'isLoggedIn': true,
        'lastLoginAt': FieldValue.serverTimestamp(),
        if (fcmToken != null && fcmToken.isNotEmpty) 'fcmToken': fcmToken,
      };

      await patientDoc.reference.update(updatePayload);

      // 6. Build the UserModel
      final user = UserModel.fromMap({
        ...userData,
        'id': patientDoc.id,
        'deviceId': currentDeviceId,
        'token': newToken,
        'patientId': userData['patientId'] ?? cleanId,
        'patientCardId': userData['patientCardId'] ?? cleanId,
        'loginType': 'patientCardId',
        'ispayment': userData['ispayment'] ?? true, // Patient Card holders have prepaid membership
        'paymentStatus': userData['paymentStatus'] ?? 'approved',
        'role': userData['role'] ?? 'patient',
        if (fcmToken != null && fcmToken.isNotEmpty) 'fcmToken': fcmToken,
      });

      // 7. Persist the Login State Locally
      await persistLocalSession(user);

      // 8. Presence Tracking & Notifications
      try {
        await patientDoc.reference.update({
          'isOnline': true,
          'lastHeartbeat': FieldValue.serverTimestamp(),
        });
      } catch (_) {}

      if (fcmToken != null && fcmToken.isNotEmpty) {
        try {
          await NotificationService().saveTokenToFirestore(user.id, user.role);
        } catch (_) {}
      }

      debugPrint('✅ [PatientAuthService] Patient successfully authenticated: ${user.fullname} (${user.id})');

      return PatientCardAuthResult(
        success: true,
        user: user,
        isProfileComplete: user.fullname.trim().isNotEmpty,
      );
    } catch (e, st) {
      debugPrint('❌ [PatientAuthService] Authentication error: $e\n$st');
      return PatientCardAuthResult(
        success: false,
        errorMessage: 'An unexpected error occurred during card authentication. Please try again.',
      );
    }
  }

  /// Persists the authenticated patient's session into local storage (SharedPreferences).
  Future<void> persistLocalSession(UserModel user) async {
    try {
      if (user.id.isEmpty) return;
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('current_doctor');
      await prefs.setString('current_user', json.encode(user.toMap()));

      // Background cache recoveries
      unawaited(ChatController().recoverChatListIfNeeded());
      unawaited(
        TimezoneService.syncUserTimezone(
          collectionName: 'telemedicine_patient',
          documentId: user.id,
        ),
      );
      debugPrint('💾 [PatientAuthService] Local session persisted for UID: ${user.id}');
    } catch (e) {
      debugPrint('⚠️ [PatientAuthService] Failed to persist local session: $e');
    }
  }

  /// Clears the locally stored patient session.
  Future<void> clearLocalSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('current_user');
      debugPrint('🗑️ [PatientAuthService] Local session cleared');
    } catch (e) {
      debugPrint('⚠️ [PatientAuthService] Failed to clear local session: $e');
    }
  }
}

