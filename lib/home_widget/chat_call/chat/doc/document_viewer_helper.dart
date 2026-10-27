// document_viewer_helper.dart
import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';

class DocumentViewerHelper {
  // Check and request appropriate permissions based on Android version
  static Future<bool> requestStoragePermission() async {
    try {
      if (Platform.isAndroid) {
        final androidInfo = await _getAndroidSdkVersion();

        // For Android 13+ (API 33+)
        if (androidInfo >= 33) {
          final permissions = [
            Permission.photos,
            Permission.videos,
            Permission.audio,
          ];

          final statuses = await permissions.request();
          final allGranted = statuses.values.every(
            (status) => status.isGranted,
          );

          if (!allGranted) {
            // Show rationale if needed
            if (await Permission.photos.shouldShowRequestRationale ||
                await Permission.videos.shouldShowRequestRationale) {
              ToastService.instance.showInfo(
                'Storage permission is needed to open documents',
              );
            }
          }
          return allGranted;
        }
        // For Android 11-12 (API 30-32)
        else if (androidInfo >= 30) {
          // Try scoped storage first
          final status = await Permission.storage.request();
          if (status.isGranted) {
            return true;
          }

          // If scoped storage denied, request MANAGE_EXTERNAL_STORAGE
          if (await Permission.manageExternalStorage.isDenied) {
            await Permission.manageExternalStorage.request();
          }
          return await Permission.manageExternalStorage.isGranted;
        }
        // For Android 10 and below (API 29 and below)
        else {
          final status = await Permission.storage.request();
          return status.isGranted;
        }
      }
      return true; // iOS doesn't need storage permission for temp files
    } catch (e) {
      debugPrint('Error requesting storage permission: $e');
      return false;
    }
  }

  static Future<int> _getAndroidSdkVersion() async {
    try {
      final deviceInfo = DeviceInfoPlugin();
      final androidInfo = await deviceInfo.androidInfo;
      return androidInfo.version.sdkInt;
    } catch (e) {
      return 0;
    }
  }

  // Main method to open documents
  static Future<void> openDocument({
    required String documentUrl,
    required String fileName,
    required BuildContext context,
  }) async {
    bool dialogShown = false;
    try {
      // Request permissions first
      final hasPermission = await requestStoragePermission();
      if (!hasPermission) {
        if (context.mounted) {
          ToastService.instance.showError(
            'Storage permission is required to open documents. Please grant permission in settings.',
          );
          _showPermissionDialog(context);
        }
        return;
      }

      if (!context.mounted) return;

      // Show loading dialog
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const Center(child: CircularProgressIndicator()),
      );
      dialogShown = true;

      // Download and open document
      await _downloadAndOpenDocument(documentUrl, fileName);

      // Close loading dialog
      if (dialogShown && context.mounted) {
        Navigator.pop(context);
        dialogShown = false;
      }
    } catch (e) {
      if (dialogShown && context.mounted) {
        Navigator.pop(context); // Close loading if open
      }
      if (context.mounted) {
        ToastService.instance.showError(
          'Error opening document: ${e.toString()}',
        );
      }
      debugPrint('Error opening document: $e');
    }
  }

  static Future<void> _downloadAndOpenDocument(
    String documentUrl,
    String fileName,
  ) async {
    try {
      // Get temporary directory (doesn't require storage permission)
      final directory = await getTemporaryDirectory();
      final filePath = '${directory.path}/$fileName';

      final file = File(filePath);

      // Check if file already exists and is not corrupted
      if (await file.exists()) {
        final fileSize = await file.length();
        if (fileSize > 0) {
          // Try to open existing file
          final result = await OpenFile.open(filePath);
          if (result.type == ResultType.done) {
            return;
          }
          // If can't open, delete and re-download
          await file.delete();
        }
      }

      // Download the file via http client stream
      final client = http.Client();
      try {
        final request = http.Request('GET', Uri.parse(documentUrl));
        final response = await client.send(request);
        if (response.statusCode != 200) {
          throw Exception(
            'Download failed with status: ${response.statusCode}',
          );
        }
        final total = response.contentLength ?? -1;
        int received = 0;
        final sink = file.openWrite();
        await response.stream.listen((chunk) {
          sink.add(chunk);
          received += chunk.length;
          if (total != -1) {
            debugPrint(
              'Download progress: ${(received / total * 100).toStringAsFixed(0)}%',
            );
          }
        }).asFuture();
        await sink.flush();
        await sink.close();
      } finally {
        client.close();
      }

      // Verify file was downloaded
      if (!await file.exists()) {
        throw Exception('File download failed');
      }

      // Open the file
      final result = await OpenFile.open(filePath);

      if (result.type != ResultType.done) {
        // If OpenFile fails, try launching in browser
        final uri = Uri.parse(documentUrl);
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
          ToastService.instance.showInfo('Opening in browser');
        } else {
          throw Exception('Cannot open file with any application');
        }
      }
    } catch (e) {
      throw Exception('Failed to download/open document: $e');
    }
  }

  static void _showPermissionDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          'Storage Permission Required',
          style: TextStyle(
            fontSize: context.fs(14),
            fontWeight: FontWeight.w600,
          ),
        ),
        content: SingleChildScrollView(
          child: Text(
            'Storage permission is needed to save and open documents. '
            'Please grant permission in settings to continue.',
            style: TextStyle(fontSize: context.fs(13)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel', style: TextStyle(fontSize: context.fs(14))),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await openAppSettings();
            },
            child: Text(
              'Open Settings',
              style: TextStyle(fontSize: context.fs(14)),
            ),
          ),
        ],
      ),
    );
  }

  // Alternative: Use file picker to save and open
  static Future<void> saveAndOpenDocument({
    required String documentUrl,
    required String fileName,
    required BuildContext context,
  }) async {
    bool dialogShown = false;
    try {
      final hasPermission = await requestStoragePermission();
      if (!hasPermission) {
        if (context.mounted) {
          ToastService.instance.showError('Storage permission required');
        }
        return;
      }

      if (!context.mounted) return;

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const Center(child: CircularProgressIndicator()),
      );
      dialogShown = true;

      // For Android 10+, use Downloads directory
      Directory? downloadDir;
      if (Platform.isAndroid) {
        downloadDir = Directory('/storage/emulated/0/Download');
        if (!await downloadDir.exists()) {
          downloadDir = await getExternalStorageDirectory();
        }
      } else {
        downloadDir = await getApplicationDocumentsDirectory();
      }

      if (downloadDir == null) {
        throw Exception('Cannot access storage');
      }

      final filePath = '${downloadDir.path}/$fileName';
      final response = await http.get(Uri.parse(documentUrl));
      if (response.statusCode != 200) {
        throw Exception('Download failed with status: ${response.statusCode}');
      }
      await File(filePath).writeAsBytes(response.bodyBytes);

      if (dialogShown && context.mounted) {
        Navigator.pop(context);
        dialogShown = false;
      }

      ToastService.instance.showSuccess(
        'Document saved to ${Platform.isAndroid ? "Downloads" : "Documents"} folder',
      );

      final result = await OpenFile.open(filePath);
      if (result.type != ResultType.done) {
        ToastService.instance.showInfo(
          'File saved but cannot be opened automatically',
        );
      }
    } catch (e) {
      if (dialogShown && context.mounted) {
        Navigator.pop(context);
      }
      if (context.mounted) {
        ToastService.instance.showError('Error: ${e.toString()}');
      }
    }
  }
}
