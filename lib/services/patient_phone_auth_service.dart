import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:telemedicine/data/models/user_model.dart';
import 'package:telemedicine/services/patient_password_reset_service.dart';

/// Exception thrown during patient phone authentication operations.
class PatientPhoneAuthException implements Exception {
  final String message;
  final String? code;
  final dynamic originalError;

  PatientPhoneAuthException(this.message, {this.code, this.originalError});

  @override
  String toString() => message;
}

/// Result returned when an SMS OTP has been dispatched.
class PhoneOtpSendResult {
  final String normalizedPhone;
  final String message;
  final int resendInSeconds;
  final String verificationId;

  const PhoneOtpSendResult({
    required this.normalizedPhone,
    required this.message,
    required this.resendInSeconds,
    required this.verificationId,
  });
}

/// Result returned after verifying the SMS OTP.
class PhoneOtpVerifyResult {
  final bool isExistingUser;
  final UserModel? existingUser;
  final bool isProfileComplete;
  final User? firebaseUser;

  const PhoneOtpVerifyResult({
    required this.isExistingUser,
    this.existingUser,
    required this.isProfileComplete,
    this.firebaseUser,
  });
}

/// Service managing patient phone-number authentication through Firebase Phone Auth.
class PatientPhoneAuthService {
  final FirebaseAuth? _customAuth;
  final FirebaseFirestore? _customFirestore;

  PatientPhoneAuthService({
    FirebaseAuth? auth,
    FirebaseFirestore? firestore,
  })  : _customAuth = auth,
        _customFirestore = firestore;

  FirebaseAuth get _auth => _customAuth ?? FirebaseAuth.instance;
  FirebaseFirestore get _firestore => _customFirestore ?? FirebaseFirestore.instance;

  String? _verificationId;
  int? _resendToken;
  bool _isSending = false;
  DateTime? _lastSendTime;
  PhoneAuthCredential? _autoRetrievedCredential;

  static const int resendCooldownSeconds = 60;
  static const int maxHourlyAttempts = 5;

  /// Whether an OTP send request is currently in-flight.
  bool get isSending => _isSending;

  /// The active Firebase verification ID from the last codeSent callback.
  String? get currentVerificationId => _verificationId;

  /// Auto-retrieved credential if SMS Retriever completed verification automatically.
  PhoneAuthCredential? get autoRetrievedCredential => _autoRetrievedCredential;

  /// Helper to safely mask phone numbers in logs and user feedback.
  static String maskPhone(String phone) {
    if (phone.length <= 6) return '***';
    final start = phone.substring(0, phone.length > 7 ? 5 : 3);
    final end = phone.substring(phone.length - 3);
    return '$start***$end';
  }

  /// Sends a real SMS OTP using Firebase Authentication.
  /// Enforces E.164 normalization, in-flight locking, persistent resend cooldown, and hourly limits.
  Future<PhoneOtpSendResult> sendLoginOtp({
    required String rawPhone,
    String defaultDialCode = '+92',
    void Function(PhoneAuthCredential credential)? onAutoVerified,
  }) async {
    final clean = rawPhone.trim();
    if (clean.isEmpty) {
      throw PatientPhoneAuthException(
        'Phone number is required.',
        code: 'empty-phone',
      );
    }

    // Normalize phone number to canonical E.164
    final normalized = PatientPasswordResetService.normalizePhone(
          clean,
          defaultDialCode: defaultDialCode,
        ) ??
        (clean.startsWith('+') ? clean : '$defaultDialCode${clean.replaceAll(RegExp(r'^0+'), '')}');

    // Enforce in-flight lock to prevent duplicate simultaneous verifyPhoneNumber calls
    if (_isSending) {
      throw PatientPhoneAuthException(
        'An SMS request is already in progress. Please wait a moment.',
        code: 'in-flight',
      );
    }

    // Enforce in-memory and persistent client-side resend cooldown & rate-limiting
    final now = DateTime.now();
    if (_lastSendTime != null) {
      final elapsed = now.difference(_lastSendTime!).inSeconds;
      if (elapsed < resendCooldownSeconds) {
        final remaining = resendCooldownSeconds - elapsed;
        throw PatientPhoneAuthException(
          'Please wait $remaining seconds before requesting another code.',
          code: 'cooldown-active',
        );
      }
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final lastSendKey = 'patient_otp_last_send_$normalized';
      final lastSendMs = prefs.getInt(lastSendKey) ?? 0;
      final nowMs = now.millisecondsSinceEpoch;
      final elapsedSec = (nowMs - lastSendMs) ~/ 1000;
      if (elapsedSec < resendCooldownSeconds) {
        final remaining = resendCooldownSeconds - elapsedSec;
        throw PatientPhoneAuthException(
          'Please wait $remaining seconds before requesting another code.',
          code: 'cooldown-active',
        );
      }

      // Hourly send limit check (max 5 requests per hour per number)
      final hourlyKey = 'patient_otp_attempts_$normalized';
      final history = prefs.getStringList(hourlyKey) ?? [];
      final oneHourAgo = nowMs - (3600 * 1000);
      final recentAttempts = history
          .map((e) => int.tryParse(e) ?? 0)
          .where((ts) => ts > oneHourAgo)
          .toList();

      if (recentAttempts.length >= maxHourlyAttempts) {
        throw PatientPhoneAuthException(
          'Too many verification attempts for this number. Please wait an hour before requesting another code.',
          code: 'too-many-requests',
        );
      }
    } catch (e) {
      if (e is PatientPhoneAuthException) rethrow;
      // If SharedPreferences fails for any non-blocking reason, continue with memory checks
    }

    _isSending = true;
    _autoRetrievedCredential = null;
    final completer = Completer<PhoneOtpSendResult>();

    try {
      debugPrint('📲 [PatientPhoneAuthService] Dispatching OTP to ${maskPhone(normalized)}');

      await _auth.verifyPhoneNumber(
        phoneNumber: normalized,
        timeout: const Duration(seconds: 60),
        forceResendingToken: _resendToken,
        verificationCompleted: (PhoneAuthCredential credential) {
          debugPrint('✅ [PatientPhoneAuthService] SMS Retriever / instant verification completed');
          _autoRetrievedCredential = credential;
          if (onAutoVerified != null) {
            onAutoVerified(credential);
          }
        },
        verificationFailed: (FirebaseAuthException error) {
          _isSending = false;
          debugPrint('❌ [PatientPhoneAuthService] Verification failed: ${error.code} - ${error.message}');
          final userFriendlyMessage = _mapFirebaseSendError(error);
          if (!completer.isCompleted) {
            completer.completeError(
              PatientPhoneAuthException(
                userFriendlyMessage,
                code: error.code,
                originalError: error,
              ),
            );
          }
        },
        codeSent: (String verificationId, int? forceResendingToken) {
          _isSending = false;
          _verificationId = verificationId;
          _resendToken = forceResendingToken;
          _lastSendTime = DateTime.now();

          // Persist timestamp and attempt count
          SharedPreferences.getInstance().then((prefs) {
            final nowMs = DateTime.now().millisecondsSinceEpoch;
            prefs.setInt('patient_otp_last_send_$normalized', nowMs);
            final hourlyKey = 'patient_otp_attempts_$normalized';
            final history = prefs.getStringList(hourlyKey) ?? [];
            final oneHourAgo = nowMs - (3600 * 1000);
            final recent = history
                .map((e) => int.tryParse(e) ?? 0)
                .where((ts) => ts > oneHourAgo)
                .toList()
              ..add(nowMs);
            prefs.setStringList(hourlyKey, recent.map((e) => e.toString()).toList());
          }).catchError((_) {});

          debugPrint('📨 [PatientPhoneAuthService] Code sent. verificationId: $verificationId');

          if (!completer.isCompleted) {
            completer.complete(
              PhoneOtpSendResult(
                normalizedPhone: normalized,
                message: 'Verification code sent to ${maskPhone(normalized)} via SMS.',
                resendInSeconds: resendCooldownSeconds,
                verificationId: verificationId,
              ),
            );
          }
        },
        codeAutoRetrievalTimeout: (String verificationId) {
          debugPrint('⏱️ [PatientPhoneAuthService] Auto-retrieval timeout for $verificationId');
          _verificationId = verificationId;
        },
      );

      return await completer.future;
    } catch (e) {
      _isSending = false;
      if (e is PatientPhoneAuthException) rethrow;
      if (e is FirebaseAuthException) {
        throw PatientPhoneAuthException(
          _mapFirebaseSendError(e),
          code: e.code,
          originalError: e,
        );
      }
      throw PatientPhoneAuthException(
        'Unable to send verification code: ${e.toString()}',
        originalError: e,
      );
    }
  }

  /// Verifies the entered SMS code or auto-retrieved credential with Firebase Authentication
  /// and resolves the patient profile.
  Future<PhoneOtpVerifyResult> verifyLoginOtp({
    required String normalizedPhone,
    String? otp,
    PhoneAuthCredential? credential,
    String defaultDialCode = '+92',
  }) async {
    PhoneAuthCredential? authCred = credential ?? _autoRetrievedCredential;

    if (authCred == null) {
      final cleanOtp = (otp ?? '').trim();
      if (cleanOtp.length != 6) {
        throw PatientPhoneAuthException(
          'Please enter the complete 6-digit code sent via SMS.',
          code: 'invalid-otp-length',
        );
      }

      final vId = _verificationId;
      if (vId == null || vId.isEmpty) {
        throw PatientPhoneAuthException(
          'Verification session expired or not found. Please request a new code.',
          code: 'missing-verification-id',
        );
      }

      authCred = PhoneAuthProvider.credential(
        verificationId: vId,
        smsCode: cleanOtp,
      );
    }

    try {
      debugPrint('🔑 [PatientPhoneAuthService] Authenticating with PhoneAuthCredential...');

      final userCredential = await _auth.signInWithCredential(authCred);
      final firebaseUser = userCredential.user;

      if (firebaseUser == null) {
        throw PatientPhoneAuthException(
          'Authentication failed. Please try again.',
          code: 'null-user',
        );
      }

      debugPrint('🎉 [PatientPhoneAuthService] Verified UID: ${firebaseUser.uid}');

      // Look up existing patient document in telemedicine_patient
      UserModel? existingPatient;

      // 1. Direct match by document ID or authUid
      final directDoc = await _firestore
          .collection('telemedicine_patient')
          .doc(firebaseUser.uid)
          .get();

      if (directDoc.exists) {
        existingPatient = UserModel.fromMap({
          ...directDoc.data()!,
          'id': directDoc.id,
        });
      } else {
        final authUidSnap = await _firestore
            .collection('telemedicine_patient')
            .where('authUid', isEqualTo: firebaseUser.uid)
            .limit(1)
            .get();

        if (authUidSnap.docs.isNotEmpty) {
          final doc = authUidSnap.docs.first;
          existingPatient = UserModel.fromMap({
            ...doc.data(),
            'id': doc.id,
          });
        } else {
          // Search by phone variants
          final variants = PatientPasswordResetService.phoneLookupVariants(normalizedPhone);
          final phoneSnap = await _firestore
              .collection('telemedicine_patient')
              .where('phoneNumber', whereIn: variants)
              .limit(1)
              .get();

          if (phoneSnap.docs.isNotEmpty) {
            final doc = phoneSnap.docs.first;
            existingPatient = UserModel.fromMap({
              ...doc.data(),
              'id': doc.id,
            });

            // Link authUid to the existing account doc
            await doc.reference.update({
              'authUid': firebaseUser.uid,
              'phoneNumber': normalizedPhone,
            });
          }
        }
      }

      if (existingPatient != null) {
        final isComplete = existingPatient.fullname.trim().isNotEmpty;
        return PhoneOtpVerifyResult(
          isExistingUser: true,
          existingUser: existingPatient,
          isProfileComplete: isComplete,
          firebaseUser: firebaseUser,
        );
      } else {
        return PhoneOtpVerifyResult(
          isExistingUser: false,
          existingUser: null,
          isProfileComplete: false,
          firebaseUser: firebaseUser,
        );
      }
    } on FirebaseAuthException catch (e) {
      debugPrint('❌ [PatientPhoneAuthService] OTP verify error: ${e.code} - ${e.message}');
      throw PatientPhoneAuthException(
        _mapFirebaseVerifyError(e),
        code: e.code,
        originalError: e,
      );
    } catch (e) {
      if (e is PatientPhoneAuthException) rethrow;
      throw PatientPhoneAuthException(
        'Verification failed: ${e.toString()}',
        originalError: e,
      );
    }
  }

  /// Maps Firebase phone authentication send errors into user-friendly diagnostic messages.
  String _mapFirebaseSendError(FirebaseAuthException e) {
    switch (e.code) {
      case 'operation-not-allowed':
        return 'Phone authentication is not enabled or Pakistan (+92) is not permitted in your Firebase SMS Region Policy. Please check Firebase Console > Authentication > Settings.';
      case 'missing-client-identifier':
      case 'app-not-authorized':
        return 'Android app verification failed (Play Integrity / SHA fingerprint mismatch). Please verify that your debug and release SHA-1/SHA-256 fingerprints are added to the Firebase Console.';
      case 'too-many-requests':
        return 'Too many SMS requests sent from this device or number. Firebase has temporarily restricted requests. Please wait a few minutes before trying again.';
      case 'invalid-phone-number':
        return 'The phone number format is invalid. Please verify your number and country code.';
      case 'quota-exceeded':
        return 'SMS quota exceeded for this Firebase project. Please try again later or contact support.';
      case 'network-request-failed':
        return 'Network connection error. Please check your internet connection and try again.';
      default:
        return e.message ?? 'Failed to send SMS verification code. Please try again.';
    }
  }

  /// Maps Firebase OTP verification errors into friendly messages.
  String _mapFirebaseVerifyError(FirebaseAuthException e) {
    switch (e.code) {
      case 'invalid-verification-code':
        return 'The 6-digit verification code is incorrect. Please check your SMS and try again.';
      case 'session-expired':
        return 'The verification code has expired. Please tap "Resend Code" to request a new code.';
      case 'invalid-verification-id':
        return 'Invalid verification session. Please request a new verification code.';
      default:
        return e.message ?? 'Verification failed. Please check the code and try again.';
    }
  }
}
