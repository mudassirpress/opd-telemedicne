// lib/features/auth/presentation/controllers/doctor_controller.dart
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:telemedicine/data/models/doctor_online_session.dart';
import 'package:telemedicine/features/admin/presentation/doctor_online_history/doctor_online_services/doctor_online_history_service.dart';
import 'package:telemedicine/data/models/user_model.dart';
import 'package:telemedicine/core/services/notification_service.dart';
import 'package:telemedicine/core/services/session_service.dart';
import 'package:telemedicine/core/services/soft_delete_service.dart';
import 'package:telemedicine/core/services/single_device_session_service.dart';
import 'package:telemedicine/core/services/timezone_service.dart';
import 'package:telemedicine/core/services/device_service.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/core/network/network_health_checker.dart';
import 'package:telemedicine/core/services/callkit_service.dart';
import 'package:telemedicine/core/services/incoming_call_coordinator.dart';
import 'package:telemedicine/features/chat/presentation/controllers/chat_controller.dart';

class DoctorController extends ChangeNotifier {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  final DoctorOnlineHistoryService _historyService =
      DoctorOnlineHistoryService();
  String? _currentSessionId;
  UserModel? _currentDoctor;
  String? _sharedAccountId;
  String? _errorMessage;
  bool _isLoading = false;

  // Presence tracking
  Timer? _presenceTimer;
  bool _isOnline = false;
  bool _manualAvailability = false;
  final NetworkHealthChecker _networkHealthChecker = NetworkHealthChecker();
  Map<String, bool> _doctorsStatusCache = {};

  // Doctor list stream: self-refreshing via periodic timer
  StreamController<List<Map<String, dynamic>>>? _doctorListStreamController;
  Timer? _doctorListRefreshTimer;
  StreamSubscription? _doctorListFirestoreSub;
  List<Map<String, dynamic>> _lastDoctorsSnapshot = [];
  int _doctorListListenerCount = 0;
  QuerySnapshot? _lastRawFirestoreSnapshot;

  // Connectivity listener for immediate offline detection
  StreamSubscription<ConnectivityResult>? _connectivitySub;
  bool _connectivityListenerSetup = false;

  // Single-device active session subscription
  StreamSubscription? _sessionSubscription;

  void _listenToDoctorSession(String doctorId) {
    _sessionSubscription?.cancel();
    DeviceService.getDeviceId().then((currentDeviceId) {
      _sessionSubscription = SingleDeviceSessionService.listenForSessionChanges(
        collectionName: 'telemedicine_doctors',
        documentId: doctorId,
        currentDeviceId: currentDeviceId,
        onSessionInvalidated: () async {
          debugPrint(
            '🔒 [DoctorController] Remote device claimed session. Dislodging this doctor.',
          );
          await signOut();
          SingleDeviceSessionService.handleForcedLogout(null);
        },
      );
    });
  }

  // Getters
  UserModel? get currentDoctor => _currentDoctor;
  String get errorMessage => _errorMessage ?? '';
  bool get isLoading => _isLoading;
  bool get isDoctorOnline => _isOnline;
  bool get manualAvailability => _manualAvailability;

  Map<String, bool> get doctorsStatusCache => _doctorsStatusCache;

  // Generate 4-digit doctor ID
  String _generateDoctorId() {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final doctorId = (timestamp % 10000).toString().padLeft(4, '0');
    return doctorId;
  }

  // Check if doctor ID already exists
  Future<bool> _isDoctorIdExists(String doctorId) async {
    final snapshot = await _firestore
        .collection('telemedicine_doctors')
        .where('doctorId', isEqualTo: doctorId)
        .where('isActive', isEqualTo: true)
        .get();
    return snapshot.docs.isNotEmpty;
  }

  // Generate unique 4-digit doctor ID
  Future<String> generateUniqueDoctorId() async {
    String doctorId;
    bool exists;
    int attempts = 0;

    do {
      doctorId = _generateDoctorId();
      exists = await _isDoctorIdExists(doctorId);
      attempts++;

      if (attempts > 10) {
        doctorId = DateTime.now().millisecondsSinceEpoch.toString().substring(
          0,
          4,
        );
        break;
      }
    } while (exists);

    return doctorId;
  }

  Future<void> initializeDoctorPresence() async {
    if (_currentDoctor != null) {
      if (_manualAvailability) {
        await updateDoctorPresence(true);
      }
      _setupConnectivityListener();
    }
  }

  /// Listen for connectivity changes.
  /// When connectivity is lost, marks doctor offline in Firebase immediately.
  /// When connectivity is restored, restores doctor's manual availability preference.
  void _setupConnectivityListener() {
    if (_connectivityListenerSetup) return;
    _connectivityListenerSetup = true;

    _connectivitySub = Connectivity().onConnectivityChanged.listen((
      result,
    ) async {
      if (_currentDoctor == null || _currentDoctor!.id.isEmpty) return;
      final doctorId = _currentDoctor!.id;

      if (result == ConnectivityResult.none) {
        // Device lost internet connection
        stopPresenceTracking();
        try {
          await _firestore.collection('telemedicine_doctors').doc(doctorId).update({
            'isAvailable': false,
            'effectiveStatus': 'OFFLINE',
            'deviceReachable': false,
            'presenceStale': true,
            'lastStatusUpdate': FieldValue.serverTimestamp(),
          });
        } catch (_) {}
      } else {
        // Interface restored - resume tracking and restore status if manual preference was ON
        if (_manualAvailability) {
          try {
            await _firestore.collection('telemedicine_doctors').doc(doctorId).update({
              'isOnline': true,
              'isAvailable': true,
              'effectiveStatus': 'ONLINE',
              'deviceReachable': true,
              'presenceStale': false,
              'lastStatusUpdate': FieldValue.serverTimestamp(),
              'lastSeen': FieldValue.serverTimestamp(),
            });
          } catch (_) {}
          startPresenceTracking();
        }
      }
    });
  }

  /// Stop the connectivity listener.
  void _stopConnectivityListener() {
    _connectivitySub?.cancel();
    _connectivitySub = null;
    _connectivityListenerSetup = false;
  }

  /// Single source of truth for Doctor Online/Offline manual toggle.
  /// Controlled strictly by the doctor, immune to app background/kill triggers or network reconnect auto-resets.
  Future<bool> toggleDoctorStatus(bool isOnline) async {
    if (_currentDoctor == null || _currentDoctor!.id.isEmpty) return false;
    final doctorId = _currentDoctor!.id;

    _manualAvailability = isOnline;
    _isOnline = isOnline;
    notifyListeners();

    try {
      await _firestore.collection('telemedicine_doctors').doc(doctorId).update({
        'isOnline': isOnline,
        'isAvailable': isOnline,
        'manualAvailability': isOnline,
        'effectiveStatus': isOnline ? 'ONLINE' : 'OFFLINE',
        'presenceStale': !isOnline,
        'deviceReachable': isOnline,
        'lastStatusUpdate': FieldValue.serverTimestamp(),
        'lastSeen': FieldValue.serverTimestamp(),
      });

      if (isOnline) {
        startPresenceTracking();
        _setupConnectivityListener();
        unawaited(
          _historyService.startOnlineSession(
            doctorId: doctorId,
            doctorName: _currentDoctor!.fullname,
          ),
        );
      } else {
        stopPresenceTracking();
        unawaited(_historyService.endAllActiveSessions(doctorId: doctorId));
        // Gracefully tear down any incoming ringing states and native CallKit UI
        unawaited(IncomingCallCoordinator.instance.dismissAllActiveRinging());
        unawaited(CallKitService.instance.endAll());
      }
      return true;
    } catch (e) {
      debugPrint('Error toggling doctor status in Firestore: $e');
      return false;
    }
  }

  /// Updates doctor presence with backend validation and network check.
  /// Returns `true` if successful, `false` otherwise.
  Future<bool> updateDoctorPresence(bool isOnline) async {
    return toggleDoctorStatus(isOnline);
  }

  /// Heartbeat loop: sends ping every 25 seconds while doctor app is in foreground.
  /// Automates online lease renewal without requiring manual duty switches.
  void startPresenceTracking() {
    _presenceTimer?.cancel();
    if (_currentDoctor == null || _currentDoctor!.id.isEmpty) return;

    unawaited(_sendDoctorHeartbeatPing());

    _presenceTimer = Timer.periodic(const Duration(seconds: 25), (timer) async {
      if (_currentDoctor == null || _currentDoctor!.id.isEmpty) {
        stopPresenceTracking();
        return;
      }
      await _sendDoctorHeartbeatPing();
    });
  }

  Future<void> _sendDoctorHeartbeatPing() async {
    if (_currentDoctor == null || _currentDoctor!.id.isEmpty) return;

    // Check internet reachability before heartbeat
    final hasData = await _networkHealthChecker.hasActiveInternet();
    if (!hasData) {
      debugPrint('Doctor heartbeat skipped: data package unreachable');
      return;
    }

    try {
      await _firestore
          .collection('telemedicine_doctors')
          .doc(_currentDoctor!.id)
          .update({
            'isOnline': true,
            'isAvailable': true,
            'manualAvailability': true,
            'lastHeartbeat': FieldValue.serverTimestamp(),
            'lastHeartbeatAt': FieldValue.serverTimestamp(),
            'lastSeen': FieldValue.serverTimestamp(),
            'isAppConnected': true,
          });
      if (!_isOnline) {
        _isOnline = true;
        notifyListeners();
      }

      if (_currentSessionId != null) {
        unawaited(SessionService.heartbeatSession(_currentSessionId!));
      }
    } catch (err) {
      debugPrint('Doctor heartbeat update error: $err');
    }
  }

  // Stop presence tracking
  void stopPresenceTracking() {
    _presenceTimer?.cancel();
    _presenceTimer = null;
  }

  Stream<List<DoctorOnlineSession>> getDoctorSessions({
    required String doctorId,
    DateTime? startDate,
    DateTime? endDate,
  }) {
    return _historyService.getDoctorSessions(
      doctorId: doctorId,
      startDate: startDate,
      endDate: endDate,
    );
  }

  // Get doctor daily stats
  Stream<List<DoctorDailyStats>> getDoctorDailyStats({
    required String doctorId,
    DateTime? startDate,
    DateTime? endDate,
  }) {
    return _historyService.getDoctorDailyStats(
      doctorId: doctorId,
      startDate: startDate,
      endDate: endDate,
    );
  }

  // Get single doctor online status — manual toggle is the single source of truth
  Future<bool> getDoctorOnlineStatus(String doctorId) async {
    try {
      final doc = await _firestore
          .collection('telemedicine_doctors')
          .doc(doctorId)
          .get();
      if (doc.exists) {
        final data = doc.data();
        final isOnline =
            data?['isOnline'] == true ||
            data?['isAvailable'] == true ||
            data?['manualAvailability'] == true;
        _doctorsStatusCache[doctorId] = isOnline;
        return isOnline;
      }
      return false;
    } catch (e) {
      print('Error getting doctor status: $e');
      return false;
    }
  }

  // Stream doctor online status (real-time) — manual toggle is the single source of truth
  Stream<bool> streamDoctorOnlineStatus(String doctorId) {
    return _firestore
        .collection('telemedicine_doctors')
        .doc(doctorId)
        .snapshots()
        .map((doc) {
          if (!doc.exists) return false;
          final data = doc.data()!;
          final isOnline =
              data['isOnline'] == true ||
              data['isAvailable'] == true ||
              data['manualAvailability'] == true;
          _doctorsStatusCache[doctorId] = isOnline;
          return isOnline;
        });
  }

  /// The most recent list already computed by the shared doctor-list stream.
  ///
  /// Lets a late subscriber paint immediately instead of showing a loading
  /// state until the next Firestore event or 15-second re-emission. The shared
  /// stream is a broadcast controller and does NOT replay, so without this a
  /// screen opened after the stream was already running (e.g. Admin Portal
  /// entered from a screen that already shows the doctor list) would sit on a
  /// spinner for up to 15 seconds.
  ///
  /// Empty until the first snapshot lands. Callers must treat an empty result
  /// as "not loaded yet", not as "there are no doctors".
  ///
  /// Returns a defensive copy: the admin screen applies in-place edits to the
  /// list it paints from (removing a just-deleted doctor), and handing out the
  /// live list would let that mutate the shared cache underneath every other
  /// consumer of the stream.
  List<Map<String, dynamic>> get cachedDoctors =>
      List<Map<String, dynamic>>.of(_lastDoctorsSnapshot);

  /// Returns a self-refreshing stream of all active doctors with computed
  /// online status. The stream emits on Firestore document changes AND
  /// every 15 seconds via a periodic timer so that stale heartbeats are
  /// detected even when no Firestore write occurs.
  ///
  /// SOFT DELETE: this is the single feed behind the patient doctor list, the
  /// doctor grid, the search field (which filters client-side off this list)
  /// and the report-sharing picker. Soft-deleted doctors are dropped here
  /// rather than in each widget, so no patient-facing listing can accidentally
  /// surface one.
  Stream<List<Map<String, dynamic>>> streamAllDoctors() {
    _doctorListListenerCount++;

    // Lazily create the shared stream + start listening to Firestore
    _doctorListStreamController ??= _initDoctorListStream();

    // Start the periodic refresh timer when the first listener attaches
    _startDoctorListRefreshTimer();

    return _doctorListStreamController!.stream;
  }

  StreamController<List<Map<String, dynamic>>> _initDoctorListStream() {
    final controller = StreamController<List<Map<String, dynamic>>>.broadcast();

    // Listen to Firestore snapshots — re-evaluate and cache on every event
    //
    // DELIBERATELY no `where('isDeleted', == false)` here. Records created
    // before the soft-delete migration have no `isDeleted` field, and a
    // server-side equality filter would exclude every one of them — hiding
    // the entire existing doctor base. The active check is therefore applied
    // in `_mapDoctorsSnapshot`, which treats a missing field as active.
    _doctorListFirestoreSub = _firestore
        .collection('telemedicine_doctors')
        .where('isActive', isEqualTo: true)
        .snapshots()
        .listen(
          (snapshot) {
            _lastRawFirestoreSnapshot = snapshot;
            _lastDoctorsSnapshot = _mapDoctorsSnapshot(snapshot);
            if (!controller.isClosed) {
              controller.add(_lastDoctorsSnapshot);
            }
          },
          onError: (error) {
            print('❌ Doctor list Firestore error: $error');
          },
        );

    return controller;
  }

  /// Evaluate online status for every doctor using the current wall-clock
  /// time. This is called both on Firestore events and on the periodic timer.
  ///
  /// Also acts as the single soft-delete gate for every patient-facing doctor
  /// listing. See [streamAllDoctors] for why this is a Dart-side filter rather
  /// than a `where` clause.
  List<Map<String, dynamic>> _mapDoctorsSnapshot(QuerySnapshot snapshot) {
    final active = <Map<String, dynamic>>[];

    for (final doc in snapshot.docs) {
      final data = doc.data() as Map<String, dynamic>;

      // Soft-deleted / deactivated doctors are excluded from active
      // discovery: patient doctor list, grid, search, categories and the
      // report-sharing picker all read this one stream.
      if (!SoftDeleteService.isActive(data)) {
        debugPrint(
          '🚫 Hiding soft-deleted doctor ${doc.id} from active listings',
        );
        _doctorsStatusCache.remove(doc.id);
        continue;
      }

      final isOnline =
          data['isOnline'] == true ||
          data['isAvailable'] == true ||
          data['manualAvailability'] == true;

      _doctorsStatusCache[doc.id] = isOnline;

      active.add({
        ...data,
        'id': doc.id,
        'isOnline': isOnline,
        'lastSeen': data['lastSeen'],
        // Exposed so the doctor list can order online-first from this very
        // stream, instead of opening a second realtime subscription.
        'onlineSince': (data['onlineSince'] as Timestamp?)?.toDate(),
      });
    }

    return active;
  }

  /// Start a 15-second periodic timer that re-evaluates online status using
  /// the cached Firestore snapshot. This ensures stale heartbeats are
  /// detected even when no Firestore write triggers a new snapshot event.
  void _startDoctorListRefreshTimer() {
    if (_doctorListRefreshTimer != null) return;

    _doctorListRefreshTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_doctorListStreamController == null ||
          _doctorListStreamController!.isClosed) {
        _stopDoctorListRefreshTimer();
        return;
      }

      // Re-map the cached Firestore snapshot with fresh DateTime.now()
      // to detect stale heartbeats. No new Firestore read needed.
      if (_lastRawFirestoreSnapshot != null) {
        _lastDoctorsSnapshot = _mapDoctorsSnapshot(_lastRawFirestoreSnapshot!);

        if (!_doctorListStreamController!.isClosed) {
          _doctorListStreamController!.add(_lastDoctorsSnapshot);
        }
      }
    });
  }

  void _stopDoctorListRefreshTimer() {
    _doctorListRefreshTimer?.cancel();
    _doctorListRefreshTimer = null;
  }

  /// Called when a StreamBuilder unsubscribes from the doctor list stream.
  void disposeDoctorListStream() {
    _doctorListListenerCount--;
    if (_doctorListListenerCount <= 0) {
      _doctorListListenerCount = 0;
      _stopDoctorListRefreshTimer();
      _doctorListFirestoreSub?.cancel();
      _doctorListFirestoreSub = null;
      _doctorListStreamController?.close();
      _doctorListStreamController = null;
      _lastRawFirestoreSnapshot = null;
    }
  }

  // Sign in with existing doctor ID
  Future<bool> signInWithDoctorId({required String doctorId}) async {
    _setLoading(true);
    _clearError();

    try {
      print('Attempting to sign in with doctor ID: $doctorId');

      final snapshot = await _firestore
          .collection('telemedicine_doctors')
          .where('doctorId', isEqualTo: doctorId)
          .where('isActive', isEqualTo: true)
          .get();

      if (snapshot.docs.isEmpty) {
        _errorMessage =
            'Doctor ID not found. Please check your ID or create a new profile.';
        _setLoading(false);
        return false;
      }

      final doctorData = snapshot.docs.first.data();
      final doctorDoc = snapshot.docs.first;

      // ── Account status check ──────────────────────────────────────────
      final accountStatus = doctorData['accountStatus'] ?? 'Active';
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
        _errorMessage = 'This Doctor ID no longer exists.';
        _setLoading(false);
        return false;
      }

      final claimResult = await SingleDeviceSessionService.claimActiveSession(
        collectionName: 'telemedicine_doctors',
        documentId: doctorDoc.id,
        role: 'doctor',
      );
      if (!claimResult.allowed) {
        _errorMessage =
            claimResult.errorMessage ??
            'Unable to establish secure doctor session.';
        _setLoading(false);
        return false;
      }
      _currentSessionId = claimResult.sessionId;

      print('Found doctor: ${doctorData['fullname']}');

      // Built through `fromMap` so every profile field the session needs —
      // `price`, `description`, `languages`, `highestDegree` — comes from the
      // document. Reconstructing it field-by-field used to drop anything the
      // caller did not enumerate, which left Update Profile seeding empty
      // price/description boxes for doctors who had already filled them in.
      _currentDoctor = UserModel.fromMap({
        ...doctorData,
        'id': doctorDoc.id,
        'role': 'doctor',
        'image': (doctorData['imageUrl'] ?? doctorData['image'] ?? '')
            .toString(),
        'deviceId': '',
        'idcard': '',
        'password': '',
        'token': DateTime.now().millisecondsSinceEpoch.toString(),
        // Doctor documents do not carry the subscription-payment fields, and
        // a non-bool there would make `fromMap` throw at login.
        'ispayment': false,
        'totalPayment': 0.0,
      });

      await _saveDoctorToLocalStorage(_currentDoctor!);
      _listenToDoctorSession(doctorDoc.id);

      // Set doctor as online
      await updateDoctorPresence(true);
      startPresenceTracking();
      _setupConnectivityListener();

      print('Doctor login successful');
      await NotificationService().saveTokenToFirestore(doctorDoc.id, 'doctor');

      // Record login event
      await _recordDoctorLogin(_currentDoctor!.id, _currentDoctor!.fullname);

      _setLoading(false);
      notifyListeners();
      return true;
    } catch (e) {
      print('Error in signInWithDoctorId: $e');
      _errorMessage = 'Failed to sign in: ${e.toString()}';
      _setLoading(false);
      return false;
    }
  }

  // Save FCM token to doctor's profile
  Future<bool> saveDoctorFcmToken({
    required String doctorId,
    required String fcmToken,
  }) async {
    try {
      print('Saving FCM token for doctor ID: $doctorId');

      await _firestore.collection('telemedicine_doctors').doc(doctorId).update({
        'fcmToken': fcmToken,
        'tokenUpdatedAt': FieldValue.serverTimestamp(),
      });

      if (_currentDoctor?.id == doctorId) {
        // `copyWith` rather than a field-by-field rebuild: rebuilding dropped
        // every field the caller did not enumerate — price, description,
        // languages and the rest vanished from the local session here.
        _currentDoctor = _currentDoctor!.copyWith(fcmToken: fcmToken);

        await _saveDoctorToLocalStorage(_currentDoctor!);
      }

      print('✅ FCM token saved to doctor profile');
      return true;
    } catch (e) {
      print('Error saving doctor FCM token: $e');
      return false;
    }
  }

  // Get FCM token for a specific doctor
  Future<String?> getDoctorFcmToken(String doctorId) async {
    try {
      final doc = await _firestore
          .collection('telemedicine_doctors')
          .doc(doctorId)
          .get();

      if (doc.exists) {
        return doc.data()?['fcmToken'] as String?;
      }
      return null;
    } catch (e) {
      print('Error getting doctor FCM token: $e');
      return null;
    }
  }

  // ── Account Status Management ───────────────────────────────────────────

  /// Check the account status of a doctor by doctorId.
  /// Returns the status string: 'Active', 'Blocked', 'Frozen', 'Deleted', or 'Active' if unset.
  Future<String> getDoctorAccountStatus(String doctorId) async {
    try {
      final doc = await _firestore
          .collection('telemedicine_doctors')
          .doc(doctorId)
          .get();
      if (doc.exists) {
        return doc.data()?['accountStatus'] ?? 'Active';
      }
      return 'Active';
    } catch (e) {
      print('Error getting doctor account status: $e');
      return 'Active';
    }
  }

  /// Update the account status of a doctor.
  Future<bool> updateDoctorAccountStatus(String doctorId, String status) async {
    try {
      await _firestore.collection('telemedicine_doctors').doc(doctorId).update({
        'accountStatus': status,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      print('✅ Doctor account status updated to $status');
      return true;
    } catch (e) {
      print('Error updating doctor account status: $e');
      return false;
    }
  }

  /// Block a doctor account.
  Future<bool> blockDoctor(String doctorId) async {
    return updateDoctorAccountStatus(doctorId, 'Blocked');
  }

  /// Freeze a doctor account.
  Future<bool> freezeDoctor(String doctorId) async {
    return updateDoctorAccountStatus(doctorId, 'Frozen');
  }

  /// Activate / unblock a doctor account.
  Future<bool> activateDoctor(String doctorId) async {
    return updateDoctorAccountStatus(doctorId, 'Active');
  }

  /// Delete a doctor ID (soft delete by setting status to Deleted).
  Future<bool> deleteDoctorId(String doctorId) async {
    return updateDoctorAccountStatus(doctorId, 'Deleted');
  }

  /// Record a login event for a doctor.
  Future<void> _recordDoctorLogin(String doctorId, String doctorName) async {
    try {
      await _firestore.collection('doctor_activity_logs').add({
        'doctorId': doctorId,
        'doctorName': doctorName,
        'event': 'login',
        'timestamp': FieldValue.serverTimestamp(),
      });
      await _firestore.collection('telemedicine_doctors').doc(doctorId).update({
        'loginStatus': 'Online',
        'lastLogin': FieldValue.serverTimestamp(),
        'lastSeen': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      print('Error recording doctor login: $e');
    }
  }

  /// Record a logout event for a doctor.
  Future<void> _recordDoctorLogout(String doctorId, String doctorName) async {
    try {
      await _firestore.collection('doctor_activity_logs').add({
        'doctorId': doctorId,
        'doctorName': doctorName,
        'event': 'logout',
        'timestamp': FieldValue.serverTimestamp(),
      });
      await _firestore.collection('telemedicine_doctors').doc(doctorId).update({
        'loginStatus': 'Offline',
        'lastLogout': FieldValue.serverTimestamp(),
        'lastSeen': FieldValue.serverTimestamp(),
        'isOnline': false,
      });
    } catch (e) {
      print('Error recording doctor logout: $e');
    }
  }

  /// Get all doctor activity logs (for online history tab).
  Stream<List<Map<String, dynamic>>> getAllDoctorActivityLogs() {
    return _firestore
        .collection('doctor_activity_logs')
        .orderBy('timestamp', descending: true)
        .snapshots()
        .map((snapshot) {
          return snapshot.docs.map((doc) {
            final data = doc.data();
            data['id'] = doc.id;
            return data;
          }).toList();
        });
  }

  /// Get all doctors with their status (for Doctors & Patients management).
  ///
  /// ADMIN VIEW — intentionally NOT filtered by soft-delete state. The admin
  /// portal must be able to see and open the complete record of a deleted
  /// doctor. The Active/Deleted toggle is applied in the UI.
  Future<List<Map<String, dynamic>>> getAllDoctorsWithStatus() async {
    try {
      final querySnapshot = await _firestore
          .collection('telemedicine_doctors')
          .get();

      List<Map<String, dynamic>> doctors = querySnapshot.docs.map((doc) {
        final data = doc.data();
        final isOnline =
            data['isOnline'] == true ||
            data['isAvailable'] == true ||
            data['manualAvailability'] == true;
        bool onlineStatus = isOnline;

        return {
          ...data,
          'id': doc.id,
          'isOnline': onlineStatus,
          'accountStatus': data['accountStatus'] ?? 'Active',
          'loginStatus': data['loginStatus'] ?? 'Offline',
          'lastLogin': data['lastLogin'],
          'lastLogout': data['lastLogout'],
          'lastSeen': data['lastSeen'],
          'createdAt': data['createdAt'],
          ..._softDeleteViewFields(data),
        };
      }).toList();

      doctors.sort((a, b) {
        final aTime = (a['createdAt'] as Timestamp?)?.toDate();
        final bTime = (b['createdAt'] as Timestamp?)?.toDate();
        if (aTime == null && bTime == null) return 0;
        if (aTime == null) return 1;
        if (bTime == null) return -1;
        return bTime.compareTo(aTime);
      });

      return doctors;
    } catch (e) {
      print('Error getting all doctors with status: $e');
      return [];
    }
  }

  /// Stream all doctors for real-time updates.
  Stream<List<Map<String, dynamic>>> streamAllDoctorsWithStatus() {
    return _firestore.collection('telemedicine_doctors').snapshots().map((
      snapshot,
    ) {
      return snapshot.docs.map((doc) {
        final data = doc.data();
        final isOnline =
            data['isOnline'] == true ||
            data['isAvailable'] == true ||
            data['manualAvailability'] == true;
        bool onlineStatus = isOnline;

        return {
          ...data,
          'id': doc.id,
          'isOnline': onlineStatus,
          'accountStatus': data['accountStatus'] ?? 'Active',
          'loginStatus': data['loginStatus'] ?? 'Offline',
          'lastLogin': data['lastLogin'],
          'lastLogout': data['lastLogout'],
          'lastSeen': data['lastSeen'],
          'createdAt': data['createdAt'],
          ..._softDeleteViewFields(data),
        };
      }).toList();
    });
  }

  /// Normalises the soft-delete fields for admin-facing views.
  ///
  /// Legacy records have no `isDeleted` / `isActive` at all, which would render
  /// as `null` in the admin UI ("Deleted?" with no value). The shared
  /// predicate collapses a missing field to `false` / `true` so every record
  /// displays a definite state.
  static Map<String, dynamic> _softDeleteViewFields(Map<String, dynamic> data) {
    return {
      SoftDeleteFields.isDeleted: SoftDeleteService.isDeleted(data),
      SoftDeleteFields.isActive: SoftDeleteService.isActiveFlag(data),
    };
  }

  // Create doctor profile
  Future<bool> createDoctorProfile({
    required String fullname,
    required String highestDegree,
    String? imageUrl,
    double price = 0,
    String description = '',
  }) async {
    _setLoading(true);
    _clearError();

    try {
      print('Creating doctor profile for: $fullname');

      final existingDoctor = await _firestore
          .collection('telemedicine_doctors')
          .where('fullname', isEqualTo: fullname)
          .where('isActive', isEqualTo: true)
          .get();

      if (existingDoctor.docs.isNotEmpty) {
        _errorMessage = 'A doctor with this name already exists';
        _setLoading(false);
        return false;
      }

      final doctorId = await generateUniqueDoctorId();
      print('Generated doctor ID: $doctorId');

      final doctorRef = _firestore.collection('telemedicine_doctors').doc();

      final doctorProfile = {
        'id': doctorRef.id,
        'doctorId': doctorId,
        'fullname': fullname,
        'highestDegree': highestDegree,
        'imageUrl': imageUrl ?? '',
        // Consultation price and profile description, saved with the profile
        // on creation. Both are optional so a partially-filled profile still
        // creates the document; the doctor can add them later from
        // Update Doctor Profile.
        'price': price,
        'consultationFee': price,
        'description': description,
        'phoneNumber': '',
        'password': '',
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        'isActive': true,
        'totalPatients': 0,
        'consultations': 0,
        'rating': 0.0,
        'role': 'doctor',
        'totalRatings': 0,
        'isOnline': false,
        'lastSeen': null,
      };

      await doctorRef.set(doctorProfile);
      print('Doctor profile saved to Firestore');

      await _firestore
          .collection('telemedicine_patient')
          .doc(_sharedAccountId ?? _currentDoctor!.id)
          .collection('doctor_profiles')
          .doc(doctorRef.id)
          .set({
            'profileId': doctorRef.id,
            'doctorId': doctorId,
            'fullname': fullname,
            'createdAt': FieldValue.serverTimestamp(),
            'imageUrl': imageUrl ?? '',
            'isActive': true,
          });

      _currentDoctor = UserModel(
        id: doctorRef.id,
        fullname: fullname,
        image: imageUrl ?? '',
        deviceId: _currentDoctor!.deviceId,
        idcard: _currentDoctor!.idcard,
        password: '',
        token: DateTime.now().millisecondsSinceEpoch.toString(),
        role: 'doctor',
        phoneNumber: '',
        ispayment: _currentDoctor!.ispayment,
        totalPayment: _currentDoctor!.totalPayment,
        paymentImage: _currentDoctor!.paymentImage,
        highestDegree: highestDegree,
        doctorId: doctorId,
        fcmToken: null,
        price: price,
        consultationFee: price,
        description: description,
      );

      await _saveDoctorToLocalStorage(_currentDoctor!);
      print('Doctor profile saved locally');

      _setLoading(false);
      notifyListeners();
      return true;
    } catch (e) {
      print('Error in createDoctorProfile: $e');
      _errorMessage = 'Failed to create doctor profile: ${e.toString()}';
      _setLoading(false);
      return false;
    }
  }

  // Add this method to DoctorController class
  void updateDoctor(UserModel updatedDoctor) {
    _currentDoctor = updatedDoctor;
    notifyListeners();
  }

  // Get all doctor profiles
  Future<List<Map<String, dynamic>>> getAllDoctorProfiles() async {
    try {
      final querySnapshot = await _firestore
          .collection('telemedicine_doctors')
          .where('isActive', isEqualTo: true)
          .get();

      List<Map<String, dynamic>> doctors = querySnapshot.docs.map((doc) {
        final data = doc.data();
        final isOnline = data['isOnline'] ?? false;
        final lastSeen = data['lastSeen'] as Timestamp?;

        bool status = isOnline;
        if (!isOnline && lastSeen != null) {
          final lastSeenDate = lastSeen.toDate();
          final now = DateTime.now();
          final difference = now.difference(lastSeenDate);
          if (difference.inMinutes < 2) {
            status = true;
          }
        }

        return {...data, 'id': doc.id, 'isOnline': status};
      }).toList();

      // Defence in depth for the soft-delete contract. The `isActive` clause
      // above already excludes soft-deleted doctors, but going through the
      // shared predicate means a future change to the server-side filter
      // cannot accidentally start leaking deleted doctors into a listing.
      doctors = SoftDeleteService.activeOnly(doctors, (doctor) => doctor);

      doctors.sort((a, b) {
        final aTime = (a['createdAt'] as Timestamp?)?.toDate();
        final bTime = (b['createdAt'] as Timestamp?)?.toDate();

        if (aTime == null && bTime == null) return 0;
        if (aTime == null) return 1;
        if (bTime == null) return -1;

        return bTime.compareTo(aTime);
      });

      return doctors;
    } catch (e) {
      print('Error getting doctor profiles: $e');
      return [];
    }
  }

  // Get specific doctor profile
  Future<Map<String, dynamic>?> getDoctorProfile(String doctorId) async {
    try {
      final doc = await _firestore
          .collection('telemedicine_doctors')
          .doc(doctorId)
          .get();

      if (doc.exists) {
        final data = doc.data()!;
        final isOnline = data['isOnline'] ?? false;
        final lastSeen = data['lastSeen'] as Timestamp?;

        bool status = isOnline;
        if (!isOnline && lastSeen != null) {
          final lastSeenDate = lastSeen.toDate();
          final now = DateTime.now();
          final difference = now.difference(lastSeenDate);
          if (difference.inMinutes < 2) {
            status = true;
          }
        }

        return {...data, 'id': doc.id, 'isOnline': status};
      }
      return null;
    } catch (e) {
      print('Error getting doctor profile: $e');
      return null;
    }
  }

  /// Wraps the raw map [getDoctorProfile] returns in the model the profile
  /// completion checks read, so every gate parses the document identically.
  ///
  /// The document itself carries no `role`, so it is stamped as a doctor
  /// here — otherwise [UserModel.fromMap] would default it to `patient`.
  static UserModel doctorFromProfileData(Map<String, dynamic> data) {
    return UserModel.fromMap({...data, 'role': 'doctor'});
  }

  /// Whether [doctor] still owes the booking flow a consultation price or a
  /// profile description, i.e. whether the completion screen is required.
  ///
  /// Every shape a "not filled in" value arrives in resolves to `true` here:
  /// the key missing entirely, `null`, `''` / whitespace-only text, the `0`
  /// placeholder admin-created documents are seeded with, and an unparseable
  /// hand-edited value. A `null` profile counts as incomplete as well, so the
  /// check can never let an unknown doctor through.
  static bool isMissingRequiredProfileFields(UserModel? doctor) {
    if (doctor == null) return true;

    // `consultationPrice` never throws and reads `price`, then the legacy
    // `consultationFee`, then 0 — "0 means not set" is the documented
    // contract of both fields.
    if (doctor.consultationPrice <= 0) return true;

    final description = doctor.description?.trim() ?? '';
    return description.isEmpty;
  }

  /// Fresh look at the doctor document to decide whether the profile
  /// completion screen must be shown before the portal is allowed to open.
  ///
  /// Firestore is the source of truth: a cached session written before
  /// `price` / `description` existed still looks valid locally, so the
  /// document has to be re-read on login, on app reopen and on every portal
  /// entry. When the document cannot be read (offline) the cached session
  /// decides instead, so a completed profile is never blocked by a dropped
  /// connection. The freshly read values are pulled into the session either
  /// way, which is the profile refresh the gate promises.
  Future<bool> requiresProfileCompletion({UserModel? sessionDoctor}) async {
    final session = sessionDoctor ?? _currentDoctor;
    if (session == null || session.id.isEmpty) return true;

    final data = await getDoctorProfile(session.id);
    if (data == null) return isMissingRequiredProfileFields(session);

    final latest = doctorFromProfileData(data);

    updateDoctor(
      session.copyWith(
        price: latest.consultationPrice,
        consultationFee: latest.consultationFee,
        description: latest.description,
      ),
    );

    return isMissingRequiredProfileFields(latest);
  }

  // Update signOut method to end sessions
  Future<void> signOut() async {
    try {
      print('Starting doctor logout process...');

      if (_currentDoctor != null && _currentDoctor!.id.isNotEmpty) {
        // Record logout event
        await _recordDoctorLogout(_currentDoctor!.id, _currentDoctor!.fullname);

        // End online session
        await _historyService.endAllActiveSessions(
          doctorId: _currentDoctor!.id,
        );

        _sessionSubscription?.cancel();
        _sessionSubscription = null;

        await SingleDeviceSessionService.releaseSession(
          collectionName: 'telemedicine_doctors',
          documentId: _currentDoctor!.id,
        );
        _currentSessionId = null;

        try {
          await _firestore
              .collection('telemedicine_doctors')
              .doc(_currentDoctor!.id)
              .update({
                'isOnline': false,
                'isAvailable': false,
                'manualAvailability': false,
                'effectiveStatus': 'OFFLINE',
                'fcmToken': null,
                'lastSeen': FieldValue.serverTimestamp(),
              });
          print('✅ Doctor presence and fcmToken updated to offline');
        } catch (e) {
          print('Error updating presence during logout: $e');
        }
      }

      stopPresenceTracking();
      _stopConnectivityListener();
      _stopDoctorListRefreshTimer();
      _doctorListFirestoreSub?.cancel();
      _doctorListFirestoreSub = null;
      _doctorListStreamController?.close();
      _doctorListStreamController = null;
      _lastRawFirestoreSnapshot = null;
      _doctorListListenerCount = 0;
      print('✅ Presence tracking stopped');

      _currentDoctor = null;
      _sharedAccountId = null;
      _errorMessage = null;
      _doctorsStatusCache.clear();
      _isOnline = false; // Set online status to false

      await _clearDoctorFromLocalStorage();
      print('✅ Local storage cleared');

      _presenceTimer?.cancel();
      _presenceTimer = null;

      notifyListeners();
      print('✅ Doctor signed out successfully');
    } catch (e) {
      print('Error during sign out: $e');
      _currentDoctor = null;
      _sharedAccountId = null;
      _errorMessage = null;
      _doctorsStatusCache.clear();
      _isOnline = false; // Set online status to false even on error
      await _clearDoctorFromLocalStorage();
      _presenceTimer?.cancel();
      _presenceTimer = null;
      notifyListeners();
    }
  }

  // Local storage methods
  Future<void> _saveDoctorToLocalStorage(UserModel doctor) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('current_user');
    await prefs.setString('current_doctor', json.encode(doctor.toMap()));
    // Login (and every session refresh): validate the local chat cache for
    // this account and fetch it if it was never confirmed. A no-op when the
    // cache is already complete.
    unawaited(ChatController().recoverChatListIfNeeded());
    unawaited(
      TimezoneService.syncUserTimezone(
        collectionName: 'telemedicine_doctors',
        documentId: doctor.id,
      ),
    );
  }

  Future<void> _clearDoctorFromLocalStorage() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('current_doctor');
  }

  Future<void> loadDoctorFromLocalStorage() async {
    Map<String, dynamic>? doctorMap;
    try {
      final prefs = await SharedPreferences.getInstance();
      final doctorJson = prefs.getString('current_doctor');

      print('Loading doctor from storage: $doctorJson');

      if (doctorJson != null && doctorJson.isNotEmpty) {
        doctorMap = json.decode(doctorJson) as Map<String, dynamic>;

        // Validate doctor has ID
        if (doctorMap['id'] == null || doctorMap['id'].toString().isEmpty) {
          print('❌ Invalid doctor data: missing ID');
          await _clearDoctorFromLocalStorage();
          _currentDoctor = null;
          notifyListeners();
          return;
        }

        // Verify doctor still exists in Firestore (optional but recommended).
        // Bounded + offline-tolerant: a dropped connection must never log the
        // doctor out or freeze the splash screen.
        DocumentSnapshot<Map<String, dynamic>> doctorDoc;
        try {
          doctorDoc = await _firestore
              .collection('telemedicine_doctors')
              .doc(doctorMap['id'])
              .get()
              .timeout(const Duration(seconds: 8));
        } catch (e) {
          print('⚠️ Doctor session refresh unavailable, using cache: $e');
          _currentDoctor = UserModel.fromMap(doctorMap);
          final cachedOnline =
              doctorMap['isOnline'] == true ||
              doctorMap['isAvailable'] == true ||
              doctorMap['manualAvailability'] == true;
          _manualAvailability = cachedOnline;
          _isOnline = cachedOnline;
          if (_manualAvailability) {
            startPresenceTracking();
            _setupConnectivityListener();
          }
          notifyListeners();
          return;
        }

        if (!doctorDoc.exists) {
          print('❌ Doctor no longer exists in database');
          await _clearDoctorFromLocalStorage();
          _currentDoctor = null;
          notifyListeners();
          return;
        }

        // Get manual availability preference from Firestore
        final firestoreData = doctorDoc.data();
        final manualAvailability =
            firestoreData?['manualAvailability'] as bool? ??
            firestoreData?['isOnline'] as bool? ??
            firestoreData?['isAvailable'] as bool? ??
            false;
        _manualAvailability = manualAvailability;
        _isOnline = manualAvailability;

        _currentDoctor = UserModel.fromMap(doctorMap);

        // Restore presence tracking if doctor previously enabled manual availability.
        if (_currentDoctor?.doctorId != null &&
            _currentDoctor!.doctorId!.isNotEmpty &&
            _manualAvailability) {
          startPresenceTracking();
          _setupConnectivityListener();
        }

        print('✅ Doctor loaded from storage: ${_currentDoctor?.fullname}');
        print('✅ Online status: $_isOnline');
        if (_currentDoctor != null && _currentDoctor!.id.isNotEmpty) {
          _listenToDoctorSession(_currentDoctor!.id);
        }
        notifyListeners();
      } else {
        _currentDoctor = null;
        notifyListeners();
      }
    } catch (e) {
      // A transient failure while refreshing the session must never sign the
      // doctor out — fall back to the cached session.
      print('Error loading doctor: $e');
      if (doctorMap != null &&
          doctorMap['id'] != null &&
          doctorMap['id'].toString().isNotEmpty) {
        try {
          _currentDoctor = UserModel.fromMap(doctorMap);
        } catch (_) {
          _currentDoctor = null;
        }
      } else {
        _currentDoctor = null;
      }
      notifyListeners();
    }
  }

  // ───────────────────────────────────────────────────────────────────────
  // Soft delete / restore
  //
  // OPD Telemedicine never hard-deletes a doctor. The document, the profile
  // and every historical record stay in Firestore; only the lifecycle flags
  // change. See `SoftDeleteService` for the full contract.
  // ───────────────────────────────────────────────────────────────────────

  /// Deactivates a doctor and removes them from all active patient-facing
  /// listings.
  ///
  /// The old implementation called `.delete()` on the doctor document and then
  /// cascaded through `doctor_online_sessions`, `doctor_daily_stats` and
  /// `doctor_chats` — destroying the record and its history. It is retained
  /// under the old name only so existing call sites keep compiling, and it now
  /// delegates to the soft-delete path.
  Future<bool> deleteDoctorProfile(
    String doctorId, {
    String? performedBy,
    String reason = 'Deleted by administrator',
  }) {
    return SoftDeleteService.softDeleteDoctor(
      doctorId: doctorId,
      performedBy: performedBy ?? 'admin',
      reason: reason,
    );
  }

  /// Restores a soft-deleted doctor **in place** — the same document id and
  /// history are reused, so no duplicate doctor record is created.
  Future<bool> restoreDoctorProfile(String doctorId, {String? performedBy}) {
    return SoftDeleteService.restoreDoctor(
      doctorId: doctorId,
      performedBy: performedBy ?? 'admin',
    );
  }

  void _setLoading(bool loading) {
    _isLoading = loading;
    notifyListeners();
  }

  void _clearError() {
    _errorMessage = null;
  }
}

final doctorControllerProvider = ChangeNotifierProvider(
  (ref) => DoctorController(),
);
