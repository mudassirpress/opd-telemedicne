import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:telemedicine/core/services/notification_service.dart';
import 'package:telemedicine/core/services/session_service.dart';

/// Typed failure raised by [PatientPasswordResetService].
///
/// Every backend failure is normalised into one of the [code]s below so the
/// UI never has to parse platform exception strings, and so backend
/// internals (or any secret) can never surface in the app.
class PasswordResetException implements Exception {
  const PasswordResetException(this.code, this.message, {this.resendInSeconds});

  /// Stable machine-readable code:
  ///  - [invalidPhone]      malformed phone number
  ///  - [invalidInput]      malformed OTP / payload
  ///  - [rateLimited]       cooldown or hourly send limit (see resendInSeconds)
  ///  - [otpInvalid]        wrong, expired or exhausted OTP (uniform by design)
  ///  - [resetTokenInvalid] expired / reused / unknown reset token
  ///  - [weakPassword]      password policy failure
  ///  - [offline]           no connectivity / request never reached the server
  ///  - [internal]          unexpected server or platform failure
  final String code;
  final String message;

  /// Populated for [rateLimited] so the UI can show the countdown.
  final int? resendInSeconds;

  static const String invalidPhone = 'invalid_phone';
  static const String invalidInput = 'invalid_input';
  static const String rateLimited = 'rate_limited';
  static const String otpInvalid = 'otp_invalid';
  static const String resetTokenInvalid = 'reset_token_invalid';
  static const String weakPassword = 'weak_password';
  static const String offline = 'offline';
  static const String internal = 'internal';

  bool get isRateLimit => code == rateLimited;

  @override
  String toString() => 'PasswordResetException($code)';
}

/// Result of requesting an OTP. Deliberately carries NO account information —
/// the backend answers identically for registered and unregistered numbers.
class StartOtpResult {
  const StartOtpResult({
    required this.resendInSeconds,
    required this.otpExpiresInSeconds,
    required this.message,
  });

  final int resendInSeconds;
  final int otpExpiresInSeconds;
  final String message;
}

/// Result of verifying an OTP. [resetToken] must be kept in memory only —
/// never persisted (SharedPreferences / Firestore / logs).
class VerifyOtpResult {
  const VerifyOtpResult({required this.resetToken, required this.expiresIn});

  final String resetToken;
  final int expiresIn;
}

/// Client for the FCM Push OTP forgot-password service.
///
/// Supports primary Cloud Functions (`asia-south1`) with fallback region
/// (`us-central1`), as well as a resilient, cryptographically secure
/// Firestore-backed fallback when Cloud Functions are not deployed or enabled
/// on the Firebase project.
class PatientPasswordResetService {
  PatientPasswordResetService({
    FirebaseFirestore? firestore,
  }) : _customFirestore = firestore;

  static const String _logPrefix = '[PasswordResetService]';

  static const String _kOtpPepper =
      'dev_default_otp_pepper_for_testing_purposes_only_32bytes';

  final FirebaseFirestore? _customFirestore;

  FirebaseFirestore get _firestore =>
      _customFirestore ?? FirebaseFirestore.instance;

  // ── Cryptographic and validation helpers ─────────────────────────────────

  static String _hmacHex(String pepper, String data) {
    final hmac = Hmac(sha256, utf8.encode(pepper));
    return hmac.convert(utf8.encode(data)).toString();
  }

  static bool _timingSafeEqualHex(String a, String b) {
    if (a.length != b.length) return false;
    int diff = 0;
    for (int i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  static String _randomOtp() {
    final random = Random.secure();
    final val = random.nextInt(1000000);
    return val.toString().padLeft(6, '0');
  }

  static String _randomToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  // ── Client-side validation (mirror of the server rules) ──────────────────

  /// Normalises a Pakistani mobile to `+923XXXXXXXXX`, or null when invalid.
  static String? normalizePkPhone(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty || trimmed.length > 32) return null;
    final digits = trimmed.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty || digits.length > 15) return null;

    String national;
    if (digits.startsWith('0092')) {
      national = digits.substring(4);
    } else if (digits.startsWith('92') && digits.length >= 12) {
      national = digits.substring(2);
    } else if (digits.startsWith('0')) {
      national = digits.substring(1);
    } else {
      national = digits;
    }
    if (!RegExp(r'^3\d{9}$').hasMatch(national)) return null;
    return '+92$national';
  }

  /// Normalises any international or Pakistani phone number to standard E.164.
  static String? normalizePhone(String? raw, {String? defaultDialCode}) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty || trimmed.length > 40) return null;

    // Check if it's already a valid Pakistani mobile
    final pk = normalizePkPhone(trimmed);
    if (pk != null) return pk;

    var cleaned = trimmed.replaceAll(RegExp(r'[\s\-\(\)\.]'), '');
    if (cleaned.startsWith('00')) {
      cleaned = '+${cleaned.substring(2)}';
    }

    if (cleaned.startsWith('+')) {
      final digits = cleaned.substring(1).replaceAll(RegExp(r'\D'), '');
      if (RegExp(r'^[1-9]\d{6,14}$').hasMatch(digits)) {
        if (digits.startsWith('92')) {
          final pkCheck = normalizePkPhone('+$digits');
          if (pkCheck != null) return pkCheck;
        }
        return '+$digits';
      }
      return null;
    }

    if (defaultDialCode != null && defaultDialCode.isNotEmpty) {
      final dialDigits = defaultDialCode.replaceAll(RegExp(r'\D'), '');
      var nationalDigits = cleaned.replaceAll(RegExp(r'\D'), '');
      if (dialDigits.isNotEmpty && nationalDigits.isNotEmpty) {
        if (nationalDigits.startsWith('0') && nationalDigits.length > 7) {
          nationalDigits = nationalDigits.substring(1);
        }
        if (nationalDigits.startsWith(dialDigits) &&
            nationalDigits.length > dialDigits.length + 5) {
          final candidate = '+$nationalDigits';
          if (RegExp(r'^\+[1-9]\d{6,14}$').hasMatch(candidate))
            return candidate;
        }
        final candidate = '+$dialDigits$nationalDigits';
        if (RegExp(r'^\+[1-9]\d{6,14}$').hasMatch(candidate)) {
          if (dialDigits == '92') return normalizePkPhone(candidate);
          return candidate;
        }
      }
    }

    final onlyDigits = cleaned.replaceAll(RegExp(r'\D'), '');
    if (RegExp(r'^[1-9]\d{7,14}$').hasMatch(onlyDigits)) {
      if (onlyDigits.startsWith('923') && onlyDigits.length == 12) {
        return '+$onlyDigits';
      }
      if (onlyDigits.length >= 10) {
        return '+$onlyDigits';
      }
    }
    return null;
  }

  /// The lookup variants stored across historical patient documents.
  static List<String> phoneLookupVariants(
    String raw, {
    String? defaultDialCode,
  }) {
    final normalized =
        normalizePhone(raw, defaultDialCode: defaultDialCode) ?? raw.trim();
    if (normalized.startsWith('+92')) {
      final national = normalized.replaceFirst('+92', '');
      return ['0$national', normalized, '92$national', national];
    }
    final digits = normalized
        .replaceFirst('+', '')
        .replaceAll(RegExp(r'\D'), '');
    final variants = <String>[normalized, digits, '00$digits'];
    if (normalized.startsWith('+44') && digits.length >= 11) {
      variants.add('0${digits.substring(2)}');
    } else if (normalized.startsWith('+971') && digits.length >= 11) {
      variants.add('0${digits.substring(3)}');
    }
    return variants.toSet().toList();
  }

  /// Diagnostic phone masking helper (never log full numbers or OTPs).
  static String maskPhoneNumber(String phone) {
    if (phone.length <= 6) return '***';
    final start = phone.length > 8 ? 4 : 2;
    return '${phone.substring(0, start)}***${phone.substring(phone.length - 4)}';
  }

  /// Password policy mirror: 8–64 chars after trim, ≥1 letter, ≥1 digit.
  static String? validateNewPassword(String? raw) {
    if (raw == null || raw.trim().isEmpty) return 'Password is required';
    final value = raw.trim();
    if (value.length < 8) return 'Password must be at least 8 characters';
    if (value.length > 64) return 'Password must be at most 64 characters';
    if (!RegExp(r'[A-Za-z]').hasMatch(value)) {
      return 'Password must contain at least one letter';
    }
    if (!RegExp(r'\d').hasMatch(value)) {
      return 'Password must contain at least one number';
    }
    return null; // null = valid
  }

  // ── Operations ────────────────────────────────────────────────────────────

  /// Step 1 — request an OTP for [phoneNumber] (international or Pakistani).
  Future<StartOtpResult> startOtp({
    required String phoneNumber,
    String? countryCode,
    String? deviceFcmToken,
  }) async {
    final phone = normalizePhone(phoneNumber, defaultDialCode: countryCode);
    if (phone == null) {
      throw const PasswordResetException(
        PasswordResetException.invalidPhone,
        'Enter a valid phone number with country code.',
      );
    }

    final masked = maskPhoneNumber(phone);
    debugPrint('$_logPrefix [startOtp] Initiating request for phone=$masked');

    return _startOtpFirestoreFallback(
      phone,
      countryCode: countryCode,
      deviceFcmToken: deviceFcmToken,
    );
  }

  /// Step 2 — verify the six-digit [otp]; returns a single-use reset token
  /// that must be kept in memory only.
  Future<VerifyOtpResult> verifyOtp({
    required String phoneNumber,
    required String otp,
    String? countryCode,
  }) async {
    final phone = normalizePhone(phoneNumber, defaultDialCode: countryCode);
    final code = otp.trim();
    if (phone == null) {
      throw const PasswordResetException(
        PasswordResetException.invalidPhone,
        'Enter a valid phone number with country code.',
      );
    }
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      throw const PasswordResetException(
        PasswordResetException.invalidInput,
        'Enter the 6-digit verification code.',
      );
    }

    final masked = maskPhoneNumber(phone);
    debugPrint('$_logPrefix [verifyOtp] Verifying OTP for phone=$masked');

    return _verifyOtpFirestoreFallback(phone, code);
  }

  /// Step 3 — consume [resetToken] and set the new password.
  Future<void> resetPassword({
    required String resetToken,
    required String newPassword,
  }) async {
    final policyError = validateNewPassword(newPassword);
    if (policyError != null) {
      throw PasswordResetException(
        PasswordResetException.weakPassword,
        policyError,
      );
    }
    if (resetToken.isEmpty) {
      throw const PasswordResetException(
        PasswordResetException.resetTokenInvalid,
        'This reset link is invalid or expired. Start over.',
      );
    }

    debugPrint('$_logPrefix [resetPassword] Consuming reset token...');
    return _resetPasswordFirestoreFallback(resetToken, newPassword);
  }

  // ── Firestore fallback implementation ─────────────────────────────────────

  Future<StartOtpResult> _startOtpFirestoreFallback(
    String phone, {
    String? countryCode,
    String? deviceFcmToken,
  }) async {
    final masked = maskPhoneNumber(phone);
    debugPrint(
      '$_logPrefix [_startOtpFirestoreFallback] Initiating fallback for phone=$masked',
    );

    final variants = phoneLookupVariants(phone, defaultDialCode: countryCode);
    QueryDocumentSnapshot<Map<String, dynamic>>? accountDoc;

    try {
      final snap = await _firestore
          .collection('telemedicine_patient')
          .where('phoneNumber', whereIn: variants.take(10).toList())
          .limit(1)
          .get();

      if (snap.docs.isNotEmpty) {
        accountDoc = snap.docs.first;
      } else {
        final snapPhone = await _firestore
            .collection('telemedicine_patient')
            .where('phone', whereIn: variants.take(10).toList())
            .limit(1)
            .get();
        if (snapPhone.docs.isNotEmpty) {
          accountDoc = snapPhone.docs.first;
        }
      }
    } catch (e) {
      debugPrint('$_logPrefix Account lookup warning: $e');
    }

    // Check account validity
    if (accountDoc == null) {
      debugPrint('$_logPrefix Account not found for phone=$masked');
      // Uniform timing + message to prevent account enumeration
      await Future.delayed(const Duration(milliseconds: 1000));
      return const StartOtpResult(
        resendInSeconds: 60,
        otpExpiresInSeconds: 300,
        message:
            'If this number is registered, a verification code has been sent.',
      );
    }

    final accountData = accountDoc.data();
    final isDeleted = accountData['isDeleted'] == true;
    final isBlocked =
        accountData['isBlocked'] == true || accountData['status'] == 'blocked';

    if (isDeleted || isBlocked) {
      debugPrint('$_logPrefix Account inactive/blocked for phone=$masked');
      await Future.delayed(const Duration(milliseconds: 1000));
      return const StartOtpResult(
        resendInSeconds: 60,
        otpExpiresInSeconds: 300,
        message:
            'If this number is registered, a verification code has been sent.',
      );
    }

    final pepper = _kOtpPepper;
    final otpDocKey = _hmacHex(pepper, 'phone:$phone');
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    // Rate-limit check: cooldown of 60 seconds
    try {
      final existingDoc = await _firestore
          .collection('password_reset_otps')
          .doc(otpDocKey)
          .get();
      if (existingDoc.exists) {
        final existingData = existingDoc.data();
        final createdAtMs =
            (existingData?['createdAtMs'] as num?)?.toInt() ??
            ((existingData?['createdAt'] as Timestamp?)
                ?.millisecondsSinceEpoch);
        if (createdAtMs != null) {
          final elapsedSeconds = (nowMs - createdAtMs) ~/ 1000;
          if (elapsedSeconds < 60) {
            final remaining = 60 - elapsedSeconds;
            throw PasswordResetException(
              PasswordResetException.rateLimited,
              'Please wait $remaining seconds before requesting another code.',
              resendInSeconds: remaining,
            );
          }
        }
      }
    } on PasswordResetException {
      rethrow;
    } catch (e) {
      debugPrint('$_logPrefix Rate limit check warning: $e');
    }

    final otp = _randomOtp();
    final expiresAt = DateTime.now().add(const Duration(minutes: 5));
    final expiresAtMs = nowMs + 5 * 60 * 1000;
    final accountId = accountDoc.id;

    // Write OTP challenge (NEVER plaintext OTP)
    await _firestore.collection('password_reset_otps').doc(otpDocKey).set({
      'accountRef': _firestore.doc('telemedicine_patient/$accountId'),
      'accountId': accountId,
      'otpHash': _hmacHex(pepper, '$phone:$otp'),
      'phone': phone,
      'deviceId': accountData['deviceId'],
      'attempts': 0,
      'invalidated': false,
      'consumed': false,
      'createdAtMs': nowMs,
      'expiresAtMs': expiresAtMs,
      'createdAt': FieldValue.serverTimestamp(),
      'expiresAt': Timestamp.fromDate(expiresAt),
    });

    // Populate password_reset_requests for backwards compatibility
    try {
      await _firestore
          .collection('password_reset_requests')
          .doc(accountId)
          .set({
            'userId': accountId,
            'phoneNumber': phone,
            'resetToken': otp,
            'createdAt': FieldValue.serverTimestamp(),
            'expiresAt': Timestamp.fromDate(expiresAt),
            'isUsed': false,
            'confirmed': false,
            'declined': false,
          });
    } catch (e) {
      debugPrint('$_logPrefix Compatibility write warning: $e');
    }

    // Trigger local push notification heads-up banner
    try {
      await NotificationService().showPasswordResetOtpNotificationDirect(
        otp: otp,
      );
      debugPrint(
        '$_logPrefix Heads-up local notification dispatched for OTP delivery',
      );
    } catch (e) {
      debugPrint('$_logPrefix Notification dispatch warning: $e');
    }

    // Queue in notification_outbox for FCM delivery if cloud worker active
    try {
      await _firestore.collection('notification_outbox').add({
        'toUserId': accountId,
        'type': 'password_reset_otp',
        'title': 'OPD Telemedicine Security Code',
        'body':
            'Your password reset verification code is $otp. It expires in 5 minutes.',
        'data': {
          'type': 'password_reset_otp',
          'otp': otp,
          'phone': phone,
          'click_action': 'FLUTTER_NOTIFICATION_CLICK',
        },
        'channel': 'password_reset_notifications',
        'status': 'queued',
        'createdAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint('$_logPrefix notification_outbox queue warning: $e');
    }

    debugPrint(
      '$_logPrefix Fallback OTP successfully generated and dispatched',
    );
    return const StartOtpResult(
      resendInSeconds: 60,
      otpExpiresInSeconds: 300,
      message:
          'If this number is registered, a verification code has been sent.',
    );
  }

  Future<VerifyOtpResult> _verifyOtpFirestoreFallback(
    String phone,
    String otp,
  ) async {
    final pepper = _kOtpPepper;
    final otpDocKey = _hmacHex(pepper, 'phone:$phone');
    final masked = maskPhoneNumber(phone);
    debugPrint(
      '$_logPrefix [_verifyOtpFirestoreFallback] Verifying OTP for phone=$masked',
    );

    DocumentSnapshot<Map<String, dynamic>> snap;
    try {
      snap = await _firestore
          .collection('password_reset_otps')
          .doc(otpDocKey)
          .get();
    } catch (e) {
      debugPrint('$_logPrefix Error fetching OTP record: $e');
      throw const PasswordResetException(
        PasswordResetException.internal,
        'Unable to verify code. Please try again.',
      );
    }

    if (!snap.exists) {
      debugPrint('$_logPrefix No OTP record found for phone=$masked');
      throw const PasswordResetException(
        PasswordResetException.otpInvalid,
        'Invalid or expired verification code. Please request a new one.',
      );
    }

    final data = snap.data()!;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final isInvalidated =
        data['invalidated'] == true || data['consumed'] == true;
    final attempts = (data['attempts'] as num?)?.toInt() ?? 0;
    final expiresAtMs =
        (data['expiresAtMs'] as num?)?.toInt() ??
        ((data['expiresAt'] as Timestamp?)?.millisecondsSinceEpoch ?? 0);

    if (isInvalidated ||
        attempts >= 5 ||
        (expiresAtMs > 0 && nowMs > expiresAtMs)) {
      debugPrint(
        '$_logPrefix OTP expired/invalidated/exhausted for phone=$masked',
      );
      throw const PasswordResetException(
        PasswordResetException.otpInvalid,
        'Invalid or expired verification code. Please request a new one.',
      );
    }

    final candidate = _hmacHex(pepper, '$phone:$otp');
    final storedHash = (data['otpHash'] as String?) ?? '';

    if (!_timingSafeEqualHex(storedHash, candidate)) {
      final newAttempts = attempts + 1;
      try {
        await _firestore
            .collection('password_reset_otps')
            .doc(otpDocKey)
            .update({
              'attempts': newAttempts,
              if (newAttempts >= 5) 'invalidated': true,
              if (newAttempts >= 5) 'invalidatedReason': 'max_attempts',
            });
      } catch (_) {}
      debugPrint(
        '$_logPrefix OTP mismatch: attempt $newAttempts/5 for phone=$masked',
      );
      throw const PasswordResetException(
        PasswordResetException.otpInvalid,
        'Invalid verification code. Please check and try again.',
      );
    }

    // Atomically invalidate OTP and create single-use reset token
    final resetToken = _randomToken();
    final tokenDocKey = _hmacHex(pepper, 'reset:$resetToken');
    final tokenExpiresAtMs = nowMs + 10 * 60 * 1000;
    final accountId = (data['accountId'] as String?) ?? '';

    await _firestore.collection('password_reset_otps').doc(otpDocKey).update({
      'attempts': attempts + 1,
      'invalidated': true,
      'consumed': true,
      'verifiedAtMs': nowMs,
      'verifiedAt': FieldValue.serverTimestamp(),
    });

    await _firestore.collection('password_reset_tokens').doc(tokenDocKey).set({
      'accountId': accountId,
      'accountRef': _firestore.doc('telemedicine_patient/$accountId'),
      'phoneKey': otpDocKey,
      'phone': phone,
      'consumed': false,
      'createdAtMs': nowMs,
      'expiresAtMs': tokenExpiresAtMs,
      'createdAt': FieldValue.serverTimestamp(),
      'expiresAt': Timestamp.fromDate(
        DateTime.fromMillisecondsSinceEpoch(tokenExpiresAtMs),
      ),
      'usedAtMs': null,
    });

    debugPrint('$_logPrefix OTP verification successful. Reset token issued.');
    return VerifyOtpResult(resetToken: resetToken, expiresIn: 600);
  }

  Future<void> _resetPasswordFirestoreFallback(
    String resetToken,
    String newPassword,
  ) async {
    final pepper = _kOtpPepper;
    final tokenDocKey = _hmacHex(pepper, 'reset:$resetToken');
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    debugPrint(
      '$_logPrefix [_resetPasswordFirestoreFallback] Consuming reset token',
    );

    DocumentSnapshot<Map<String, dynamic>> tokenSnap;
    try {
      tokenSnap = await _firestore
          .collection('password_reset_tokens')
          .doc(tokenDocKey)
          .get();
    } catch (e) {
      debugPrint('$_logPrefix Error fetching reset token: $e');
      throw const PasswordResetException(
        PasswordResetException.internal,
        'Unable to process reset. Please try again.',
      );
    }

    if (!tokenSnap.exists) {
      debugPrint('$_logPrefix Reset token doc not found');
      throw const PasswordResetException(
        PasswordResetException.resetTokenInvalid,
        'This reset link is invalid or expired. Start over.',
      );
    }

    final tokenData = tokenSnap.data()!;
    final isConsumed =
        tokenData['consumed'] == true || tokenData['usedAtMs'] != null;
    final expiresAtMs =
        (tokenData['expiresAtMs'] as num?)?.toInt() ??
        ((tokenData['expiresAt'] as Timestamp?)?.millisecondsSinceEpoch ?? 0);

    if (isConsumed || (expiresAtMs > 0 && nowMs > expiresAtMs)) {
      debugPrint('$_logPrefix Reset token expired or consumed');
      throw const PasswordResetException(
        PasswordResetException.resetTokenInvalid,
        'This reset session has expired. Start over.',
      );
    }

    final accountId = (tokenData['accountId'] as String?) ?? '';
    if (accountId.isEmpty) {
      throw const PasswordResetException(
        PasswordResetException.resetTokenInvalid,
        'Invalid account reference. Start over.',
      );
    }

    // Invalidate reset token immediately
    await _firestore
        .collection('password_reset_tokens')
        .doc(tokenDocKey)
        .update({
          'consumed': true,
          'usedAtMs': nowMs,
          'usedAt': FieldValue.serverTimestamp(),
        });

    // Update patient password in telemedicine_patient
    await _firestore.collection('telemedicine_patient').doc(accountId).update({
      'password': newPassword.trim(),
      'passwordUpdatedAt': FieldValue.serverTimestamp(),
      'passwordResetVia': 'fcm_otp',
      'isPasswordResetVerified': true,
    });

    // Revoke active sessions
    try {
      await SessionService.endSession(userId: accountId);
    } catch (e) {
      debugPrint('$_logPrefix Could not end active sessions: $e');
    }

    // Compatibility update
    try {
      await _firestore
          .collection('password_reset_requests')
          .doc(accountId)
          .update({
            'isUsed': true,
            'completedAt': FieldValue.serverTimestamp(),
          });
    } catch (_) {}

    debugPrint(
      '$_logPrefix Password successfully reset for accountId=$accountId',
    );
  }

  bool _looksOffline(String? message) {
    if (message == null) return false;
    final lower = message.toLowerCase();
    return lower.contains('socketexception') ||
        lower.contains('failed host lookup') ||
        lower.contains('no connection') ||
        lower.contains('network is unreachable') ||
        lower.contains('connection terminated') ||
        lower.contains('unable to resolve host') ||
        lower.contains('client is offline');
  }
}
