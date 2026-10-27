import 'package:flutter/foundation.dart';
import 'package:gal/gal.dart';
import 'package:http/http.dart' as http;
import 'package:telemedicine/core/utils/toast_utils.dart';

/// Saves a chat image to the device gallery.
///
/// Download first, then hand the bytes to `gal`, so a download failure never
/// opens a permission dialog and a denied permission never leaves a half-written
/// file behind.
class ChatImageDownloadService {
  ChatImageDownloadService._();

  static const Duration _downloadTimeout = Duration(seconds: 45);

  /// Downloads [imageUrl] and puts it in the gallery.
  ///
  /// Returns true only when the image is actually in the gallery. Every failure
  /// path shows a toast explaining why, so the caller only needs to refresh UI.
  static Future<bool> saveImageToGallery({
    required String imageUrl,
    required String messageId,
  }) async {
    if (imageUrl.isEmpty) {
      ToastService.instance.showError('This image has no downloadable file');
      return false;
    }

    try {
      final response = await http
          .get(Uri.parse(imageUrl))
          .timeout(_downloadTimeout);

      if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
        debugPrint(
          'IMAGE_DOWNLOAD_FAILED status=${response.statusCode} url=$imageUrl',
        );
        ToastService.instance.showError('Could not download the image');
        return false;
      }

      final granted = await _ensureAlbumAccess();
      if (!granted) return false;

      await Gal.putImageBytes(
        response.bodyBytes,
        name: _fileNameFor(imageUrl, messageId),
      );

      ToastService.instance.showSuccess('Image saved to your gallery');
      return true;
    } on GalException catch (e) {
      debugPrint('IMAGE_SAVE_FAILED ${e.type.name}');
      ToastService.instance.showError(_permissionMessage(e.type));
      return false;
    } catch (e) {
      debugPrint('IMAGE_SAVE_FAILED $e');
      ToastService.instance.showError('Could not save the image');
      return false;
    }
  }

  /// Requests (once) the access `gal` needs to write into the gallery.
  static Future<bool> _ensureAlbumAccess() async {
    try {
      if (await Gal.hasAccess()) return true;
      return await Gal.requestAccess();
    } catch (e) {
      debugPrint('GALLERY_ACCESS_CHECK_FAILED $e');
      return false;
    }
  }

  static String _permissionMessage(GalExceptionType type) {
    switch (type) {
      case GalExceptionType.accessDenied:
        return 'Allow photo access in Settings to save images';
      case GalExceptionType.notEnoughSpace:
        return 'Not enough storage space to save the image';
      case GalExceptionType.notSupportedFormat:
        return 'This file is not a supported image';
      case GalExceptionType.unexpected:
        return 'Could not save the image';
    }
  }

  /// `gal` wants a name without an extension, so the remote file name is used
  /// as-is up to its query string; `messageId` keeps it unique per bubble.
  static String _fileNameFor(String imageUrl, String messageId) {
    final segments = Uri.tryParse(imageUrl)?.pathSegments ?? const <String>[];
    final path = segments.isEmpty ? '' : segments.last;
    final base = path.contains('.')
        ? path.substring(0, path.lastIndexOf('.'))
        : path;
    final trimmed = base.trim();
    if (trimmed.isEmpty || trimmed == 'image') {
      return 'Chat_$messageId';
    }
    return trimmed;
  }
}
