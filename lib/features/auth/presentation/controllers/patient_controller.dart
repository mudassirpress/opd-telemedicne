import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:telemedicine/data/models/user_model.dart';
import 'package:telemedicine/core/services/device_service.dart';
import 'package:telemedicine/core/services/notification_dispatcher.dart';
import 'package:telemedicine/core/services/notification_service.dart';
import 'package:telemedicine/core/services/patient_presence_service.dart';
import 'package:telemedicine/core/services/account_expiry_service.dart';
import 'package:telemedicine/core/services/session_service.dart';
import 'package:telemedicine/core/services/soft_delete_service.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/core/utils/firestore_time.dart';
import 'package:telemedicine/features/chat/presentation/controllers/chat_controller.dart';
import 'package:telemedicine/features/auth/data/services/patient_password_reset_service.dart';
import 'package:telemedicine/features/auth/data/services/phone_verification_service.dart';
import 'package:firebase_auth/firebase_auth.dart' hide EmailAuthProvider;
import 'package:telemedicine/features/auth/data/services/phone_auth_service.dart';
import 'package:telemedicine/core/services/single_device_session_service.dart';
import 'package:telemedicine/core/utils/subscription_calculator.dart';
import 'package:telemedicine/data/models/patient_id_model.dart';
import 'package:uuid/uuid.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Device-restriction rules (single source of truth)
//
//   • role == 'admin'           → NEVER restricted  (any device)
//   • role == 'patient'         → restricted UNLESS exempt account
//   • role == 'doctor'          → NEVER restricted  (doctors travel between
//                                  devices; add restriction here if needed)
//   • exempt phone + password   → NEVER restricted  (test / support account)
// ─────────────────────────────────────────────────────────────────────────────
const String _kExemptPhone = "03356975643";
const String _kExemptPassword = "Sherdil@123";

/// Returns true when the given [role] / [phoneNumber] combination must be

bool _requiresDeviceCheck({required String role, required String phoneNumber}) {
  // iOS par device check bilkul disable
  if (Platform.isIOS) {
    print('🍎 iOS detected - Device check disabled');
    return false;
  }

  // Admins
  if (role == 'admin') {
    return false;
  }

  // Doctors
  if (role == 'doctor') {
    return false;
  }

  // Exempt account
  if (phoneNumber == _kExemptPhone ||
      phoneNumber == '+923356975643' ||
      phoneNumber == '923356975643') {
    return false;
  }

  // Sirf Android patients
  return role == 'patient';
}

class PatientController extends ChangeNotifier {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  bool _isLoading = false;
  String _errorMessage = '';
  UserModel? _currentUser;
  String? _currentSessionId;
  StreamSubscription? _sessionSubscription;

  bool get isLoading => _isLoading;
  String get errorMessage => _errorMessage;
  UserModel? get currentUser => _currentUser;
  bool _isPatientOnline = false;
  bool get isPatientOnline => _isPatientOnline;

  // ── Presence service ──────────────────────────────────────────────────
  late final PatientPresenceService _presenceService;

  PatientController() {
    _presenceService = PatientPresenceService(
      delegate: _PatientPresenceDelegateImpl(this),
    );
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Device-ID helper with persistent storage
  // ───────────────────────────────────────────────────────────────────────────

  static double _safeDouble(dynamic value) {
    if (value == null) return 0.0;
    if (value is double) return value;
    if (value is int) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0.0;
    return 0.0;
  }

  Future<String> getDeviceId() => DeviceService.getDeviceId();

  /// Clears the persistent device ID (call on logout if needed)
  Future<void> clearPersistentDeviceId() =>
      DeviceService.clearPersistentDeviceId();

  // ───────────────────────────────────────────────────────────────────────────
  // Online-status helpers
  // ───────────────────────────────────────────────────────────────────────────

  Stream<bool> getPatientOnlineStatus(String patientId) =>
      _presenceService.getPatientOnlineStatus(patientId);

  Future<void> updatePatientOnlineStatus(bool isOnline) =>
      _presenceService.updatePatientOnlineStatus(isOnline);

  /// Initialize presence: set online, start heartbeat, listen for connectivity.
  Future<void> initializePatientPresence() =>
      _presenceService.initializePatientPresence();

  /// Heartbeat every 15 seconds — writes lastHeartbeat so the Cloud Function
  /// can distinguish a live client from one that merely set isOnline=true once.
  void startPresenceTracking() => _presenceService.startPresenceTracking();

  /// Stop the heartbeat timer.
  void stopPresenceTracking() => _presenceService.stopPresenceTracking();

  /// Stop the connectivity listener.
  void _stopConnectivityListener() =>
      _presenceService.stopConnectivityListener();

  Stream<bool> getPatientOnlineStatusStream(String patientId) =>
      _presenceService.getPatientOnlineStatusStream(patientId);

  // ───────────────────────────────────────────────────────────────────────────
  // Session persistence
  // ───────────────────────────────────────────────────────────────────────────

  Future<void> loadSavedUser({bool forceRefresh = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();

      if (forceRefresh && _currentUser != null && _currentUser!.id.isNotEmpty) {
        print('🔄 Force refreshing user data from Firestore…');
        final freshUser = await getUserById(_currentUser!.id);
        if (freshUser != null) {
          if (freshUser.isDeleted == true) {
            print('❌ Account is deleted, clearing local data');
            await _clearSavedUser();
            _currentUser = null;
            notifyListeners();
            return;
          }
          _currentUser = freshUser;
          await _saveUserToLocalStorage(freshUser);
          print('✅ User data force-refreshed from Firestore');
          notifyListeners();
          return;
        } else {
          print('❌ User not found in Firestore, clearing local data');
          await _clearSavedUser();
          _currentUser = null;
          notifyListeners();
          return;
        }
      }

      final userJson = prefs.getString('current_user');
      print('Loading saved user, raw JSON: $userJson');

      if (userJson != null && userJson.isNotEmpty) {
        final Map<String, dynamic> userData = json.decode(userJson);

        if (userData['role'] == 'guest') {
          print('👤 Restoring guest mode session');
          _currentUser = UserModel.guest();
          notifyListeners();
          return;
        }

        if (userData['id'] == null || userData['id'].toString().isEmpty) {
          print('❌ Invalid user data: missing ID');
          await _clearSavedUser();
          _currentUser = null;
          notifyListeners();
          return;
        }

        DocumentSnapshot<Map<String, dynamic>> userDoc;
        try {
          userDoc = await _firestore
              .collection('telemedicine_patient')
              .doc(userData['id'])
              .get()
              // Bounded so a poor/offline network can never freeze the splash
              // screen waiting for a server acknowledgement.
              .timeout(const Duration(seconds: 8));
        } catch (e) {
          // Offline / transient failure: fall back to the cached session so a
          // dropped connection never logs the patient out or blocks startup.
          // The in-session expiry/payment checks re-verify once online.
          print('⚠️ Session refresh unavailable, using cached user: $e');
          _restoreCachedSessionOnly(userData);
          return;
        }

        if (!userDoc.exists) {
          print('❌ User no longer exists in database');
          await _clearSavedUser();
          _currentUser = null;
          notifyListeners();
          return;
        }

        final firestoreData = userDoc.data()!;

        if (firestoreData['isDeleted'] == true) {
          print('❌ Account is marked as deleted, clearing local data');
          await _clearSavedUser();
          _currentUser = null;
          notifyListeners();
          return;
        }

        final phoneNumber = firestoreData['phoneNumber'] ?? '';
        final role = firestoreData['role'] ?? 'patient';
        final needsCheck = _requiresDeviceCheck(
          role: role,
          phoneNumber: phoneNumber,
        );

        print('✅ Role: $role | Needs device check on load: $needsCheck');

        _isPatientOnline = firestoreData['isOnline'] ?? false;

        _currentUser = UserModel(
          id: userDoc.id,
          fullname: firestoreData['fullname'] ?? '',
          image: firestoreData['image'],
          // Store empty deviceId for accounts that don't need a device check
          deviceId: needsCheck ? (firestoreData['deviceId'] ?? '') : '',
          idcard: firestoreData['idcard'] ?? '',
          password: firestoreData['password'] ?? '',
          token: firestoreData['token'] ?? '',
          role: role,
          phoneNumber: phoneNumber,
          ispayment: firestoreData['ispayment'] ?? false,
          totalPayment: _safeDouble(firestoreData['totalPayment']),
          paymentImage: firestoreData['paymentImage'],
          highestDegree: firestoreData['highestDegree'],
          doctorId: firestoreData['doctorId'],
          paymentStatus: firestoreData['paymentStatus'],
          rejectionReason: firestoreData['rejectionReason'],
          paymentSubmittedAt: firestoreData['paymentSubmittedAt'] != null
              ? DateTime.tryParse(firestoreData['paymentSubmittedAt'])
              : null,
          fcmToken: firestoreData['fcmToken'],
          isDeleted: firestoreData['isDeleted'] ?? false,
          loginType: firestoreData['loginType'],
          patientId: firestoreData['patientId'],
          expiryDate:
              (await _fetchPatientExpiryDate(
                firestoreData['patientId'],
                userDoc.id,
              )) ??
              _parseAnyExpiryDate(
                firestoreData['expiryDate'] ??
                    firestoreData['patientCardExpiryDate'] ??
                    firestoreData['cardValidUntil'],
              ),
          cardStatus: firestoreData['cardStatus']?.toString(),
        );

        // Check if patient is expired. The session is intentionally KEPT so
        // the splash screen can route the patient to ExpiredPatientScreen
        // (reactivation) instead of silently dumping them on sign-in, and so a
        // cold start while expired is consistent with the in-session expiry
        // redirect.
        if (_currentUser!.isExpired) {
          print(
            '⚠️ Patient ID expired – keeping session for reactivation route',
          );
          await _saveUserToLocalStorage(_currentUser!);
          notifyListeners();
          return;
        }

        await _saveUserToLocalStorage(_currentUser!);

        // For accounts that don't need a device check, clear the deviceId
        // in Firestore so it never gets used as a lock in the future.
        // Fire-and-forget: an offline write must never block startup.
        if (!needsCheck) {
          unawaited(
            _firestore
                .collection('telemedicine_patient')
                .doc(userDoc.id)
                .update({'deviceId': '', 'activeDeviceId': null})
                .then(
                  (_) => print(
                    '✅ Cleared deviceId for non-restricted account ($role)',
                  ),
                )
                .catchError(
                  (Object e) => print(
                    '⚠️ Could not clear deviceId (will retry next launch): $e',
                  ),
                ),
          );
        } else {
          // If restricted patient account: ensure session record is claimed/initialized for current device
          final currentDevId = await getDeviceId();
          final storedActiveId = firestoreData['activeDeviceId'] as String?;
          final storedDeviceId = firestoreData['deviceId'] as String?;

          // If activeDeviceId is null, or legacy build string (not valid installation ID), update it
          if (storedActiveId == null ||
              storedActiveId.isEmpty ||
              !DeviceService.isValidInstallationId(storedActiveId) ||
              firestoreData['isLoggedIn'] != true) {
            unawaited(
              userDoc.reference.update({
                'activeDeviceId': currentDevId,
                'deviceId': storedDeviceId != null &&
                        storedDeviceId.isNotEmpty &&
                        DeviceService.isValidInstallationId(storedDeviceId)
                    ? storedDeviceId
                    : currentDevId,
                'isLoggedIn': true,
                'lastLoginAt': FieldValue.serverTimestamp(),
              }).catchError((e) {
                print('⚠️ Error updating session record on load: $e');
              }),
            );
          }
        }

        print('✅ User loaded – Payment Status: ${_currentUser?.paymentStatus}');
        print('✅ User: ${_currentUser?.fullname} (ID: ${_currentUser?.id})');
        notifyListeners();

        // Start presence tracking for patients on app startup
        if (role == 'patient' && !_currentUser!.isExpired) {
          initializePatientPresence();
          _startSingleDeviceSessionWatcher(_currentUser!.id);
        }
      } else {
        _currentUser = null;
        notifyListeners();
      }
    } catch (e) {
      // A transient failure while refreshing the session must never sign the
      // patient out — fall back to whatever was cached locally.
      print('Error loading saved user: $e');
      try {
        final prefs = await SharedPreferences.getInstance();
        final userJson = prefs.getString('current_user');
        if (userJson != null && userJson.isNotEmpty) {
          _restoreCachedSessionOnly(
            json.decode(userJson) as Map<String, dynamic>,
          );
          return;
        }
      } catch (_) {
        // fall through to a clean signed-out state below
      }
      _currentUser = null;
      notifyListeners();
    }
  }

  /// Restores the session purely from the locally cached user JSON, skipping
  /// every Firestore round-trip. Used when the network is unavailable so app
  /// startup never freezes and a signed-in patient is never logged out by a
  /// connectivity blip.
  void _restoreCachedSessionOnly(Map<String, dynamic> userData) {
    try {
      _currentUser = UserModel.fromMap(userData);
    } catch (e) {
      print('❌ Cached user data unusable: $e');
      _currentUser = null;
    }
    notifyListeners();
    if (_currentUser != null &&
        _currentUser!.role == 'patient' &&
        !_currentUser!.isExpired) {
      // Presence needs the network anyway — never block on it.
      unawaited(initializePatientPresence());
    }
  }

  Future<void> _saveUserToLocalStorage(UserModel user) async {
    try {
      if (user.id.isEmpty) {
        print('❌ Cannot save user with empty ID');
        return;
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('current_doctor');
      final userMap = user.toMap();
      await prefs.setString('current_user', json.encode(userMap));
      // Login (and every session refresh): validate the local chat cache for
      // this account and fetch it if it was never confirmed. A no-op when the
      // cache is already complete.
      unawaited(ChatController().recoverChatListIfNeeded());
      print(
        '✅ User saved – ${user.fullname}, ID: ${user.id}, '
        'Payment Status: ${user.paymentStatus}',
      );
    } catch (e) {
      print('Error saving user: $e');
    }
  }

  Future<void> _clearSavedUser() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('current_user');
      print('✅ User cleared from local storage');
    } catch (e) {
      print('Error clearing user: $e');
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // SIGN UP
  // ───────────────────────────────────────────────────────────────────────────

  Future<bool> signUp({
    required String fullname,
    required String password,
    required String phoneNumber,
    String? gender,
    int? age,
  }) async {
    _setLoading(true);
    _clearError();

    try {
      print('📝 Starting signup process…');

      final variants = PatientPasswordResetService.phoneLookupVariants(
        phoneNumber,
      );
      final docCheck = await _firestore
          .collection('telemedicine_patient')
          .where('phoneNumber', whereIn: variants)
          .get();

      final activePatientDocs = docCheck.docs
          .where((d) => (d.data()['isDeleted'] ?? false) != true)
          .toList();

      if (activePatientDocs.isNotEmpty) {
        _errorMessage =
            'This phone number is already registered. Please log in instead.';
        _setLoading(false);
        return false;
      }

      final docDoctorCheck = await _firestore
          .collection('telemedicine_doctors')
          .where('phoneNumber', whereIn: variants)
          .get();

      final activeDoctorDocs = docDoctorCheck.docs
          .where((d) => (d.data()['isDeleted'] ?? false) != true)
          .toList();

      if (activeDoctorDocs.isNotEmpty) {
        _errorMessage =
            'This phone number is already registered. Please log in instead.';
        _setLoading(false);
        return false;
      }

      String? fcmToken;
      try {
        fcmToken = await NotificationService().getToken();
      } catch (e) {
        print('⚠️ Error getting FCM token: $e');
      }
      String deviceId = '';
      // Store persistent device ID at signup time
      if (Platform.isAndroid) {
        deviceId = await getDeviceId();
      }
      print('✅ Device ID stored at signup: $deviceId');

      final userRef = _firestore.collection('telemedicine_patient').doc();

      UserModel user = UserModel(
        id: userRef.id,
        fullname: fullname,
        idcard: '',
        password: password,
        token: DateTime.now().millisecondsSinceEpoch.toString(),
        deviceId: deviceId,
        role: "patient",
        phoneNumber: phoneNumber,
        ispayment: false,
        totalPayment: 0.0,
        paymentImage: null,
        paymentStatus: null,
        fcmToken: fcmToken ?? '',
        loginType: 'normal',
        gender: gender,
        age: age,
      );

      await userRef.set(user.toMap());

      try {
        await PhoneVerificationService().claimPhoneUniqueness(
          phoneNumber,
          userId: userRef.id,
          role: 'patient',
        );
      } catch (e) {
        print('⚠️ Could not claim phone uniqueness: $e');
      }

      // Verify deviceId was saved correctly
      final verifyDoc = await userRef.get();
      final savedDeviceId = verifyDoc.data()?['deviceId'];
      print('🔍 Verification - Saved device ID: $savedDeviceId');
      print('🔍 Verification - Expected device ID: $deviceId');

      if (savedDeviceId != deviceId) {
        print('⚠️ WARNING: Device ID mismatch! Updating...');
        await userRef.update({'deviceId': deviceId});
      }

      _currentUser = user;
      await _saveUserToLocalStorage(user);

      if (fcmToken != null && fcmToken.isNotEmpty) {
        await NotificationService().saveTokenToFirestore(user.id, user.role);
      }

      print('✅ Signup complete. Device ID: $deviceId');
      _setLoading(false);
      notifyListeners();
      return true;
    } catch (e, st) {
      print('❌ Signup error: $e\n$st');
      _errorMessage = 'Failed to sign up: ${e.toString()}';
      _setLoading(false);
      return false;
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Device-lock check  (used by external callers, e.g. SplashScreen)
  // ───────────────────────────────────────────────────────────────────────────

  /// Returns true only when a *patient* account is locked to a different device.
  /// Always returns false for admins, doctors, and the exempt account.
  Future<bool> checkIfDeviceLocked(String userId) async {
    try {
      print('🔍 checkIfDeviceLocked called for userId: $userId');

      final userDoc = await _firestore
          .collection('telemedicine_patient')
          .doc(userId)
          .get();

      if (!userDoc.exists) {
        print('❌ User document not found');
        return false;
      }

      final userData = userDoc.data()!;
      final role = userData['role'] ?? ''; // Get role, default to empty string
      final phoneNumber = userData['phoneNumber'] ?? '';

      print('📋 User data - Role: "$role", Phone: "$phoneNumber"');

      // Honour the same exemption rules used at login time.
      if (!_requiresDeviceCheck(role: role, phoneNumber: phoneNumber)) {
        print(
          '✅ checkIfDeviceLocked: no device check needed for role="$role" / phone=$phoneNumber',
        );
        return false;
      }

      final storedDeviceId = userData['deviceId'] ?? '';
      if (storedDeviceId.isEmpty) {
        print('✅ checkIfDeviceLocked: No stored device ID, not locked');
        return false;
      }

      final currentDeviceId = await getDeviceId();
      final isLocked = storedDeviceId != currentDeviceId;

      print(
        '🔒 Device lock check – stored: $storedDeviceId | '
        'current: $currentDeviceId | locked: $isLocked',
      );

      if (isLocked) {
        print('⚠️ DEVICE LOCK ACTIVE! User cannot login from this device');
      }

      return isLocked;
    } catch (e) {
      print('Error checking device lock: $e');
      return false;
    }
  }

  /// Debug method to check device lock status
  Future<void> debugDeviceLockStatus(String userId) async {
    try {
      final userDoc = await _firestore
          .collection('telemedicine_patient')
          .doc(userId)
          .get();

      if (!userDoc.exists) {
        print('❌ User not found');
        return;
      }

      final userData = userDoc.data()!;
      final storedDeviceId = userData['deviceId'] ?? '';
      final currentDeviceId = await getDeviceId();
      final role = userData['role'] ?? '';
      final phoneNumber = userData['phoneNumber'] ?? '';
      final needsCheck = _requiresDeviceCheck(
        role: role,
        phoneNumber: phoneNumber,
      );

      print('=== DEVICE LOCK DEBUG ===');
      print('User ID: $userId');
      print('Role: "$role"');
      print('Phone: "$phoneNumber"');
      print('Needs device check: $needsCheck');
      print('Stored device ID: "$storedDeviceId"');
      print('Current device ID: "$currentDeviceId"');
      print('Match: ${storedDeviceId == currentDeviceId}');
      print('Stored empty: ${storedDeviceId.isEmpty}');
      print('Current empty: ${currentDeviceId.isEmpty}');
      print('Stored length: ${storedDeviceId.length}');
      print('Current length: ${currentDeviceId.length}');

      if (storedDeviceId.isNotEmpty && storedDeviceId != currentDeviceId) {
        print('⚠️ DEVICE LOCK WOULD BLOCK LOGIN');
      } else {
        print('✅ Device lock would NOT block login');
      }
      print('========================');
    } catch (e) {
      print('Debug error: $e');
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // SIGN IN
  // ───────────────────────────────────────────────────────────────────────────

  Future<bool> signIn({
    required String phoneNumber,
    required String password,
  }) async {
    _setLoading(true);
    _clearError();

    try {
      print('🔐 Starting sign-in for: $phoneNumber');

      final variants = PatientPasswordResetService.phoneLookupVariants(
        phoneNumber,
      );
      final querySnapshot = await _firestore
          .collection('telemedicine_patient')
          .where('phoneNumber', whereIn: variants)
          .limit(1)
          .get();

      if (querySnapshot.docs.isEmpty) {
        _errorMessage = 'No user found with this phone number';
        _setLoading(false);
        return false;
      }

      final userDoc = querySnapshot.docs.first;
      final userData = userDoc.data();

      // ── 1. Password check (always first) ──────────────────────────────────
      if (userData['password'] != password) {
        _errorMessage = 'Incorrect password';
        _setLoading(false);
        return false;
      }

      // ── 2. Deleted-account check ──────────────────────────────────────────
      if (userData['isDeleted'] == true) {
        _errorMessage =
            'This account has been deleted. Please contact support.';
        _setLoading(false);
        return false;
      }

      // ── 2b. Account status check ─────────────────────────────────────────
      final accountStatus = userData['accountStatus'] ?? 'Active';
      if (accountStatus == 'Blocked') {
        _errorMessage = 'Your account has been blocked by the administrator.';
        _setLoading(false);
        return false;
      }
      if (accountStatus == 'Frozen') {
        _errorMessage = 'Your ID has been frozen by the administrator.';
        _setLoading(false);
        return false;
      }
      if (accountStatus == 'Deleted') {
        _errorMessage = 'This account no longer exists.';
        _setLoading(false);
        return false;
      }

      final role = userData['role'] ?? 'patient';
      final phoneNumberFromDoc = userData['phoneNumber'] ?? '';

      final needsCheck = _requiresDeviceCheck(
        role: role,
        phoneNumber: phoneNumberFromDoc,
      );

      print('ℹ️  Role: "$role" | Needs device check: $needsCheck');

      // ── 3. Session-based Device Verification ────────────────────────────────
      String deviceIdToStore = '';

      if (needsCheck) {
        final hasOtherSession =
            await SessionService.hasActiveSessionOnOtherDevice(userDoc.id);

        if (hasOtherSession) {
          // ── BLOCKED ──────────────────────────────────────────────────────
          print('❌ Active session exists on another device – login blocked');
          _errorMessage =
              'Your account is already logged in on another device. '
              'Please log out from that device first.';
          _setLoading(false);
          return false;
        }

        deviceIdToStore = await getDeviceId();
      } else {
        // Non-restricted accounts: clear any lingering deviceId
        await userDoc.reference.update({'deviceId': ''});
      }

      // ── 4. Refresh token ───────────────────────────────────────────────────
      final newToken = DateTime.now().millisecondsSinceEpoch.toString();
      await userDoc.reference.update({'token': newToken});

      // ── 5. Check patient ID expiry ─────────────────────────────────────────
      DateTime? expiryDate;
      String? cardStatus = userData['cardStatus']?.toString();
      if (role == 'patient') {
        final patientIdVal = userData['patientId'] ?? userData['patient_id'];
        if (patientIdVal != null && patientIdVal.toString().isNotEmpty) {
          expiryDate = await _fetchPatientExpiryDate(patientIdVal, userDoc.id);
        }

        // Also check if expiry is directly on the user doc
        if (expiryDate == null) {
          final directExp =
              userData['expiryDate'] ??
              userData['patientCardExpiryDate'] ??
              userData['cardValidUntil'];
          expiryDate = _parseAnyExpiryDate(directExp);
        }
      }

      // ── 6. Build the in-memory user model ─────────────────────────────────
      _currentUser = UserModel(
        id: userDoc.id,
        fullname: userData['fullname'] ?? '',
        image: userData['image'],
        deviceId: deviceIdToStore,
        idcard: userData['idcard'] ?? '',
        password: userData['password'] ?? '',
        token: newToken,
        role: role,
        phoneNumber: phoneNumberFromDoc,
        ispayment: userData['ispayment'] ?? false,
        totalPayment: _safeDouble(userData['totalPayment']),
        paymentImage: userData['paymentImage'],
        highestDegree: userData['highestDegree'],
        doctorId: userData['doctorId'],
        paymentStatus: userData['paymentStatus'],
        fcmToken: userData['fcmToken'],
        loginType:
            userData['loginType'] ??
            ((userData['patientId'] != null &&
                    userData['patientId'].toString().isNotEmpty)
                ? 'patientId'
                : null),
        patientId: userData['patientId'],
        expiryDate: expiryDate,
        cardStatus: cardStatus,
      );

      // ── 7. Expired patients handled by UI ─────────────────────────────────
      if (_currentUser!.isExpired) {
        // UI (SignInScreen and SplashScreen) will detect this and redirect.
        // We do not return false here.
      }

      if (_currentUser!.role == 'patient') {
        if (needsCheck) {
          _currentSessionId = await SessionService.createSession(
            userId: _currentUser!.id,
            role: _currentUser!.role,
          );
        }
        await initializePatientPresence();
        // Record login event
        await _recordPatientLogin(_currentUser!.id, _currentUser!.fullname);
      }

      await _saveUserToLocalStorage(_currentUser!);
      await NotificationService().saveTokenToFirestore(
        _currentUser!.id,
        _currentUser!.role,
      );

      print('✅ Signed in: ${_currentUser!.fullname} (${_currentUser!.role})');
      _setLoading(false);
      notifyListeners();
      return true;
    } catch (e) {
      print('❌ Sign-in error: $e');
      _errorMessage = 'An unexpected error occurred: ${e.toString()}';
      _setLoading(false);
      return false;
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Session verification  (called on app resume / splash)
  // ───────────────────────────────────────────────────────────────────────────

  Future<bool> verifyCurrentSession() async {
    if (_currentUser == null || _currentUser!.id.isEmpty) return false;

    // Determine quickly – without Firestore – whether this account could
    // ever be device-locked.
    final quickCheck = _requiresDeviceCheck(
      role: _currentUser!.role,
      phoneNumber: _currentUser!.phoneNumber,
    );

    if (!quickCheck) {
      print(
        '✅ Session verification skipped for '
        '${_currentUser!.role} / ${_currentUser!.phoneNumber}',
      );
      return true;
    }

    // Patient: re-validate against Firestore to catch remote changes.
    try {
      final userDoc = await _firestore
          .collection('telemedicine_patient')
          .doc(_currentUser!.id)
          .get();

      if (!userDoc.exists) {
        print('❌ User document no longer exists');
        return false;
      }

      final userData = userDoc.data()!;
      final role = userData['role'] ?? '';
      final phoneNumber = userData['phoneNumber'] ?? '';

      // Re-check using Firestore values (role may have changed server-side).
      if (!_requiresDeviceCheck(role: role, phoneNumber: phoneNumber)) {
        print('✅ Firestore confirms no device check needed');
        return true;
      }

      if (userData['isDeleted'] == true) {
        await signOut();
        return false;
      }

      final hasOtherSession =
          await SessionService.hasActiveSessionOnOtherDevice(_currentUser!.id);

      if (hasOtherSession) {
        print(
          '❌ Session verification failed – active session on another device',
        );
        await signOut();
        return false;
      }
      print('✅ Session verification passed');
      return true;
    } catch (e) {
      print('Error verifying session: $e');
      return false;
    }
  }
  // ───────────────────────────────────────────────────────────────────────────
  // Sign out
  // ───────────────────────────────────────────────────────────────────────────

  Future<void> signOut() async {
    try {
      _sessionSubscription?.cancel();
      _sessionSubscription = null;
      try {
        await PhoneAuthService.instance.signOut();
      } catch (_) {}

      stopPresenceTracking();
      _stopConnectivityListener();
      // Drop the session-scoped expiry-warning dismissals so a different
      // account signing in on this device starts from a clean slate.
      AccountExpiryService.resetSessionState();
      if (_currentUser != null && _currentUser!.role == 'patient') {
        final currentId = _currentUser!.id;
        try {
          await SingleDeviceSessionService.releaseSession(
            collectionName: 'telemedicine_patient',
            documentId: currentId,
          );
        } catch (_) {}

        await SessionService.endSession(
          userId: currentId,
          sessionId: _currentSessionId,
        );
        _currentSessionId = null;
        await updatePatientOnlineStatus(false);
        // Record logout event
        await _recordPatientLogout(currentId, _currentUser!.fullname);
        // A signed-out account must stop receiving this device's pushes.
        // Without this, signing into another patient account on the same
        // phone left the previous patient's token on their profile.
        try {
          await FirebaseFirestore.instance
              .collection(FirestoreCollections.patients)
              .doc(currentId)
              .update({'fcmToken': null});
        } catch (e) {
          print('Error clearing patient FCM token during logout: $e');
        }
      }
      _currentUser = null;
      await _clearSavedUser();
      notifyListeners();
      print('✅ User signed out successfully');
    } catch (e) {
      print('❌ Error during signOut: $e');
      _currentUser = null;
      await _clearSavedUser();
      notifyListeners();
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // User lookups
  // ───────────────────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>?> getUserByPhoneNumber(String phoneNumber) async {
    try {
      final variants = PatientPasswordResetService.phoneLookupVariants(
        phoneNumber,
      );
      final qs = await _firestore
          .collection('telemedicine_patient')
          .where('phoneNumber', whereIn: variants)
          .limit(1)
          .get();

      if (qs.docs.isNotEmpty) {
        return {...qs.docs.first.data(), 'id': qs.docs.first.id};
      }
      return null;
    } catch (e) {
      print('Error getting user by phone: $e');
      return null;
    }
  }

  Future<String?> getUserIdByPhoneNumber(String phoneNumber) async {
    try {
      final variants = PatientPasswordResetService.phoneLookupVariants(
        phoneNumber,
      );
      final qs = await _firestore
          .collection('telemedicine_patient')
          .where('phoneNumber', whereIn: variants)
          .limit(1)
          .get();

      return qs.docs.isNotEmpty ? qs.docs.first.id : null;
    } catch (e) {
      print('Error getting user ID: $e');
      return null;
    }
  }

  Future<UserModel?> getUserById(String userId) async {
    try {
      if (userId.isEmpty) {
        print('❌ getUserById called with empty userId');
        return null;
      }
      final doc = await _firestore
          .collection('telemedicine_patient')
          .doc(userId)
          .get();

      if (doc.exists) {
        final user = UserModel.fromMap({...doc.data()!, 'id': doc.id});
        print(
          '📡 Fresh user from Firestore – Role: ${user.role}, Payment Status: ${user.paymentStatus}',
        );
        return user;
      }
      return null;
    } catch (e) {
      print('Error getting user: $e');
      return null;
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Profile update
  // ───────────────────────────────────────────────────────────────────────────

  Future<bool> updateUserProfile({
    String? image,
    required String fullname,
    String? gender,
  }) async {
    _setLoading(true);
    _clearError();

    try {
      if (_currentUser == null) {
        _errorMessage = 'No user logged in';
        _setLoading(false);
        return false;
      }

      if (_currentUser!.id.isEmpty) {
        _errorMessage = 'Invalid user session. Please logout and login again.';
        _setLoading(false);
        return false;
      }

      final userRef = _firestore
          .collection('telemedicine_patient')
          .doc(_currentUser!.id);

      if (!(await userRef.get()).exists) {
        _errorMessage =
            'User document not found. Please logout and login again.';
        _setLoading(false);
        return false;
      }

      Map<String, dynamic> updateData = {
        'fullname': fullname,
        'token': DateTime.now().millisecondsSinceEpoch.toString(),
      };

      if (image != null && image.isNotEmpty) updateData['image'] = image;
      if (gender != null && gender.isNotEmpty) updateData['gender'] = gender;

      await userRef.update(updateData);

      _currentUser = _currentUser!.copyWith(
        fullname: fullname,
        image: image ?? _currentUser!.image,
        gender: gender ?? _currentUser!.gender,
      );

      await _saveUserToLocalStorage(_currentUser!);
      _setLoading(false);
      notifyListeners();
      return true;
    } catch (e) {
      _errorMessage = 'Failed to update profile: ${e.toString()}';
      _setLoading(false);
      return false;
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Admin helpers
  // ───────────────────────────────────────────────────────────────────────────

  /// Active patients in the `telemedicine_patient` collection.
  ///
  /// Soft-deleted patients are excluded. Filtering happens in Dart via the
  /// shared predicate rather than as a `where('isDeleted', == false)` clause,
  /// so records predating the soft-delete migration (which have no such field)
  /// are not accidentally hidden.
  ///
  /// For an unfiltered admin/archive view use
  /// [getAllPatientsWithStatus] and switch to the 'deleted' filter in the UI.
  Future<List<UserModel>> getAllPatients() async {
    try {
      final qs = await _firestore
          .collection('telemedicine_patient')
          .where('role', isEqualTo: 'patient')
          .get();

      final all = qs.docs
          .map((d) => Map<String, dynamic>.from({...d.data(), 'id': d.id}))
          .toList();

      return SoftDeleteService.activeOnly(
        all,
        (data) => data,
      ).map(UserModel.fromMap).toList();
    } catch (e) {
      print('Error getting patients: $e');
      return [];
    }
  }

  /// Active legacy-path doctors (those stored inside `telemedicine_patient`
  /// with `role == 'doctor'` rather than in `telemedicine_doctors`).
  Future<List<UserModel>> getAllDoctors() async {
    try {
      final qs = await _firestore
          .collection('telemedicine_patient')
          .where('role', isEqualTo: 'doctor')
          .get();

      final all = qs.docs
          .map((d) => Map<String, dynamic>.from({...d.data(), 'id': d.id}))
          .toList();

      return SoftDeleteService.activeOnly(
        all,
        (data) => data,
      ).map(UserModel.fromMap).toList();
    } catch (e) {
      print('Error getting doctors: $e');
      return [];
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Payment flows
  //
  // Payment records are financial/audit history, so these queries are
  // deliberately NOT filtered by soft-delete state: a deleted patient's
  // submitted proof and its outcome must remain reviewable by an admin.
  // ───────────────────────────────────────────────────────────────────────────

  Stream<List<UserModel>> getPaymentRequests() {
    return _firestore
        .collection('telemedicine_patient')
        .where('paymentImage', isGreaterThan: '')
        .snapshots()
        .map(
          (snapshot) => snapshot.docs
              .where((d) => d.data() != null)
              .map((d) {
                final data = Map<String, dynamic>.from(d.data()!);
                data['id'] = d.id;
                return UserModel.fromMap(data);
              })
              .where(
                (u) => u.paymentImage != null && u.paymentImage!.isNotEmpty,
              )
              .toList(),
        );
  }

  /// Streams payment requests for the admin review screens, newest first.
  ///
  /// ORDERING: sorted by `paymentSubmittedAt` descending, so a freshly
  /// submitted proof is always at the top of the admin's list. The sort is
  /// applied here, on the raw document, rather than with a Firestore
  /// `orderBy`, for two reasons:
  ///
  ///   * a server-side `orderBy` silently **excludes** documents missing the
  ///     field. This query is a range (`paymentImage isGreaterThan ''`) over
  ///     records that predate the field, and losing an un-reviewed payment
  ///     record is far worse than it sorting to the bottom;
  ///   * this query also filters by `paymentStatus` client-side per status
  ///     chip, so a server-side sort would be re-sorted anyway.
  ///
  /// REALTIME: this is a `snapshots()` stream, so a new submission is pushed to
  /// every open admin screen on the Firestore event — no manual refresh. The
  /// ordering is recomputed on each emission, so approving or rejecting an item
  /// (which rewrites the document) keeps the list in correct order.
  Stream<List<UserModel>> getFilteredPaymentRequests(String status) {
    return _firestore
        .collection('telemedicine_patient')
        .where('paymentImage', isGreaterThan: '')
        .snapshots()
        .map((snapshot) {
          final List<UserModel> users = [];
          // Timestamp is read from the raw document, not from
          // `UserModel.paymentSubmittedAt`, so ordering never depends on the
          // model's tolerance for a legacy non-String value.
          final Map<String, DateTime?> submittedAtByPatientId = {};

          for (final doc in snapshot.docs) {
            try {
              final data = Map<String, dynamic>.from(
                doc.data() as Map<String, dynamic>,
              );
              data['id'] = doc.id;
              submittedAtByPatientId[doc.id] = parseFirestoreTimestamp(
                data['paymentSubmittedAt'],
              );
              final user = UserModel.fromMap(data);
              if (user.paymentImage != null && user.paymentImage!.isNotEmpty) {
                if (status == 'all' || user.paymentStatus == status) {
                  users.add(user);
                }
              }
            } catch (e) {
              print('Error processing document ${doc.id}: $e');
            }
          }

          return sortByTimestampDesc<UserModel>(
            users,
            (u) => submittedAtByPatientId[u.id],
            // Two proofs landing in the same millisecond still get a
            // deterministic order.
            tieBreakOf: (u) => u.id,
          );
        });
  }

  Future<bool> submitPaymentProof(
    String paymentImageUrl, {
    String? subscriptionPlan,
    int? durationMonths,
    double? amount,
  }) async {
    _setLoading(true);
    _clearError();

    try {
      if (_currentUser == null || _currentUser!.id.isEmpty) {
        _errorMessage = 'No user logged in';
        _setLoading(false);
        return false;
      }

      final paymentId = const Uuid().v4();
      final notificationId = const Uuid().v4();
      final submittedAt = DateTime.now();

      final updatePayload = <String, dynamic>{
        'paymentImage': paymentImageUrl,
        'paymentStatus': 'pending',
        'paymentType': 'account_activation',
        'paymentSubmittedAt': submittedAt.toIso8601String(),
        'paymentId': paymentId,
        'lastPaymentNotificationId': notificationId,
        'rejectionReason': FieldValue.delete(),
        if (subscriptionPlan != null) 'subscriptionPlan': subscriptionPlan,
        if (durationMonths != null) 'durationMonths': durationMonths,
        if (amount != null) 'totalPayment': amount,
      };

      await _firestore
          .collection('telemedicine_patient')
          .doc(_currentUser!.id)
          .update(updatePayload);

      // Save consistent record to unified payments collection
      try {
        await _firestore.collection('payments').doc(paymentId).set({
          'paymentId': paymentId,
          'patientUid': _currentUser!.id,
          'patientId': _currentUser!.patientId ?? '',
          'patientName': _currentUser!.fullname,
          'paymentType': 'account_activation',
          'amount': amount ?? _currentUser!.totalPayment,
          'currency': 'PKR',
          'proofReference': paymentImageUrl,
          'status': 'pending',
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
      } catch (e) {
        debugPrint('Note: Error saving to payments collection: $e');
      }

      _currentUser = UserModel(
        id: _currentUser!.id,
        fullname: _currentUser!.fullname,
        image: _currentUser!.image,
        deviceId: _currentUser!.deviceId,
        idcard: _currentUser!.idcard,
        password: _currentUser!.password,
        token: _currentUser!.token,
        role: _currentUser!.role,
        phoneNumber: _currentUser!.phoneNumber,
        ispayment: _currentUser!.ispayment,
        totalPayment: amount ?? _currentUser!.totalPayment,
        paymentImage: paymentImageUrl,
        highestDegree: _currentUser!.highestDegree,
        doctorId: _currentUser!.doctorId,
        paymentStatus: 'pending',
        fcmToken: _currentUser!.fcmToken,
        loginType: _currentUser!.loginType,
        patientId: _currentUser!.patientId,
        gender: _currentUser!.gender,
        age: _currentUser!.age,
        expiryDate: _currentUser!.expiryDate,
        paymentSubmittedAt: submittedAt,
        rejectionReason: null,
        subscriptionPlan: subscriptionPlan ?? _currentUser!.subscriptionPlan,
        durationMonths: durationMonths ?? _currentUser!.durationMonths,
      );

      await _saveUserToLocalStorage(_currentUser!);
      _setLoading(false);
      notifyListeners();

      // Admins are notified by the `sendAdminPaymentProofNotifications` Cloud
      // Function, which fires on this very `paymentStatus: pending` write.
      // Sending a push from here as well delivered the same notification twice
      // and required an Admin credential inside the app.

      return true;
    } catch (e) {
      _errorMessage = 'Failed to submit payment: ${e.toString()}';
      _setLoading(false);
      return false;
    }
  }

  Future<void> _notifyAdminsOfPaymentProof({
    required String patientName,
    required String patientId,
    required double amount,
    required String paymentId,
    required String notificationId,
  }) async {
    // Deliberately empty. Admins are notified by the
    // `sendAdminPaymentProofNotifications` Cloud Function, which triggers on
    // the `paymentStatus: pending` write above. Sending from the client as
    // well produced a duplicate notification for every submission and needed a
    // Firebase Admin credential inside the app.
    return;
  }

  /// Reads the authoritative payment status straight from Firestore.
  ///
  /// The locally cached session is never trusted for access decisions: a
  /// `payment_approved` push is only a hint that something changed, and this is
  /// what confirms it before the app unlocks.
  Future<String?> fetchLatestPaymentStatus(String userId) async {
    if (userId.isEmpty) return null;
    try {
      final doc = await _firestore
          .collection('telemedicine_patient')
          .doc(userId)
          .get();
      if (!doc.exists) return null;
      final status = doc.data()?['paymentStatus'] as String?;
      print('🔎 Latest Firestore payment status for $userId: $status');
      return status;
    } catch (e) {
      print('Error fetching latest payment status: $e');
      return null;
    }
  }

  /// Pushes the admin's decision to the patient immediately.
  ///
  /// [paymentId] defaults to the id stored on the patient's document so the
  /// push always points at the submission that was just reviewed, even when
  /// the caller (e.g. a deep-linked notification tap) doesn't know it.
  Future<void> _notifyPatientOfPaymentDecision(
    String userId, {
    required bool approved,
    String? paymentId,
  }) async {
    try {
      final doc = await _firestore
          .collection('telemedicine_patient')
          .doc(userId)
          .get();
      if (!doc.exists) return;

      final data = doc.data() ?? {};
      final token = data['fcmToken'] as String?;
      if (token == null || token.isEmpty) {
        print('⚠️ No FCM token for patient $userId; skipping push');
        return;
      }

      final resolvedPaymentId =
          paymentId ?? (data['paymentId'] as String?) ?? '';
      // One notification id per decision. The receiving app de-duplicates on
      // it, so a retry cannot produce a second tap handler run.
      final notificationId = const Uuid().v4();

      final dispatcher = NotificationDispatcher();
      if (approved) {
        await dispatcher.sendPaymentApprovedNotification(
          toUserId: userId,
          patientId: userId,
          paymentId: resolvedPaymentId,
          notificationId: notificationId,
        );
      } else {
        await dispatcher.sendPaymentRejectedNotification(
          toUserId: userId,
          patientId: userId,
          paymentId: resolvedPaymentId,
          notificationId: notificationId,
        );
      }
    } catch (e) {
      print('Error notifying patient of payment decision: $e');
    }
  }

  Future<bool> approvePayment(String userId) async {
    _setLoading(true);
    _clearError();

    try {
      final doc = await _firestore
          .collection('telemedicine_patient')
          .doc(userId)
          .get();
      final data = doc.data() ?? {};
      final paymentTypeStr = (data['paymentType'] as String?) ?? 'account_activation';
      final isReactivation = paymentTypeStr == 'account_reactivation';
      final paymentId = (data['paymentId'] as String?) ?? '';
      final durationMonths = data['durationMonths'] is int
          ? data['durationMonths'] as int
          : 1;
      final now = DateTime.now();
      final expiryDate = SubscriptionCalculator.calculateExpiry(
        now,
        durationMonths: durationMonths,
      );

      await _firestore.collection('telemedicine_patient').doc(userId).update({
        'paymentStatus': 'approved',
        'ispayment': true,
        'cardStatus': 'Active',
        'approvedAt': now.toIso8601String(),
        'subscriptionStartDate': now.toIso8601String(),
        'expiryDate': Timestamp.fromDate(expiryDate),
      });

      if (paymentId.isNotEmpty) {
        try {
          await _firestore.collection('payments').doc(paymentId).set({
            'status': 'approved',
            'reviewedAt': FieldValue.serverTimestamp(),
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
        } catch (_) {}
      }

      // Persistent patient notification
      final notifId = const Uuid().v4();
      try {
        await _firestore.collection('patient_notifications').doc(notifId).set({
          'notificationId': notifId,
          'recipientUid': userId,
          'type': FcmMessageType.paymentApproved,
          'title': isReactivation
              ? 'Account Reactivation Approved'
              : 'Account Activation Approved',
          'body': isReactivation
              ? 'Your account has been reactivated successfully.'
              : 'Your account activation payment has been approved.',
          'senderName': 'OPD Telemedicine Admin',
          'paymentId': paymentId,
          'paymentType': paymentTypeStr,
          'isRead': false,
          'createdAt': FieldValue.serverTimestamp(),
        });
      } catch (e) {
        debugPrint('Error creating patient persistent notification: $e');
      }

      if (_currentUser != null && _currentUser!.id == userId) {
        final freshUser = await getUserById(userId);
        if (freshUser != null) {
          _currentUser = freshUser;
          await _saveUserToLocalStorage(_currentUser!);
        }
      }

      _setLoading(false);
      notifyListeners();

      // Fire-and-forget: the Firestore write above is the source of truth, so a
      // failed push only costs the patient the instant heads-up (their 3s
      // status poller still catches the approval).
      _notifyPatientOfPaymentDecision(userId, approved: true);

      return true;
    } catch (e) {
      _errorMessage = 'Failed to approve payment: ${e.toString()}';
      _setLoading(false);
      return false;
    }
  }

  Future<bool> rejectPayment(String userId, String reason) async {
    _setLoading(true);
    _clearError();

    try {
      final doc = await _firestore
          .collection('telemedicine_patient')
          .doc(userId)
          .get();
      final data = doc.data() ?? {};
      final paymentTypeStr = (data['paymentType'] as String?) ?? 'account_activation';
      final paymentId = (data['paymentId'] as String?) ?? '';

      await _firestore.collection('telemedicine_patient').doc(userId).update({
        'paymentStatus': 'rejected',
        'rejectionReason': reason,
        'rejectedAt': DateTime.now().toIso8601String(),
      });

      if (paymentId.isNotEmpty) {
        try {
          await _firestore.collection('payments').doc(paymentId).set({
            'status': 'rejected',
            'rejectionReason': reason,
            'reviewedAt': FieldValue.serverTimestamp(),
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
        } catch (_) {}
      }

      // Persistent patient notification
      final notifId = const Uuid().v4();
      try {
        await _firestore.collection('patient_notifications').doc(notifId).set({
          'notificationId': notifId,
          'recipientUid': userId,
          'type': FcmMessageType.paymentRejected,
          'title': 'Payment Proof Rejected',
          'body': reason.isNotEmpty
              ? reason
              : 'Your payment proof has been rejected.',
          'senderName': 'OPD Telemedicine Admin',
          'paymentId': paymentId,
          'paymentType': paymentTypeStr,
          'isRead': false,
          'createdAt': FieldValue.serverTimestamp(),
        });
      } catch (e) {
        debugPrint('Error creating patient persistent notification: $e');
      }

      if (_currentUser != null && _currentUser!.id == userId) {
        final freshUser = await getUserById(userId);
        if (freshUser != null) {
          _currentUser = freshUser;
          await _saveUserToLocalStorage(_currentUser!);
        }
      }

      _setLoading(false);
      notifyListeners();

      _notifyPatientOfPaymentDecision(userId, approved: false);

      return true;
    } catch (e) {
      _errorMessage = 'Failed to reject payment: ${e.toString()}';
      _setLoading(false);
      return false;
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Password reset flow
  // ───────────────────────────────────────────────────────────────────────────

  Future<bool> sendPasswordResetRequestWithNotification({
    required String userId,
    required String phoneNumber,
  }) async {
    _setLoading(true);
    _clearError();

    try {
      final userDoc = await _firestore
          .collection('telemedicine_patient')
          .doc(userId)
          .get();

      if (!userDoc.exists) {
        _errorMessage = 'User not found';
        _setLoading(false);
        return false;
      }

      final fcmToken = userDoc.data()!['fcmToken'] as String?;
      if (fcmToken == null || fcmToken.isEmpty) {
        _errorMessage =
            'No FCM token found. Please ensure notifications are enabled.';
        _setLoading(false);
        return false;
      }

      final resetToken = _generateResetToken();
      final expiryTime = DateTime.now().add(const Duration(minutes: 15));

      await _firestore.collection('password_reset_requests').doc(userId).set({
        'userId': userId,
        'phoneNumber': phoneNumber,
        'resetToken': resetToken,
        'createdAt': FieldValue.serverTimestamp(),
        'expiresAt': expiryTime,
        'isUsed': false,
        'confirmed': false,
        'declined': false,
      });

      // The `sendPasswordResetNotifications` Cloud Function fires on this
      // document creation and is the single sender. Pushing from the client as
      // well delivered the request twice and needed an Admin credential inside
      // the app, so the push is no longer sent here.
      _listenForResetConfirmation(userId);
      _setLoading(false);
      return true;
    } catch (e) {
      _errorMessage = 'Failed to send reset request: ${e.toString()}';
      _setLoading(false);
      return false;
    }
  }

  String _generateResetToken() =>
      DateTime.now().millisecondsSinceEpoch.toString() +
      (100000 + DateTime.now().microsecond % 900000).toString();

  void _listenForResetConfirmation(String userId) {
    _firestore
        .collection('password_reset_requests')
        .doc(userId)
        .snapshots()
        .listen((snapshot) {
          if (!snapshot.exists) return;
          final data = snapshot.data()!;
          final confirmed = data['confirmed'] ?? false;
          final isUsed = data['isUsed'] ?? false;

          if (confirmed && !isUsed && _onResetConfirmedCallback != null) {
            _firestore.collection('password_reset_requests').doc(userId).update(
              {'isUsed': true, 'confirmedAt': FieldValue.serverTimestamp()},
            );
            _onResetConfirmedCallback!(true);
          }
        });
  }

  Function(bool)? _onResetConfirmedCallback;

  void listenForResetConfirmation(Function(bool) onConfirmed) {
    _onResetConfirmedCallback = onConfirmed;
  }

  Future<bool> resetPassword(String userId, String newPassword) async {
    _setLoading(true);
    _clearError();

    try {
      final resetDoc = await _firestore
          .collection('password_reset_requests')
          .doc(userId)
          .get();

      if (!resetDoc.exists) {
        _setLoading(false);
        return false;
      }

      await _firestore.collection('telemedicine_patient').doc(userId).update({
        'password': newPassword,
        'passwordUpdatedAt': FieldValue.serverTimestamp(),
      });

      await _firestore.collection('password_reset_requests').doc(userId).update(
        {'isUsed': true, 'completedAt': FieldValue.serverTimestamp()},
      );

      _setLoading(false);
      return true;
    } catch (e) {
      print('Error resetting password: $e');
      _setLoading(false);
      return false;
    }
  }

  Future<bool> confirmPasswordReset(String userId, String resetToken) async {
    try {
      final resetDoc = await _firestore
          .collection('password_reset_requests')
          .doc(userId)
          .get();

      if (!resetDoc.exists) return false;

      final resetData = resetDoc.data()!;
      final expiresAt = resetData['expiresAt'] as Timestamp?;

      if (expiresAt != null && expiresAt.toDate().isBefore(DateTime.now())) {
        print('Reset request expired');
        return false;
      }

      if (resetData['resetToken'] != resetToken) {
        print('Invalid reset token');
        return false;
      }

      await _firestore.collection('password_reset_requests').doc(userId).update(
        {'confirmed': true, 'confirmedAt': FieldValue.serverTimestamp()},
      );

      await markPasswordResetVerified(userId, true);
      return true;
    } catch (e) {
      print('Error confirming reset: $e');
      return false;
    }
  }

  Future<void> markPasswordResetVerified(String userId, bool isVerified) async {
    try {
      await _firestore.collection('telemedicine_patient').doc(userId).update({
        'isPasswordResetVerified': isVerified,
        'passwordResetVerifiedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      print('Error updating verified status: $e');
    }
  }

  Future<bool> declinePasswordReset(String userId, String resetToken) async {
    try {
      final resetDoc = await _firestore
          .collection('password_reset_requests')
          .doc(userId)
          .get();

      if (!resetDoc.exists) return false;

      if (resetDoc.data()!['resetToken'] != resetToken) return false;

      await _firestore
          .collection('password_reset_requests')
          .doc(userId)
          .update({
            'declined': true,
            'declinedAt': FieldValue.serverTimestamp(),
            'isUsed': true,
          });
      return true;
    } catch (e) {
      print('Error declining reset: $e');
      return false;
    }
  }

  Future<bool> isPasswordResetVerified(String userId) async {
    try {
      final doc = await _firestore
          .collection('telemedicine_patient')
          .doc(userId)
          .get();

      return doc.exists
          ? (doc.data()?['isPasswordResetVerified'] ?? false)
          : false;
    } catch (e) {
      print('Error checking verified status: $e');
      return false;
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Account deletion
  //
  // Soft delete only. The patient document, chats, messages, prescriptions,
  // reports, payment records and payment proofs are all preserved; only the
  // lifecycle flags on the one primary document change. See
  // `SoftDeleteService`.
  // ───────────────────────────────────────────────────────────────────────────

  Future<bool> deleteAccountWithPassword(String password) async {
    _setLoading(true);
    _clearError();

    try {
      if (_currentUser == null) {
        _errorMessage = "No user logged in";
        _setLoading(false);
        return false;
      }

      if (_currentUser!.password != password) {
        _errorMessage = "Incorrect password";
        _setLoading(false);
        notifyListeners();
        return false;
      }

      final userId = _currentUser!.id;
      print('🗑️ Soft-deleting account: $userId');

      // The session is terminated locally, but the server-side record is only
      // flagged — `deletedAt` is a serverTimestamp, never device time.
      final success = await SoftDeleteService.softDeletePatientSelf(
        patientId: userId,
      );

      if (!success) {
        _errorMessage = 'Failed to deactivate account';
        _setLoading(false);
        notifyListeners();
        return false;
      }

      _currentUser = null;
      await _clearSavedUser();

      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('current_user');
      await prefs.remove('user_$userId');

      _setLoading(false);
      notifyListeners();
      return true;
    } catch (e) {
      print('❌ Error deleting account: $e');
      _errorMessage = e.toString();
      _setLoading(false);
      notifyListeners();
      return false;
    }
  }

  /// Admin-initiated deactivation of a patient. Preserves every historical
  /// record attached to the patient.
  Future<bool> softDeletePatient(
    String userId, {
    String? performedBy,
    String reason = 'Deleted by administrator',
  }) {
    return SoftDeleteService.softDeletePatient(
      patientId: userId,
      performedBy: performedBy ?? 'admin',
      reason: reason,
    );
  }

  /// Restores a soft-deleted patient in place — same document id, no
  /// duplicate record.
  Future<bool> restorePatient(String userId, {String? performedBy}) {
    return SoftDeleteService.restorePatient(
      patientId: userId,
      performedBy: performedBy ?? 'admin',
    );
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Convenience getters
  // ───────────────────────────────────────────────────────────────────────────

  bool isLoggedIn() => _currentUser != null && _currentUser!.id.isNotEmpty;

  bool get isDoctor => _currentUser?.role == 'doctor';
  bool get isPatient => _currentUser?.role == 'patient';
  bool get isAdmin => _currentUser?.role == 'admin';

  /// Set the current user directly (used after new patient registration).
  void setCurrentUser(UserModel user) {
    _currentUser = user;
    _saveUserToLocalStorage(user);
    notifyListeners();
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Patient ID / Patient Card Expiry
  // ───────────────────────────────────────────────────────────────────────────

  /// Parses diverse expiry date representations with complete null-safety and fallbacks.
  static DateTime? _parseAnyExpiryDate(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    if (value is Timestamp) return value.toDate();
    if (value is String) return DateTime.tryParse(value);
    if (value is int) {
      try {
        return DateTime.fromMillisecondsSinceEpoch(value);
      } catch (_) {
        return null;
      }
    }
    if (value is Object && value.runtimeType.toString() == 'Timestamp') {
      try {
        return (value as dynamic).toDate() as DateTime?;
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// Fetch the expiry date for a patient from their patient_ids document,
  /// supporting patientId or patientUserId lookup, with fallback across
  /// expiryDate, patientCardExpiryDate, and cardValidUntil fields.
  Future<DateTime?> _fetchPatientExpiryDate(
    dynamic patientIdValue, [
    String? patientUserId,
  ]) async {
    try {
      if (patientIdValue != null &&
          patientIdValue.toString().trim().isNotEmpty) {
        final snapshot = await _firestore
            .collection('patient_ids')
            .where('patientId', isEqualTo: patientIdValue.toString().trim())
            .limit(1)
            .get()
            .timeout(const Duration(seconds: 6));
        if (snapshot.docs.isNotEmpty) {
          final data = snapshot.docs.first.data();
          final exp =
              data['expiryDate'] ??
              data['patientCardExpiryDate'] ??
              data['cardValidUntil'];
          final parsed = _parseAnyExpiryDate(exp);
          if (parsed != null) return parsed;
        }
      }

      if (patientUserId != null && patientUserId.trim().isNotEmpty) {
        final snapshot = await _firestore
            .collection('patient_ids')
            .where('patientUserId', isEqualTo: patientUserId.trim())
            .limit(1)
            .get()
            .timeout(const Duration(seconds: 6));
        if (snapshot.docs.isNotEmpty) {
          final data = snapshot.docs.first.data();
          final exp =
              data['expiryDate'] ??
              data['patientCardExpiryDate'] ??
              data['cardValidUntil'];
          final parsed = _parseAnyExpiryDate(exp);
          if (parsed != null) return parsed;
        }
      }
      return null;
    } catch (e) {
      print('Error fetching patient expiry date: $e');
      return null;
    }
  }

  /// Check whether the currently logged-in patient is expired.
  /// Returns true if the patient's expiryDate has passed.
  Future<bool> isCurrentPatientExpired() async {
    if (_currentUser == null || _currentUser!.role != 'patient') return false;
    if (_currentUser!.cardStatus != null &&
        _currentUser!.cardStatus!.toLowerCase() == 'expired') {
      return true;
    }

    // Refresh the expiry date from Firestore
    final expiryDate =
        (await _fetchPatientExpiryDate(
          _currentUser!.patientId,
          _currentUser!.id,
        )) ??
        _currentUser!.expiryDate;
    if (expiryDate == null) return false;

    return DateTime.now().isAfter(expiryDate);
  }

  /// Get the expiry date for the current patient.
  Future<DateTime?> getCurrentPatientExpiryDate() async {
    if (_currentUser == null || _currentUser!.role != 'patient') return null;
    return (await _fetchPatientExpiryDate(
          _currentUser!.patientId,
          _currentUser!.id,
        )) ??
        _currentUser!.expiryDate;
  }

  /// Current account-validity status for the signed-in patient.
  ///
  /// Reads the authoritative `patient_ids.expiryDate` rather than
  /// `_currentUser!.expiryDate`, which is only written at registration and goes
  /// stale after a reactivation — so the warning can never be computed from an
  /// out-of-date cached value.
  ///
  /// Fails open: a non-patient, an absent session or a patient with no
  /// time-based validity all return [PatientExpiryStatus.none], which never
  /// triggers a warning and never interferes with the existing expiry logic.
  Future<PatientExpiryStatus> getCurrentPatientExpiryStatus() async {
    if (_currentUser == null || _currentUser!.role != 'patient') {
      return const PatientExpiryStatus.none();
    }
    final expiryDate = await _fetchPatientExpiryDate(_currentUser!.patientId);
    return AccountExpiryService.evaluate(
      expiryDate: expiryDate,
      durationMonths: _currentUser!.effectiveDurationMonths,
    );
  }

  /// Whether the once-per-period "account expiring soon" heads-up should fire
  /// for the current patient.
  ///
  /// Suppressed when the patient already has a reactivation request awaiting
  /// admin review — re-warning someone whose proof is already in the queue is
  /// pure noise.
  Future<bool> shouldWarnAboutUpcomingExpiry() async {
    if (_currentUser == null || _currentUser!.id.isEmpty) return false;

    final status = await getCurrentPatientExpiryStatus();
    return AccountExpiryService.shouldWarn(
      status: status,
      userId: _currentUser!.id,
      hasPendingReactivation: await hasPendingReactivationRequest(),
    );
  }

  /// Records that the warning period has been surfaced, so the heads-up cannot
  /// repeat for the same 6-month period. A reactivation issues a new expiry
  /// date, which changes the period key and re-arms the warning automatically.
  Future<void> markUpcomingExpiryWarningShown() async {
    if (_currentUser == null || _currentUser!.id.isEmpty) return;
    final status = await getCurrentPatientExpiryStatus();
    await AccountExpiryService.markWarned(
      status: status,
      userId: _currentUser!.id,
    );
  }

  /// Force-expire the current patient session (called when expiry is detected).
  Future<void> expirePatientSession() async {
    stopPresenceTracking();
    _stopConnectivityListener();
    if (_currentUser != null && _currentUser!.role == 'patient') {
      await updatePatientOnlineStatus(false);
    }
    _currentUser = null;
    await _clearSavedUser();
    notifyListeners();
    print('⚠️ Patient session expired and cleared');
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Reactivation Payment Proof Submission
  // ───────────────────────────────────────────────────────────────────────────

  /// Submit a reactivation payment proof for an expired patient.
  /// Creates a document in the `patient_reactivation_requests` collection.
  Future<bool> submitReactivationPaymentProof({
    required String paymentProofUrl,
  }) async {
    _setLoading(true);
    _clearError();

    try {
      if (_currentUser == null || _currentUser!.id.isEmpty) {
        _errorMessage = 'No user logged in';
        _setLoading(false);
        return false;
      }

      // Get the current expiry date before submitting
      final currentExpiry = await _fetchPatientExpiryDate(
        _currentUser!.patientId,
      );

      final plan = _currentUser!.plan;
      final durationMonths = _currentUser!.effectiveDurationMonths;
      final amount = plan.amount > 0 ? plan.amount : (_currentUser!.totalPayment > 0 ? _currentUser!.totalPayment : 300.0);

      final requestRef = _firestore
          .collection('patient_reactivation_requests')
          .doc();

      await requestRef.set({
        'id': requestRef.id,
        'patientUserId': _currentUser!.id,
        'patientId': _currentUser!.patientId ?? '',
        'patientName': _currentUser!.fullname,
        'paymentProofUrl': paymentProofUrl,
        'status': 'pending',
        'paymentType': 'account_reactivation',
        'amount': amount,
        'currency': 'PKR',
        'subscriptionPlan': plan.planId,
        'durationMonths': durationMonths,
        'submittedAt': FieldValue.serverTimestamp(),
        'previousExpiryDate': currentExpiry != null
            ? Timestamp.fromDate(currentExpiry)
            : null,
      });

      // Write consistent payment audit record
      try {
        await _firestore.collection('payments').doc(requestRef.id).set({
          'paymentId': requestRef.id,
          'patientUid': _currentUser!.id,
          'patientId': _currentUser!.patientId ?? '',
          'patientName': _currentUser!.fullname,
          'paymentType': 'account_reactivation',
          'amount': amount,
          'currency': 'PKR',
          'proofReference': paymentProofUrl,
          'status': 'pending',
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
      } catch (e) {
        debugPrint('Note: Error saving reactivation to payments: $e');
      }

      // Update patient profile so Cloud Function and Admin screen pick up pending reactivation
      try {
        final notifId = const Uuid().v4();
        await _firestore.collection('telemedicine_patient').doc(_currentUser!.id).update({
          'paymentStatus': 'pending',
          'paymentType': 'account_reactivation',
          'paymentImage': paymentProofUrl,
          'paymentId': requestRef.id,
          'lastPaymentNotificationId': notifId,
          'paymentSubmittedAt': DateTime.now().toIso8601String(),
        });
        _currentUser = _currentUser?.copyWith(
          paymentStatus: 'pending',
          paymentImage: paymentProofUrl,
          paymentId: requestRef.id,
        );
        if (_currentUser != null) {
          await _saveUserToLocalStorage(_currentUser!);
        }
      } catch (e) {
        debugPrint('Note: Error updating patient for reactivation: $e');
      }

      _setLoading(false);
      notifyListeners();
      return true;
    } catch (e) {
      _errorMessage = 'Failed to submit reactivation proof: ${e.toString()}';
      _setLoading(false);
      return false;
    }
  }

  /// Check if there is a pending reactivation request for the current patient.
  Future<bool> hasPendingReactivationRequest() async {
    if (_currentUser == null || _currentUser!.id.isEmpty) return false;

    try {
      final snapshot = await _firestore
          .collection('patient_reactivation_requests')
          .where('patientUserId', isEqualTo: _currentUser!.id)
          .where('status', isEqualTo: 'pending')
          .limit(1)
          .get();
      return snapshot.docs.isNotEmpty;
    } catch (e) {
      print('Error checking reactivation request: $e');
      return false;
    }
  }

  /// Stream reactivation requests for admin view.
  /// Stream reactivation requests for admin view, newest submission first.
  ///
  /// ORDERING: sorted by `submittedAt` descending via [sortByTimestampDesc], so
  /// the most recent reactivation request is always at the top.
  ///
  /// DELIBERATELY no server-side `orderBy`. Two reasons:
  ///
  ///   * Firestore's `orderBy` **excludes documents that lack the field**. Any
  ///     request written before `submittedAt` existed, or whose
  ///     `serverTimestamp()` has not resolved, would silently disappear from
  ///     the admin's review queue. Those records now sort to the bottom and stay
  ///     visible instead.
  ///   * combining a `where` on `status` with an `orderBy` on a different field
  ///     needs a composite index, and there is no `patient_reactivation_requests`
  ///     entry in `firestore.indexes.json` — so the status-filtered query could
  ///     fail outright with a "requires an index" error. Dropping the server
  ///     order leaves a single equality filter, which uses the default
  ///     single-field index.
  ///
  /// REALTIME: `snapshots()`, so a new request is pushed to the open screen on
  /// its Firestore event and lands at the top without a manual refresh.
  Stream<List<Map<String, dynamic>>> getReactivationRequests({
    String? statusFilter,
  }) {
    Query query = _firestore.collection('patient_reactivation_requests');

    if (statusFilter != null && statusFilter != 'all') {
      query = query.where('status', isEqualTo: statusFilter);
    }

    return query.snapshots().map((snapshot) {
      final requests = snapshot.docs.map((doc) {
        final data = Map<String, dynamic>.from(
          doc.data() as Map<String, dynamic>,
        );
        data['id'] = doc.id;
        return data;
      }).toList();

      return sortByTimestampDesc<Map<String, dynamic>>(
        requests,
        (r) => parseFirestoreTimestamp(r['submittedAt']),
        tieBreakOf: (r) => (r['id'] ?? '').toString(),
      );
    });
  }

  /// Approve a reactivation request: reactivate patient ID with calendar-safe renewal expiry based on plan.
  Future<bool> approveReactivationRequest({
    required String requestId,
    required String patientUserId,
  }) async {
    _setLoading(true);
    _clearError();

    try {
      // 1. Fetch request document to ensure idempotency & read assigned plan
      final requestDoc = await _firestore
          .collection('patient_reactivation_requests')
          .doc(requestId)
          .get();

      if (!requestDoc.exists) {
        _errorMessage = 'Reactivation request not found';
        _setLoading(false);
        return false;
      }

      final requestData = requestDoc.data()!;
      // Idempotency guard: prevent duplicate approval events from extending expiry twice
      if (requestData['status'] == 'approved') {
        _setLoading(false);
        return true;
      }

      // Fetch patient user document
      final patientUserDoc = await _firestore
          .collection('telemedicine_patient')
          .doc(patientUserId)
          .get();
      final userData = patientUserDoc.data();

      // Resolve plan & duration:
      // Priority: requestData -> patientUserDoc -> patient_ids -> legacy default (six_months)
      String? planId =
          requestData['subscriptionPlan']?.toString() ??
          userData?['subscriptionPlan']?.toString();
      int? durationMonths = requestData['durationMonths'] is int
          ? requestData['durationMonths'] as int
          : (userData?['durationMonths'] is int
                ? userData!['durationMonths'] as int
                : null);

      final patientIdVal = userData?['patientId'] ?? requestData['patientId'];
      DocumentReference? pidDocRef;
      if (patientIdVal != null && patientIdVal.toString().isNotEmpty) {
        final pidSnapshot = await _firestore
            .collection('patient_ids')
            .where('patientId', isEqualTo: patientIdVal.toString())
            .limit(1)
            .get();
        if (pidSnapshot.docs.isNotEmpty) {
          pidDocRef = pidSnapshot.docs.first.reference;
          final pidData = pidSnapshot.docs.first.data();
          planId ??= pidData['subscriptionPlan']?.toString();
          durationMonths ??= pidData['durationMonths'] is int
              ? pidData['durationMonths'] as int
              : null;
        }
      }

      final effectivePlan = SubscriptionPlan.fromPlanId(planId);
      final effectiveDuration = durationMonths ?? effectivePlan.durationMonths;

      // Determine current/previous expiry date
      DateTime? previousExpiry;
      final rawPrev = requestData['previousExpiryDate'];
      if (rawPrev != null) {
        previousExpiry = _parseAnyExpiryDate(rawPrev);
      }
      previousExpiry ??= await _fetchPatientExpiryDate(
        patientIdVal,
        patientUserId,
      );

      final now = DateTime.now();
      // Renewal policy:
      // - If subscription is still active (now < previousExpiry), extend from existing expiry date.
      // - If already expired (or previousExpiry is null), extend from now.
      final newExpiry = SubscriptionCalculator.calculateRenewalExpiry(
        currentExpiry: previousExpiry,
        now: now,
        durationMonths: effectiveDuration,
      );

      // 1. Update the reactivation request
      await _firestore
          .collection('patient_reactivation_requests')
          .doc(requestId)
          .update({
            'status': 'approved',
            'reviewedAt': FieldValue.serverTimestamp(),
            'newExpiryDate': Timestamp.fromDate(newExpiry),
            'subscriptionPlan': effectivePlan.planId,
            'durationMonths': effectiveDuration,
          });

      // 2. Update the patient_ids document with new expiry and plan details
      if (pidDocRef != null) {
        await pidDocRef.update({
          'expiryDate': Timestamp.fromDate(newExpiry),
          'status': 'Assigned',
          'subscriptionPlan': effectivePlan.planId,
          'durationMonths': effectiveDuration,
        });
      }

      // 3. Keep the denormalised copy on the patient document in step
      if (patientUserDoc.exists) {
        await patientUserDoc.reference.update({
          'expiryDate': newExpiry.toIso8601String(),
          'cardStatus': 'Active',
          'paymentStatus': 'approved',
          'subscriptionPlan': effectivePlan.planId,
          'durationMonths': effectiveDuration,
        });
      }

      // Update unified payments collection
      try {
        await _firestore.collection('payments').doc(requestId).set({
          'status': 'approved',
          'reviewedAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      } catch (_) {}

      // Persistent patient notification
      final notifId = const Uuid().v4();
      try {
        await _firestore.collection('patient_notifications').doc(notifId).set({
          'notificationId': notifId,
          'recipientUid': patientUserId,
          'type': FcmMessageType.paymentApproved,
          'title': 'Account Reactivation Approved',
          'body': 'Your account has been reactivated successfully.',
          'senderName': 'OPD Telemedicine Admin',
          'paymentId': requestId,
          'paymentType': 'account_reactivation',
          'isRead': false,
          'createdAt': FieldValue.serverTimestamp(),
        });
      } catch (_) {}

      // Send push notification
      await NotificationDispatcher().sendPaymentApprovedNotification(
        toUserId: patientUserId,
        patientId: patientUserId,
        paymentId: requestId,
        notificationId: notifId,
      );

      _setLoading(false);
      notifyListeners();
      return true;
    } catch (e) {
      _errorMessage = 'Failed to approve reactivation: ${e.toString()}';
      _setLoading(false);
      return false;
    }
  }

  /// Reject a reactivation request.
  Future<bool> rejectReactivationRequest({
    required String requestId,
    required String reason,
  }) async {
    _setLoading(true);
    _clearError();

    try {
      await _firestore
          .collection('patient_reactivation_requests')
          .doc(requestId)
          .update({
            'status': 'rejected',
            'reviewedAt': FieldValue.serverTimestamp(),
            'rejectionReason': reason,
          });

      // Update unified payments collection
      try {
        await _firestore.collection('payments').doc(requestId).set({
          'status': 'rejected',
          'rejectionReason': reason,
          'reviewedAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      } catch (_) {}

      // Find patientUserId to notify
      try {
        final reqDoc = await _firestore.collection('patient_reactivation_requests').doc(requestId).get();
        final pUid = (reqDoc.data()?['patientUserId'] ?? '').toString();
        if (pUid.isNotEmpty) {
          final notifId = const Uuid().v4();
          await _firestore.collection('patient_notifications').doc(notifId).set({
            'notificationId': notifId,
            'recipientUid': pUid,
            'type': FcmMessageType.paymentRejected,
            'title': 'Payment Proof Rejected',
            'body': reason.isNotEmpty ? reason : 'Your reactivation payment proof has been rejected.',
            'senderName': 'OPD Telemedicine Admin',
            'paymentId': requestId,
            'paymentType': 'account_reactivation',
            'isRead': false,
            'createdAt': FieldValue.serverTimestamp(),
          });
          await NotificationDispatcher().sendPaymentRejectedNotification(
            toUserId: pUid,
            patientId: pUid,
            paymentId: requestId,
            notificationId: notifId,
          );
        }
      } catch (_) {}

      _setLoading(false);
      notifyListeners();
      return true;
    } catch (e) {
      _errorMessage = 'Failed to reject reactivation: ${e.toString()}';
      _setLoading(false);
      return false;
    }
  }

  /// Sign in with Patient ID and password.
  Future<bool> signInWithPatientId({
    required String patientId,
    required String password,
  }) async {
    _setLoading(true);
    _clearError();

    try {
      print('🔐 Starting sign-in with Patient ID: $patientId');

      // Find the patient_ids document first
      final patientIdSnapshot = await _firestore
          .collection('patient_ids')
          .where('patientId', isEqualTo: patientId)
          .where('isActive', isEqualTo: true)
          .limit(1)
          .get();

      if (patientIdSnapshot.docs.isEmpty) {
        _errorMessage = 'Patient ID not found';
        _setLoading(false);
        return false;
      }

      final patientIdData = patientIdSnapshot.docs.first.data();
      final status = patientIdData['status'] ?? 'Available';
      final patientUserId = patientIdData['patientUserId'] as String?;

      if (status == 'Available') {
        _errorMessage = 'This Patient ID has not been registered yet';
        _setLoading(false);
        return false;
      }

      if (status == 'Blocked') {
        _errorMessage = 'This Patient ID has been blocked. Contact support.';
        _setLoading(false);
        return false;
      }

      if (patientUserId == null || patientUserId.isEmpty) {
        _errorMessage = 'Invalid Patient ID data. Contact support.';
        _setLoading(false);
        return false;
      }

      // Now find the user document
      final userDoc = await _firestore
          .collection('telemedicine_patient')
          .doc(patientUserId)
          .get();

      if (!userDoc.exists) {
        _errorMessage = 'Patient account not found';
        _setLoading(false);
        return false;
      }

      final userData = userDoc.data()!;

      // Password check
      if (userData['password'] != password) {
        _errorMessage = 'Incorrect password';
        _setLoading(false);
        return false;
      }

      // Deleted check
      if (userData['isDeleted'] == true) {
        _errorMessage = 'This account has been deleted. Contact support.';
        _setLoading(false);
        return false;
      }

      // Account status check
      final accountStatus = userData['accountStatus'] ?? 'Active';
      if (accountStatus == 'Blocked') {
        _errorMessage = 'Your account has been blocked by the administrator.';
        _setLoading(false);
        return false;
      }
      if (accountStatus == 'Frozen') {
        _errorMessage = 'Your ID has been frozen by the administrator.';
        _setLoading(false);
        return false;
      }
      if (accountStatus == 'Deleted') {
        _errorMessage = 'This account no longer exists.';
        _setLoading(false);
        return false;
      }

      // Device lock check
      final role = userData['role'] ?? 'patient';
      final phoneNumber = userData['phoneNumber'] ?? '';
      final needsCheck = _requiresDeviceCheck(
        role: role,
        phoneNumber: phoneNumber,
      );

      String deviceIdToStore = '';

      if (needsCheck) {
        final storedDeviceId = userData['deviceId'] ?? '';
        final currentDeviceId = await getDeviceId();

        if (storedDeviceId.isNotEmpty && storedDeviceId != currentDeviceId) {
          _errorMessage =
              'This account is locked to another device. Please use your original device.';
          _setLoading(false);
          return false;
        }

        if (storedDeviceId.isEmpty) {
          await userDoc.reference.update({'deviceId': currentDeviceId});
        }

        deviceIdToStore = currentDeviceId;
      }

      // Refresh token
      final newToken = DateTime.now().millisecondsSinceEpoch.toString();
      await userDoc.reference.update({'token': newToken});

      // Resolve the authoritative expiry from the patient_ids document or user document.
      DateTime? expiryDate;
      String? cardStatus = userData['cardStatus']?.toString();
      if (role == 'patient') {
        expiryDate = await _fetchPatientExpiryDate(patientId, userDoc.id);
        if (expiryDate == null) {
          final directExp =
              userData['expiryDate'] ??
              userData['patientCardExpiryDate'] ??
              userData['cardValidUntil'];
          expiryDate = _parseAnyExpiryDate(directExp);
        }
        if (cardStatus == null && patientIdData['cardStatus'] != null) {
          cardStatus = patientIdData['cardStatus']?.toString();
        }
        // Notice: We deliberately do NOT return false here if expired.
        // The authenticated model is created and saved so the UI routing layer
        // (AuthRoutingService / SignInScreen) detects `user.isExpired == true` and routes
        // to ExpiredPatientScreen so the patient can submit a renewal payment receipt.
      }

      // Resolve subscription plan & duration
      final subscriptionPlan =
          patientIdData['subscriptionPlan']?.toString() ??
          userData['subscriptionPlan']?.toString() ??
          'six_months';
      final durationMonths = patientIdData['durationMonths'] is int
          ? patientIdData['durationMonths'] as int
          : (userData['durationMonths'] is int
                ? userData['durationMonths'] as int
                : SubscriptionPlan.fromPlanId(subscriptionPlan).durationMonths);
      final subscriptionStartDate = parseFirestoreTimestamp(
        patientIdData['startDate'] ??
            patientIdData['assignedAt'] ??
            userData['subscriptionStartDate'] ??
            userData['assignedAt'],
      );

      // Build user model
      _currentUser = UserModel(
        id: userDoc.id,
        fullname: userData['fullname'] ?? '',
        image: userData['image'],
        deviceId: deviceIdToStore,
        idcard: userData['idcard'] ?? '',
        password: userData['password'] ?? '',
        token: newToken,
        role: role,
        phoneNumber: phoneNumber,
        ispayment: userData['ispayment'] ?? false,
        totalPayment: _safeDouble(userData['totalPayment']),
        paymentImage: userData['paymentImage'],
        highestDegree: userData['highestDegree'],
        doctorId: userData['doctorId'],
        paymentStatus: userData['paymentStatus'],
        fcmToken: userData['fcmToken'],
        patientId: userData['patientId'] ?? patientId,
        gender: userData['gender'],
        age: userData['age'],
        expiryDate: expiryDate,
        cardStatus: cardStatus,
        loginType: 'patientId',
        subscriptionPlan: subscriptionPlan,
        durationMonths: durationMonths,
        subscriptionStartDate: subscriptionStartDate,
      );

      if (_currentUser!.role == 'patient') {
        await initializePatientPresence();
        // Record login event
        await _recordPatientLogin(_currentUser!.id, _currentUser!.fullname);
      }

      await _saveUserToLocalStorage(_currentUser!);
      await NotificationService().saveTokenToFirestore(
        _currentUser!.id,
        _currentUser!.role,
      );

      print('✅ Signed in with Patient ID: ${_currentUser!.fullname}');
      _setLoading(false);
      notifyListeners();
      return true;
    } catch (e) {
      print('❌ Sign-in error with Patient ID: $e');
      _errorMessage = 'An unexpected error occurred: ${e.toString()}';
      _setLoading(false);
      return false;
    }
  }

  void _startSingleDeviceSessionWatcher(String patientId) {
    if (patientId.trim().isEmpty) return;
    _sessionSubscription?.cancel();
    getDeviceId().then((currentDevId) {
      if (_currentUser == null || _currentUser!.id != patientId) return;
      _sessionSubscription = SingleDeviceSessionService.listenForSessionChanges(
        collectionName: 'telemedicine_patient',
        documentId: patientId,
        currentDeviceId: currentDevId,
        onSessionInvalidated: () async {
          if (_currentUser == null) return;
          print('⚠️ Session revoked remotely on another device');
          await signOut();
        },
      );
    });
  }

  /// Completes Phone OTP Sign-In with verified Firebase User.
  ///
  /// Reuses or links existing patient profile by UID or phone number.
  /// Automatically claims active device session (superseding previous devices).
  Future<
    ({
      bool success,
      bool needsProfileCompletion,
      UserModel? user,
      String? errorMessage,
    })
  >
  signInWithFirebasePhoneUser({
    required User firebaseUser,
    required String rawPhone,
    required String normalizedPhone,
  }) async {
    _setLoading(true);
    _clearError();

    try {
      print(
        '📱 Completing Firebase Phone sign-in for UID: ${firebaseUser.uid}',
      );

      // 1. Search for existing patient document
      DocumentSnapshot<Map<String, dynamic>>? patientDoc;

      // Direct lookup by UID first
      final directDoc = await _firestore
          .collection('telemedicine_patient')
          .doc(firebaseUser.uid)
          .get();

      if (directDoc.exists) {
        patientDoc = directDoc;
      } else {
        // Search by authUid
        final authUidSnap = await _firestore
            .collection('telemedicine_patient')
            .where('authUid', isEqualTo: firebaseUser.uid)
            .limit(1)
            .get();

        if (authUidSnap.docs.isNotEmpty) {
          patientDoc = authUidSnap.docs.first;
        } else {
          // Search by phone variants
          final variants = PatientPasswordResetService.phoneLookupVariants(
            normalizedPhone,
          );
          final phoneSnap = await _firestore
              .collection('telemedicine_patient')
              .where('phoneNumber', whereIn: variants)
              .limit(1)
              .get();

          if (phoneSnap.docs.isNotEmpty) {
            patientDoc = phoneSnap.docs.first;
          }
        }
      }

      final currentDeviceId = await getDeviceId();
      String? fcmToken;
      try {
        fcmToken = await NotificationService().getToken();
      } catch (_) {}

      late String patientUserId;
      Map<String, dynamic> docData;

      if (patientDoc != null && patientDoc.exists) {
        patientUserId = patientDoc.id;
        docData = patientDoc.data() ?? {};

        // Account status checks
        if (docData['isDeleted'] == true) {
          _errorMessage =
              'This account has been deleted. Please contact support.';
          _setLoading(false);
          return (
            success: false,
            needsProfileCompletion: false,
            user: null,
            errorMessage: _errorMessage,
          );
        }
        final status = docData['accountStatus'] ?? 'Active';
        if (status == 'Blocked' || status == 'Frozen') {
          _errorMessage = 'Your account has been $status by the administrator.';
          _setLoading(false);
          return (
            success: false,
            needsProfileCompletion: false,
            user: null,
            errorMessage: _errorMessage,
          );
        }

        // Link authUid and update active device atomically (blockSecondLogin: false to take over session)
        final updatePayload = <String, dynamic>{
          'authUid': firebaseUser.uid,
          'phoneNumber': normalizedPhone,
          'deviceId': currentDeviceId,
          'activeDeviceId': currentDeviceId,
          'isLoggedIn': true,
          'lastLoginAt': FieldValue.serverTimestamp(),
          if (fcmToken != null && fcmToken.isNotEmpty) 'fcmToken': fcmToken,
        };

        await patientDoc.reference.update(updatePayload);
      } else {
        // Create new patient record with verified UID
        patientUserId = firebaseUser.uid;
        docData = {
          'id': patientUserId,
          'authUid': firebaseUser.uid,
          'fullname': '',
          'phoneNumber': normalizedPhone,
          'role': 'patient',
          'loginType': 'phone',
          'ispayment': false,
          'totalPayment': 0.0,
          'paymentStatus': null,
          'deviceId': currentDeviceId,
          'activeDeviceId': currentDeviceId,
          'isLoggedIn': true,
          'lastLoginAt': FieldValue.serverTimestamp(),
          'createdAt': FieldValue.serverTimestamp(),
          'token': DateTime.now().millisecondsSinceEpoch.toString(),
          if (fcmToken != null && fcmToken.isNotEmpty) 'fcmToken': fcmToken,
        };

        await _firestore
            .collection('telemedicine_patient')
            .doc(patientUserId)
            .set(docData);
      }

      // Check single device session claim
      await SingleDeviceSessionService.validateAndClaimSession(
        collectionName: 'telemedicine_patient',
        documentId: patientUserId,
        currentDeviceId: currentDeviceId,
        blockSecondLogin: false, // takeover session
      );

      // Start listening for remote revocation on this device
      _startSingleDeviceSessionWatcher(patientUserId);

      // Resolve expiry
      DateTime? expiryDate;
      final directExp =
          docData['expiryDate'] ??
          docData['patientCardExpiryDate'] ??
          docData['cardValidUntil'];
      expiryDate = _parseAnyExpiryDate(directExp);

      _currentUser = UserModel(
        id: patientUserId,
        authUid: firebaseUser.uid,
        fullname: docData['fullname'] ?? '',
        image: docData['image'],
        deviceId: currentDeviceId,
        idcard: docData['idcard'] ?? '',
        password: docData['password'] ?? '',
        token:
            docData['token'] ??
            DateTime.now().millisecondsSinceEpoch.toString(),
        role: docData['role'] ?? 'patient',
        phoneNumber: normalizedPhone,
        ispayment: docData['ispayment'] ?? false,
        totalPayment: _safeDouble(docData['totalPayment']),
        paymentImage: docData['paymentImage'],
        highestDegree: docData['highestDegree'],
        doctorId: docData['doctorId'],
        paymentStatus: docData['paymentStatus'],
        fcmToken: fcmToken ?? docData['fcmToken'],
        loginType: docData['loginType'] ?? 'phone',
        patientId: docData['patientId'],
        gender: docData['gender'],
        age: docData['age'],
        expiryDate: expiryDate,
        subscriptionPlan: docData['subscriptionPlan'],
        durationMonths: docData['durationMonths'] is int
            ? docData['durationMonths'] as int
            : null,
      );

      await _saveUserToLocalStorage(_currentUser!);

      if (fcmToken != null && fcmToken.isNotEmpty) {
        unawaited(
          NotificationService().saveTokenToFirestore(
            _currentUser!.id,
            _currentUser!.role,
          ),
        );
      }

      await initializePatientPresence();
      await _recordPatientLogin(_currentUser!.id, _currentUser!.fullname);

      final bool needsProfileCompletion = _currentUser!.fullname.trim().isEmpty;

      _setLoading(false);
      notifyListeners();
      return (
        success: true,
        needsProfileCompletion: needsProfileCompletion,
        user: _currentUser,
        errorMessage: null,
      );
    } catch (e, st) {
      print('❌ Error in signInWithFirebasePhoneUser: $e\n$st');
      _errorMessage = 'Failed to sign in with phone: ${e.toString()}';
      _setLoading(false);
      return (
        success: false,
        needsProfileCompletion: false,
        user: null,
        errorMessage: _errorMessage,
      );
    }
  }

  /// Signs in as a read-only guest user.
  Future<void> signInAsGuest() async {
    await signOut();
    _currentUser = UserModel.guest();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('current_doctor');
    await prefs.setString('current_user', json.encode(_currentUser!.toMap()));
    notifyListeners();
  }

  /// Validates a 12-digit Patient Card against `patient_ids` and logs in or requests profile completion.
  Future<
    ({
      bool success,
      bool needsProfileCompletion,
      PatientIdModel? cardModel,
      UserModel? user,
      String? error,
    })
  >
  signInWithPatientCard({required String cardId}) async {
    _setLoading(true);
    _clearError();

    final cleanId = cardId.trim();
    if (cleanId.length != 12) {
      _errorMessage = 'Patient Card ID must contain exactly 12 digits';
      _setLoading(false);
      return (
        success: false,
        needsProfileCompletion: false,
        cardModel: null,
        user: null,
        error: _errorMessage,
      );
    }

    try {
      final snapshot = await _firestore
          .collection('patient_ids')
          .where('patientId', isEqualTo: cleanId)
          .where('isActive', isEqualTo: true)
          .limit(1)
          .get();

      if (snapshot.docs.isEmpty) {
        _errorMessage = 'Invalid or inactive Patient Card ID';
        _setLoading(false);
        return (
          success: false,
          needsProfileCompletion: false,
          cardModel: null,
          user: null,
          error: _errorMessage,
        );
      }

      final doc = snapshot.docs.first;
      final cardData = PatientIdModel.fromMap({...doc.data(), 'id': doc.id});

      if (cardData.status == 'Blocked' || cardData.status == 'Revoked') {
        _errorMessage = 'This Patient Card is inactive or revoked.';
        _setLoading(false);
        return (
          success: false,
          needsProfileCompletion: false,
          cardModel: null,
          user: null,
          error: _errorMessage,
        );
      }

      // Check card expiry
      if (cardData.isExpired) {
        _errorMessage =
            'This Patient Card has expired. Please contact support or renew.';
        _setLoading(false);
        return (
          success: false,
          needsProfileCompletion: false,
          cardModel: null,
          user: null,
          error: _errorMessage,
        );
      }

      // If Available, this card hasn't been registered yet -> Needs profile completion!
      if (cardData.status == 'Available') {
        _setLoading(false);
        return (
          success: true,
          needsProfileCompletion: true,
          cardModel: cardData,
          user: null,
          error: null,
        );
      }

      // If Assigned, find the patient user document
      final patientUserId = cardData.patientUserId;
      DocumentSnapshot<Map<String, dynamic>>? userDoc;

      if (patientUserId != null && patientUserId.isNotEmpty) {
        userDoc = await _firestore
            .collection('telemedicine_patient')
            .doc(patientUserId)
            .get();
      }

      if (userDoc == null || !userDoc.exists) {
        // Query by patientId field in telemedicine_patient
        final querySnap = await _firestore
            .collection('telemedicine_patient')
            .where('patientId', isEqualTo: cleanId)
            .limit(1)
            .get();
        if (querySnap.docs.isNotEmpty) {
          userDoc = querySnap.docs.first;
        }
      }

      if (userDoc == null || !userDoc.exists) {
        // Needs profile completion
        _setLoading(false);
        return (
          success: true,
          needsProfileCompletion: true,
          cardModel: cardData,
          user: null,
          error: null,
        );
      }

      final userData = userDoc.data()!;
      if (userData['isDeleted'] == true) {
        _errorMessage =
            'This account has been deleted. Please contact support.';
        _setLoading(false);
        return (
          success: false,
          needsProfileCompletion: false,
          cardModel: null,
          user: null,
          error: _errorMessage,
        );
      }

      final fullname = (userData['fullname'] ?? '').toString().trim();
      if (fullname.isEmpty) {
        _setLoading(false);
        return (
          success: true,
          needsProfileCompletion: true,
          cardModel: cardData,
          user: null,
          error: null,
        );
      }

      // Build and log in patient
      final newToken = DateTime.now().millisecondsSinceEpoch.toString();
      await userDoc.reference.update({'token': newToken});

      DateTime? expiryDate =
          cardData.expiryDate ??
          _parseAnyExpiryDate(
            userData['expiryDate'] ?? userData['cardValidUntil'],
          );

      _currentUser = UserModel(
        id: userDoc.id,
        fullname: fullname,
        image: userData['image'],
        deviceId: '',
        idcard: userData['idcard'] ?? '',
        password: userData['password'] ?? '',
        token: newToken,
        role: 'patient',
        phoneNumber: userData['phoneNumber'] ?? '',
        ispayment: true, // Patient Card payment is already handled!
        totalPayment: _safeDouble(userData['totalPayment']),
        paymentImage: userData['paymentImage'],
        highestDegree: userData['highestDegree'],
        doctorId: userData['doctorId'],
        paymentStatus: 'approved',
        fcmToken: userData['fcmToken'],
        patientId: cleanId,
        gender: userData['gender'],
        age: userData['age'],
        expiryDate: expiryDate,
        cardStatus: cardData.status,
        loginType: 'patientId',
        subscriptionPlan: cardData.subscriptionPlan,
        durationMonths: cardData.durationMonths,
        subscriptionStartDate:
            cardData.startDate ??
            parseFirestoreTimestamp(userData['subscriptionStartDate']),
      );

      await _saveUserToLocalStorage(_currentUser!);
      await initializePatientPresence();
      await _recordPatientLogin(_currentUser!.id, _currentUser!.fullname);

      _setLoading(false);
      notifyListeners();
      return (
        success: true,
        needsProfileCompletion: false,
        cardModel: cardData,
        user: _currentUser,
        error: null,
      );
    } catch (e) {
      _errorMessage = 'Failed to verify Patient Card: ${e.toString()}';
      _setLoading(false);
      return (
        success: false,
        needsProfileCompletion: false,
        cardModel: null,
        user: null,
        error: _errorMessage,
      );
    }
  }

  /// High-level adapter for 12-digit Patient Card authentication.
  Future<Map<String, dynamic>?> validateAndAuthenticatePatientCard({
    required String patientId,
  }) async {
    final res = await signInWithPatientCard(cardId: patientId);
    if (!res.success) {
      final err = (res.error ?? '').toLowerCase();
      if (err.contains('expired')) {
        return {'status': 'expired'};
      }
      if (err.contains('blocked') || err.contains('revoked')) {
        return {'status': 'blocked'};
      }
      return {'status': 'not_found', 'error': res.error};
    }
    if (res.needsProfileCompletion && res.cardModel != null) {
      return {
        'status': 'available',
        'cardData': res.cardModel!.toMap(),
        'cardDocId': res.cardModel!.id,
      };
    }
    if (res.user != null) {
      final isComplete = res.user!.fullname.trim().isNotEmpty;
      return {
        'status': 'authenticated',
        'user': res.user,
        'isProfileComplete': isComplete,
      };
    }
    return {'status': 'error'};
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Account Status Management (Admin)
  // ───────────────────────────────────────────────────────────────────────────

  /// Get account status for a patient user document.
  Future<String> getPatientAccountStatus(String userId) async {
    try {
      final doc = await _firestore
          .collection('telemedicine_patient')
          .doc(userId)
          .get();
      if (doc.exists) {
        return doc.data()?['accountStatus'] ?? 'Active';
      }
      return 'Active';
    } catch (e) {
      print('Error getting patient account status: $e');
      return 'Active';
    }
  }

  /// Update account status for a patient user.
  Future<bool> updatePatientAccountStatus(String userId, String status) async {
    try {
      await _firestore.collection('telemedicine_patient').doc(userId).update({
        'accountStatus': status,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      print('✅ Patient account status updated to $status');
      return true;
    } catch (e) {
      print('Error updating patient account status: $e');
      return false;
    }
  }

  Future<bool> blockPatient(String userId) =>
      updatePatientAccountStatus(userId, 'Blocked');

  Future<bool> freezePatient(String userId) =>
      updatePatientAccountStatus(userId, 'Frozen');

  Future<bool> activatePatient(String userId) =>
      updatePatientAccountStatus(userId, 'Active');

  /// Delete a patient account.
  ///
  /// Routes through the soft-delete service: the record and all of its history
  /// are preserved, the patient simply stops appearing in active listings and
  /// can no longer sign in.
  Future<bool> deletePatientId(
    String userId, {
    String? performedBy,
    String reason = 'Deleted by administrator',
  }) async {
    final softDeleted = await SoftDeleteService.softDeletePatient(
      patientId: userId,
      performedBy: performedBy ?? 'admin',
      reason: reason,
    );
    if (!softDeleted) return false;

    // Keep the existing account-status workflow in sync for screens that key
    // off `accountStatus` rather than `isDeleted`.
    return updatePatientAccountStatus(userId, 'Deleted');
  }

  /// Record a login event for a patient.
  Future<void> _recordPatientLogin(String userId, String userName) async {
    try {
      await _firestore.collection('patient_activity_logs').add({
        'patientUserId': userId,
        'patientName': userName,
        'event': 'login',
        'timestamp': FieldValue.serverTimestamp(),
      });
      await _firestore.collection('telemedicine_patient').doc(userId).update({
        'loginStatus': 'Online',
        'lastLogin': FieldValue.serverTimestamp(),
        'lastSeen': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      print('Error recording patient login: $e');
    }
  }

  /// Record a logout event for a patient.
  Future<void> _recordPatientLogout(String userId, String userName) async {
    try {
      await _firestore.collection('patient_activity_logs').add({
        'patientUserId': userId,
        'patientName': userName,
        'event': 'logout',
        'timestamp': FieldValue.serverTimestamp(),
      });
      await _firestore.collection('telemedicine_patient').doc(userId).update({
        'loginStatus': 'Offline',
        'lastLogout': FieldValue.serverTimestamp(),
        'lastSeen': FieldValue.serverTimestamp(),
        'isOnline': false,
      });
    } catch (e) {
      print('Error recording patient logout: $e');
    }
  }

  /// Get all patients with their status (for Doctors & Patients management).
  ///
  /// ADMIN VIEW — intentionally NOT filtered by soft-delete state so the admin
  /// can open the complete preserved record of a deleted patient. The
  /// Active/Deleted toggle is applied in the UI.
  Future<List<Map<String, dynamic>>> getAllPatientsWithStatus() async {
    try {
      final qs = await _firestore
          .collection('telemedicine_patient')
          .where('role', isEqualTo: 'patient')
          .get();

      return qs.docs.map((doc) {
        final data = doc.data();
        return {
          ...data,
          'id': doc.id,
          'accountStatus': data['accountStatus'] ?? 'Active',
          'loginStatus': data['loginStatus'] ?? 'Offline',
          'lastLogin': data['lastLogin'],
          'lastLogout': data['lastLogout'],
          'lastSeen': data['lastSeen'],
          'createdAt': data['createdAt'],
          ...softDeleteViewFields(data),
        };
      }).toList();
    } catch (e) {
      print('Error getting all patients with status: $e');
      return [];
    }
  }

  /// Stream all patients for real-time updates.
  ///
  /// ADMIN VIEW — unfiltered by soft-delete state, same reasoning as
  /// [getAllPatientsWithStatus].
  Stream<List<Map<String, dynamic>>> streamAllPatientsWithStatus() {
    return _firestore
        .collection('telemedicine_patient')
        .where('role', isEqualTo: 'patient')
        .snapshots()
        .map((snapshot) {
          return snapshot.docs.map((doc) {
            final data = doc.data();
            return {
              ...data,
              'id': doc.id,
              'accountStatus': data['accountStatus'] ?? 'Active',
              'loginStatus': data['loginStatus'] ?? 'Offline',
              'lastLogin': data['lastLogin'],
              'lastLogout': data['lastLogout'],
              'lastSeen': data['lastSeen'],
              'createdAt': data['createdAt'],
              ...softDeleteViewFields(data),
            };
          }).toList();
        });
  }

  /// Patients still eligible to appear in active listings.
  ///
  /// Applies the soft-delete predicate in Dart rather than as a
  /// `where('isDeleted', == false)` clause, so records created before the
  /// soft-delete migration — which have no such field — are not accidentally
  /// excluded.
  Stream<List<UserModel>> streamActivePatients() {
    return _firestore
        .collection('telemedicine_patient')
        .where('role', isEqualTo: 'patient')
        .snapshots()
        .map((snapshot) => _toActiveUserModels(snapshot));
  }

  /// One-shot variant of [streamActivePatients].
  Future<List<UserModel>> getActivePatients() async {
    final snapshot = await _firestore
        .collection('telemedicine_patient')
        .where('role', isEqualTo: 'patient')
        .get();
    return _toActiveUserModels(snapshot);
  }

  /// Normalises the soft-delete fields for admin-facing views so legacy records
  /// without the fields render a definite `false` / `true` instead of `null`.
  static Map<String, dynamic> softDeleteViewFields(Map<String, dynamic> data) {
    return {
      SoftDeleteFields.isDeleted: SoftDeleteService.isDeleted(data),
      SoftDeleteFields.isActive: SoftDeleteService.isActiveFlag(data),
    };
  }

  List<UserModel> _toActiveUserModels(QuerySnapshot snapshot) {
    final users = <UserModel>[];
    for (final doc in snapshot.docs) {
      final data = Map<String, dynamic>.from(
        doc.data() as Map<String, dynamic>,
      );
      data['id'] = doc.id;
      if (!SoftDeleteService.isActive(data)) {
        debugPrint(
          '🚫 Excluding soft-deleted patient ${doc.id} from active listing',
        );
        continue;
      }
      try {
        users.add(UserModel.fromMap(data));
      } catch (e) {
        print('Error processing patient document ${doc.id}: $e');
      }
    }
    return users;
  }

  /// Completes or updates the patient profile in Firestore and syncs local session state.
  /// Handles both Phone Auth and Patient Card/ID registrations.
  Future<UserModel> completePatientProfile({
    required String? explicitUid,
    required String fullname,
    required String gender,
    required int? age,
    required String phoneNumber,
    PatientIdModel? patientIdModel,
  }) async {
    _setLoading(true);
    _clearError();

    // 1. Resolve active UID with thorough fallback checks
    String? resolvedUid = explicitUid?.trim();
    if (resolvedUid == null || resolvedUid.isEmpty) {
      resolvedUid = _currentUser?.id;
    }
    if (resolvedUid == null || resolvedUid.isEmpty) {
      resolvedUid = FirebaseAuth.instance.currentUser?.uid;
    }
    if (resolvedUid == null || resolvedUid.isEmpty) {
      if (patientIdModel?.patientUserId != null &&
          patientIdModel!.patientUserId!.isNotEmpty) {
        resolvedUid = patientIdModel.patientUserId;
      }
    }

    debugPrint('📝 [PatientController.completePatientProfile] Resolving session:');
    debugPrint('   - explicitUid: $explicitUid');
    debugPrint('   - _currentUser?.id: ${_currentUser?.id}');
    debugPrint('   - FirebaseAuth.currentUser?.uid: ${FirebaseAuth.instance.currentUser?.uid}');
    debugPrint('   - patientIdModel?.patientUserId: ${patientIdModel?.patientUserId}');
    debugPrint('   - resolvedUid: $resolvedUid');

    // If still null and it is a phone/existing user flow, fail with clear exception
    if ((resolvedUid == null || resolvedUid.isEmpty) && patientIdModel == null) {
      _errorMessage = 'No active patient session found.';
      _setLoading(false);
      debugPrint('❌ [PatientController.completePatientProfile] Failed: No active patient session found.');
      throw Exception('No active patient session found.');
    }

    try {
      final now = DateTime.now();
      final currentDeviceId = await DeviceService.getDeviceId();
      String? fcmToken;
      try {
        fcmToken = await NotificationService().getToken();
      } catch (e) {
        debugPrint('FCM token fetch warning: $e');
      }

      // ── Handle Patient Card / ID Registration ──────────────────────────
      if (patientIdModel != null) {
        final plan = patientIdModel.plan;
        final durationMonths = patientIdModel.durationMonths;
        final expiryDate = SubscriptionCalculator.calculateExpiry(
          now,
          durationMonths: durationMonths,
        );

        final userDocRef = (resolvedUid != null && resolvedUid.isNotEmpty)
            ? _firestore.collection('telemedicine_patient').doc(resolvedUid)
            : _firestore.collection('telemedicine_patient').doc();

        final userId = userDocRef.id;
        final token = now.millisecondsSinceEpoch.toString();

        final newUser = UserModel(
          id: userId,
          fullname: fullname.trim(),
          idcard: '',
          password: '',
          token: token,
          deviceId: currentDeviceId,
          role: 'patient',
          phoneNumber: phoneNumber.trim(),
          ispayment: false,
          totalPayment: 0.0,
          paymentImage: null,
          paymentStatus: null,
          fcmToken: fcmToken ?? '',
          patientId: patientIdModel.patientId,
          gender: gender,
          age: age,
          loginType: 'patientId',
          subscriptionPlan: plan.planId,
          durationMonths: durationMonths,
          subscriptionStartDate: now,
          expiryDate: expiryDate,
          cardStatus: 'Active',
        );

        await userDocRef.set(newUser.toMap(), SetOptions(merge: true));

        // Claim device session and start session watcher
        await SingleDeviceSessionService.validateAndClaimSession(
          collectionName: 'telemedicine_patient',
          documentId: userId,
          currentDeviceId: currentDeviceId,
          blockSecondLogin: false,
        );
        _startSingleDeviceSessionWatcher(userId);

        // Mark patient card assigned
        await _firestore.collection('patient_ids').doc(patientIdModel.id).update({
          'status': 'Assigned',
          'assignedAt': FieldValue.serverTimestamp(),
          'startDate': FieldValue.serverTimestamp(),
          'expiryDate': Timestamp.fromDate(expiryDate),
          'patientUserId': userId,
          'subscriptionPlan': plan.planId,
          'durationMonths': durationMonths,
        });

        // Claim phone uniqueness
        try {
          await PhoneVerificationService().claimPhoneUniqueness(
            phoneNumber.trim(),
            userId: userId,
            role: 'patient',
            patientId: patientIdModel.patientId,
          );
        } catch (e) {
          debugPrint('Patient card phone uniqueness notice: $e');
        }

        if (fcmToken != null && fcmToken.isNotEmpty) {
          await NotificationService().saveTokenToFirestore(userId, 'patient');
        }

        setCurrentUser(newUser);
        _setLoading(false);
        return newUser;
      }

      // ── Handle Phone / Normal Auth Profile Completion ──────────────────
      final targetUserId = resolvedUid!;
      final userDocRef =
          _firestore.collection('telemedicine_patient').doc(targetUserId);

      final userDocSnap = await userDocRef.get();

      final Map<String, dynamic> updatePayload = {
        'fullname': fullname.trim(),
        'gender': gender,
        if (age != null) 'age': age,
        'phoneNumber': phoneNumber.trim(),
        'role': 'patient',
        'updatedAt': FieldValue.serverTimestamp(),
        if (fcmToken != null && fcmToken.isNotEmpty) 'fcmToken': fcmToken,
      };

      updatePayload['deviceId'] = currentDeviceId;
      updatePayload['activeDeviceId'] = currentDeviceId;
      updatePayload['isLoggedIn'] = true;
      updatePayload['lastLoginAt'] = FieldValue.serverTimestamp();

      if (!userDocSnap.exists) {
        // Document didn't exist yet -> include base fields
        final token = now.millisecondsSinceEpoch.toString();
        final authUid = FirebaseAuth.instance.currentUser?.uid ?? targetUserId;
        updatePayload['id'] = targetUserId;
        updatePayload['authUid'] = authUid;
        updatePayload['loginType'] = 'phone';
        updatePayload['ispayment'] = false;
        updatePayload['totalPayment'] = 0.0;
        updatePayload['token'] = token;
        updatePayload['createdAt'] = FieldValue.serverTimestamp();
      }

      await userDocRef.set(updatePayload, SetOptions(merge: true));

      await SingleDeviceSessionService.validateAndClaimSession(
        collectionName: 'telemedicine_patient',
        documentId: targetUserId,
        currentDeviceId: currentDeviceId,
        blockSecondLogin: false,
      );
      _startSingleDeviceSessionWatcher(targetUserId);

      // Fetch fresh updated document
      final freshDoc = await userDocRef.get();
      final updatedUser = UserModel.fromMap({
        ...freshDoc.data()!,
        'id': freshDoc.id,
      });

      // Claim phone uniqueness
      try {
        await PhoneVerificationService().claimPhoneUniqueness(
          phoneNumber.trim(),
          userId: targetUserId,
          role: 'patient',
        );
      } catch (e) {
        debugPrint('Phone uniqueness notice: $e');
      }

      if (fcmToken != null && fcmToken.isNotEmpty) {
        await NotificationService().saveTokenToFirestore(
          targetUserId,
          'patient',
        );
      }

      setCurrentUser(updatedUser);
      _setLoading(false);
      return updatedUser;
    } catch (e, st) {
      debugPrint('❌ [PatientController.completePatientProfile] Error: $e\n$st');
      _errorMessage = e.toString();
      _setLoading(false);
      rethrow;
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Private helpers
  // ───────────────────────────────────────────────────────────────────────────

  void _setLoading(bool value) {
    _isLoading = value;
    notifyListeners();
  }

  void _clearError() {
    _errorMessage = '';
  }
}

/// Bridges [PatientPresenceService] to the controller's internal state.
class _PatientPresenceDelegateImpl implements PatientPresenceDelegate {
  _PatientPresenceDelegateImpl(this._controller);

  final PatientController _controller;

  @override
  String? get currentUserId => _controller._currentUser?.id;

  @override
  String? get currentSessionId => _controller._currentSessionId;

  @override
  String? get currentUserRole => _controller._currentUser?.role;

  @override
  bool get isPatientOnline => _controller._isPatientOnline;

  @override
  void setIsPatientOnline(bool value) => _controller._isPatientOnline = value;

  @override
  void onPresenceStateChanged() {
    // ignore: invalid_use_of_visible_for_testing_member, invalid_use_of_protected_member
    _controller.notifyListeners();
  }
}
