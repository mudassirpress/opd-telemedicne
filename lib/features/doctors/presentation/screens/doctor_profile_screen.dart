import 'dart:convert';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:telemedicine/core/services/firebase_storage_service.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/data/models/user_model.dart';
import 'package:telemedicine/features/auth/presentation/controllers/doctor_controller.dart';
import 'package:telemedicine/features/auth/presentation/providers/user_provider.dart';
import 'package:telemedicine/features/auth/presentation/screens/sign_in_screen.dart';
import 'package:telemedicine/features/doctors/presentation/screens/update_doctor_profile_screen.dart';
import 'package:telemedicine/shared/widgets/auth_layout.dart';
import 'package:telemedicine/shared/widgets/opd_design_system.dart';
import 'package:telemedicine/shared/widgets/opd_profile_components.dart';

class DoctorProfileScreen extends ConsumerStatefulWidget {
  const DoctorProfileScreen({super.key});

  @override
  ConsumerState<DoctorProfileScreen> createState() =>
      _DoctorProfileScreenState();
}

class _DoctorProfileScreenState extends ConsumerState<DoctorProfileScreen> {
  final ImagePicker _picker = ImagePicker();

  bool _isUploadingPhoto = false;
  bool _isOnline = false;
  bool _notificationsEnabled = true;
  String _selectedLanguage = 'English';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadInitialData();
    });
  }

  Future<void> _loadInitialData() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _notificationsEnabled = prefs.getBool('notifications_enabled') ?? true;
        _selectedLanguage = prefs.getString('app_language') ?? 'English';
      });
    }

    final doctor = ref.read(currentDoctorProvider) ?? ref.read(userProvider);
    if (doctor != null) {
      try {
        final doc = await FirebaseFirestore.instance
            .collection('telemedicine_doctors')
            .doc(doctor.id)
            .get();
        if (doc.exists && mounted) {
          setState(() {
            _isOnline = doc.data()?['isOnline'] ?? false;
          });
        }
      } catch (_) {}
    }
  }

  Future<void> _toggleOnlineStatus(bool targetStatus) async {
    final doctorController = ref.read(doctorControllerProvider);
    final currentDoctor = doctorController.currentDoctor;
    if (currentDoctor == null) return;

    final success = await doctorController.toggleDoctorStatus(targetStatus);

    if (success && mounted) {
      setState(() {
        _isOnline = targetStatus;
      });
      if (targetStatus) {
        ToastService.instance.showSuccess(
          'You are now online and ready for consultations',
        );
      } else {
        ToastService.instance.showInfo('You are now offline');
      }
    } else if (mounted) {
      ToastService.instance.showWarning(
        'Unable to change status. Please check internet connection.',
      );
    }
  }

  Future<void> _toggleNotifications(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('notifications_enabled', value);
    if (!mounted) return;
    setState(() {
      _notificationsEnabled = value;
    });
    ToastService.instance.showInfo(
      value ? 'Notifications enabled' : 'Notifications disabled',
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
    final doctorController = ref.read(doctorControllerProvider);
    final currentDoctor = doctorController.currentDoctor;
    if (currentDoctor == null) return;

    try {
      final picked = await _picker.pickImage(source: source, imageQuality: 80);
      if (picked == null) return;

      setState(() => _isUploadingPhoto = true);
      ToastService.instance.showInfo('Uploading doctor photo...');

      final uploadResult = await FirebaseStorageService.instance
          .uploadDoctorProfileImage(
            doctorUid: currentDoctor.id,
            file: File(picked.path),
          );

      final updateData = {
        'imageUrl': uploadResult.downloadUrl,
        'image': uploadResult.downloadUrl,
        'profile_image': uploadResult.downloadUrl,
        'updatedAt': FieldValue.serverTimestamp(),
      };

      await FirebaseFirestore.instance
          .collection('telemedicine_doctors')
          .doc(currentDoctor.id)
          .update(updateData);

      final updatedDoctor = currentDoctor.copyWith(
        image: uploadResult.downloadUrl,
      );

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'current_doctor',
        json.encode(updatedDoctor.toMap()),
      );

      doctorController.updateDoctor(updatedDoctor);
      ref.invalidate(userProvider);

      if (mounted) {
        ToastService.instance.showSuccess('Profile photo updated');
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
    final doctorController = ref.read(doctorControllerProvider);
    final currentDoctor = doctorController.currentDoctor;
    if (currentDoctor == null) return;

    setState(() => _isUploadingPhoto = true);
    try {
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();

      await FirebaseFirestore.instance
          .collection('telemedicine_doctors')
          .doc(currentDoctor.id)
          .update({
            'imageUrl': null,
            'image': null,
            'profile_image': null,
            'remove_profile_image': true,
            'updatedAt': FieldValue.serverTimestamp(),
          });

      final updatedDoctor = currentDoctor.copyWith(clearImage: true);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'current_doctor',
        json.encode(updatedDoctor.toMap()),
      );

      doctorController.updateDoctor(updatedDoctor);
      ref.invalidate(userProvider);

      if (mounted) {
        ToastService.instance.showInfo('Profile picture removed');
      }
    } catch (_) {
      if (mounted) ToastService.instance.showError('Failed to remove photo');
    } finally {
      if (mounted) setState(() => _isUploadingPhoto = false);
    }
  }

  void _showPhotoOptionsDialog() {
    final doctor = ref.read(currentDoctorProvider) ?? ref.read(userProvider);
    final hasPhoto = doctor?.image != null && doctor!.image!.isNotEmpty;

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
                'Doctor Profile Photo',
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

  void _showDoctorAccountDetailsModal(UserModel doctor) {
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
                      Icons.badge_outlined,
                      color: Color(0xFF062B72),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Doctor Account Details',
                          style: TextStyle(
                            fontSize: context.fs(16),
                            fontWeight: FontWeight.w700,
                            color: const Color(0xFF1F2F44),
                          ),
                        ),
                        Text(
                          'Official verified credentials on file',
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

              _buildDetailItem(
                label: 'Doctor ID',
                value: (doctor.doctorId != null && doctor.doctorId!.isNotEmpty)
                    ? 'DOC-${doctor.doctorId}'
                    : 'Verified Doctor',
                icon: Icons.tag_rounded,
              ),
              const SizedBox(height: 10),

              _buildDetailItem(
                label: 'Consultation Fee',
                value: doctor.consultationPrice > 0
                    ? 'Rs. ${doctor.consultationPrice.toStringAsFixed(0)}'
                    : 'Not configured',
                icon: Icons.payments_outlined,
              ),
              const SizedBox(height: 10),

              _buildDetailItem(
                label: 'Highest Qualification / Degree',
                value: doctor.highestDegree?.trim().isNotEmpty == true
                    ? doctor.highestDegree!
                    : 'MBBS',
                icon: Icons.school_outlined,
              ),
              const SizedBox(height: 10),

              _buildDetailItem(
                label: 'Languages',
                value: doctor.languages.isNotEmpty
                    ? doctor.languages.join(', ')
                    : 'English, Urdu',
                icon: Icons.language_rounded,
              ),
              const SizedBox(height: 10),

              if (doctor.description?.trim().isNotEmpty == true) ...[
                _buildDetailItem(
                  label: 'Professional Summary',
                  value: doctor.description!,
                  icon: Icons.description_outlined,
                ),
                const SizedBox(height: 10),
              ],

              const SizedBox(height: 16),

              GradientButton(
                text: 'Edit Professional Details',
                icon: Icons.edit_note_rounded,
                onPressed: () {
                  Navigator.pop(ctx);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const UpdateDoctorProfileScreen(),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDetailItem({
    required String label,
    required String value,
    required IconData icon,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: const Color(0xFF062B72)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF657991),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1F2F44),
                  ),
                ),
              ],
            ),
          ),
        ],
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
          'Are you sure you want to sign out of doctor portal?',
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
      final doctorController = ref.read(doctorControllerProvider);
      if (doctorController.currentDoctor != null) {
        try {
          await FirebaseFirestore.instance
              .collection('telemedicine_doctors')
              .doc(doctorController.currentDoctor!.id)
              .update({
                'isOnline': false,
                'isAvailable': false,
                'manualAvailability': false,
                'effectiveStatus': 'OFFLINE',
                'fcmToken': null,
                'lastSeen': FieldValue.serverTimestamp(),
              })
              .timeout(const Duration(seconds: 3));
        } catch (_) {}
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('current_doctor');
      await doctorController.signOut();

      if (mounted) {
        Navigator.pop(context); // spinner
        ToastService.instance.showSuccess('Logged out successfully');
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const SignInScreen()),
          (route) => false,
        );
      }
    } catch (e) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('current_doctor');
      if (mounted) {
        Navigator.pop(context); // spinner
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const SignInScreen()),
          (route) => false,
        );
      }
    }
  }

  Future<void> _deleteAccount() async {
    final doctorController = ref.read(doctorControllerProvider);
    final currentDoctor = doctorController.currentDoctor;
    if (currentDoctor == null) return;

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
              'Deactivate Account',
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
              'Your doctor profile will be deactivated and hidden from patient search listings.',
              style: TextStyle(
                fontSize: context.fs(13),
                color: const Color(0xFF657991),
                height: 1.4,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Note: Completed consultations, medical prescriptions, and patient records are preserved on file in compliance with healthcare regulations.',
              style: TextStyle(
                fontSize: context.fs(11.5),
                color: const Color(0xFF657991),
                height: 1.4,
              ),
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
              'Deactivate',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      if (!mounted) return;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(
          child: CircularProgressIndicator(color: Color(0xFF062B72)),
        ),
      );

      final success = await doctorController.deleteDoctorProfile(
        currentDoctor.id,
        performedBy: currentDoctor.id,
        reason: 'Requested by doctor',
      );

      if (success) {
        await doctorController.signOut();
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('current_doctor');

        if (mounted) {
          Navigator.pop(context); // spinner
          ToastService.instance.showSuccess('Doctor account deactivated');
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (_) => const SignInScreen()),
            (route) => false,
          );
        }
      } else {
        if (mounted) {
          Navigator.pop(context); // spinner
          ToastService.instance.showError('Failed to deactivate account');
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentDoctor =
        ref.watch(currentDoctorProvider) ?? ref.watch(userProvider);

    if (currentDoctor == null) {
      return Scaffold(
        backgroundColor: const Color(0xFFEDF2F8),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.person_off_outlined,
                size: 64,
                color: Color(0xFF7E90A6),
              ),
              const SizedBox(height: 16),
              const Text(
                'Session Ended',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF1F2F44),
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Please sign in again to manage your profile.',
                style: TextStyle(fontSize: 13, color: Color(0xFF657991)),
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: () => Navigator.pushAndRemoveUntil(
                  context,
                  MaterialPageRoute(builder: (_) => const SignInScreen()),
                  (route) => false,
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF062B72),
                ),
                child: const Text('Sign in again'),
              ),
            ],
          ),
        ),
      );
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
                              name: currentDoctor.fullname,
                              subtitle:
                                  currentDoctor.highestDegree?.isNotEmpty ==
                                      true
                                  ? currentDoctor.highestDegree!
                                  : (currentDoctor.phoneNumber ?? 'Doctor'),
                              imageUrl: currentDoctor.image,
                              roleBadge:
                                  (currentDoctor.doctorId != null &&
                                      currentDoctor.doctorId!.isNotEmpty)
                                  ? 'Doctor • ID: ${currentDoctor.doctorId}'
                                  : 'Verified Doctor',
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
                                  subtitle: 'Name, photo & contact info',
                                  onTap: () async {
                                    final updated = await Navigator.push<bool>(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) =>
                                            const UpdateDoctorProfileScreen(),
                                      ),
                                    );
                                    if (updated == true && mounted) {
                                      ref.invalidate(userProvider);
                                      _loadInitialData();
                                    }
                                  },
                                ),

                                OpdSettingsTile(
                                  icon: Icons.badge_outlined,
                                  title: 'Doctor Account Details',
                                  subtitle: 'View credentials, fee & languages',
                                  onTap: () {
                                    _showDoctorAccountDetailsModal(
                                      currentDoctor,
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
                                  icon: Icons.sensors_rounded,
                                  title: 'Available for Consultations',
                                  subtitle: _isOnline
                                      ? 'You are online for patient calls'
                                      : 'You appear offline to patients',
                                  value: _isOnline,
                                  onChanged: _toggleOnlineStatus,
                                ),
                                OpdSettingsSwitchTile(
                                  icon: Icons.notifications_none_rounded,
                                  title: 'Notifications',
                                  subtitle:
                                      'Patient chat & consultation alerts',
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
                                  subtitle: '24/7 Doctor support helpline',
                                  onTap: () {
                                    OpdSupportDialogs.showHelpCenter(context);
                                  },
                                ),
                                OpdSettingsTile(
                                  icon: Icons.policy_outlined,
                                  title: 'Terms & Policies',
                                  subtitle: 'Medical practitioner guidelines',
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
                                    color: const Color(
                                      0xFF0F233C,
                                    ).withValues(alpha: 0.035),
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
                                      subtitle: 'Sign out of doctor portal',
                                      iconBgColor: Colors.red.withValues(
                                        alpha: 0.08,
                                      ),
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
                                      title: 'Deactivate Account',
                                      subtitle:
                                          'Deactivate doctor account securely',
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
}
