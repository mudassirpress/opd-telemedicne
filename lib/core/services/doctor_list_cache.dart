import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/features/auth/presentation/controllers/doctor_controller.dart';
import 'package:telemedicine/data/local/offline_doctor_service.dart';

/// Doctor list served from the local Hive cache, kept current by a background
/// sync with Firestore.
///
/// Architecture — "load once, serve locally, sync in the background":
///
///   1. The constructor seeds [doctors] **synchronously** from the Hive cache.
///      An open Hive box serves reads from memory, so a consumer has a usable
///      list during its very first `build()` and never needs a spinner.
///   2. [attach] subscribes once to the app-wide shared doctor stream. That
///      stream is a broadcast singleton owned by `DoctorController`, so
///      attaching here adds **no** extra Firestore listener — it reuses the
///      one the patient doctor list and the admin portal already use.
///   3. Every emission replaces the in-memory list (so the UI updates live) and
///      rewrites the Hive box — but only when the doctor set actually changed
///      (see `OfflineDoctorService.isEquivalent`), so the stream's 15-second
///      online-status re-emission does not cause disk churn.
///
/// The Firestore stream is a *push* source, so new doctors, profile edits and
/// soft-deletes are all handled by the same path: the next emission simply
/// contains the new set, and the rewritten snapshot replaces the old one. There
/// is no separate add/update/delete bookkeeping to keep consistent.
///
/// Staleness note: the cached `isOnline` flag is a snapshot of when the list was
/// last written, so a doctor can briefly show a stale online dot on a cold
/// start. That is the deliberate trade for instant paint; the background sync
/// corrects it with no user interaction.
///
/// Never calls `DoctorController.disposeDoctorListStream()`. This subscription
/// is deliberately held for the whole process lifetime, so releasing the shared
/// stream when a screen detaches would break every other consumer of it.
class DoctorListCache extends ChangeNotifier {
  /// Seeds from the local cache. Synchronous, so a consumer that reads this in
  /// `build()` has data on the very first frame.
  DoctorListCache() {
    final cached = OfflineDoctorService.instance.readDoctors();
    if (cached.isEmpty) return;
    _doctors = cached;
    _hasLocalData = true;
  }

  /// The doctors to render. Never null. Populated from disk first, then
  /// replaced by live Firestore data as it arrives.
  List<Map<String, dynamic>> _doctors = const <Map<String, dynamic>>[];

  /// True once the local cache has been read. False means "genuinely first
  /// launch" — the only case where a consumer may need to show a loader.
  bool _hasLocalData = false;

  /// True once a live Firestore emission has arrived.
  bool _hasSynced = false;

  /// True while the first background sync is outstanding.
  ///
  /// Diagnostic only — it never gates rendering. Cached data is shown whether
  /// or not a sync is in flight, which is the whole point of the cache.
  bool _isSyncing = false;

  String _lastError = '';

  StreamSubscription<List<Map<String, dynamic>>>? _subscription;

  List<Map<String, dynamic>> get doctors => _doctors;

  /// Whether locally cached data is available to render immediately.
  bool get hasLocalData => _hasLocalData;

  bool get hasSynced => _hasSynced;

  bool get isSyncing => _isSyncing;

  String get lastError => _lastError;

  /// Subscribes to the shared doctor stream. Idempotent, so repeated reads of
  /// the provider cannot produce a second Firestore subscription.
  void attach(Stream<List<Map<String, dynamic>>> doctorsStream) {
    if (_subscription != null) return;

    // A first launch with nothing on disk has to wait for the network, so flag
    // the sync. A warm launch already has data to render and does not.
    _isSyncing = !_hasLocalData;

    _subscription = doctorsStream.listen(
      (doctors) {
        _isSyncing = false;
        _lastError = '';
        _hasSynced = true;

        // A first emission with the same doctors (the 15s refresh re-emits) must
        // still refresh in memory so the online dots stay live, but must not
        // rewrite the box.
        final changed =
            _doctors.isEmpty ||
            !OfflineDoctorService.isEquivalent(_doctors, doctors);

        _doctors = doctors;
        // A live emission is authoritative, so the cache now has data even if
        // this was the first launch — every later open is instant.
        _hasLocalData = true;

        if (changed) {
          unawaited(OfflineDoctorService.instance.saveDoctors(doctors));
        }
        notifyListeners();
      },
      onError: (Object error) {
        _isSyncing = false;
        _lastError = error.toString();
        // Keep whatever list is already on screen. A sync failure must not
        // blank a list the user can already see and act on.
        notifyListeners();
      },
    );
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _subscription = null;
    super.dispose();
  }
}

/// App-scoped doctor cache.
///
/// Deliberately **not** `autoDispose`: the provider is read once at app start
/// and must outlive every screen, otherwise closing `ShareReportScreen` would
/// drop the single background subscription and the next open would re-fetch.
final doctorListCacheProvider = ChangeNotifierProvider<DoctorListCache>((ref) {
  final cache = DoctorListCache();
  // `streamAllDoctors()` returns the shared broadcast singleton, so this
  // reuses the existing Firestore listener instead of opening a second one.
  cache.attach(ref.read(doctorControllerProvider).streamAllDoctors());
  return cache;
});
