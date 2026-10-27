import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// Service managing Firebase Phone Authentication flows:
/// SMS OTP dispatch, verification, resend, and session management.
class PhoneAuthService {
  PhoneAuthService._();
  static final PhoneAuthService instance = PhoneAuthService._();

  final FirebaseAuth _auth = FirebaseAuth.instance;

  FirebaseAuth get auth => _auth;

  /// Currently authenticated Firebase user (null if signed out).
  User? get currentUser => _auth.currentUser;

  /// Whether there is an active Firebase Auth user session.
  bool get isAuthenticated => _auth.currentUser != null;

  /// Dispatches an SMS verification code to [phoneNumber] (must be in E.164 format, e.g. +923001234567).
  Future<void> sendOtp({
    required String phoneNumber,
    required void Function(String verificationId, int? resendToken) onCodeSent,
    required void Function(FirebaseAuthException exception)
    onVerificationFailed,
    required void Function(PhoneAuthCredential credential)
    onVerificationCompleted,
    required void Function(String verificationId) onCodeAutoRetrievalTimeout,
    int? resendToken,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    try {
      debugPrint('📲 [PhoneAuthService] Sending OTP to $phoneNumber');
      await _auth.verifyPhoneNumber(
        phoneNumber: phoneNumber,
        timeout: timeout,
        forceResendingToken: resendToken,
        verificationCompleted: (PhoneAuthCredential credential) {
          debugPrint(
            '✅ [PhoneAuthService] Instant verification / auto-retrieval completed',
          );
          onVerificationCompleted(credential);
        },
        verificationFailed: (FirebaseAuthException exception) {
          debugPrint(
            '❌ [PhoneAuthService] Verification failed: ${exception.code} - ${exception.message}',
          );
          onVerificationFailed(exception);
        },
        codeSent: (String verificationId, int? token) {
          debugPrint(
            '📨 [PhoneAuthService] Code sent successfully. verificationId: $verificationId',
          );
          onCodeSent(verificationId, token);
        },
        codeAutoRetrievalTimeout: (String verificationId) {
          debugPrint(
            '⏱️ [PhoneAuthService] Code auto-retrieval timeout for $verificationId',
          );
          onCodeAutoRetrievalTimeout(verificationId);
        },
      );
    } catch (e) {
      debugPrint('❌ [PhoneAuthService] Error in verifyPhoneNumber: $e');
      rethrow;
    }
  }

  /// Verifies the 6-digit [smsCode] against [verificationId].
  /// Returns the verified [UserCredential] containing the authenticated Firebase [User].
  Future<UserCredential> verifyOtp({
    required String verificationId,
    required String smsCode,
  }) async {
    final credential = PhoneAuthProvider.credential(
      verificationId: verificationId,
      smsCode: smsCode,
    );
    return await signInWithCredential(credential);
  }

  /// Signs in using a [PhoneAuthCredential] (e.g. from auto-retrieval or manually entered code).
  Future<UserCredential> signInWithCredential(
    PhoneAuthCredential credential,
  ) async {
    try {
      final userCredential = await _auth.signInWithCredential(credential);
      debugPrint(
        '🎉 [PhoneAuthService] Successfully signed in user: ${userCredential.user?.uid}',
      );
      return userCredential;
    } on FirebaseAuthException catch (e) {
      debugPrint(
        '❌ [PhoneAuthService] signInWithCredential failed: ${e.code} - ${e.message}',
      );
      rethrow;
    }
  }

  /// Signs out of Firebase Authentication.
  Future<void> signOut() async {
    try {
      await _auth.signOut();
      debugPrint('🔓 [PhoneAuthService] Signed out of Firebase Authentication');
    } catch (e) {
      debugPrint('⚠️ [PhoneAuthService] Error during Firebase signOut: $e');
    }
  }
}
