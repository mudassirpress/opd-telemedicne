import 'package:flutter/material.dart';
import 'package:telemedicine/core/theme/app_theme.dart';
import 'package:telemedicine/core/utils/responsive.dart';

/// Consistent user avatar with optional online indicator dot.
class UserAvatar extends StatelessWidget {
  final String? imageUrl;
  final String fallbackName;
  final double radius;
  final bool showOnlineDot;
  final bool? isOnline;
  final Color? backgroundColor;
  final VoidCallback? onTap;

  const UserAvatar({
    super.key,
    this.imageUrl,
    required this.fallbackName,
    this.radius = 28,
    this.showOnlineDot = false,
    this.isOnline,
    this.backgroundColor,
    this.onTap,
  });

  String get _initials {
    final parts = fallbackName.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts[0][0].toUpperCase();
    return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final avatar = CircleAvatar(
      radius: radius,
      backgroundColor: backgroundColor ?? AppColors.grey200,
      backgroundImage: (imageUrl != null && imageUrl!.isNotEmpty)
          ? NetworkImage(imageUrl!)
          : null,
      child: (imageUrl == null || imageUrl!.isEmpty)
          ? Text(
              _initials,
              style: TextStyle(
                fontSize: radius * 0.6,
                fontWeight: FontWeight.w600,
                color: AppColors.primaryRed,
              ),
            )
          : null,
    );

    final result = onTap != null ? GestureDetector(onTap: onTap, child: avatar) : avatar;

    if (!showOnlineDot) return result;

    return Stack(
      children: [
        result,
        Positioned(
          right: 0,
          bottom: 0,
          child: Container(
            width: radius * 0.4,
            height: radius * 0.4,
            decoration: BoxDecoration(
              color: isOnline == true ? AppColors.success : AppColors.grey400,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
            ),
          ),
        ),
      ],
    );
  }
}

/// Small online/offline indicator dot.
class OnlineIndicatorDot extends StatelessWidget {
  final bool isOnline;
  final double size;

  const OnlineIndicatorDot({
    super.key,
    required this.isOnline,
    this.size = 10,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: isOnline ? AppColors.success : AppColors.grey400,
        shape: BoxShape.circle,
      ),
    );
  }
}

/// Status chip with colored background based on status string.
class StatusChip extends StatelessWidget {
  final String status;
  final Map<String, Color>? colorMap;

  const StatusChip({super.key, required this.status, this.colorMap});

  static const _defaultColors = {
    'Active': AppColors.success,
    'Blocked': AppColors.error,
    'Frozen': AppColors.warning,
    'Deleted': AppColors.grey500,
    'Inactive': AppColors.grey500,
    'Suspended': AppColors.warning,
    'pending': AppColors.warning,
    'approved': AppColors.success,
    'rejected': AppColors.error,
    'online': AppColors.success,
    'offline': AppColors.grey500,
  };

  @override
  Widget build(BuildContext context) {
    final colors = colorMap ?? _defaultColors;
    final color = colors[status] ?? AppColors.grey500;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        status,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: context.fs(11),
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

/// Image source selection bottom sheet (Camera / Gallery).
class ImageSourceBottomSheet extends StatelessWidget {
  final Function(String source) onSelected;

  const ImageSourceBottomSheet({super.key, required this.onSelected});

  static void show(BuildContext context, Function(String source) onSelected) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => ImageSourceBottomSheet(onSelected: onSelected),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: context.rsp(24),
          vertical: 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.grey300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Select Image Source',
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: context.fs(14.5),
                fontWeight: FontWeight.w600,
                color: AppColors.grey800,
              ),
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.camera_alt, color: AppColors.primaryRed),
              title: const Text('Camera'),
              onTap: () {
                Navigator.pop(context);
                onSelected('camera');
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library, color: AppColors.primaryRed),
              title: const Text('Gallery'),
              onTap: () {
                Navigator.pop(context);
                onSelected('gallery');
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Standard confirmation dialog.
class ConfirmDialog extends StatelessWidget {
  final String title;
  final String content;
  final String confirmLabel;
  final String cancelLabel;
  final Color? confirmColor;
  final bool isDestructive;

  const ConfirmDialog({
    super.key,
    required this.title,
    required this.content,
    this.confirmLabel = 'Confirm',
    this.cancelLabel = 'Cancel',
    this.confirmColor,
    this.isDestructive = false,
  });

  static Future<bool> show({
    required BuildContext context,
    required String title,
    required String content,
    String confirmLabel = 'Confirm',
    String cancelLabel = 'Cancel',
    Color? confirmColor,
    bool isDestructive = false,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => ConfirmDialog(
        title: title,
        content: content,
        confirmLabel: confirmLabel,
        cancelLabel: cancelLabel,
        confirmColor: confirmColor,
        isDestructive: isDestructive,
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final effectiveConfirmColor =
        confirmColor ?? (isDestructive ? AppColors.error : AppColors.primaryRed);

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(
        title,
        textAlign: TextAlign.center,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: context.fs(15),
          fontWeight: FontWeight.w600,
        ),
      ),
      content: SingleChildScrollView(child: Text(content)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(cancelLabel, style: TextStyle(color: AppColors.grey600)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(
            confirmLabel,
            style: TextStyle(
              color: effectiveConfirmColor,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

/// Logout confirmation dialog (standardized across the app).
class LogoutConfirmDialog {
  static Future<void> show(BuildContext context, VoidCallback onConfirm) async {
    final confirmed = await ConfirmDialog.show(
      context: context,
      title: 'Logout',
      content: 'Are you sure you want to logout?',
      confirmLabel: 'Logout',
      isDestructive: true,
    );
    if (confirmed) onConfirm();
  }
}

/// Section header for settings/lists.
class SectionHeader extends StatelessWidget {
  final String title;

  const SectionHeader({super.key, required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: context.fs(12),
          fontWeight: FontWeight.w600,
          letterSpacing: 1.2,
          color: AppColors.grey500,
        ),
      ),
    );
  }
}
