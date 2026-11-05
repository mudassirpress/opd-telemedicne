import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:telemedicine/core/services/firebase_storage_service.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/features/auth/presentation/providers/user_provider.dart';
import 'package:telemedicine/features/auth/presentation/screens/sign_in_screen.dart';
import 'package:telemedicine/features/patients/presentation/screens/edit_patient_profile_screen.dart';
import 'package:telemedicine/features/prescriptions/presentation/patient_prescriptions_screen.dart';
import 'package:telemedicine/shared/widgets/auth_layout.dart';
import 'package:telemedicine/shared/widgets/opd_design_system.dart';
import 'package:telemedicine/shared/widgets/opd_profile_components.dart';

class PatientProfileScreen extends ConsumerStatefulWidget {
  const PatientProfileScreen({super.key});

  @override
  ConsumerState<PatientProfileScreen> createState() =>
      _PatientProfileScreenState();
}

class _PatientProfileScreenState extends ConsumerState<PatientProfileScreen>
    with AutomaticKeepAliveClientMixin {
  final ImagePicker _picker = ImagePicker();

  bool _isUploadingPhoto = false;
  bool _notificationsEnabled = true;
  String _selectedLanguage = 'English';

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _notificationsEnabled = prefs.getBool('notifications_enabled') ?? true;
      _selectedLanguage = prefs.getString('app_language') ?? 'English';
    });
  }

  Future<void> _toggleNotifications(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('notifications_enabled', value);
    if (!mounted) return;
    setState(() {
      _notificationsEnabled = value;
    });
    ToastService.instance.showInfo(
      value ? 'Notifications turned on' : 'Notifications turned off',
    );
  }

  Future<void> _setLanguage(String lang) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('app_language', lang);
    if (!mounted) return;
    setState(() {
      _selectedLanguage = lang;
    });
    ToastService.instance.showSuccess('Language set to $lang');
  }

  Future<void> _pickAndUploadPhoto(ImageSource source) async {
    final currentUser = ref.read(userProvider);
    if (currentUser == null) return;

    try {
      final picked = await _picker.pickImage(
        source: source,
        imageQuality: 80,
      );
      if (picked == null) return;

      setState(() => _isUploadingPhoto = true);
      ToastService.instance.showInfo('Uploading profile picture...');

      final uploadResult = await FirebaseStorageService.instance
          .uploadPatientProfileImage(
            patientUid: currentUser.id,
            file: File(picked.path),
          );

      final patientController = ref.read(patientControllerProvider);
      final success = await patientController.updateUserProfile(
        fullname: currentUser.fullname,
        image: uploadResult.downloadUrl,
      );

      if (success && mounted) {
        ToastService.instance.showSuccess('Profile photo updated');
        ref.invalidate(userProvider);
      } else if (mounted) {
        ToastService.instance.showError('Failed to update profile photo');
      }
    } catch (e) {
      if (mounted) {
        ToastService.instance.showError('Upload failed: ${e.toString()}');
      }
    } finally {
      if (mounted) setState(() => _isUploadingPhoto = false);
    }
  }

  Future<void> _removePhoto() async {
    final currentUser = ref.read(userProvider);
    if (currentUser == null) return;

    setState(() => _isUploadingPhoto = true);
    try {
      final patientController = ref.read(patientControllerProvider);
      final success = await patientController.updateUserProfile(
        fullname: currentUser.fullname,
        image: null,
      );
      if (success && mounted) {
        ToastService.instance.showInfo('Profile picture removed');
        ref.invalidate(userProvider);
      }
    } catch (_) {
      if (mounted) ToastService.instance.showError('Failed to remove photo');
    } finally {
      if (mounted) setState(() => _isUploadingPhoto = false);
    }
  }

  void _showPhotoOptionsDialog() {
    final currentUser = ref.read(userProvider);
    final hasPhoto =
        currentUser?.image != null && currentUser!.image!.isNotEmpty;

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
                'Profile Picture',
                style: TextStyle(
                  fontSize: context.fs(16),
                  fontWeight: FontWeight.w700,
                  color: const Color(0xFF1F2F44),
                ),
              ),
              const SizedBox(height: 16),
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEDF2F8),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.camera_alt_rounded,
                    color: Color(0xFF062B72),
                  ),
                ),
                title: const Text(
                  'Take Photo',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickAndUploadPhoto(ImageSource.camera);
                },
              ),
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEDF2F8),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.photo_library_rounded,
                    color: Color(0xFF062B72),
                  ),
                ),
                title: const Text(
                  'Choose from Gallery',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickAndUploadPhoto(ImageSource.gallery);
                },
              ),
              if (hasPhoto)
                ListTile(
                  leading: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.delete_outline_rounded,
                      color: Colors.red,
                    ),
                  ),
                  title: const Text(
                    'Remove Photo',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: Colors.red,
                    ),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    _removePhoto();
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _logout() async {
    final shouldLogout = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text(
          'Logout',
          style: TextStyle(
            fontSize: context.fs(16),
            fontWeight: FontWeight.w700,
            color: const Color(0xFF1F2F44),
          ),
        ),
        content: Text(
          'Are you sure you want to sign out of your account?',
          style: TextStyle(
            fontSize: context.fs(13.5),
            color: const Color(0xFF657991),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text(
              'Cancel',
              style: TextStyle(
                color: Color(0xFF657991),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text(
              'Logout',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );

    if (shouldLogout != true) return;

    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: CircularProgressIndicator(color: Color(0xFF062B72)),
      ),
    );

    try {
      final patientController = ref.read(patientControllerProvider);
      await patientController.signOut();
      if (mounted) {
        Navigator.pop(context); // Dismiss spinner
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (_) => const SignInScreen()),
          (route) => false,
        );
      }
    } catch (e) {
      if (mounted) Navigator.pop(context);
      ToastService.instance.showError('Logout failed');
    }
  }

  Future<void> _deleteAccount() async {
    final passwordController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: Colors.red),
            const SizedBox(width: 8),
            Text(
              'Delete Account',
              style: TextStyle(
                fontSize: context.fs(16),
                fontWeight: FontWeight.w700,
                color: const Color(0xFF1F2F44),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Your account will be deactivated and you will no longer be able to sign in.',
              style: TextStyle(
                fontSize: context.fs(13),
                color: const Color(0xFF657991),
                height: 1.4,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Note: In compliance with medical record regulations, your consultations, prescriptions and clinical logs remain securely archived.',
              style: TextStyle(
                fontSize: context.fs(11.5),
                color: const Color(0xFF657991),
                height: 1.4,
              ),
            ),
            const SizedBox(height: 16),
            MetallicInput(
              hintText: 'Enter account password',
              icon: Icons.lock_outline_rounded,
              isPassword: true,
              controller: passwordController,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text(
              'Cancel',
              style: TextStyle(
                color: Color(0xFF657991),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text(
              'Delete',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true && passwordController.text.isNotEmpty) {
      final patientController = ref.read(patientControllerProvider);
      final result = await patientController.deleteAccountWithPassword(
        passwordController.text.trim(),
      );
      if (result && mounted) {
        ToastService.instance.showSuccess(
          'Account deactivated. Records have been archived.',
        );
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (_) => const SignInScreen()),
          (route) => false,
        );
      } else {
        ToastService.instance.showError('Failed to delete account');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final currentUser = ref.watch(userProvider);

    if (currentUser == null) {
      return const Scaffold(
        backgroundColor: Color(0xFFEDF2F8),
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFF062B72)),
        ),
      );
    }

    if (currentUser.isGuest) {
      return _buildGuestProfileView(context);
    }

    final bool canPop = Navigator.of(context).canPop();

    return Scaffold(
      backgroundColor: const Color(0xFFEDF2F8),
      body: Stack(
        children: [
          // ECG Watermark - Top Right
          Positioned(
            top: 20,
            right: 0,
            child: Opacity(
              opacity: 0.15,
              child: CustomPaint(
                size: const Size(240, 180),
                painter: ECGWatermarkPainter(),
              ),
            ),
          ),

          SafeArea(
            child: Column(
              children: [
                // Top App Bar
                Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: context.rsp(20),
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      if (canPop) ...[
                        CircularBackButton(
                          onPressed: () => Navigator.pop(context),
                        ),
                        const SizedBox(width: 14),
                      ],
                      Expanded(
                        child: Text(
                          'Profile & Settings',
                          style: TextStyle(
                            fontSize: context.fs(20),
                            fontWeight: FontWeight.w700,
                            color: const Color(0xFF1F2F44),
                            letterSpacing: -0.3,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // Main Scrollable Settings Content
                Expanded(
                  child: SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(
                      context.rsp(20),
                      context.rsp(8),
                      context.rsp(20),
                      context.rsp(32),
                    ),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: context.contentMaxWidth < 440
                              ? context.contentMaxWidth
                              : 440,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // 1. Profile Header
                            OpdProfileHeader(
                              name: currentUser.fullname,
                              subtitle: (currentUser.phoneNumber?.isNotEmpty == true
                                      ? currentUser.phoneNumber
                                      : 'Patient') ??
                                  'Patient',
                              imageUrl: currentUser.image,
                              roleBadge: 'Patient',
                              isUploading: _isUploadingPhoto,
                              onEditPhoto: _showPhotoOptionsDialog,
                            ),

                            const SizedBox(height: 12),

                            // 2. Account Section
                            OpdSettingsGroup(
                              title: 'Account',
                              items: [
                                OpdSettingsTile(
                                  icon: Icons.person_outline_rounded,
                                  title: 'Manage Profile',
                                  subtitle: 'Personal information & photo',
                                  onTap: () async {
                                    final updated = await Navigator.push<bool>(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) =>
                                            const EditPatientProfileScreen(),
                                      ),
                                    );
                                    if (updated == true) {
                                      ref.invalidate(userProvider);
                                    }
                                  },
                                ),
                                OpdSettingsTile(
                                  icon: Icons.receipt_long_outlined,
                                  title: 'My Prescriptions',
                                  subtitle: 'Digital prescriptions & advice',
                                  onTap: () {
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) =>
                                            const PatientPrescriptionsScreen(),
                                      ),
                                    );
                                  },
                                ),
                              ],
                            ),

                            // 3. Preferences Section
                            OpdSettingsGroup(
                              title: 'Preferences',
                              items: [
                                OpdSettingsSwitchTile(
                                  icon: Icons.notifications_none_rounded,
                                  title: 'Notifications',
                                  subtitle: 'Consultation & message alerts',
                                  value: _notificationsEnabled,
                                  onChanged: _toggleNotifications,
                                ),
                                OpdSettingsTile(
                                  icon: Icons.translate_rounded,
                                  title: 'Language',
                                  subtitle: _selectedLanguage,
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        _selectedLanguage,
                                        style: TextStyle(
                                          fontSize: context.fs(13),
                                          fontWeight: FontWeight.w600,
                                          color: const Color(0xFF062B72),
                                        ),
                                      ),
                                      const SizedBox(width: 4),
                                      const Icon(
                                        Icons.chevron_right_rounded,
                                        color: Color(0xFF94A3B8),
                                        size: 20,
                                      ),
                                    ],
                                  ),
                                  onTap: () {
                                    OpdSupportDialogs.showLanguageSelector(
                                      context: context,
                                      currentLanguage: _selectedLanguage,
                                      onSelected: _setLanguage,
                                    );
                                  },
                                ),
                              ],
                            ),

                            // 4. Support Section
                            OpdSettingsGroup(
                              title: 'Support',
                              items: [
                                OpdSettingsTile(
                                  icon: Icons.headset_mic_outlined,
                                  title: 'Help Center',
                                  subtitle: '24/7 Helpline & contacts',
                                  onTap: () {
                                    OpdSupportDialogs.showHelpCenter(context);
                                  },
                                ),
                                OpdSettingsTile(
                                  icon: Icons.policy_outlined,
                                  title: 'Terms & Policies',
                                  subtitle: 'Clinical & privacy guidelines',
                                  onTap: () {
                                    OpdSupportDialogs.showTermsAndPolicies(
                                      context,
                                    );
                                  },
                                ),
                                OpdSettingsTile(
                                  icon: Icons.info_outline_rounded,
                                  title: 'About Us',
                                  subtitle: 'Version 1.0.6 (Build 6)',
                                  onTap: () {
                                    OpdSupportDialogs.showAboutUs(context);
                                  },
                                ),
                              ],
                            ),

                            const SizedBox(height: 24),

                            // 5. Account Actions (Visually Separated)
                            Container(
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: const Color(0xFFE2E8F0),
                                  width: 1,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: const Color(0xFF0F233C)
                                        .withValues(alpha: 0.035),
                                    blurRadius: 10,
                                    offset: const Offset(0, 3),
                                  ),
                                ],
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(16),
                                child: Column(
                                  children: [
                                    OpdSettingsTile(
                                      icon: Icons.logout_rounded,
                                      title: 'Logout',
                                      subtitle: 'Sign out of this session',
                                      iconBgColor:
                                          Colors.red.withValues(alpha: 0.08),
                                      iconColor: const Color(0xFFD32F2F),
                                      titleColor: const Color(0xFFD32F2F),
                                      trailing: const Icon(
                                        Icons.chevron_right_rounded,
                                        color: Color(0xFFD32F2F),
                                        size: 20,
                                      ),
                                      onTap: _logout,
                                    ),
                                    const Divider(
                                      height: 1,
                                      thickness: 1,
                                      color: Color(0xFFF1F5F9),
                                      indent: 54,
                                      endIndent: 14,
                                    ),
                                    OpdSettingsTile(
                                      icon: Icons.delete_outline_rounded,
                                      title: 'Delete Account',
                                      subtitle: 'Deactivate account securely',
                                      iconBgColor: const Color(0xFFF1F5F9),
                                      iconColor: const Color(0xFF64748B),
                                      titleColor: const Color(0xFF64748B),
                                      trailing: const Icon(
                                        Icons.chevron_right_rounded,
                                        color: Color(0xFF94A3B8),
                                        size: 20,
                                      ),
                                      onTap: _deleteAccount,
                                    ),
                                  ],
                                ),
                              ),
                            ),

                            const SizedBox(height: 24),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGuestProfileView(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEDF2F8),
      body: Stack(
        children: [
          Positioned(
            top: 20,
            right: 0,
            child: Opacity(
              opacity: 0.15,
              child: CustomPaint(
                size: const Size(240, 180),
                painter: ECGWatermarkPainter(),
              ),
            ),
          ),
          SafeArea(
            child: Center(
              child: Padding(
                padding: EdgeInsets.all(context.rsp(24)),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 90,
                      height: 90,
                      decoration: BoxDecoration(
                        color: const Color(0xFFD6E4F0),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 3),
                      ),
                      child: const Icon(
                        Icons.person_rounded,
                        size: 48,
                        color: Color(0xFF062B72),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Guest User',
                      style: TextStyle(
                        fontSize: context.fs(22),
                        fontWeight: FontWeight.w800,
                        color: const Color(0xFF1F2F44),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE2E8F0),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        'Read-Only Mode',
                        style: TextStyle(
                          fontSize: context.fs(12),
                          fontWeight: FontWeight.w600,
                          color: const Color(0xFF64748B),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'You are currently browsing as a guest. Sign in to access room chat, appointments, prescriptions, and medical history.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: context.fs(13),
                        color: const Color(0xFF6B7B8D),
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 28),
                    GradientButton(
                      text: 'Sign In / Register',
                      icon: Icons.login_rounded,
                      onPressed: () {
                        Navigator.pushAndRemoveUntil(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const SignInScreen(),
                          ),
                          (route) => false,
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
