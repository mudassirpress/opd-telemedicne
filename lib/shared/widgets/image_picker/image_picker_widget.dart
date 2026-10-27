// lib/shared/widgets/image_picker/image_picker_widget.dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:image_picker/image_picker.dart';
import 'package:telemedicine/core/services/image_picker_service.dart';
import 'package:telemedicine/core/utils/responsive.dart';

class ImagePickerWidget extends StatefulWidget {
  final Function(File? imageFile) onImageSelected;
  final String? initialImageUrl;
  final File? initialImageFile;
  final double width;
  final double height;
  final double borderRadius;
  final bool isCircle;
  final String? placeholderText;
  final Widget? customPlaceholder;
  final CropStyle cropStyle;
  final double? aspectRatioX;
  final double? aspectRatioY;
  final bool showRemoveButton;
  final Color primaryColor;
  final String buttonText;
  final bool isLoading;

  const ImagePickerWidget({
    Key? key,
    required this.onImageSelected,
    this.initialImageUrl,
    this.initialImageFile,
    this.width = 120,
    this.height = 120,
    this.borderRadius = 12,
    this.isCircle = false,
    this.placeholderText = 'Tap to add image',
    this.customPlaceholder,
    this.cropStyle = CropStyle.square,
    this.aspectRatioX,
    this.aspectRatioY,
    this.showRemoveButton = true,
    this.primaryColor = Colors.red,
    this.buttonText = 'Choose Image',
    this.isLoading = false,
  }) : super(key: key);

  @override
  State<ImagePickerWidget> createState() => _ImagePickerWidgetState();
}

class _ImagePickerWidgetState extends State<ImagePickerWidget> {
  File? _selectedImage;
  final ImagePickerService _imagePickerService = ImagePickerService();
  bool _isUploading = false;
  bool _hasPermissionError = false;

  @override
  void initState() {
    super.initState();
    _selectedImage = widget.initialImageFile;
    _checkPermissions();
  }

  Future<void> _checkPermissions() async {
    // On Android, permissions are handled automatically
    // On iOS, we need to check
    if (Theme.of(context).platform == TargetPlatform.iOS) {
      try {
        final picker = ImagePicker();
        // Just test if we can access
        await picker.pickImage(source: ImageSource.gallery);
      } catch (e) {
        setState(() {
          _hasPermissionError = true;
        });
      }
    }
  }

  Future<void> _pickImage(ImageSourceType source) async {
    setState(() {
      _isUploading = true;
    });

    try {
      final File? image = await _imagePickerService.pickAndCropImage(
        source: source,
        cropStyle: widget.cropStyle,
        aspectRatioX: widget.aspectRatioX,
        aspectRatioY: widget.aspectRatioY,
        compressImage: true,
        quality: 80,
      );

      if (image != null && mounted) {
        setState(() {
          _selectedImage = image;
        });
        widget.onImageSelected(image);

        // Show success message
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Image selected successfully!'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 1),
          ),
        );
      }
    } catch (e) {
      debugPrint('Error picking image: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to pick image: ${e.toString()}'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 2),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isUploading = false;
        });
      }
    }
  }

  Future<void> _removeImage() async {
    setState(() {
      _selectedImage = null;
    });
    widget.onImageSelected(null);
  }

  void _showImageSourceDialog() {
    if (_hasPermissionError) {
      _showPermissionDialog();
      return;
    }

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      backgroundColor: Colors.white,
      builder: (BuildContext context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  widget.buttonText,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: context.fs(15.5),
                    fontWeight: FontWeight.bold,
                    color: Colors.grey[800],
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _buildSourceOption(
                      icon: Icons.camera_alt,
                      label: 'Camera',
                      onTap: () {
                        Navigator.pop(context);
                        _pickImage(ImageSourceType.camera);
                      },
                    ),
                    _buildSourceOption(
                      icon: Icons.photo_library,
                      label: 'Gallery',
                      onTap: () {
                        Navigator.pop(context);
                        _pickImage(ImageSourceType.gallery);
                      },
                    ),
                  ],
                ),
                if (widget.showRemoveButton && _selectedImage != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 20),
                    child: TextButton.icon(
                      onPressed: () {
                        Navigator.pop(context);
                        _removeImage();
                      },
                      icon: const Icon(Icons.delete_outline, color: Colors.red),
                      label: Text(
                        'Remove Image',
                        style: TextStyle(color: Colors.red),
                      ),
                    ),
                  ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showPermissionDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Permission Required'),
        content: Text(
          'Please grant camera and storage permissions to use this feature.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              openAppSettings();
            },
            child: Text('Open Settings'),
          ),
        ],
      ),
    );
  }

  Widget _buildSourceOption({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.grey[50],
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey[200]!),
        ),
        child: Column(
          children: [
            Icon(icon, size: 32, color: widget.primaryColor),
            const SizedBox(height: 8),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: context.fs(13),
                color: Colors.grey[700],
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasImage = _selectedImage != null || widget.initialImageUrl != null;

    return Column(
      children: [
        GestureDetector(
          onTap: (widget.isLoading || _isUploading)
              ? null
              : _showImageSourceDialog,
          child: Container(
            width: widget.width,
            height: widget.height,
            decoration: BoxDecoration(
              shape: widget.isCircle ? BoxShape.circle : BoxShape.rectangle,
              borderRadius: widget.isCircle
                  ? null
                  : BorderRadius.circular(widget.borderRadius),
              color: Colors.grey[100],
              border: Border.all(color: Colors.grey[300]!, width: 1),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 10,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: _buildImageContent(hasImage),
          ),
        ),
        if (widget.buttonText.isNotEmpty) ...[
          const SizedBox(height: 12),
          TextButton.icon(
            onPressed: (widget.isLoading || _isUploading)
                ? null
                : _showImageSourceDialog,
            icon: _isUploading || widget.isLoading
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(Icons.edit, size: 16, color: widget.primaryColor),
            label: Text(
              widget.isLoading ? 'Uploading...' : widget.buttonText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: context.fs(12),
                color: widget.primaryColor,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildImageContent(bool hasImage) {
    if (_isUploading || widget.isLoading) {
      return Center(
        child: CircularProgressIndicator(color: widget.primaryColor),
      );
    }

    if (_selectedImage != null) {
      return ClipRRect(
        borderRadius: widget.isCircle
            ? BorderRadius.circular(widget.width / 2)
            : BorderRadius.circular(widget.borderRadius),
        child: Image.file(
          _selectedImage!,
          width: widget.width,
          height: widget.height,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) {
            return _buildPlaceholder();
          },
        ),
      );
    }

    if (widget.initialImageUrl != null && widget.initialImageUrl!.isNotEmpty) {
      return ClipRRect(
        borderRadius: widget.isCircle
            ? BorderRadius.circular(widget.width / 2)
            : BorderRadius.circular(widget.borderRadius),
        child: Image.network(
          widget.initialImageUrl!,
          width: widget.width,
          height: widget.height,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) {
            return _buildPlaceholder();
          },
          loadingBuilder: (context, child, loadingProgress) {
            if (loadingProgress == null) return child;
            return Center(
              child: CircularProgressIndicator(color: widget.primaryColor),
            );
          },
        ),
      );
    }

    return _buildPlaceholder();
  }

  Widget _buildPlaceholder() {
    if (widget.customPlaceholder != null) {
      return widget.customPlaceholder!;
    }

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.add_photo_alternate, size: 40, color: Colors.grey[400]),
        const SizedBox(height: 8),
        Text(
          widget.placeholderText!,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: context.fs(12), color: Colors.grey[500]),
        ),
      ],
    );
  }
}
