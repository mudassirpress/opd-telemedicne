import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:telemedicine/core/services/firebase_storage_service.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/features/auth/presentation/providers/user_provider.dart';
import 'package:telemedicine/shared/widgets/auth_layout.dart';
import 'package:telemedicine/shared/widgets/opd_design_system.dart';

class EditPatientProfileScreen extends ConsumerStatefulWidget {
  const EditPatientProfileScreen({super.key});

  @override
  ConsumerState<EditPatientProfileScreen> createState() =>
      _EditPatientProfileScreenState();
}

class _EditPatientProfileScreenState
    extends ConsumerState<EditPatientProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController nameController = TextEditingController();
  final TextEditingController phoneController = TextEditingController();
  final ImagePicker _picker = ImagePicker();

  File? selectedImage;
  String? currentImageUrl;
  String? selectedGender;
  bool isUploading = false;
  bool isSaving = false;
  bool _isImageRemoved = false;

  @override
  void initState() {
    super.initState();
    _loadInitialData();
  }

  @override
  void dispose() {
    nameController.dispose();
    phoneController.dispose();
    super.dispose();
  }

  void _loadInitialData() {
    final currentUser = ref.read(userProvider);
    if (currentUser != null) {
      nameController.text = currentUser.fullname;
      phoneController.text = currentUser.phoneNumber ?? '';
      currentImageUrl = currentUser.image;
      selectedGender = currentUser.gender;
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final picked = await _picker.pickImage(source: source, imageQuality: 80);
      if (picked != null) {
        setState(() {
          selectedImage = File(picked.path);
          _isImageRemoved = false;
        });
      }
    } catch (_) {
      ToastService.instance.showError('Failed to pick image');
    }
  }

  void _showImageOptions() {
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
                'Change Profile Photo',
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
                  _pickImage(ImageSource.camera);
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
                  _pickImage(ImageSource.gallery);
                },
              ),
              if (selectedImage != null ||
                  (currentImageUrl != null && currentImageUrl!.isNotEmpty))
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
                    setState(() {
                      selectedImage = null;
                      currentImageUrl = null;
                      _isImageRemoved = true;
                    });
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _saveChanges() async {
    if (!_formKey.currentState!.validate()) return;

    final currentUser = ref.read(userProvider);
    if (currentUser == null) {
      ToastService.instance.showError('No active user session');
      return;
    }

    setState(() => isSaving = true);

    try {
      String? finalImageUrl = _isImageRemoved ? null : currentImageUrl;

      if (selectedImage != null) {
        final uploadResult = await FirebaseStorageService.instance
            .uploadPatientProfileImage(
              patientUid: currentUser.id,
              file: selectedImage!,
            );
        finalImageUrl = uploadResult.downloadUrl;
      }

      final patientController = ref.read(patientControllerProvider);
      final success = await patientController.updateUserProfile(
        image: finalImageUrl,
        fullname: nameController.text.trim(),
        gender: selectedGender,
      );

      if (success && mounted) {
        ToastService.instance.showSuccess('Profile updated successfully');
        ref.invalidate(userProvider);
        Navigator.pop(context, true);
      } else if (mounted) {
        ToastService.instance.showError(
          patientController.errorMessage.isNotEmpty
              ? patientController.errorMessage
              : 'Failed to update profile',
        );
      }
    } catch (e) {
      if (mounted) {
        ToastService.instance.showError('Update failed: ${e.toString()}');
      }
    } finally {
      if (mounted) setState(() => isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return OpdScreenShell(
      title: 'Manage Profile',
      subtitle: 'Edit your personal account details',
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Avatar picker
            Center(
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Container(
                    width: 96,
                    height: 96,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white,
                      border: Border.all(color: Colors.white, width: 3),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(
                            0xFF0F233C,
                          ).withValues(alpha: 0.12),
                          blurRadius: 14,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: ClipOval(child: _buildAvatarImage()),
                  ),
                  Positioned(
                    bottom: 0,
                    right: 0,
                    child: GestureDetector(
                      onTap: _showImageOptions,
                      child: Container(
                        width: 32,
                        height: 32,
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
                              color: const Color(
                                0xFF062B72,
                              ).withValues(alpha: 0.35),
                              blurRadius: 6,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.camera_alt_rounded,
                          size: 16,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            // Form container
            OpdCard(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Full Name',
                    style: TextStyle(
                      fontSize: context.fs(13),
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFF1F2F44),
                    ),
                  ),
                  const SizedBox(height: 8),
                  MetallicInput(
                    hintText: 'Enter full name',
                    icon: Icons.person_outline_rounded,
                    controller: nameController,
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) {
                        return 'Full name is required';
                      }
                      return null;
                    },
                  ),

                  const SizedBox(height: 18),

                  Text(
                    'Phone Number',
                    style: TextStyle(
                      fontSize: context.fs(13),
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFF1F2F44),
                    ),
                  ),
                  const SizedBox(height: 8),
                  MetallicInput(
                    hintText: 'Phone number',
                    icon: Icons.phone_android_rounded,
                    controller: phoneController,
                    enabled: false,
                  ),

                  const SizedBox(height: 18),

                  Text(
                    'Gender',
                    style: TextStyle(
                      fontSize: context.fs(13),
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFF1F2F44),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _buildGenderChip('Male', Icons.male_rounded),
                      const SizedBox(width: 10),
                      _buildGenderChip('Female', Icons.female_rounded),
                      const SizedBox(width: 10),
                      _buildGenderChip('Other', Icons.transgender_rounded),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 28),

            GradientButton(
              text: isSaving ? 'Saving...' : 'Save Changes',
              icon: isSaving ? null : Icons.check_circle_outline_rounded,
              onPressed: isSaving ? null : _saveChanges,
            ),

            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildGenderChip(String label, IconData icon) {
    final isSelected = selectedGender?.toLowerCase() == label.toLowerCase();
    return Expanded(
      child: GestureDetector(
        onTap: () {
          setState(() {
            selectedGender = label;
          });
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: isSelected
                ? const Color(0xFF062B72).withValues(alpha: 0.08)
                : const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected
                  ? const Color(0xFF062B72)
                  : const Color(0xFFDCE6F2),
              width: isSelected ? 1.5 : 1,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 16,
                color: isSelected
                    ? const Color(0xFF062B72)
                    : const Color(0xFF657991),
              ),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                  color: isSelected
                      ? const Color(0xFF062B72)
                      : const Color(0xFF1F2F44),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAvatarImage() {
    if (selectedImage != null) {
      return Image.file(
        selectedImage!,
        fit: BoxFit.cover,
        width: 96,
        height: 96,
      );
    }
    if (currentImageUrl != null && currentImageUrl!.trim().isNotEmpty) {
      return Image.network(
        currentImageUrl!,
        fit: BoxFit.cover,
        width: 96,
        height: 96,
        errorBuilder: (_, __, ___) => _buildFallbackInitial(),
      );
    }
    return _buildFallbackInitial();
  }

  Widget _buildFallbackInitial() {
    final name = nameController.text.trim();
    final initial = name.isNotEmpty ? name[0].toUpperCase() : 'P';
    return Container(
      color: const Color(0xFFEDF2F8),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: const TextStyle(
          fontSize: 36,
          fontWeight: FontWeight.w700,
          color: Color(0xFF062B72),
        ),
      ),
    );
  }
}
