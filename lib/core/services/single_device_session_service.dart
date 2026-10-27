import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:telemedicine/features/auth/presentation/screens/sign_in_screen.dart';
import 'package:telemedicine/core/services/device_service.dart';
import 'package:telemedicine/features/auth/data/services/phone_auth_service.dart';

/// Service enforcing strict single-device login per account.
///
/// Ensures an account can only be active on one mobile device at any time.
/// If user A logs in on Device 2, Device 1 is automatically signed out in real-time.
class SingleDeviceSessionService {
  SingleDeviceSessionService._();
  static final SingleDeviceSessionService instance =
      SingleDeviceSessionService._();

  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Retrieves the persistent hardware/installation device ID.
  static Future<String> getDeviceId() async {
    return await DeviceService.getDeviceId();
  }

  /// Validates whether the account is currently logged in on another device.
  ///
  /// - If [blockSecondLogin] is true (default):
  ///   Rejects login if `isLoggedIn == true` and `activeDeviceId` does not match [currentDeviceId].
  /// - If [blockSecondLogin] is false:
  /// Validates whether the account is currently logged in on another device.
  ///
  /// - If [blockSecondLogin] is true (default):
  ///   Rejects login if `isLoggedIn == true` and `activeDeviceId` does not match [currentDeviceId].
  /// - If [blockSecondLogin] is false:
  ///   Allows login and updates `activeDeviceId`, which invalidates Device 1.
  ///
  /// Uses a Firestore transaction for atomic, concurrency-safe session claiming.
  /// Returns a record with `allowed` and an optional `errorMessage`.
  static Future<({bool allowed, String? errorMessage})>
  validateAndClaimSession({
    required String collectionName,
    required String documentId,
    required String currentDeviceId,
    bool blockSecondLogin = true,
  }) async {
    if (documentId.trim().isEmpty) {
      return (allowed: false, errorMessage: 'Invalid user document ID.');
    }

    try {
      final docRef = _firestore
          .collection(collectionName)
          .doc(documentId.trim());

      return await _firestore.runTransaction<
        ({bool allowed, String? errorMessage})
      >((transaction) async {
        final docSnap = await transaction.get(docRef);

        if (!docSnap.exists) {
          return (allowed: false, errorMessage: 'Account record not found.');
        }

        final data = docSnap.data() ?? {};
        final bool isLoggedIn = data['isLoggedIn'] == true;
        final String? activeDeviceId = data['activeDeviceId'] as String?;

        // Check if another DIFFERENT device is currently active
        if (blockSecondLogin &&
            isLoggedIn &&
            activeDeviceId != null &&
            activeDeviceId.isNotEmpty &&
            activeDeviceId != currentDeviceId &&
            DeviceService.isValidInstallationId(activeDeviceId)) {
          debugPrint(
            '🔒 [SingleDeviceSession] Second login rejected: active on $activeDeviceId (current: $currentDeviceId)',
          );
          return (
            allowed: false,
            errorMessage:
                'This account is already active on another device. Please logout first.',
          );
        }

        // Atomically claim session on this device
        transaction.update(docRef, {
          'activeDeviceId': currentDeviceId,
          'deviceId': currentDeviceId,
          'isLoggedIn': true,
          'lastLoginAt': FieldValue.serverTimestamp(),
        });

        debugPrint(
          '✅ [SingleDeviceSession] Session claimed successfully for $documentId on $currentDeviceId',
        );
        return (allowed: true, errorMessage: null);
      });
    } catch (e) {
      debugPrint('❌ [SingleDeviceSession] Error claiming session: $e');
      return (
        allowed: false,
        errorMessage:
            'Unable to verify device session. Please check your connection and try again.',
      );
    }
  }

  /// Releases the device session in Firestore upon explicit user logout.
  ///
  /// Prevents clearing `fcmToken` and `activeDeviceId` if another active device
  /// has already claimed the session.
  static Future<void> releaseSession({
    required String collectionName,
    required String documentId,
  }) async {
    if (documentId.isEmpty) return;

    try {
      final currentDeviceId = await getDeviceId();
      final docRef = _firestore.collection(collectionName).doc(documentId);
      final docSnap = await docRef.get();

      if (!docSnap.exists) return;
      final data = docSnap.data() ?? {};
      final String? activeDeviceId = data['activeDeviceId'] as String?;

      final bool isCurrentDeviceActive =
          activeDeviceId == null ||
          activeDeviceId.isEmpty ||
          activeDeviceId == currentDeviceId;

      final updateData = <String, dynamic>{
        'lastLogoutAt': FieldValue.serverTimestamp(),
      };

      if (isCurrentDeviceActive) {
        updateData['activeDeviceId'] = null;
        updateData['isLoggedIn'] = false;
        updateData['fcmToken'] = null;

        if (collectionName == 'telemedicine_doctors') {
          updateData['isOnline'] = false;
          updateData['isAvailable'] = false;
          updateData['manualAvailability'] = false;
          updateData['effectiveStatus'] = 'OFFLINE';
          updateData['lastSeen'] = FieldValue.serverTimestamp();
        }
      }

      await docRef.update(updateData);
      debugPrint(
        '🔓 [SingleDeviceSession] Session released for $documentId (isCurrentDeviceActive=$isCurrentDeviceActive)',
      );
    } catch (e) {
      debugPrint('⚠️ [SingleDeviceSession] Error releasing session: $e');
    }
  }

  /// Subscribes to real-time changes on the user's Firestore document.
  ///
  /// Correctly distinguishes between:
  /// - Matching session on this device (healthy)
  /// - Uninitialized / null session field (self-heals without logout)
  /// - Confirmed remote session claimed by another device (invalidates session)
  /// - Transient network/listener errors (fails open without logout)
  static StreamSubscription<DocumentSnapshot> listenForSessionChanges({
    required String collectionName,
    required String documentId,
    required String currentDeviceId,
    required VoidCallback onSessionInvalidated,
  }) {
    final docRef = _firestore.collection(collectionName).doc(documentId);

    // Tracks whether this device has already established an active session
    bool hasEstablishedSession = false;

    return docRef.snapshots().listen(
      (snapshot) {
        if (!snapshot.exists) {
          debugPrint(
            'ℹ️ [SingleDeviceSession] Document does not exist yet for $documentId. Waiting...',
          );
          return;
        }

        final data = snapshot.data() ?? {};
        final String? activeDeviceId = data['activeDeviceId'] as String?;
        final bool? isLoggedInRaw = data['isLoggedIn'] as bool?;
        final bool isLoggedIn = isLoggedInRaw == true;

        debugPrint(
          '🔍 [SingleDeviceSession] Snapshot check for $documentId: activeDeviceId=$activeDeviceId | isLoggedIn=$isLoggedIn | currentDeviceId=$currentDeviceId | established=$hasEstablishedSession',
        );

        // Case 1: Session belongs to THIS device
        if (activeDeviceId == currentDeviceId) {
          if (isLoggedIn) {
            hasEstablishedSession = true;
          } else if (hasEstablishedSession) {
            // The session was previously established on this device, but was explicitly
            // marked inactive on the server (e.g. administrative suspension/revocation).
            debugPrint(
              '⚠️ [SingleDeviceSession] Active session explicitly marked inactive on server.',
            );
            onSessionInvalidated();
          }
          return;
        }

        // Case 2: A different, non-empty device ID is registered
        if (activeDeviceId != null &&
            activeDeviceId.isNotEmpty &&
            activeDeviceId != currentDeviceId) {
          // Confirm that the other device ID is not an un-migrated build string matching this device
          // If another device genuinely claimed the session:
          debugPrint(
            '⚠️ [SingleDeviceSession] Confirmed remote device session ($activeDeviceId != $currentDeviceId). Invalidating local session.',
          );
          onSessionInvalidated();
          return;
        }

        // Case 3: activeDeviceId is null or empty
        // A null or missing session field MUST NOT be treated as remote device login!
        if (activeDeviceId == null || activeDeviceId.isEmpty) {
          if (!hasEstablishedSession) {
            // Uninitialized or legacy document. Self-heal and claim for current device.
            debugPrint(
              'ℹ️ [SingleDeviceSession] Uninitialized session field on $documentId. Initializing for current device ($currentDeviceId)...',
            );
            hasEstablishedSession = true;
            docRef
                .update({
                  'activeDeviceId': currentDeviceId,
                  'deviceId': currentDeviceId,
                  'isLoggedIn': true,
                  'lastLoginAt': FieldValue.serverTimestamp(),
                })
                .catchError((e) {
                  debugPrint(
                    '⚠️ [SingleDeviceSession] Error initializing session: $e',
                  );
                });
          } else if (isLoggedInRaw == false) {
            // Previously established on this device, but now explicitly revoked/cleared
            debugPrint(
              '⚠️ [SingleDeviceSession] Active session revoked remotely (cleared by server).',
            );
            onSessionInvalidated();
          }
        }
      },
      onError: (error) {
        // Fail open: a transient network or Firestore glitch must never cause false logouts
        debugPrint(
          '⚠️ [SingleDeviceSession] Snapshot error (failing open, retaining session): $error',
        );
      },
    );
  }

  /// Performs full local logout and displays an informative dialog before routing to SignInScreen.
  static Future<void> handleForcedLogout(
    BuildContext context, {
    String title = 'Session Expired',
    String message =
        'Your account was logged in on another device. You have been logged out of this device.',
  }) async {
    // Clear local cache/doctor/patient session and Firebase Auth
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('current_doctor');
      await prefs.remove('current_user');
      await prefs.remove('current_patient');
      await prefs.remove('auth_token');
    } catch (_) {}

    try {
      await PhoneAuthService.instance.signOut();
    } catch (_) {}

    if (!context.mounted) return;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => PopScope(
        canPop: false,
        child: AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Row(
            children: [
              const Icon(Icons.devices_other_rounded, color: Color(0xFFE53935)),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          content: Text(
            message,
            style: const TextStyle(fontSize: 14, color: Color(0xFF4B5563)),
          ),
          actions: [
            ElevatedButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                Navigator.of(context).pushAndRemoveUntil(
                  MaterialPageRoute(builder: (_) => const SignInScreen()),
                  (route) => false,
                );
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF062B72),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: const Text('Back to Sign In'),
            ),
          ],
        ),
      ),
    );
  }
}
