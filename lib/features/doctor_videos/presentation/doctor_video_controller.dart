import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/core/constants/app_constants.dart';

/// One doctor introduction video assigned by an admin.
///
/// Doc id is the doctor's id, so one doctor always has exactly one record and
/// "only one active video per doctor" is structural, not a manual check.
class DoctorVideoModel {
  final String id;
  final String doctorId;
  final String youtubeUrl;
  final String youtubeVideoId;
  final bool isActive;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const DoctorVideoModel({
    required this.id,
    required this.doctorId,
    required this.youtubeUrl,
    required this.youtubeVideoId,
    required this.isActive,
    this.createdAt,
    this.updatedAt,
  });

  factory DoctorVideoModel.fromMap(String id, Map<String, dynamic> map) {
    return DoctorVideoModel(
      id: id,
      doctorId: map['doctorId'] ?? id,
      youtubeUrl: map['youtubeUrl'] ?? '',
      youtubeVideoId: map['youtubeVideoId'] ?? '',
      isActive: map['isActive'] ?? false,
      createdAt: (map['createdAt'] as Timestamp?)?.toDate(),
      updatedAt: (map['updatedAt'] as Timestamp?)?.toDate(),
    );
  }
}

/// Admin-assigned doctor videos and the patient-side watch tracking.
///
/// The existing booking discount keeps reading the doctor document's
/// `youtubeVideoUrl` / `discountPercentage`, so assigning a video also updates
/// the doctor record — one source of truth for the patient screen, while the
/// `doctor_videos` collection keeps the admin-facing record.
class DoctorVideoController {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _videos =>
      _firestore.collection(FirestoreCollections.doctorVideos);

  CollectionReference<Map<String, dynamic>> get _watches =>
      _firestore.collection(FirestoreCollections.doctorVideoWatches);

  CollectionReference<Map<String, dynamic>> get _doctors =>
      _firestore.collection(FirestoreCollections.doctors);

  static String watchIdFor({
    required String patientId,
    required String doctorId,
  }) => '${patientId}_$doctorId';

  /// Extracts the video id from the supported YouTube URL shapes.
  static String videoIdFromUrl(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return '';
    final uri = Uri.tryParse(trimmed);
    if (uri == null) return '';
    final host = uri.host.toLowerCase();
    if (host == 'youtu.be') {
      return uri.pathSegments.isEmpty ? '' : uri.pathSegments.first;
    }
    if (host.endsWith('youtube.com') || host.endsWith('youtube-nocookie.com')) {
      final fromQuery = uri.queryParameters['v'];
      if (fromQuery != null && fromQuery.isNotEmpty) return fromQuery;
      final segments = uri.pathSegments;
      if (segments.length >= 2 &&
          (segments[segments.length - 2] == 'shorts' ||
              segments[segments.length - 2] == 'embed')) {
        return segments.last;
      }
    }
    return '';
  }

  static bool isSupportedUrl(String url) => videoIdFromUrl(url).isNotEmpty;

  Stream<DoctorVideoModel?> watchDoctorVideo(String doctorId) async* {
    if (doctorId.isEmpty) {
      yield null;
      return;
    }
    try {
      await for (final doc in _videos.doc(doctorId).snapshots()) {
        yield doc.exists
            ? DoctorVideoModel.fromMap(doc.id, doc.data()!)
            : null;
      }
    } catch (_) {
      yield null;
    }
  }

  Stream<List<DoctorVideoModel>> watchAllVideos() async* {
    try {
      await for (final snap in _videos.snapshots()) {
        yield snap.docs
            .map((d) => DoctorVideoModel.fromMap(d.id, d.data()))
            .toList();
      }
    } catch (_) {
      yield const <DoctorVideoModel>[];
    }
  }

  /// Assigns or updates the doctor's video. Also mirrors onto the doctor
  /// document so the existing patient price/video flow picks it up.
  Future<String?> saveVideo({
    required String doctorId,
    required String youtubeUrl,
  }) async {
    final videoId = videoIdFromUrl(youtubeUrl);
    if (doctorId.isEmpty) return 'Please select a doctor.';
    if (videoId.isEmpty) {
      return 'Enter a valid YouTube link (watch, youtu.be, or shorts).';
    }
    try {
      final ref = _videos.doc(doctorId);
      final existing = await ref.get();
      await ref.set({
        'doctorId': doctorId,
        'youtubeUrl': youtubeUrl.trim(),
        'youtubeVideoId': videoId,
        'isActive': true,
        if (!existing.exists) 'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      await _doctors.doc(doctorId).set({
        'youtubeVideoUrl': youtubeUrl.trim(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      return null;
    } catch (e) {
      return 'Could not save the video: $e';
    }
  }

  Future<String?> removeVideo(String doctorId) async {
    if (doctorId.isEmpty) return 'Please select a doctor.';
    try {
      await _videos.doc(doctorId).set({
        'isActive': false,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      await _doctors.doc(doctorId).set({
        'youtubeVideoUrl': '',
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      return null;
    } catch (e) {
      return 'Could not remove the video: $e';
    }
  }

  /// Records that the patient watched (or is watching) the assigned video.
  ///
  /// [watchProgress] is 0..1; reaching ~0.9 counts as completed, matching the
  /// "watched enough to unlock the discount" business rule.
  Future<void> recordWatchProgress({
    required String patientId,
    required String doctorId,
    required String videoAssignmentId,
    required String youtubeVideoId,
    required double watchProgress,
  }) async {
    final completed = watchProgress >= 0.9;
    try {
      await _watches.doc(watchIdFor(patientId: patientId, doctorId: doctorId)).set({
        'patientId': patientId,
        'doctorId': doctorId,
        'videoAssignmentId': videoAssignmentId,
        'youtubeVideoId': youtubeVideoId,
        'watchProgress': watchProgress.clamp(0.0, 1.0),
        'completed': completed,
        if (completed) 'completedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (_) {
      // Tracking is best-effort; it must never block booking.
    }
  }
}

final doctorVideoControllerProvider = Provider<DoctorVideoController>((ref) {
  return DoctorVideoController();
});

final doctorVideoProvider =
    StreamProvider.autoDispose.family<DoctorVideoModel?, String>((ref, doctorId) {
  return ref.read(doctorVideoControllerProvider).watchDoctorVideo(doctorId);
});
