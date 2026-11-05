import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/core/utils/firestore_time.dart';

/// Holds a doctor's presence and reachability data across the application.
class DoctorPresenceData {
  /// True ONLY when:
  ///  1. manualAvailability == true (doctor manually turned ON)
  ///  2. Account is approved, active, not suspended, and not deleted
  ///  3. Doctor is not currently busy on another active call
  ///
  /// Heartbeat freshness is exposed separately as [isAppConnected]; it never
  /// changes [isOnline], because the heartbeat stops when the app is
  /// backgrounded or terminated.
  /// True when active heartbeat lease is fresh and account is eligible.
  final bool isOnline;

  /// True when isOnline is true and doctor is not busy on another call.
  final bool isAvailable;

  /// Effective status: 'ONLINE' | 'OFFLINE' | 'BUSY' | 'UNREACHABLE'
  final String effectiveStatus;

  /// Doctor's availability flag
  final bool manualAvailability;

  /// Last seen timestamp
  final DateTime? lastSeen;

  /// Last verified heartbeat received by backend
  final DateTime? lastHeartbeat;

  /// When this doctor transitioned offline -> online this session
  final DateTime? onlineSince;

  /// When real internet reachability was verified
  final DateTime? lastVerifiedInternet;

  /// When the doctor's device last successfully acknowledged an incoming call probe
  final DateTime? lastCallAckAt;

  /// Doctor's administrative account status ('Active', 'Suspended', etc.)
  final String accountStatus;

  /// Whether the doctor satisfies administrative eligibility requirements
  final bool isEligible;

  /// Internal connection/heartbeat state
  final bool isAppConnected;

  const DoctorPresenceData({
    required this.isOnline,
    this.isAvailable = false,
    this.effectiveStatus = 'OFFLINE',
    this.manualAvailability = false,
    this.isAppConnected = true,
    this.lastSeen,
    this.lastHeartbeat,
    this.onlineSince,
    this.lastVerifiedInternet,
    this.lastCallAckAt,
    this.accountStatus = 'Active',
    this.isEligible = true,
  });

  static const empty = DoctorPresenceData(
    isOnline: false,
    isAvailable: false,
    effectiveStatus: 'OFFLINE',
    manualAvailability: false,
    isAppConnected: false,
  );
}

/// Centralized doctor online/offline presence service.
///
/// Single source of truth for doctor status across the entire app.
/// Doctor List, Chat List, Chat Screen, and Calling flows MUST all use this service.
///
/// Online criteria (all must be true):
///   1. `manualAvailability == true`
///   2. `isActive == true`, `isDeleted != true`, `isSuspended != true`
///   3. `accountStatus == 'Active'` (or legacy null)
///   4. Not currently attending another active call
///
/// Heartbeat freshness does NOT decide online status. The heartbeat timer runs
/// only while the app is in the foreground, so it is exposed separately as
/// [DoctorPresenceData.isAppConnected] and must never end a manual shift.
class DoctorPresence extends StateNotifier<Map<String, DoctorPresenceData>> {
  DoctorPresence() : super({}) {
    _init();
  }

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  StreamSubscription<QuerySnapshot>? _firestoreSub;
  Timer? _refreshTimer;
  QuerySnapshot? _lastSnapshot;

  /// Heartbeat timeout in seconds (TTL window).
  static const int heartbeatTimeoutSeconds = 60;

  /// Timer interval for re-evaluating online status against current wall-clock.
  static const Duration refreshInterval = Duration(seconds: 15);

  void _init() {
    _firestoreSub = _firestore
        .collection('telemedicine_doctors')
        .where('isActive', isEqualTo: true)
        .snapshots()
        .listen(
          (snapshot) {
            _lastSnapshot = snapshot;
            _evaluate(snapshot);
          },
          onError: (error) {
            // Log Firestore stream error gracefully
          },
        );

    _refreshTimer = Timer.periodic(refreshInterval, (_) {
      if (_lastSnapshot != null) {
        _evaluate(_lastSnapshot!);
      }
    });
  }

  /// Evaluate online status for all doctors using current wall-clock time.
  void _evaluate(QuerySnapshot snapshot) {
    final now = DateTime.now();
    final newStatus = <String, DoctorPresenceData>{};

    for (final doc in snapshot.docs) {
      final data = doc.data() as Map<String, dynamic>?;
      if (data == null) continue;

      // Extract raw fields
      final manualAvailability =
          data['manualAvailability'] as bool? ??
          data['isOnline'] as bool? ??
          false;
      final isDeleted = data['isDeleted'] as bool? ?? false;
      final isSuspended = data['isSuspended'] as bool? ?? false;
      final accountStatus = (data['accountStatus'] ?? 'Active').toString();
      final isEligible =
          !isDeleted && !isSuspended && accountStatus == 'Active';

      final lastHeartbeatTs =
          (data['lastHeartbeat'] ?? data['lastHeartbeatAt']) as Timestamp?;
      final lastSeenTs = data['lastSeen'] as Timestamp?;
      final onlineSinceTs = data['onlineSince'] as Timestamp?;
      final lastVerifiedTs = data['lastVerifiedInternetAt'] as Timestamp?;
      final lastCallAckTs = data['lastCallAckAt'] as Timestamp?;
      final activeCallId = data['activeCallId'] ?? data['currentCallId'];

      // Evaluate Heartbeat Freshness (active lease within TTL 60s)
      bool heartbeatFresh = false;
      final reference = lastHeartbeatTs ?? lastSeenTs;
      if (reference != null) {
        final diff = now.difference(reference.toDate());
        heartbeatFresh =
            diff.inSeconds >= 0 && diff.inSeconds < heartbeatTimeoutSeconds;
      } else {
        heartbeatFresh = data['isOnline'] == true;
      }

      // Compute Effective Status:
      // isOnline: doctor's manual preference && account eligibility
      // isAvailable: isOnline && !isBusy
      // isAppConnected: active foreground heartbeat lease
      final isBusy = activeCallId != null && activeCallId.toString().isNotEmpty;
      final isOnline = manualAvailability && isEligible;
      final isAvailable = isOnline && !isBusy;

      String effectiveStatus = 'OFFLINE';
      if (!isEligible || !isOnline) {
        effectiveStatus = 'OFFLINE';
      } else if (isBusy) {
        effectiveStatus = 'BUSY';
      } else {
        effectiveStatus = 'ONLINE';
      }

      newStatus[doc.id] = DoctorPresenceData(
        isOnline: isOnline,
        isAvailable: isAvailable,
        effectiveStatus: effectiveStatus,
        manualAvailability: manualAvailability,
        isAppConnected: heartbeatFresh,
        lastSeen: lastSeenTs?.toDate(),
        lastHeartbeat: lastHeartbeatTs?.toDate(),
        onlineSince: onlineSinceTs?.toDate(),
        lastVerifiedInternet: lastVerifiedTs?.toDate(),
        lastCallAckAt: lastCallAckTs?.toDate(),
        accountStatus: accountStatus,
        isEligible: isEligible,
      );
    }

    // Only update state if values actually changed
    bool changed = newStatus.length != state.length;
    if (!changed) {
      for (final entry in newStatus.entries) {
        final existing = state[entry.key];
        if (existing == null ||
            existing.isOnline != entry.value.isOnline ||
            existing.isAvailable != entry.value.isAvailable ||
            existing.effectiveStatus != entry.value.effectiveStatus ||
            existing.manualAvailability != entry.value.manualAvailability ||
            existing.lastSeen != entry.value.lastSeen ||
            existing.lastHeartbeat != entry.value.lastHeartbeat ||
            existing.onlineSince != entry.value.onlineSince) {
          changed = true;
          break;
        }
      }
    }

    if (changed) {
      state = newStatus;
    }
  }

  /// Check if a specific doctor is online (heartbeat active within TTL).
  bool isDoctorOnline(String doctorId) {
    return state[doctorId]?.isOnline ?? false;
  }

  /// Check if a specific doctor is available (online and not busy on another call).
  bool isDoctorAvailable(String doctorId) {
    return state[doctorId]?.isAvailable ?? false;
  }

  /// Get rich presence data for a doctor.
  DoctorPresenceData? getDoctorPresence(String doctorId) {
    return state[doctorId];
  }

  /// Get the lastSeen timestamp for a specific doctor.
  DateTime? getLastSeen(String doctorId) {
    return state[doctorId]?.lastSeen;
  }

  @override
  void dispose() {
    _firestoreSub?.cancel();
    _refreshTimer?.cancel();
    super.dispose();
  }
}

/// Riverpod provider for the centralized doctor presence service.
final doctorPresenceProvider =
    StateNotifierProvider<DoctorPresence, Map<String, DoctorPresenceData>>((
      ref,
    ) {
      return DoctorPresence();
    });

/// Convenience provider to check a specific doctor's online status.
/// Usage: final isOnline = ref.watch(doctorOnlineProvider('doctorId'));
final doctorOnlineProvider = Provider.family<bool, String>((ref, doctorId) {
  final presenceMap = ref.watch(doctorPresenceProvider);
  return presenceMap[doctorId]?.isOnline ?? false;
});

/// Convenience provider to access a doctor's full presence data.
/// Usage: final presenceData = ref.watch(doctorPresenceDataProvider('doctorId'));
final doctorPresenceDataProvider = Provider.family<DoctorPresenceData?, String>(
  (ref, doctorId) {
    final presenceMap = ref.watch(doctorPresenceProvider);
    return presenceMap[doctorId];
  },
);

/// Convenience provider to get a doctor's last seen timestamp.
/// Usage: final lastSeen = ref.watch(doctorLastSeenProvider('doctorId'));
final doctorLastSeenProvider = Provider.family<DateTime?, String>((
  ref,
  doctorId,
) {
  final presenceMap = ref.watch(doctorPresenceProvider);
  return presenceMap[doctorId]?.lastSeen;
});

/// Convenience provider for when a doctor came online this session.
/// Usage: final onlineSince = ref.watch(doctorOnlineSinceProvider('doctorId'));
final doctorOnlineSinceProvider = Provider.family<DateTime?, String>((
  ref,
  doctorId,
) {
  final presenceMap = ref.watch(doctorPresenceProvider);
  return presenceMap[doctorId]?.onlineSince;
});

/// Normalises a Firestore date field to a [DateTime].
DateTime? asDateTime(Object? value) => parseFirestoreTimestamp(value);

/// Builds a presence lookup from doctor maps that already carry the evaluated
/// `isOnline` / `onlineSince` fields — i.e. the maps produced by
/// `DoctorController.streamAllDoctors()`.
Map<String, DoctorPresenceData> presenceFromDoctorList(
  Iterable<Map<String, dynamic>> doctors,
) {
  final result = <String, DoctorPresenceData>{};
  for (final doctor in doctors) {
    final id = (doctor['id'] ?? '').toString();
    if (id.isEmpty) continue;
    final isOnline = doctor['isOnline'] == true;
    result[id] = DoctorPresenceData(
      isOnline: isOnline,
      effectiveStatus: isOnline ? 'ONLINE' : 'OFFLINE',
      manualAvailability: doctor['manualAvailability'] == true || isOnline,
      lastSeen: asDateTime(doctor['lastSeen']),
      lastHeartbeat: asDateTime(doctor['lastHeartbeat']),
      onlineSince: asDateTime(doctor['onlineSince']),
    );
  }
  return result;
}

/// Presence lookup for a doctor list, with the centralized service as the authority.
Map<String, DoctorPresenceData> presenceForDoctorList(
  Iterable<Map<String, dynamic>> doctors,
  Map<String, DoctorPresenceData> centralized,
) {
  final fromList = presenceFromDoctorList(doctors);
  if (centralized.isEmpty) return fromList;
  return {...fromList, ...centralized};
}

/// Orders doctors for display: online first, then offline.
/// Online doctors are sorted by the time they became online, most recently online first.
List<T> sortDoctorsByPresence<T>(
  List<T> doctors,
  Map<String, DoctorPresenceData> presence,
  String Function(T) idOf,
) {
  final originalIndex = <T, int>{};
  for (var i = 0; i < doctors.length; i++) {
    originalIndex[doctors[i]] = i;
  }

  final online = <T>[];
  final offline = <T>[];

  for (final doctor in doctors) {
    final data = presence[idOf(doctor)];
    if (data != null && data.isOnline) {
      online.add(doctor);
    } else {
      offline.add(doctor);
    }
  }

  online.sort((a, b) {
    final aSince = presence[idOf(a)]?.onlineSince;
    final bSince = presence[idOf(b)]?.onlineSince;
    if (aSince == null && bSince == null) {
      return originalIndex[a]!.compareTo(originalIndex[b]!);
    }
    if (aSince == null) return 1;
    if (bSince == null) return -1;
    final byTime = bSince.compareTo(aSince); // newest first
    return byTime != 0
        ? byTime
        : originalIndex[a]!.compareTo(originalIndex[b]!);
  });

  offline.sort((a, b) => originalIndex[a]!.compareTo(originalIndex[b]!));

  return [...online, ...offline];
}
