import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:telemedicine/core/utils/phone_utils.dart';

/// Result of checking phone number availability.
class PhoneAvailabilityResult {
  final bool isAvailable;
  final bool isRegistered;
  final String normalizedPhone;
  final String message;
  final String? role;
  final String? userId;
  final bool hasPatientId;
  final String? error;

  const PhoneAvailabilityResult({
    required this.isAvailable,
    required this.isRegistered,
    required this.normalizedPhone,
    required this.message,
    this.role,
    this.userId,
    this.hasPatientId = false,
    this.error,
  });

  factory PhoneAvailabilityResult.available(String normalizedPhone) {
    return PhoneAvailabilityResult(
      isAvailable: true,
      isRegistered: false,
      normalizedPhone: normalizedPhone,
      message: 'Phone number is available.',
    );
  }

  factory PhoneAvailabilityResult.alreadyRegistered({
    required String normalizedPhone,
    String? role,
    String? userId,
    bool hasPatientId = false,
    String? customMessage,
  }) {
    return PhoneAvailabilityResult(
      isAvailable: false,
      isRegistered: true,
      normalizedPhone: normalizedPhone,
      role: role,
      userId: userId,
      hasPatientId: hasPatientId,
      message:
          customMessage ??
          'This phone number is already registered. Please log in instead.',
    );
  }

  factory PhoneAvailabilityResult.invalid(String rawPhone) {
    return PhoneAvailabilityResult(
      isAvailable: false,
      isRegistered: false,
      normalizedPhone: rawPhone,
      error: 'INVALID_FORMAT',
      message: 'Please enter a valid phone number with country code.',
    );
  }
}

/// Service to verify phone number availability and uniqueness.
class PhoneVerificationService {
  static const String region = 'asia-south1';
  static const String fallbackRegion = 'us-central1';
  static const String _callableName = 'checkPhoneAvailability';
  static const String registeredPhonesCollection = 'registered_phones';

  final FirebaseFirestore _firestore;
  final FirebaseFunctions _functions;

  PhoneVerificationService({
    FirebaseFirestore? firestore,
    FirebaseFunctions? functions,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _functions = functions ?? FirebaseFunctions.instanceFor(region: region);

  /// Checks if [rawPhone] is available or already registered in the system.
  Future<PhoneAvailabilityResult> checkPhoneAvailability(
    String rawPhone, {
    String role = 'patient',
    String defaultDialCode = '+92',
  }) async {
    final normalized = PhoneUtils.normalizePhone(
      rawPhone,
      defaultDialCode: defaultDialCode,
    );
    if (normalized == null || !PhoneUtils.isValidE164(normalized)) {
      return PhoneAvailabilityResult.invalid(rawPhone);
    }

    // 1. Try Cloud Functions callable
    try {
      final callable = _functions.httpsCallable(_callableName);
      final response = await callable.call<Map<String, dynamic>>({
        'phone': normalized,
        'role': role,
        'countryCode': defaultDialCode,
      });

      final data = Map<String, dynamic>.from(response.data);
      final isRegistered = data['is_registered'] == true;
      final isSuccess = data['success'] == true;

      if (isRegistered) {
        return PhoneAvailabilityResult.alreadyRegistered(
          normalizedPhone: normalized,
          role: data['role']?.toString(),
          userId: data['user_id']?.toString(),
          hasPatientId: data['has_patient_id'] == true,
          customMessage: data['message']?.toString(),
        );
      }

      if (isSuccess) {
        return PhoneAvailabilityResult.available(normalized);
      }
    } catch (e) {
      debugPrint(
        '[PhoneVerificationService] Cloud Function failed or unavailable: $e. Falling back to direct Firestore check.',
      );
    }

    // 2. Direct Firestore fallback (resilient offline/direct mode)
    return _checkDirectFirestore(
      normalized,
      role: role,
      defaultDialCode: defaultDialCode,
    );
  }

  /// Direct Firestore fallback query.
  Future<PhoneAvailabilityResult> _checkDirectFirestore(
    String normalizedPhone, {
    required String role,
    required String defaultDialCode,
  }) async {
    final variants = PhoneUtils.phoneLookupVariants(
      normalizedPhone,
      defaultDialCode: defaultDialCode,
    );

    try {
      // Check registered_phones index doc
      final phoneDoc = await _firestore
          .collection(registeredPhonesCollection)
          .doc(normalizedPhone)
          .get();
      if (phoneDoc.exists) {
        final data = phoneDoc.data() ?? {};
        final existingRole = data['role']?.toString() ?? 'patient';
        final existingUserId = data['userId']?.toString();

        return PhoneAvailabilityResult.alreadyRegistered(
          normalizedPhone: normalizedPhone,
          role: existingRole,
          userId: existingUserId,
          hasPatientId: data['patientId'] != null,
        );
      }

      // Check telemedicine_patient
      final patientQuery = await _firestore
          .collection('telemedicine_patient')
          .where('phoneNumber', whereIn: variants)
          .limit(5)
          .get();

      for (final doc in patientQuery.docs) {
        final data = doc.data();
        if (data['isDeleted'] == true) continue;

        final hasPid =
            data['patientId'] != null &&
            data['patientId'].toString().trim().isNotEmpty;
        return PhoneAvailabilityResult.alreadyRegistered(
          normalizedPhone: normalizedPhone,
          role: 'patient',
          userId: doc.id,
          hasPatientId: hasPid,
        );
      }

      // Check telemedicine_doctors
      final doctorQuery = await _firestore
          .collection('telemedicine_doctors')
          .where('phoneNumber', whereIn: variants)
          .limit(5)
          .get();

      for (final doc in doctorQuery.docs) {
        final data = doc.data();
        if (data['isDeleted'] == true) continue;

        return PhoneAvailabilityResult.alreadyRegistered(
          normalizedPhone: normalizedPhone,
          role: 'doctor',
          userId: doc.id,
          hasPatientId: false,
        );
      }

      return PhoneAvailabilityResult.available(normalizedPhone);
    } catch (e) {
      debugPrint('[PhoneVerificationService] Direct Firestore check error: $e');
      // If Firestore read fails, rethrow or return safe fallback
      rethrow;
    }
  }

  /// Records the phone in `registered_phones` uniqueness index doc atomically.
  Future<void> claimPhoneUniqueness(
    String normalizedPhone, {
    required String userId,
    required String role,
    String? patientId,
  }) async {
    final docRef = _firestore
        .collection(registeredPhonesCollection)
        .doc(normalizedPhone);
    await docRef.set({
      'phone': normalizedPhone,
      'userId': userId,
      'role': role,
      'patientId': patientId,
      'registeredAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }
}
