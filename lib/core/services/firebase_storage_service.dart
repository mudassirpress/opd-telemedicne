import 'dart:io';
import 'dart:typed_data';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Upload result carrying both the direct download URL and the storage path.
class StorageUploadResult {
  final String downloadUrl;
  final String storagePath;
  final int sizeBytes;

  const StorageUploadResult({
    required this.downloadUrl,
    required this.storagePath,
    required this.sizeBytes,
  });

  @override
  String toString() => 'StorageUploadResult($storagePath, size: $sizeBytes)';
}

/// Centralized, production-grade service for all file uploads, downloads,
/// and metadata operations using Firebase Storage.
class FirebaseStorageService {
  FirebaseStorageService._();
  static final FirebaseStorageService instance = FirebaseStorageService._();

  FirebaseStorage get _storage => FirebaseStorage.instance;

  /// Determines if a URL points to Firebase Storage.
  static bool isFirebaseStorageUrl(String? url) {
    if (url == null || url.trim().isEmpty) return false;
    final lower = url.toLowerCase();
    return lower.contains('firebasestorage.googleapis.com') ||
        lower.contains('firebasestorage.app') ||
        lower.contains('storage.googleapis.com');
  }

  /// Determines if a URL points to Cloudinary.
  static bool isCloudinaryUrl(String? url) {
    if (url == null || url.trim().isEmpty) return false;
    final lower = url.toLowerCase();
    return lower.contains('cloudinary.com') || lower.contains('res.cloudinary');
  }

  /// Resolves the appropriate MIME content-type from file extension.
  static String resolveContentType(String filePath) {
    final ext = p.extension(filePath).toLowerCase();
    switch (ext) {
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      case '.png':
        return 'image/png';
      case '.webp':
        return 'image/webp';
      case '.gif':
        return 'image/gif';
      case '.pdf':
        return 'application/pdf';
      case '.m4a':
      case '.aac':
        return 'audio/mp4';
      case '.mp3':
        return 'audio/mpeg';
      case '.wav':
        return 'audio/wav';
      case '.mp4':
        return 'video/mp4';
      case '.mov':
        return 'video/quicktime';
      case '.doc':
        return 'application/msword';
      case '.docx':
        return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      default:
        return 'application/octet-stream';
    }
  }

  /// Low-level upload from a local File.
  Future<StorageUploadResult> uploadFile({
    required String storagePath,
    required File file,
    String? contentType,
    Map<String, String>? customMetadata,
  }) async {
    final resolvedType = contentType ?? resolveContentType(file.path);
    final ref = _storage.ref().child(storagePath);

    final metadata = SettableMetadata(
      contentType: resolvedType,
      customMetadata: customMetadata,
    );

    final uploadTask = ref.putFile(file, metadata);
    final snapshot = await uploadTask;
    final downloadUrl = await snapshot.ref.getDownloadURL();

    debugPrint(
      '✅ [FirebaseStorage] Uploaded: $storagePath (${snapshot.totalBytes} bytes)',
    );

    return StorageUploadResult(
      downloadUrl: downloadUrl,
      storagePath: storagePath,
      sizeBytes: snapshot.totalBytes,
    );
  }

  /// Low-level upload from memory bytes.
  Future<StorageUploadResult> uploadData({
    required String storagePath,
    required Uint8List data,
    String? contentType,
    Map<String, String>? customMetadata,
  }) async {
    final ref = _storage.ref().child(storagePath);

    final metadata = SettableMetadata(
      contentType: contentType ?? 'application/octet-stream',
      customMetadata: customMetadata,
    );

    final uploadTask = ref.putData(data, metadata);
    final snapshot = await uploadTask;
    final downloadUrl = await snapshot.ref.getDownloadURL();

    debugPrint(
      '✅ [FirebaseStorage] Uploaded bytes: $storagePath (${data.length} bytes)',
    );

    return StorageUploadResult(
      downloadUrl: downloadUrl,
      storagePath: storagePath,
      sizeBytes: data.length,
    );
  }

  // ── Patient Profile Image ──────────────────────────────────────────────────
  Future<StorageUploadResult> uploadPatientProfileImage({
    required String patientUid,
    required File file,
  }) async {
    final ext = p.extension(file.path).isEmpty
        ? '.jpg'
        : p.extension(file.path);
    final fileName = 'profile_${DateTime.now().millisecondsSinceEpoch}$ext';
    final path = 'patients/$patientUid/profile/$fileName';
    return uploadFile(storagePath: path, file: file);
  }

  // ── Doctor Profile Image ───────────────────────────────────────────────────
  Future<StorageUploadResult> uploadDoctorProfileImage({
    required String doctorUid,
    required File file,
  }) async {
    final ext = p.extension(file.path).isEmpty
        ? '.jpg'
        : p.extension(file.path);
    final fileName = 'profile_${DateTime.now().millisecondsSinceEpoch}$ext';
    final path = 'doctors/$doctorUid/profile/$fileName';
    return uploadFile(storagePath: path, file: file);
  }

  // ── Payment Proof (Account Activation / Reactivation) ──────────────────────
  Future<StorageUploadResult> uploadPaymentProof({
    required String patientUid,
    required String paymentId,
    required File file,
  }) async {
    final ext = p.extension(file.path).isEmpty
        ? '.jpg'
        : p.extension(file.path);
    final fileName = 'proof_${DateTime.now().millisecondsSinceEpoch}$ext';
    final path = 'payment_proofs/$patientUid/$paymentId/$fileName';
    return uploadFile(storagePath: path, file: file);
  }

  // ── Appointment Payment Proof ──────────────────────────────────────────────
  Future<StorageUploadResult> uploadAppointmentPaymentProof({
    required String appointmentId,
    required File file,
  }) async {
    final ext = p.extension(file.path).isEmpty
        ? '.jpg'
        : p.extension(file.path);
    final fileName = 'proof_${DateTime.now().millisecondsSinceEpoch}$ext';
    final path = 'appointments/$appointmentId/payment_proofs/$fileName';
    return uploadFile(storagePath: path, file: file);
  }

  // ── Chat Attachments (Images, Documents, Videos) ───────────────────────────
  Future<StorageUploadResult> uploadChatAttachment({
    required String conversationId,
    required String messageId,
    required File file,
    String? originalFileName,
  }) async {
    final cleanName =
        originalFileName != null && originalFileName.trim().isNotEmpty
        ? p.basename(originalFileName)
        : p.basename(file.path);
    final path = 'chat_attachments/$conversationId/${messageId}_$cleanName';
    return uploadFile(storagePath: path, file: file);
  }

  // ── Chat Voice Audio ───────────────────────────────────────────────────────
  Future<StorageUploadResult> uploadChatVoice({
    required String conversationId,
    required String messageId,
    required File file,
  }) async {
    final path = 'chat_voice/$conversationId/$messageId.m4a';
    return uploadFile(storagePath: path, file: file, contentType: 'audio/mp4');
  }

  // ── Medical / Lab Reports ──────────────────────────────────────────────────
  Future<StorageUploadResult> uploadMedicalReport({
    required String userId,
    required File file,
    String? originalFileName,
  }) async {
    final cleanName =
        originalFileName != null && originalFileName.trim().isNotEmpty
        ? p.basename(originalFileName)
        : p.basename(file.path);
    final path =
        'reports/$userId/${DateTime.now().millisecondsSinceEpoch}_$cleanName';
    return uploadFile(storagePath: path, file: file);
  }

  // ── Admin Uploads ──────────────────────────────────────────────────────────
  Future<StorageUploadResult> uploadAdminFile({
    required String adminUid,
    required File file,
    String? originalFileName,
  }) async {
    final cleanName =
        originalFileName != null && originalFileName.trim().isNotEmpty
        ? p.basename(originalFileName)
        : p.basename(file.path);
    final path =
        'admin_uploads/$adminUid/${DateTime.now().millisecondsSinceEpoch}_$cleanName';
    return uploadFile(storagePath: path, file: file);
  }

  // ── Safe Deletion ──────────────────────────────────────────────────────────
  Future<bool> deleteByUrl(String downloadUrl) async {
    try {
      final ref = _storage.refFromURL(downloadUrl);
      await ref.delete();
      debugPrint('🗑️ [FirebaseStorage] Deleted: $downloadUrl');
      return true;
    } catch (e) {
      debugPrint('⚠️ [FirebaseStorage] Delete error: $e');
      return false;
    }
  }

  Future<bool> deleteByPath(String storagePath) async {
    try {
      final ref = _storage.ref().child(storagePath);
      await ref.delete();
      debugPrint('🗑️ [FirebaseStorage] Deleted: $storagePath');
      return true;
    } catch (e) {
      debugPrint('⚠️ [FirebaseStorage] Delete error: $e');
      return false;
    }
  }
}
