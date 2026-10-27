// lib/admin_portal/services/doctor_online_history_service.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:telemedicine/data/models/doctor_online_session.dart';

class DoctorOnlineHistoryService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // Start tracking a doctor's online session
  Future<void> startOnlineSession({
    required String doctorId,
    required String doctorName,
  }) async {
    try {
      // Check if there's already an active session
      final existingActiveSession = await _firestore
          .collection('doctor_online_sessions')
          .where('doctorId', isEqualTo: doctorId)
          .where('isActive', isEqualTo: true)
          .get();

      // End any existing active sessions
      for (var doc in existingActiveSession.docs) {
        await endOnlineSession(doc.id);
      }

      // Create new session
      final session = DoctorOnlineSession(
        id: _firestore.collection('doctor_online_sessions').doc().id,
        doctorId: doctorId,
        doctorName: doctorName,
        startTime: DateTime.now(),
        endTime: null,
        duration: Duration.zero,
        isActive: true,
      );

      await _firestore
          .collection('doctor_online_sessions')
          .doc(session.id)
          .set(session.toMap());

      print('✅ Started online session for doctor: $doctorName');
    } catch (e) {
      print('❌ Error starting online session: $e');
    }
  }

  // End an online session
  Future<void> endOnlineSession(String sessionId) async {
    try {
      final sessionDoc = await _firestore
          .collection('doctor_online_sessions')
          .doc(sessionId)
          .get();

      if (!sessionDoc.exists) return;

      final sessionData = sessionDoc.data()!;
      final startTime = (sessionData['startTime'] as Timestamp).toDate();
      final endTime = DateTime.now();
      final duration = endTime.difference(startTime);

      await _firestore
          .collection('doctor_online_sessions')
          .doc(sessionId)
          .update({
            'endTime': Timestamp.fromDate(endTime),
            'durationInSeconds': duration.inSeconds,
            'isActive': false,
          });

      // Update daily stats
      await _updateDailyStats(
        doctorId: sessionData['doctorId'],
        doctorName: sessionData['doctorName'],
        date: startTime,
        duration: duration,
      );

      print('✅ Ended online session. Duration: ${duration.inMinutes} minutes');
    } catch (e) {
      print('❌ Error ending online session: $e');
    }
  }

  // Update daily statistics
  Future<void> _updateDailyStats({
    required String doctorId,
    required String doctorName,
    required DateTime date,
    required Duration duration,
  }) async {
    try {
      final dailyStatsId = '${doctorId}_${date.year}_${date.month}_${date.day}';
      final dailyStatsRef = _firestore
          .collection('doctor_daily_stats')
          .doc(dailyStatsId);

      final doc = await dailyStatsRef.get();

      if (doc.exists) {
        // Update existing stats
        final existingData = doc.data()!;
        final newDuration = Duration(
          seconds: existingData['totalDurationInSeconds'] + duration.inSeconds,
        );

        await dailyStatsRef.update({
          'totalDurationInSeconds': newDuration.inSeconds,
          'sessionsCount': FieldValue.increment(1),
          'updatedAt': FieldValue.serverTimestamp(),
        });
      } else {
        // Create new stats
        final dailyStats = DoctorDailyStats(
          doctorId: doctorId,
          doctorName: doctorName,
          date: DateTime(date.year, date.month, date.day),
          totalOnlineDuration: duration,
          sessionsCount: 1,
        );

        await dailyStatsRef.set(dailyStats.toMap());
      }
    } catch (e) {
      print('❌ Error updating daily stats: $e');
    }
  }

  // Get online sessions for a doctor with date range
  Stream<List<DoctorOnlineSession>> getDoctorSessions({
    required String doctorId,
    DateTime? startDate,
    DateTime? endDate,
  }) {
    var query = _firestore
        .collection('doctor_online_sessions')
        .where('doctorId', isEqualTo: doctorId)
        .orderBy('startTime', descending: true);

    if (startDate != null) {
      query = query.where(
        'startTime',
        isGreaterThanOrEqualTo: Timestamp.fromDate(startDate),
      );
    }
    if (endDate != null) {
      query = query.where(
        'startTime',
        isLessThanOrEqualTo: Timestamp.fromDate(endDate),
      );
    }

    return query.snapshots().map((snapshot) {
      return snapshot.docs.map((doc) {
        return DoctorOnlineSession.fromMap(doc.id, doc.data());
      }).toList();
    });
  }

  Stream<List<DoctorDailyStats>> getDoctorDailyStats({
    required String doctorId,
    DateTime? startDate,
    DateTime? endDate,
  }) async* {
    try {
      CollectionReference statsRef = _firestore.collection(
        'doctor_daily_stats',
      );

      Query query = statsRef.where('doctorId', isEqualTo: doctorId);

      if (startDate != null) {
        final startOfDay = DateTime(
          startDate.year,
          startDate.month,
          startDate.day,
        );
        query = query.where(
          'date',
          isGreaterThanOrEqualTo: Timestamp.fromDate(startOfDay),
        );
      }

      if (endDate != null) {
        final endOfDay = DateTime(
          endDate.year,
          endDate.month,
          endDate.day,
          23,
          59,
          59,
        );
        query = query.where(
          'date',
          isLessThanOrEqualTo: Timestamp.fromDate(endOfDay),
        );
      }

      // Order by date descending
      query = query.orderBy('date', descending: true);

      await for (var snapshot in query.snapshots()) {
        final stats = snapshot.docs.map((doc) {
          return DoctorDailyStats.fromMap(doc.data() as Map<String, dynamic>);
        }).toList();
        yield stats;
      }
    } catch (e) {
      print('Error getting daily stats: $e');
      print('Please create the required index in Firebase Console');
      // Yield empty list on error
      yield [];
    }
  }

  // Alternative method to get stats without needing the composite index
  Future<List<DoctorDailyStats>> getDoctorDailyStatsAlternative({
    required String doctorId,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    try {
      // First, get all stats for this doctor
      final snapshot = await _firestore
          .collection('doctor_daily_stats')
          .where('doctorId', isEqualTo: doctorId)
          .get();

      // Then filter by date in memory
      List<DoctorDailyStats> stats = snapshot.docs.map((doc) {
        return DoctorDailyStats.fromMap(doc.data() as Map<String, dynamic>);
      }).toList();

      // Apply date filters
      if (startDate != null) {
        stats = stats
            .where(
              (stat) =>
                  stat.date.isAfter(startDate) ||
                  stat.date.isAtSameMomentAs(startDate),
            )
            .toList();
      }

      if (endDate != null) {
        stats = stats
            .where(
              (stat) =>
                  stat.date.isBefore(endDate) ||
                  stat.date.isAtSameMomentAs(endDate),
            )
            .toList();
      }

      // Sort by date descending
      stats.sort((a, b) => b.date.compareTo(a.date));

      return stats;
    } catch (e) {
      print('Error getting stats: $e');
      return [];
    }
  }

  /// End the active sessions of ONE doctor (going offline / signing out).
  ///
  /// [doctorId] is required on purpose: the old no-arg version queried every
  /// `isActive == true` session in the collection and ended ALL of them, so
  /// one doctor going offline silently terminated every other online doctor's
  /// session and wrote bogus durations into their daily stats.
  Future<void> endAllActiveSessions({required String doctorId}) async {
    if (doctorId.isEmpty) return;
    try {
      final activeSessions = await _firestore
          .collection('doctor_online_sessions')
          .where('doctorId', isEqualTo: doctorId)
          .where('isActive', isEqualTo: true)
          .get();

      for (var doc in activeSessions.docs) {
        await endOnlineSession(doc.id);
      }
    } catch (e) {
      print('❌ Error ending active sessions for $doctorId: $e');
    }
  }
}
