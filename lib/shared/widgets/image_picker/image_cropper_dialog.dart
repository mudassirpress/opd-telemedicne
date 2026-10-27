// lib/widgets/image_cropper_dialog.dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_cropper/image_cropper.dart';

class ImageCropperDialog {
  static Future<File?> showCropper({
    required BuildContext context,
    required String imagePath,
    CropStyle cropStyle = CropStyle.rectangle,
    double? aspectRatioX,
    double? aspectRatioY,
    bool lockAspectRatio = false,
  }) async {
    CropAspectRatio? aspectRatio;

    if (aspectRatioX != null && aspectRatioY != null) {
      aspectRatio = CropAspectRatio(ratioX: aspectRatioX, ratioY: aspectRatioY);
    }

    try {
      final CroppedFile? croppedFile = await ImageCropper().cropImage(
        sourcePath: imagePath,
        aspectRatio: aspectRatio,
        uiSettings: [
          AndroidUiSettings(
            toolbarTitle: 'Crop Image',
            toolbarColor: Colors.red,
            toolbarWidgetColor: Colors.white,
            initAspectRatio: CropAspectRatioPreset.original,
            lockAspectRatio: lockAspectRatio,
            showCropGrid: true,
            hideBottomControls: false,
            activeControlsWidgetColor: Colors.red,
          ),
          IOSUiSettings(
            title: 'Crop Image',
            aspectRatioLockEnabled: lockAspectRatio,
            rotateButtonsHidden: false,
            rotateClockwiseButtonHidden: false,
          ),
        ],
      );

      if (croppedFile != null) {
        return File(croppedFile.path);
      }
      return null;
    } catch (e) {
      debugPrint('Error cropping image: $e');
      return null;
    }
  }
}

