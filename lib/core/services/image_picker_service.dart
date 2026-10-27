// lib/services/image_picker_service.dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;

enum ImageSourceType { camera, gallery }

enum CropStyle { rectangle, square, circle }

class ImagePickerService {
  final ImagePicker _picker = ImagePicker();

  // MAIN FUNCTION
  Future<File?> pickAndCropImage({
    required ImageSourceType source,
    CropStyle cropStyle = CropStyle.square,
    double? aspectRatioX,
    double? aspectRatioY,
    bool compressImage = true,
    int quality = 80,
  }) async {
    try {
      final XFile? pickedFile = await _picker.pickImage(
        source: source == ImageSourceType.camera
            ? ImageSource.camera
            : ImageSource.gallery,
        imageQuality: compressImage ? quality : null,
      );

      if (pickedFile == null) return null;

      final File tempFile = await _createTempFile(pickedFile);

      final File? croppedFile = await _cropImageSafely(
        file: tempFile,
        cropStyle: cropStyle,
        aspectRatioX: aspectRatioX,
        aspectRatioY: aspectRatioY,
      );

      // delete original temp
      await _safeDelete(tempFile);

      return croppedFile;
    } catch (e) {
      debugPrint('❌ Error picking image: $e');
      return null;
    }
  }

  // CREATE TEMP FILE
  Future<File> _createTempFile(XFile pickedFile) async {
    final tempDir = await getTemporaryDirectory();
    final file = File(
      path.join(
        tempDir.path,
        'temp_${DateTime.now().millisecondsSinceEpoch}.jpg',
      ),
    );

    await file.writeAsBytes(await pickedFile.readAsBytes());
    return file;
  }

  // SAFE CROPPER
  Future<File?> _cropImageSafely({
    required File file,
    required CropStyle cropStyle,
    double? aspectRatioX,
    double? aspectRatioY,
  }) async {
    try {
      if (!await file.exists()) {
        debugPrint('⚠️ File not found');
        return null;
      }

      CropAspectRatio? aspectRatio;
      if (aspectRatioX != null &&
          aspectRatioY != null &&
          aspectRatioX > 0 &&
          aspectRatioY > 0) {
        aspectRatio = CropAspectRatio(
          ratioX: aspectRatioX,
          ratioY: aspectRatioY,
        );
      }

      final cropped = await ImageCropper().cropImage(
        sourcePath: file.path,
        aspectRatio: aspectRatio,
        compressQuality: 90,
        uiSettings: [
          AndroidUiSettings(
            toolbarTitle: 'Crop Image',
            toolbarColor: Colors.red,
            toolbarWidgetColor: Colors.white,
            backgroundColor: Colors.black,
            activeControlsWidgetColor: Colors.red,
            lockAspectRatio: aspectRatio != null,
          ),
          IOSUiSettings(
            title: 'Crop Image',

            aspectRatioLockEnabled: aspectRatio != null,
          ),
        ],
      );

      if (cropped == null) return null;

      final tempDir = await getTemporaryDirectory();
      final newFile = File(
        path.join(
          tempDir.path,
          'cropped_${DateTime.now().millisecondsSinceEpoch}.jpg',
        ),
      );

      await newFile.writeAsBytes(await cropped.readAsBytes());

      return newFile;
    } catch (e) {
      debugPrint('❌ Crop Error: $e');
      return file; // fallback
    }
  }

  // MULTIPLE IMAGES
  Future<List<File>> pickMultipleImages({
    int maxImages = 5,
    int quality = 80,
  }) async {
    try {
      final List<XFile> pickedFiles = await _picker.pickMultiImage(
        imageQuality: quality,
      );

      if (pickedFiles.isEmpty) return [];

      List<File> images = [];

      for (int i = 0; i < pickedFiles.length && i < maxImages; i++) {
        images.add(await _createTempFile(pickedFiles[i]));
      }

      return images;
    } catch (e) {
      debugPrint('❌ Multi Image Error: $e');
      return [];
    }
  }

  // CROP EXISTING
  Future<File?> cropExistingImage({
    required File imageFile,
    CropStyle cropStyle = CropStyle.square,
    double? aspectRatioX,
    double? aspectRatioY,
  }) async {
    return _cropImageSafely(
      file: imageFile,
      cropStyle: cropStyle,
      aspectRatioX: aspectRatioX,
      aspectRatioY: aspectRatioY,
    );
  }

  // BYTES
  Future<List<int>?> getImageBytes(File file) async {
    try {
      return await file.readAsBytes();
    } catch (e) {
      debugPrint('❌ Byte Error: $e');
      return null;
    }
  }

  // SAFE DELETE
  Future<void> _safeDelete(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }
}
