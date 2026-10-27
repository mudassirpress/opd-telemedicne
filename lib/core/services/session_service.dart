import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:uuid/uuid.dart';
import 'package:telemedicine/core/services/device_service.dart';

class SessionService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static const String _collection = 'active_sessions';
  
  /// Create a new session for a user and return the sessionId
  static Future<String> createSession({
    required String userId,
    required String role,
  }) async {
    final sessionId = const Uuid().v4();
    final deviceId = await DeviceService.getDeviceId();
    
    // Determine platform
    String platform = 'Unknown';
    if (Platform.isAndroid) platform = 'Android';
    if (Platform.isIOS) platform = 'iOS';
    if (Platform.isWindows) platform = 'Windows';
    if (Platform.isMacOS) platform = 'macOS';

    // Terminate any previous sessions on THIS device for this user
    final oldSessions = await _firestore
        .collection(_collection)
        .where('userId', isEqualTo: userId)
        .where('deviceId', isEqualTo: deviceId)
        .where('sessionStatus', isEqualTo: 'active')
        .get();
        
    for (var doc in oldSessions.docs) {
      await doc.reference.update({'sessionStatus': 'terminated'});
    }

    await _firestore.collection(_collection).doc(sessionId).set({
      'sessionId': sessionId,
      'deviceId': deviceId,
      'platform': platform,
      'loginAt': FieldValue.serverTimestamp(),
      'lastSeen': FieldValue.serverTimestamp(),
      'userId': userId,
      'role': role,
      'sessionStatus': 'active',
    });

    return sessionId;
  }

  /// End a specific session (or all active sessions for a user if sessionId is null)
  static Future<void> endSession({required String userId, String? sessionId}) async {
    if (sessionId != null) {
      await _firestore.collection(_collection).doc(sessionId).update({
        'sessionStatus': 'terminated',
      });
    } else {
      // Terminate all active sessions for this user
      final snapshot = await _firestore
          .collection(_collection)
          .where('userId', isEqualTo: userId)
          .where('sessionStatus', isEqualTo: 'active')
          .get();
      
      if (snapshot.docs.isEmpty) return;

      final batch = _firestore.batch();
      for (var doc in snapshot.docs) {
        batch.update(doc.reference, {'sessionStatus': 'terminated'});
      }
      await batch.commit();
    }
  }

  /// Heartbeat the session to keep it alive
  static Future<void> heartbeatSession(String sessionId) async {
    if (sessionId.isEmpty) return;
    try {
      await _firestore.collection(_collection).doc(sessionId).update({
        'lastSeen': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      print('Session heartbeat error: $e');
    }
  }

  /// Check if there is another active session for this user
  /// Returns true if there is an active session on ANOTHER device that is less than 2 minutes old.
  static Future<bool> hasActiveSessionOnOtherDevice(String userId) async {
    final currentDeviceId = await DeviceService.getDeviceId();
    
    final snapshot = await _firestore
        .collection(_collection)
        .where('userId', isEqualTo: userId)
        .where('sessionStatus', isEqualTo: 'active')
        .get();

    for (var doc in snapshot.docs) {
      final data = doc.data();
      final deviceId = data['deviceId'] ?? '';
      
      // If the active session is on THIS device, it's fine (maybe a previous login without logout).
      // We will terminate it when creating the new one.
      if (deviceId == currentDeviceId) {
        continue;
      }
      
      // If it's on a different device, check if it's stale (lastSeen > 2 mins ago)
      final lastSeen = data['lastSeen'] as Timestamp?;
      if (lastSeen != null) {
        final diff = DateTime.now().difference(lastSeen.toDate());
        if (diff.inMinutes < 2) {
          // The other device is actively using the app (or closed it < 2 mins ago)
          return true;
        } else {
          // The other device's session is stale (crashed, network loss, etc.)
          // We can terminate it to clean up.
          try {
            await doc.reference.update({'sessionStatus': 'terminated'});
          } catch(e) {
            print('Error terminating stale session: $e');
          }
        }
      }
    }
    
    return false;
  }
}
