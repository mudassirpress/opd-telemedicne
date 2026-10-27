import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/data/models/appointment_model.dart';
import 'package:telemedicine/features/appointments/presentation/appointment_controller.dart';

/// Foreground half of the appointment lifecycle.
///
/// Firestore has no notion of time: a document only changes when somebody
/// writes it. This service keeps a light clock running while the app is open
/// so that an appointment's scheduled start turns it `active` and fires the
/// one-shot alarm, and its scheduled end turns it `expired` and unpins the
/// chat message — with no screen open and no user action.
///
/// It holds the user's appointments in a live listener and evaluates that
/// in-memory list on every tick, instead of re-querying: the time boundary is
/// what moves, not the data, and only the transaction that actually claims an
/// alarm (or the write that closes an expired slot) costs a read.
///
/// The scheduled Cloud Function in `functions/index.js` is the other half and
/// covers the background and terminated case. Both go through the same guarded
/// transitions in `AppointmentController` and the same
/// `appointmentStartNotificationSent` claim, so this timer, the appointment
/// screens' own `initState` pass and the Cloud Function can all run — exactly
/// one alarm still goes out.
class AppointmentLifecycleService with WidgetsBindingObserver {
  AppointmentLifecycleService._();

  static final AppointmentLifecycleService instance =
      AppointmentLifecycleService._();

  /// How often the clock is consulted. The alarm itself fires within one tick
  /// of its scheduled start, and a slot's end is never missed for longer than
  /// this while the app is open.
  static const Duration interval = Duration(seconds: 15);

  final AppointmentController _controller = AppointmentController();

  final Map<String, AppointmentModel> _appointments = {};
  final List<StreamSubscription<QuerySnapshot<Map<String, dynamic>>>>
      _subscriptions = [];

  Timer? _timer;
  bool _watching = false;
  bool _passRunning = false;
  bool _passQueued = false;
  String _userId = '';

  /// Starts watching for the signed-in user. Safe to call more than once —
  /// only the first call does anything.
  Future<void> start() async {
    if (_watching) return;
    _watching = true;

    WidgetsBinding.instance.addObserver(this);

    // The session blob is written a moment after the splash resolves, so give
    // it a few attempts instead of silently never watching.
    var session = await _resolveSession();
    for (var attempt = 0; attempt < 6 && session.id.isEmpty; attempt++) {
      await Future<void>.delayed(const Duration(seconds: 5));
      session = await _resolveSession();
    }

    if (session.id.isEmpty) {
      debugPrint('⚠️ Appointment lifecycle not started: no signed-in user');
      _watching = false;
      WidgetsBinding.instance.removeObserver(this);
      return;
    }
    _userId = session.id;

    // One listener, on whichever side of the record this session is: an id is
    // a patient in one document and a doctor in another only for a shared
    // account, and the screens' own pass covers that rare case anyway.
    _subscribe(isDoctor: session.isDoctor);

    unawaited(_runPass());
    _timer = Timer.periodic(interval, (_) => unawaited(_runPass()));
  }

  /// Re-evaluates immediately — used when the app comes back to the
  /// foreground, which is exactly when a phone that was asleep has missed one
  /// or more boundaries.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_runPass());
  }

  void _subscribe({required bool isDoctor}) {
    try {
      final query = isDoctor
          ? FirebaseFirestore.instance
              .collection(FirestoreCollections.appointments)
              .where('doctorId', isEqualTo: _userId)
          : FirebaseFirestore.instance
              .collection(FirestoreCollections.appointments)
              .where('patientId', isEqualTo: _userId);

      _subscriptions.add(
        query.snapshots().listen(
          (snapshot) {
            for (final change in snapshot.docChanges) {
              final id = change.doc.id;
              if (change.type == DocumentChangeType.removed) {
                _appointments.remove(id);
                continue;
              }
              _appointments[id] = AppointmentModel.fromMap(
                id,
                change.doc.data() ?? const <String, dynamic>{},
              );
            }
            // A fresh document may already be past its start or its end, so
            // do not wait for the next tick to notice.
            unawaited(_runPass());
          },
          onError: (Object e) {
            debugPrint('⚠️ Appointment lifecycle listener error: $e');
          },
        ),
      );
    } catch (e) {
      debugPrint('⚠️ Appointment lifecycle listener not started: $e');
    }
  }

  /// One clock tick. Overlapping ticks are collapsed rather than queued up:
  /// the pass is idempotent, so running it twice in a row adds nothing.
  Future<void> _runPass() async {
    if (_userId.isEmpty) return;
    if (_passRunning) {
      _passQueued = true;
      return;
    }

    _passRunning = true;
    try {
      await _controller
          .evaluateAppointments(_appointments.values.toList(growable: false));
    } catch (_) {
      // Housekeeping never surfaces an error to the UI.
    } finally {
      _passRunning = false;
      if (_passQueued) {
        _passQueued = false;
        unawaited(_runPass());
      }
    }
  }

  /// The signed-in session, taken from whichever persisted blob holds it.
  ///
  /// `current_doctor` (or a `role` of `doctor`) means the session sits on the
  /// doctor side of every appointment it appears in.
  Future<({String id, bool isDoctor})> _resolveSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final key in const ['current_user', 'current_doctor']) {
        final raw = prefs.getString(key);
        if (raw == null || raw.isEmpty) continue;
        try {
          final map = jsonDecode(raw) as Map<String, dynamic>;
          final id = (map['id'] ?? '').toString().trim();
          if (id.isEmpty) continue;
          return (
            id: id,
            isDoctor: key == 'current_doctor' ||
                map['role']?.toString() == UserRoles.doctor,
          );
        } catch (_) {
          // Ignore a malformed blob and try the next one.
        }
      }
    } catch (e) {
      debugPrint('⚠️ Could not resolve the signed-in user: $e');
    }
    return (id: '', isDoctor: false);
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
    _appointments.clear();
    _watching = false;
    WidgetsBinding.instance.removeObserver(this);
  }
}
