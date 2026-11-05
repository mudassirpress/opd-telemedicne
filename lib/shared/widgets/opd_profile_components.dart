import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';

/// Clean, modular profile & settings components preserving OPD Telemedicine's
/// visual identity (navy/blue colors, white card containers, soft shadows,
/// and rounded corners).
class OpdProfileHeader extends StatelessWidget {
  final String? imageUrl;
  final File? localImage;
  final String name;
  final String subtitle;
  final String? roleBadge;
  final VoidCallback? onEditPhoto;
  final bool isUploading;

  const OpdProfileHeader({
    super.key,
    required this.name,
    required this.subtitle,
    this.imageUrl,
    this.localImage,
    this.roleBadge,
    this.onEditPhoto,
    this.isUploading = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Centered Avatar with Camera Badge
        Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 86,
              height: 86,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white,
                border: Border.all(color: Colors.white, width: 3),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF0F233C).withValues(alpha: 0.12),
                    blurRadius: 14,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: ClipOval(
                child: _buildAvatarImage(),
              ),
            ),

            if (isUploading)
              Container(
                width: 86,
                height: 86,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.black.withValues(alpha: 0.45),
                ),
                child: const Center(
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),

            // Camera / Edit Badge
            if (onEditPhoto != null)
              Positioned(
                bottom: 0,
                right: 0,
                child: GestureDetector(
                  onTap: onEditPhoto,
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF284F85), Color(0xFF062B72)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF062B72).withValues(alpha: 0.35),
                          blurRadius: 6,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.camera_alt_rounded,
                      size: 14,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
          ],
        ),

        const SizedBox(height: 12),

        // User Full Name
        Text(
          name.trim().isEmpty ? 'User Profile' : name,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: context.fs(18),
            fontWeight: FontWeight.w700,
            color: const Color(0xFF1F2F44),
            letterSpacing: -0.2,
          ),
        ),

        const SizedBox(height: 4),

        // Subtitle (Phone number, Email, or Qualification)
        Text(
          subtitle,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: context.fs(13),
            fontWeight: FontWeight.w500,
            color: const Color(0xFF657991),
          ),
        ),

        if (roleBadge != null && roleBadge!.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(
              color: const Color(0xFF062B72).withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: const Color(0xFF062B72).withValues(alpha: 0.18),
                width: 1,
              ),
            ),
            child: Text(
              roleBadge!,
              style: TextStyle(
                fontSize: context.fs(11.5),
                fontWeight: FontWeight.w600,
                color: const Color(0xFF062B72),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildAvatarImage() {
    if (localImage != null) {
      return Image.file(
        localImage!,
        fit: BoxFit.cover,
        width: 86,
        height: 86,
      );
    }
    if (imageUrl != null && imageUrl!.trim().isNotEmpty) {
      return Image.network(
        imageUrl!,
        fit: BoxFit.cover,
        width: 86,
        height: 86,
        errorBuilder: (_, __, ___) => _buildFallbackInitial(),
        loadingBuilder: (context, child, progress) {
          if (progress == null) return child;
          return const Center(
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Color(0xFF062B72),
              ),
            ),
          );
        },
      );
    }
    return _buildFallbackInitial();
  }

  Widget _buildFallbackInitial() {
    final initial = name.trim().isNotEmpty ? name.trim()[0].toUpperCase() : 'U';
    return Container(
      color: const Color(0xFFEDF2F8),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: const TextStyle(
          fontSize: 32,
          fontWeight: FontWeight.w700,
          color: Color(0xFF062B72),
        ),
      ),
    );
  }
}

/// Grouped settings section card matching OPD design
class OpdSettingsGroup extends StatelessWidget {
  final String title;
  final List<Widget> items;

  const OpdSettingsGroup({
    super.key,
    required this.title,
    required this.items,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8, top: 16),
          child: Text(
            title.toUpperCase(),
            style: TextStyle(
              fontSize: context.fs(11.5),
              fontWeight: FontWeight.w700,
              color: const Color(0xFF657991),
              letterSpacing: 0.8,
            ),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFE2E8F0), width: 1),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF0F233C).withValues(alpha: 0.035),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Column(
              children: [
                for (int i = 0; i < items.length; i++) ...[
                  items[i],
                  if (i < items.length - 1)
                    const Divider(
                      height: 1,
                      thickness: 1,
                      color: Color(0xFFF1F5F9),
                      indent: 54,
                      endIndent: 14,
                    ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Compact settings menu item row
class OpdSettingsTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Color? iconColor;
  final Color? iconBgColor;
  final Color? titleColor;

  const OpdSettingsTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.iconColor,
    this.iconBgColor,
    this.titleColor,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: iconBgColor ?? const Color(0xFFEDF2F8),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  icon,
                  color: iconColor ?? const Color(0xFF062B72),
                  size: 19,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: context.fs(14),
                        fontWeight: FontWeight.w600,
                        color: titleColor ?? const Color(0xFF1F2F44),
                      ),
                    ),
                    if (subtitle != null && subtitle!.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: context.fs(11.5),
                          color: const Color(0xFF657991),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              trailing ??
                  const Icon(
                    Icons.chevron_right_rounded,
                    color: Color(0xFF94A3B8),
                    size: 20,
                  ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact settings switch row
class OpdSettingsSwitchTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final Color? iconColor;
  final Color? iconBgColor;

  const OpdSettingsSwitchTile({
    super.key,
    required this.icon,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.iconColor,
    this.iconBgColor,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: iconBgColor ?? const Color(0xFFEDF2F8),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              icon,
              color: iconColor ?? const Color(0xFF062B72),
              size: 19,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: context.fs(14),
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF1F2F44),
                  ),
                ),
                if (subtitle != null && subtitle!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: context.fs(11.5),
                      color: const Color(0xFF657991),
                    ),
                  ),
                ],
              ],
            ),
          ),
          Transform.scale(
            scale: 0.85,
            child: Switch.adaptive(
              value: value,
              onChanged: onChanged,
              activeColor: const Color(0xFF062B72),
              activeTrackColor: const Color(0xFF284F85).withValues(alpha: 0.35),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shared Support Dialogs
class OpdSupportDialogs {
  /// Help Center modal sheet
  static void showHelpCenter(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: const Color(0xFFD6E4F0),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: const Color(0xFFEDF2F8),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.headset_mic_rounded,
                      color: Color(0xFF062B72),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'OPD Help Center',
                          style: TextStyle(
                            fontSize: context.fs(16),
                            fontWeight: FontWeight.w700,
                            color: const Color(0xFF1F2F44),
                          ),
                        ),
                        Text(
                          'We are here to help you 24/7',
                          style: TextStyle(
                            fontSize: context.fs(12.5),
                            color: const Color(0xFF657991),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // Helpline card
              _buildHelpRow(
                context: context,
                icon: Icons.phone_in_talk_rounded,
                title: 'Helpline & Telemedicine Support',
                value: '+92 300 0000000',
                actionLabel: 'Copy',
                onAction: () {
                  Clipboard.setData(const ClipboardData(text: '+923000000000'));
                  ToastService.instance.showSuccess('Phone number copied');
                },
              ),
              const SizedBox(height: 12),

              // Email support card
              _buildHelpRow(
                context: context,
                icon: Icons.email_outlined,
                title: 'Support Email',
                value: 'support@opdtelemedicine.com',
                actionLabel: 'Copy',
                onAction: () {
                  Clipboard.setData(
                    const ClipboardData(text: 'support@opdtelemedicine.com'),
                  );
                  ToastService.instance.showSuccess('Email address copied');
                },
              ),
              const SizedBox(height: 12),

              // Operating hours
              _buildHelpRow(
                context: context,
                icon: Icons.access_time_rounded,
                title: 'Operating Hours',
                value: 'Open 24 Hours / 7 Days a Week',
                actionLabel: null,
                onAction: null,
              ),

              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  style: TextButton.styleFrom(
                    backgroundColor: const Color(0xFFEDF2F8),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(
                    'Close',
                    style: TextStyle(
                      fontSize: context.fs(14),
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFF062B72),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static Widget _buildHelpRow({
    required BuildContext context,
    required IconData icon,
    required String title,
    required String value,
    required String? actionLabel,
    required VoidCallback? onAction,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Row(
        children: [
          Icon(icon, color: const Color(0xFF062B72), size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: context.fs(11.5),
                    fontWeight: FontWeight.w500,
                    color: const Color(0xFF657991),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: context.fs(13.5),
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF1F2F44),
                  ),
                ),
              ],
            ),
          ),
          if (actionLabel != null && onAction != null)
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                foregroundColor: const Color(0xFF062B72),
              ),
              child: Text(
                actionLabel,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
        ],
      ),
    );
  }

  /// Terms & Policies Dialog
  static void showTermsAndPolicies(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFFEDF2F8),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.policy_outlined,
                color: Color(0xFF062B72),
                size: 20,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Terms & Policies',
                style: TextStyle(
                  fontSize: context.fs(16),
                  fontWeight: FontWeight.w700,
                  color: const Color(0xFF1F2F44),
                ),
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildPolicyParagraph(
                context,
                title: '1. Telemedicine Consultations',
                body:
                    'All remote consultations on OPD Telemedicine are provided by qualified medical doctors. Recommendations and prescriptions are issued based on user-provided clinical information and remote evaluation.',
              ),
              const SizedBox(height: 12),
              _buildPolicyParagraph(
                context,
                title: '2. Digital Prescriptions',
                body:
                    'Branded OPD Telemedicine digital prescriptions are legally valid medical documents generated by attending physicians. Patients can view, download, or share prescriptions directly.',
              ),
              const SizedBox(height: 12),
              _buildPolicyParagraph(
                context,
                title: '3. Privacy & Health Records',
                body:
                    'Patient health records, medical reports, prescriptions, and consult chats are confidential. Your records remain strictly protected in compliance with clinical privacy standards.',
              ),
              const SizedBox(height: 12),
              _buildPolicyParagraph(
                context,
                title: '4. Account Management & Data Retention',
                body:
                    'When an account is deleted or deactivated, medical consultation histories, prescriptions, and financial audit logs are preserved in accordance with healthcare record retention guidelines.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              'Understood',
              style: TextStyle(
                color: Color(0xFF062B72),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  static Widget _buildPolicyParagraph(
    BuildContext context, {
    required String title,
    required String body,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: context.fs(13),
            fontWeight: FontWeight.w700,
            color: const Color(0xFF1F2F44),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          body,
          style: TextStyle(
            fontSize: context.fs(12),
            color: const Color(0xFF657991),
            height: 1.4,
          ),
        ),
      ],
    );
  }

  /// About Us Dialog
  static void showAboutUs(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFFEDF2F8),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.local_hospital_rounded,
                color: Color(0xFF062B72),
                size: 20,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'About OPD Telemedicine',
                style: TextStyle(
                  fontSize: context.fs(16),
                  fontWeight: FontWeight.w700,
                  color: const Color(0xFF1F2F44),
                ),
              ),
            ),
          ],
        ),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'OPD Telemedicine Healthcare Delivery',
              style: TextStyle(
                fontSize: context.fs(13.5),
                fontWeight: FontWeight.w700,
                color: const Color(0xFF1F2F44),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Version 1.0.6 (Build 6)',
              style: TextStyle(
                fontSize: context.fs(12),
                color: const Color(0xFF657991),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'OPD Telemedicine connects patients with trusted healthcare providers across Pakistan. Our platform facilitates live consultations, appointments, medical chat, certified digital prescriptions, and health report management.',
              style: TextStyle(
                fontSize: context.fs(12.5),
                color: const Color(0xFF657991),
                height: 1.45,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              'Close',
              style: TextStyle(
                color: Color(0xFF062B72),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Language picker sheet
  static void showLanguageSelector({
    required BuildContext context,
    required String currentLanguage,
    required ValueChanged<String> onSelected,
  }) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: const Color(0xFFD6E4F0),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Text(
                'Select Language',
                style: TextStyle(
                  fontSize: context.fs(16),
                  fontWeight: FontWeight.w700,
                  color: const Color(0xFF1F2F44),
                ),
              ),
              const SizedBox(height: 16),
              _buildLanguageOption(
                context: ctx,
                title: 'English',
                subtitle: 'English (Default)',
                isSelected: currentLanguage.toLowerCase() != 'urdu',
                onTap: () {
                  Navigator.pop(ctx);
                  onSelected('English');
                },
              ),
              const SizedBox(height: 8),
              _buildLanguageOption(
                context: ctx,
                title: 'اردو',
                subtitle: 'Urdu',
                isSelected: currentLanguage.toLowerCase() == 'urdu',
                onTap: () {
                  Navigator.pop(ctx);
                  onSelected('Urdu');
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  static Widget _buildLanguageOption({
    required BuildContext context,
    required String title,
    required String subtitle,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: isSelected
            ? const Color(0xFF062B72).withValues(alpha: 0.06)
            : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isSelected
              ? const Color(0xFF062B72)
              : const Color(0xFFE2E8F0),
          width: isSelected ? 1.5 : 1,
        ),
      ),
      child: ListTile(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        onTap: onTap,
        title: Text(
          title,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: isSelected ? const Color(0xFF062B72) : const Color(0xFF1F2F44),
          ),
        ),
        subtitle: Text(
          subtitle,
          style: TextStyle(
            fontSize: 12,
            color: const Color(0xFF657991),
          ),
        ),
        trailing: isSelected
            ? const Icon(Icons.check_circle_rounded, color: Color(0xFF062B72))
            : null,
      ),
    );
  }
}

