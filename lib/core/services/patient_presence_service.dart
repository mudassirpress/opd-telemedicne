import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:telemedicine/core/services/session_service.dart';

/// Tracks a patient's online presence (heartbeat + connectivity listener)
/// and writes status to Firestore.
///
/// The service does **not** own the `isPatientOnline` boolean or the current
/// user – it communicates with the owning [PatientController] through the
/// supplied [PatientPresenceDelegate] so that state remains in a single place.
class PatientPresenceService {
  PatientPresenceService({
    required this.delegate,
  });

  final PatientPresenceDelegate delegate;

  Timer? _presenceTimer;
  StreamSubscription<ConnectivityResult>? _connectivitySub;
  bool _connectivityListenerSetup = false;

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // ── Public API ────────────────────────────────────────────────────────

  /// Initialize presence: mark online, start heartbeat, listen for
  /// connectivity changes.
  Future<void> initializePatientPresence() async {
    if (delegate.currentUserId == null || delegate.currentUserRole != 'patient') {
      return;
    }

    await updatePatientOnlineStatus(true);
    startPresenceTracking();
    setupConnectivityListener();
  }

  /// Mark the patient as online/offline in Firestore and update local state.
  Future<void> updatePatientOnlineStatus(bool isOnline) async {
    final userId = delegate.currentUserId;
    if (userId == null || userId.isEmpty) return;

    try {
      delegate.setIsPatientOnline(isOnline);
      final updateData = <String, dynamic>{
        'isOnline': isOnline,
        'lastSeen': isOnline ? null : FieldValue.serverTimestamp(),
      };
      if (isOnline) {
        updateData['lastHeartbeat'] = FieldValue.serverTimestamp();
      }
      await _firestore
          .collection('telemedicine_patient')
          .doc(userId)
          .update(updateData);
      delegate.onPresenceStateChanged();
    } catch (e) {
      print('Error updating patient online status: $e');
    }
  }

  /// Start the periodic heartbeat timer (every 15 s).
  void startPresenceTracking() {
    _presenceTimer?.cancel();

    _presenceTimer = Timer.periodic(const Duration(seconds: 15), (timer) async {
      final userId = delegate.currentUserId;
      if (userId != null && delegate.isPatientOnline) {
        try {
          await _firestore
              .collection('telemedicine_patient')
              .doc(userId)
              .update({
                'lastSeen': FieldValue.serverTimestamp(),
                'lastHeartbeat': FieldValue.serverTimestamp(),
              });
              
          final sessionId = delegate.currentSessionId;
          if (sessionId != null) {
            await SessionService.heartbeatSession(sessionId);
          }
        } catch (e) {
          print('Patient heartbeat error: $e');
          if (delegate.isPatientOnline) {
            delegate.setIsPatientOnline(false);
            delegate.onPresenceStateChanged();
          }
        }
      }
    });
  }

  /// Stop the heartbeat timer.
  void stopPresenceTracking() {
    _presenceTimer?.cancel();
    _presenceTimer = null;
  }

  /// Stream the real-time online status for a given [patientId].
  Stream<bool> getPatientOnlineStatus(String patientId) {
    return _firestore
        .collection('telemedicine_patient')
        .doc(patientId)
        .snapshots()
        .map((doc) {
          if (doc.exists) {
            return doc.data()?['isOnline'] == true;
          }
          return false;
        });
  }

  /// Stream a *derived* online status that also considers heartbeat recency.
  Stream<bool> getPatientOnlineStatusStream(String patientId) {
    return _firestore
        .collection('telemedicine_patient')
        .doc(patientId)
        .snapshots()
        .map((doc) {
          if (!doc.exists) return false;
          final data = doc.data();
          final isOnline = data?['isOnline'] ?? false;
          final lastHeartbeat = data?['lastHeartbeat'] as Timestamp?;
          final lastSeen = data?['lastSeen'] as Timestamp?;

          if (!isOnline) return false;

          final reference = lastHeartbeat ?? lastSeen;
          if (reference == null) return false;

          final diff = DateTime.now().difference(reference.toDate());
          return diff.inSeconds < 45;
        });
  }

  /// Tear down – stop heartbeat + connectivity listener.
  void dispose() {
    stopPresenceTracking();
    stopConnectivityListener();
  }

  // ── Private helpers ──────────────────────────────────────────────────

  /// Listen for connectivity changes – immediately mark offline on disconnect.
  void setupConnectivityListener() {
    if (_connectivityListenerSetup) return;
    _connectivityListenerSetup = true;

    _connectivitySub = Connectivity().onConnectivityChanged.listen((result) {
      if (delegate.currentUserId == null ||
          delegate.currentUserRole != 'patient') {
        return;
      }

      if (result == ConnectivityResult.none) {
        updatePatientOnlineStatus(false);
      } else {
        if (!delegate.isPatientOnline) {
          updatePatientOnlineStatus(true);
          startPresenceTracking();
        }
      }
    });
  }

  /// Stop the connectivity listener.
  void stopConnectivityListener() {
    _connectivitySub?.cancel();
    _connectivitySub = null;
    _connectivityListenerSetup = false;
  }
}

/// Interface that the owning controller must implement so the service can
/// read / write the minimum state it needs without holding a direct
/// reference to the controller class.
abstract class PatientPresenceDelegate {
  String? get currentUserId;
  String? get currentSessionId;
  String? get currentUserRole;
  bool get isPatientOnline;
  void setIsPatientOnline(bool value);
  void onPresenceStateChanged();
}
