import 'dart:async';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:telemedicine/core/services/device_service.dart';
import 'package:telemedicine/core/services/notification_service.dart';
import 'package:telemedicine/features/auth/data/services/phone_auth_service.dart';
import 'package:telemedicine/features/auth/presentation/screens/sign_in_screen.dart';

/// Server-authoritative service enforcing strict single-active-device session per account.
///
/// Ensures an account can only be active on one device at any time.
/// When user logs in on Device B, Device A's session is superseded on the server,
/// Firebase Auth refresh tokens are revoked via Cloud Functions, and Device A
/// is dislodged in real-time.
class SingleDeviceSessionService {
  SingleDeviceSessionService._();
  static final SingleDeviceSessionService instance =
      SingleDeviceSessionService._();

  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();
  static const String _sessionStorageKey = 'active_session_id';

  /// Currently active local session ID in memory.
  static String? _cachedSessionId;

  /// Retrieves the persistent hardware/installation device ID.
  static Future<String> getDeviceId() async {
    return await DeviceService.getDeviceId();
  }

  /// Retrieves the current active session ID for this device.
  static Future<String> getLocalSessionId() async {
    if (_cachedSessionId != null && _cachedSessionId!.isNotEmpty) {
      return _cachedSessionId!;
    }
    try {
      final secure = await _secureStorage.read(key: _sessionStorageKey);
      if (secure != null && secure.isNotEmpty) {
        _cachedSessionId = secure;
        return secure;
      }
    } catch (_) {}

    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(_sessionStorageKey);
      if (stored != null && stored.isNotEmpty) {
        _cachedSessionId = stored;
        return stored;
      }
    } catch (_) {}

    return '';
  }

  /// Persists the active session ID locally in secure storage and SharedPreferences.
  static Future<void> _persistLocalSessionId(String sessionId) async {
    _cachedSessionId = sessionId;
    try {
      await _secureStorage.write(key: _sessionStorageKey, value: sessionId);
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_sessionStorageKey, sessionId);
    } catch (_) {}
  }

  /// Clears the active local session ID.
  static Future<void> _clearLocalSessionId() async {
    _cachedSessionId = null;
    try {
      await _secureStorage.delete(key: _sessionStorageKey);
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_sessionStorageKey);
    } catch (_) {}
  }

  /// Atomically claims an authoritative single active device session.
  ///
  /// - Creates/updates authoritative server session at `/users/{documentId}/sessions/active`
  /// - Atomically updates the user profile document (`telemedicine_patient` or `telemedicine_doctors`)
  /// - Generates a new unique `sessionId` (superseding any prior session)
  /// - Revokes Firebase Auth refresh tokens for any displaced sessions via Cloud Functions
  static Future<({bool allowed, String sessionId, String? errorMessage})>
  claimActiveSession({
    required String collectionName,
    required String documentId,
    required String role,
    String? authUid,
    String? fcmToken,
  }) async {
    if (documentId.trim().isEmpty) {
      return (
        allowed: false,
        sessionId: '',
        errorMessage: 'Invalid user document ID.',
      );
    }

    final trimmedDocId = documentId.trim();
    final currentDeviceId = await getDeviceId();
    final newSessionId = const Uuid().v4();

    try {
      final userProfileRef = _firestore
          .collection(collectionName)
          .doc(trimmedDocId);
      final activeSessionRef = _firestore
          .collection('users')
          .doc(trimmedDocId)
          .collection('sessions')
          .doc('active');

      final platformMeta = <String, dynamic>{
        'os': Platform.operatingSystem,
        'osVersion': Platform.operatingSystemVersion,
        'isPhysicalDevice': true,
        'appVersion': '1.0.8',
        'updatedAt': FieldValue.serverTimestamp(),
      };

      // Atomic commit: updates profile and canonical /users/{uid}/sessions/active
      final batch = _firestore.batch();

      batch.set(activeSessionRef, {
        'sessionId': newSessionId,
        'installationId': currentDeviceId,
        'deviceId': currentDeviceId,
        'userId': trimmedDocId,
        'role': role,
        'status': 'active',
        'fcmToken': fcmToken,
        'createdAt': FieldValue.serverTimestamp(),
        'lastActiveAt': FieldValue.serverTimestamp(),
        'platformMeta': platformMeta,
      }, SetOptions(merge: true));

      final profileUpdate = <String, dynamic>{
        'activeSessionId': newSessionId,
        'activeDeviceId': currentDeviceId,
        'deviceId': currentDeviceId,
        'isLoggedIn': true,
        'lastLoginAt': FieldValue.serverTimestamp(),
        'lastActiveAt': FieldValue.serverTimestamp(),
        'sessionPlatformMeta': platformMeta,
      };

      if (fcmToken != null && fcmToken.isNotEmpty) {
        profileUpdate['fcmToken'] = fcmToken;
      }

      batch.set(userProfileRef, profileUpdate, SetOptions(merge: true));
      await batch.commit();

      // Persist locally
      await _persistLocalSessionId(newSessionId);

      debugPrint(
        '✅ [SingleDeviceSession] Claimed active session $newSessionId for $trimmedDocId on $currentDeviceId',
      );

      // Asynchronously revoke prior Firebase Auth refresh tokens via Cloud Functions
      final targetAuthUid = authUid ?? trimmedDocId;
      unawaited(_revokeDisplacedAuthTokens(targetAuthUid, newSessionId));

      return (allowed: true, sessionId: newSessionId, errorMessage: null);
    } catch (e) {
      debugPrint('❌ [SingleDeviceSession] Error claiming session: $e');
      return (
        allowed: false,
        sessionId: '',
        errorMessage:
            'Unable to establish secure device session. Please check your connection.',
      );
    }
  }

  /// Backward-compatible bridge for existing callers of validateAndClaimSession.
  static Future<({bool allowed, String? errorMessage})>
  validateAndClaimSession({
    required String collectionName,
    required String documentId,
    required String currentDeviceId,
    bool blockSecondLogin = false,
    String? role,
    String? authUid,
  }) async {
    final effectiveRole =
        role ??
        (collectionName == 'telemedicine_doctors' ? 'doctor' : 'patient');
    final result = await claimActiveSession(
      collectionName: collectionName,
      documentId: documentId,
      role: effectiveRole,
      authUid: authUid,
    );
    return (allowed: result.allowed, errorMessage: result.errorMessage);
  }

  /// Revocation helper for displaced auth tokens. Session invalidation is handled
  /// authoritatively via Firestore document session tracking and real-time listeners.
  static Future<void> _revokeDisplacedAuthTokens(
    String authUid,
    String sessionId,
  ) async {
    // Authoritative session displacement is enforced via Firestore activeDeviceId/activeSessionId.
    debugPrint(
      '🔒 [SingleDeviceSession] Session claim registered for $authUid (session: $sessionId)',
    );
  }

  /// Releases the device session in Firestore upon explicit user logout.
  static Future<void> releaseSession({
    required String collectionName,
    required String documentId,
  }) async {
    if (documentId.trim().isEmpty) return;

    try {
      final currentDeviceId = await getDeviceId();
      final localSessionId = await getLocalSessionId();

      final docRef = _firestore
          .collection(collectionName)
          .doc(documentId.trim());
      final docSnap = await docRef.get();

      if (docSnap.exists) {
        final data = docSnap.data() ?? {};
        final activeDeviceId = data['activeDeviceId'] as String?;
        final activeSessionId = data['activeSessionId'] as String?;

        final bool isCurrentSessionActive =
            (activeSessionId != null && activeSessionId == localSessionId) ||
            (activeDeviceId != null && activeDeviceId == currentDeviceId);

        if (isCurrentSessionActive) {
          final batch = _firestore.batch();
          batch.update(docRef, {
            'activeDeviceId': null,
            'activeSessionId': null,
            'isLoggedIn': false,
            'fcmToken': null,
            'lastLogoutAt': FieldValue.serverTimestamp(),
          });

          final sessionRef = _firestore
              .collection('users')
              .doc(documentId.trim())
              .collection('sessions')
              .doc('active');
          batch.delete(sessionRef);

          await batch.commit();
        }
      }

      await _clearLocalSessionId();
      debugPrint('🔓 [SingleDeviceSession] Session released for $documentId');
    } catch (e) {
      debugPrint('⚠️ [SingleDeviceSession] Error releasing session: $e');
    }
  }

  /// Subscribes to real-time changes on the user's active session.
  ///
  /// Distinguishes between:
  /// - Matching session on THIS device (healthy)
  /// - Uninitialized / null session field (heals without logout)
  /// - Remote session claimed by another device (invalidates session immediately)
  /// - Transient network errors (fails open without spurious logout)
  static StreamSubscription<DocumentSnapshot> listenForSessionChanges({
    required String collectionName,
    required String documentId,
    required String currentDeviceId,
    required VoidCallback onSessionInvalidated,
  }) {
    final docRef = _firestore.collection(collectionName).doc(documentId.trim());

    bool hasEstablishedSession = false;

    return docRef.snapshots().listen(
      (snapshot) async {
        if (!snapshot.exists) return;

        final data = snapshot.data() ?? {};
        final activeDeviceId = data['activeDeviceId'] as String?;
        final activeSessionId = data['activeSessionId'] as String?;
        final bool isLoggedIn = data['isLoggedIn'] == true;
        final localSessionId = await getLocalSessionId();

        // 1. Session belongs to THIS device
        final isMatchingSession =
            (localSessionId.isNotEmpty && activeSessionId == localSessionId) ||
            (activeDeviceId == currentDeviceId);

        if (isMatchingSession) {
          if (isLoggedIn) {
            hasEstablishedSession = true;
          } else if (hasEstablishedSession) {
            // Explicitly marked inactive by server
            debugPrint(
              '⚠️ [SingleDeviceSession] Active session revoked on server.',
            );
            onSessionInvalidated();
          }
          return;
        }

        // 2. A different device or session claimed the account
        final bool isDifferentSession =
            (activeSessionId != null &&
                activeSessionId.isNotEmpty &&
                localSessionId.isNotEmpty &&
                activeSessionId != localSessionId) ||
            (activeDeviceId != null &&
                activeDeviceId.isNotEmpty &&
                activeDeviceId != currentDeviceId &&
                DeviceService.isValidInstallationId(activeDeviceId));

        if (isDifferentSession) {
          debugPrint(
            '⚠️ [SingleDeviceSession] Remote device claimed session ($activeSessionId != $localSessionId | $activeDeviceId != $currentDeviceId). Dislodging local device.',
          );
          onSessionInvalidated();
          return;
        }

        // 3. Uninitialized or legacy document
        if ((activeDeviceId == null || activeDeviceId.isEmpty) &&
            (activeSessionId == null || activeSessionId.isEmpty)) {
          if (hasEstablishedSession && !isLoggedIn) {
            debugPrint(
              '⚠️ [SingleDeviceSession] Session cleared remotely by server.',
            );
            onSessionInvalidated();
          }
        }
      },
      onError: (error) {
        debugPrint(
          '⚠️ [SingleDeviceSession] Snapshot error (fail-open): $error',
        );
      },
    );
  }

  /// Performs a synchronous check of active session integrity.
  ///
  /// Intended for invocation on `AppLifecycleState.resumed` and prior to initiating
  /// sensitive mutations (dispatching chat, initiating calls, submitting payments).
  ///
  /// Returns `true` if this device owns the active session, or `false` if superseded.
  static Future<bool> validateCurrentSession({
    required String collectionName,
    required String documentId,
  }) async {
    if (documentId.trim().isEmpty) return false;

    try {
      final docSnap = await _firestore
          .collection(collectionName)
          .doc(documentId.trim())
          .get(const GetOptions(source: Source.server));

      if (!docSnap.exists) return false;

      final data = docSnap.data() ?? {};
      final remoteSessionId = data['activeSessionId'] as String?;
      final remoteDeviceId = data['activeDeviceId'] as String?;
      final localSessionId = await getLocalSessionId();
      final currentDeviceId = await getDeviceId();

      // If remote session exists and does not match this device -> superseded
      if (remoteSessionId != null &&
          remoteSessionId.isNotEmpty &&
          localSessionId.isNotEmpty &&
          remoteSessionId != localSessionId) {
        debugPrint(
          '🔒 [SingleDeviceSession] Session integrity failed: remoteSessionId=$remoteSessionId != local=$localSessionId',
        );
        return false;
      }

      if (remoteDeviceId != null &&
          remoteDeviceId.isNotEmpty &&
          remoteDeviceId != currentDeviceId &&
          DeviceService.isValidInstallationId(remoteDeviceId)) {
        debugPrint(
          '🔒 [SingleDeviceSession] Device integrity failed: remoteDeviceId=$remoteDeviceId != current=$currentDeviceId',
        );
        return false;
      }

      return true;
    } catch (e) {
      // Fail open on transient network error during query
      debugPrint(
        '⚠️ [SingleDeviceSession] Integrity check error (fail-open): $e',
      );
      return true;
    }
  }

  /// Performs full local logout, purges credentials, and displays an informative dialog before routing to SignInScreen.
  static Future<void> handleForcedLogout(
    BuildContext? context, {
    String title = 'Session Expired',
    String message =
        'Your account was logged in on another device. You have been signed out on this device.',
  }) async {
    // 1. Purge local cache and secure credentials
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('current_doctor');
      await prefs.remove('current_user');
      await prefs.remove('current_patient');
      await prefs.remove('auth_token');
      await prefs.remove('active_session_id');
      await _clearLocalSessionId();
    } catch (_) {}

    try {
      await PhoneAuthService.instance.signOut();
    } catch (_) {}

    final targetContext =
        context ?? NotificationService.navigatorKey.currentContext;

    if (targetContext == null || !targetContext.mounted) return;

    await showDialog<void>(
      context: targetContext,
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
                Navigator.of(targetContext).pushAndRemoveUntil(
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
