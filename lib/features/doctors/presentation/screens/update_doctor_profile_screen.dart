import 'dart:convert';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/core/services/firebase_storage_service.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/data/models/user_model.dart';
import 'package:telemedicine/features/appointments/presentation/appointment_controller.dart';
import 'package:telemedicine/features/auth/presentation/controllers/doctor_controller.dart';
import 'package:telemedicine/features/auth/presentation/providers/user_provider.dart';
import 'package:telemedicine/features/auth/presentation/screens/sign_in_screen.dart';
import 'package:telemedicine/features/doctor_portal/presentation/bottom_nav/doctor_portal_wrapper.dart';
import 'package:telemedicine/shared/widgets/auth_layout.dart';
import 'package:telemedicine/shared/widgets/language_field.dart';
import 'package:telemedicine/shared/widgets/opd_design_system.dart';

class UpdateDoctorProfileScreen extends ConsumerStatefulWidget {
  const UpdateDoctorProfileScreen({super.key});

  @override
  ConsumerState<UpdateDoctorProfileScreen> createState() =>
      _UpdateDoctorProfileScreenState();
}

class _UpdateDoctorProfileScreenState
    extends ConsumerState<UpdateDoctorProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  final ImagePicker _picker = ImagePicker();

  final TextEditingController nameController = TextEditingController();
  final TextEditingController phoneController = TextEditingController();
  final TextEditingController degreeController = TextEditingController();
  final TextEditingController feeController = TextEditingController();
  final TextEditingController descriptionController = TextEditingController();
  final TextEditingController videoUrlController = TextEditingController();

  File? selectedImage;
  String? existingImageUrl;
  bool _isImageRemoved = false;
  String? selectedGender;

  bool isUpdating = false;
  String errorText = '';

  List<String> _selectedLanguages = <String>[];
  double _savedPrice = 0;
  String? _savedDescription;
  String? _savedVideoUrl;

  @override
  void initState() {
    super.initState();
    _loadExistingDoctorData();
  }

  @override
  void dispose() {
    nameController.dispose();
    phoneController.dispose();
    degreeController.dispose();
    feeController.dispose();
    descriptionController.dispose();
    videoUrlController.dispose();
    super.dispose();
  }

  Future<void> _loadExistingDoctorData() async {
    final currentDoctor =
        ref.read(currentDoctorProvider) ?? ref.read(userProvider);
    if (currentDoctor == null) return;

    Map<String, dynamic>? document;
    if (currentDoctor.id.isNotEmpty) {
      try {
        final snapshot = await FirebaseFirestore.instance
            .collection('telemedicine_doctors')
            .doc(currentDoctor.id)
            .get();
        if (snapshot.exists) document = snapshot.data();
      } catch (_) {
        document = null;
      }
    }
    if (!mounted) return;

    final data = document ?? <String, dynamic>{};

    final name = (data['fullname'] ?? currentDoctor.fullname).toString().trim();
    if (name.isNotEmpty) nameController.text = name;

    final phone = (data['phoneNumber'] ?? currentDoctor.phoneNumber ?? '')
        .toString()
        .trim();
    phoneController.text = phone;

    final gender = (data['gender'] ?? currentDoctor.gender)?.toString().trim();
    if (gender != null && gender.isNotEmpty) selectedGender = gender;

    final degree = (data['highestDegree'] ?? currentDoctor.highestDegree ?? '')
        .toString()
        .trim();
    if (degree.isNotEmpty) degreeController.text = degree;

    final image =
        (data['imageUrl'] ?? data['image'] ?? currentDoctor.image ?? '')
            .toString()
            .trim();
    if (image.isNotEmpty) existingImageUrl = image;

    _savedPrice =
        _parsePrice(data['price']) ?? _parsePrice(data['consultationFee']) ?? 0;
    if (_savedPrice <= 0 && document == null) {
      _savedPrice = currentDoctor.consultationPrice;
    }
    if (_savedPrice > 0) {
      feeController.text = _savedPrice.toStringAsFixed(0);
    }

    _savedDescription = document != null
        ? _asTrimmedStringOrNull(data['description'])
        : currentDoctor.description;
    descriptionController.text = _savedDescription ?? '';

    _savedVideoUrl = document != null
        ? _asTrimmedStringOrNull(data['youtubeVideoUrl'])
        : currentDoctor.youtubeVideoUrl;
    videoUrlController.text = _savedVideoUrl ?? '';

    _selectedLanguages = document != null
        ? DoctorLanguages.parse(
            data[DoctorLanguages.field] ?? data[DoctorLanguages.legacyField],
          )
        : List<String>.of(currentDoctor.languages);

    if (mounted) setState(() {});
  }

  double? _parsePrice(dynamic value) {
    if (value == null) return null;
    final parsed = value is num
        ? value.toDouble()
        : value is String
        ? double.tryParse(value.trim())
        : null;
    if (parsed == null || parsed <= 0) return null;
    return parsed;
  }

  String? _asTrimmedStringOrNull(dynamic value) {
    if (value == null) return null;
    final text = value is String ? value : value.toString();
    return text.trim();
  }

  String? _validateFee(String? value) {
    final raw = (value ?? '').trim();
    if (raw.isEmpty) return 'Please enter your consultation price';
    final fee = double.tryParse(raw);
    if (fee == null || fee <= 0) {
      return 'Enter a price greater than 0';
    }
    if (fee > 1000000) return 'That price looks too high';
    return null;
  }

  String? _validateDescription(String? value) {
    if ((value ?? '').trim().isEmpty) {
      return 'Please add a short description about yourself';
    }
    return null;
  }

  String? _validateVideoUrl(String? value) {
    final url = (value ?? '').trim();
    if (url.isEmpty) return null;
    if (AppointmentController.isUsableYoutubeUrl(url)) return null;
    return 'Enter a valid YouTube link, or leave it blank';
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
                'Change Doctor Photo',
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
                  (existingImageUrl != null && existingImageUrl!.isNotEmpty))
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
                      existingImageUrl = null;
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

  Future<void> _updateDoctorProfile() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      isUpdating = true;
      errorText = '';
    });

    try {
      final doctorController = ref.read(doctorControllerProvider);
      final currentDoctor = doctorController.currentDoctor;

      if (currentDoctor == null) {
        setState(() {
          errorText = 'Session expired. Please login again.';
          isUpdating = false;
        });
        ToastService.instance.showError('Session expired. Please login again.');
        return;
      }

      ToastService.instance.showInfo('Updating profile...');

      String? imageUrl = _isImageRemoved ? null : existingImageUrl;

      if (selectedImage != null) {
        ToastService.instance.showInfo('Uploading image...');
        final uploadResult = await FirebaseStorageService.instance
            .uploadDoctorProfileImage(
              doctorUid: currentDoctor.id,
              file: selectedImage!,
            );
        imageUrl = uploadResult.downloadUrl;
        _isImageRemoved = false;
      }

      final firestore = FirebaseFirestore.instance;
      final fee = double.parse(feeController.text.trim());
      final description = descriptionController.text.trim();
      final videoUrl = videoUrlController.text.trim();

      final bool isRemovingImage = _isImageRemoved && selectedImage == null;

      final updates = <String, dynamic>{
        'fullname': nameController.text.trim(),
        'highestDegree': degreeController.text.trim(),
        if (selectedGender != null) 'gender': selectedGender,
        'price': fee,
        'consultationFee': fee,
        'imageUrl': imageUrl,
        'image': imageUrl,
        'profile_image': imageUrl,
        if (isRemovingImage) 'remove_profile_image': true,
        DoctorLanguages.field: List<String>.from(_selectedLanguages),
        'updatedAt': FieldValue.serverTimestamp(),
      };

      if (description != (_savedDescription ?? '').trim()) {
        updates['description'] = description;
      }
      if (videoUrl != (_savedVideoUrl ?? '').trim()) {
        updates['youtubeVideoUrl'] = videoUrl;
      }

      await firestore
          .collection('telemedicine_doctors')
          .doc(currentDoctor.id)
          .update(updates);

      if (isRemovingImage) {
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();
      }

      final updatedDoctor = currentDoctor.copyWith(
        fullname: nameController.text.trim(),
        highestDegree: degreeController.text.trim(),
        gender: selectedGender,
        image: imageUrl,
        clearImage: isRemovingImage,
        languages: _selectedLanguages,
        price: fee,
        consultationFee: fee,
        description: description,
        youtubeVideoUrl: videoUrl,
      );

      _isImageRemoved = false;
      _savedPrice = fee;
      _savedDescription = description;
      _savedVideoUrl = videoUrl;

      doctorController.updateDoctor(updatedDoctor);
      await _saveUpdatedDoctorToLocalStorage(updatedDoctor);
      ref.invalidate(userProvider);

      if (mounted) {
        final stillIncomplete = await doctorController
            .requiresProfileCompletion();

        if (!mounted) return;

        if (stillIncomplete) {
          setState(() {
            errorText =
                'Your price and description could not be saved. Please try again.';
          });
          ToastService.instance.showError(
            'Please complete your price and description',
          );
          return;
        }

        ToastService.instance.showSuccess(
          'Doctor profile updated successfully!',
        );

        await Future.delayed(const Duration(milliseconds: 400));

        if (mounted) {
          if (Navigator.of(context).canPop()) {
            Navigator.pop(context, true);
          } else {
            Navigator.pushAndRemoveUntil(
              context,
              MaterialPageRoute(
                builder: (context) => const DoctorPortalWrapper(),
              ),
              (route) => false,
            );
          }
        }
      }
    } catch (e) {
      ToastService.instance.showError(
        'Error updating profile: ${e.toString()}',
      );
      setState(() {
        errorText = 'An unexpected error occurred: ${e.toString()}';
      });
    } finally {
      if (mounted) {
        setState(() {
          isUpdating = false;
        });
      }
    }
  }

  Future<void> _saveUpdatedDoctorToLocalStorage(UserModel doctor) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('current_doctor', json.encode(doctor.toMap()));
  }

  @override
  Widget build(BuildContext context) {
    final bool canPop = Navigator.of(context).canPop();

    return OpdScreenShell(
      title: canPop ? 'Manage Profile' : 'Complete Profile',
      subtitle: canPop
          ? 'Update your personal and professional details'
          : 'Please complete your profile to continue',
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

            // Card 1: Personal Information
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
                    hintText: 'Enter full name (e.g. Dr. John Doe)',
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

            const SizedBox(height: 16),

            // Card 2: Professional Information & Consultation Fee
            OpdCard(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Highest Qualification / Degree',
                    style: TextStyle(
                      fontSize: context.fs(13),
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFF1F2F44),
                    ),
                  ),
                  const SizedBox(height: 8),
                  MetallicInput(
                    hintText: 'e.g. MBBS, FCPS Cardiology, MD',
                    icon: Icons.school_outlined,
                    controller: degreeController,
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) {
                        return 'Qualification/Degree is required';
                      }
                      return null;
                    },
                  ),

                  const SizedBox(height: 18),

                  Text(
                    'Consultation Fee (PKR)',
                    style: TextStyle(
                      fontSize: context.fs(13),
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFF1F2F44),
                    ),
                  ),
                  const SizedBox(height: 8),
                  MetallicInput(
                    hintText: 'Enter fee in PKR (e.g. 1500)',
                    icon: Icons.payments_outlined,
                    controller: feeController,
                    keyboardType: TextInputType.number,
                    validator: _validateFee,
                  ),

                  const SizedBox(height: 18),

                  DoctorLanguageSelector(
                    label: 'Consultation Languages',
                    selected: _selectedLanguages,
                    onChanged: (value) {
                      setState(() {
                        _selectedLanguages = value;
                      });
                    },
                    helperText: _selectedLanguages.isEmpty
                        ? 'Select the languages you communicate in with patients.'
                        : 'Tap a language again to remove it.',
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // Card 3: Bio & Introduction Link
            OpdCard(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Professional Summary / Bio',
                    style: TextStyle(
                      fontSize: context.fs(13),
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFF1F2F44),
                    ),
                  ),
                  const SizedBox(height: 8),
                  MetallicInput(
                    hintText:
                        'Tell patients about your medical background, clinical experience, and clinical expertise...',
                    icon: Icons.description_outlined,
                    controller: descriptionController,
                    maxLines: 4,
                    minLines: 3,
                    validator: _validateDescription,
                  ),

                  const SizedBox(height: 18),

                  Text(
                    'YouTube Introduction Video (Optional)',
                    style: TextStyle(
                      fontSize: context.fs(13),
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFF1F2F44),
                    ),
                  ),
                  const SizedBox(height: 8),
                  MetallicInput(
                    hintText: 'https://youtube.com/watch?v=...',
                    icon: Icons.video_library_outlined,
                    controller: videoUrlController,
                    validator: _validateVideoUrl,
                  ),
                ],
              ),
            ),

            if (errorText.isNotEmpty) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.red.withValues(alpha: 0.25)),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.error_outline_rounded,
                      color: Colors.red,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        errorText,
                        style: TextStyle(
                          fontSize: context.fs(12.5),
                          color: Colors.red[800],
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 28),

            GradientButton(
              text: isUpdating ? 'Saving...' : 'Save Changes',
              icon: isUpdating ? null : Icons.check_circle_outline_rounded,
              onPressed: isUpdating ? null : _updateDoctorProfile,
            ),

            const SizedBox(height: 24),
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
    if (existingImageUrl != null && existingImageUrl!.trim().isNotEmpty) {
      return Image.network(
        existingImageUrl!,
        fit: BoxFit.cover,
        width: 96,
        height: 96,
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
    final name = nameController.text.trim();
    final initial = name.isNotEmpty ? name[0].toUpperCase() : 'D';
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
