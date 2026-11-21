// lib/features/auth/data/services/patient_phone_reset_service.dart

import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:telemedicine/core/utils/phone_utils.dart';
import 'package:telemedicine/core/services/password_security_service.dart';

class PatientPhoneResetService {
  PatientPhoneResetService._();
  static final PatientPhoneResetService instance = PatientPhoneResetService._();

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  String? _verificationId;
  int? _resendToken;

  String? get currentVerificationId => _verificationId;

  /// Sends a Firebase Phone Auth SMS OTP to the given phone number after verifying
  /// that an active patient account exists in Firestore.
  Future<void> sendOtp({
    required String normalizedPhone,
    required Function(String verificationId) onCodeSent,
    required Function(String error) onError,
  }) async {
    final variants = PhoneUtils.phoneLookupVariants(normalizedPhone);

    // 1. Check if patient exists in Firestore
    QuerySnapshot<Map<String, dynamic>>? userQuery;
    for (final phoneVariant in variants) {
      final snap = await _firestore
          .collection('telemedicine_patient')
          .where('phoneNumber', isEqualTo: phoneVariant)
          .where('isDeleted', isEqualTo: false)
          .limit(1)
          .get();

      if (snap.docs.isNotEmpty) {
        userQuery = snap;
        break;
      }
    }

    if (userQuery == null || userQuery.docs.isEmpty) {
      onError('No registered patient account found with this phone number.');
      return;
    }

    try {
      debugPrint('📲 [PhoneResetService] Disagreeing verification code to $normalizedPhone');
      await _auth.verifyPhoneNumber(
        phoneNumber: normalizedPhone,
        timeout: const Duration(seconds: 60),
        forceResendingToken: _resendToken,
        verificationCompleted: (PhoneAuthCredential credential) async {
          debugPrint('✅ [PhoneResetService] Phone verification completed automatically.');
        },
        verificationFailed: (FirebaseAuthException e) {
          debugPrint('❌ [PhoneResetService] Phone verification failed: ${e.code} - ${e.message}');
          String message = 'Failed to send SMS OTP. Please check your number.';
          if (e.code == 'invalid-phone-number') {
            message = 'The provided phone number is invalid.';
          } else if (e.code == 'too-many-requests') {
            message = 'Too many requests. Please try again later.';
          } else if (e.code == 'quota-exceeded') {
            message = 'SMS quota exceeded. Please contact hospital support.';
          }
          onError(message);
        },
        codeSent: (String verificationId, int? resendToken) {
          debugPrint('📩 [PhoneResetService] OTP code sent. VerificationId: $verificationId');
          _verificationId = verificationId;
          _resendToken = resendToken;
          onCodeSent(verificationId);
        },
        codeAutoRetrievalTimeout: (String verificationId) {
          _verificationId = verificationId;
        },
      );
    } catch (e) {
      debugPrint('❌ [PhoneResetService] Exception sending OTP: $e');
      onError('An unexpected error occurred. Please try again.');
    }
  }

  /// Verifies the entered 6-digit SMS OTP against Firebase Authentication.
  Future<bool> verifyOtp({
    required String verificationId,
    required String smsCode,
  }) async {
    try {
      final credential = PhoneAuthProvider.credential(
        verificationId: verificationId,
        smsCode: smsCode.trim(),
      );

      final userCredential = await _auth.signInWithCredential(credential);
      return userCredential.user != null;
    } on FirebaseAuthException catch (e) {
      debugPrint('❌ [PhoneResetService] OTP verification failed: ${e.code}');
      return false;
    } catch (e) {
      debugPrint('❌ [PhoneResetService] Exception during OTP verification: $e');
      return false;
    }
  }

  /// Updates the password in Firestore for the patient document matching the phone number.
  Future<bool> updatePassword({
    required String normalizedPhone,
    required String newPassword,
  }) async {
    try {
      final variants = PhoneUtils.phoneLookupVariants(normalizedPhone);
      DocumentSnapshot<Map<String, dynamic>>? matchedDoc;

      for (final variant in variants) {
        final query = await _firestore
            .collection('telemedicine_patient')
            .where('phoneNumber', isEqualTo: variant)
            .where('isDeleted', isEqualTo: false)
            .limit(1)
            .get();

        if (query.docs.isNotEmpty) {
          matchedDoc = query.docs.first;
          break;
        }
      }

      // Fallback: check by Firebase Auth UID if doc was not matched by phone number
      if (matchedDoc == null && _auth.currentUser != null) {
        final uid = _auth.currentUser!.uid;
        final directDoc =
            await _firestore.collection('telemedicine_patient').doc(uid).get();
        if (directDoc.exists) {
          matchedDoc = directDoc;
        } else {
          final authUidQuery = await _firestore
              .collection('telemedicine_patient')
              .where('authUid', isEqualTo: uid)
              .where('isDeleted', isEqualTo: false)
              .limit(1)
              .get();
          if (authUidQuery.docs.isNotEmpty) {
            matchedDoc = authUidQuery.docs.first;
          }
        }
      }

      if (matchedDoc == null) {
        debugPrint(
          '❌ [PhoneResetService] No user doc found to update password.',
        );
        return false;
      }

      final docId = matchedDoc.id;

      // 1. Update in Firestore with secure BCrypt hash
      await _firestore.collection('telemedicine_patient').doc(docId).update({
        'password': PasswordSecurityService.hashPassword(newPassword.trim()),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // 2. Update in Firebase Authentication currentUser if signed in
      if (_auth.currentUser != null) {
        try {
          await _auth.currentUser!.updatePassword(newPassword.trim());
          debugPrint(
            '🔑 [PhoneResetService] Firebase Auth currentUser password updated successfully.',
          );
        } catch (authError) {
          debugPrint(
            '⚠️ [PhoneResetService] Firebase Auth updatePassword error: $authError',
          );
        }
      }

      // 3. Clean sign-out of Firebase Auth session so the user must log in explicitly with new credentials
      try {
        await _auth.signOut();
      } catch (_) {}

      debugPrint(
        '✅ [PhoneResetService] Password updated successfully for patient: $docId',
      );
      return true;
    } catch (e) {
      debugPrint('❌ [PhoneResetService] Error updating password in Firestore: $e');
      return false;
    }
  }
}

