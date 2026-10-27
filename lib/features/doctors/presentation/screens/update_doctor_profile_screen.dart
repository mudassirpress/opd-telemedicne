// lib/features/doctors/presentation/screens/update_doctor_profile_screen.dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:telemedicine/features/auth/presentation/providers/user_provider.dart';
import 'package:telemedicine/core/services/firebase_storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:telemedicine/data/models/user_model.dart';
import 'package:telemedicine/features/auth/presentation/screens/sign_in_screen.dart';
import 'package:telemedicine/features/auth/presentation/controllers/doctor_controller.dart';
import 'package:telemedicine/features/doctor_portal/presentation/bottom_nav/doctor_portal_wrapper.dart';

import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/app/theme/app_theme.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/features/appointments/presentation/appointment_controller.dart';
import 'package:telemedicine/shared/widgets/custom_text_field.dart';
import 'package:telemedicine/shared/widgets/language_field.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class UpdateDoctorProfileScreen extends ConsumerStatefulWidget {
  const UpdateDoctorProfileScreen({super.key});

  @override
  ConsumerState<UpdateDoctorProfileScreen> createState() =>
      _UpdateDoctorProfileScreenState();
}

class _UpdateDoctorProfileScreenState
    extends ConsumerState<UpdateDoctorProfileScreen> {
  final TextEditingController nameController = TextEditingController();
  final TextEditingController degreeController = TextEditingController();

  /// Appointment booking fields — the fee is what the patient is charged and
  /// the video URL is what gates the 30% discount.
  final TextEditingController feeController = TextEditingController();
  final TextEditingController descriptionController = TextEditingController();
  final TextEditingController videoUrlController = TextEditingController();

  File? selectedImage;
  bool isUploading = false;
  String errorText = '';
  bool isUpdating = false; // Changed from isCreatingProfile
  String? existingImageUrl;
  bool _isImageRemoved = false;

  final _formKey = GlobalKey<FormState>();
  final ImagePicker _picker = ImagePicker();

  /// Languages the doctor has selected on this form. Seeded from the saved
  /// profile so re-opening the screen never shows a blank picker.
  List<String> _selectedLanguages = <String>[];

  /// Price / description / video link exactly as they exist on the doctor
  /// document right now, `null` when the document has never carried the field.
  ///
  /// Used to write only what actually changed: an old doctor who leaves the
  /// Description box blank must not stamp `''` over a value saved elsewhere,
  /// and an untouched blank stays *missing* rather than becoming empty text.
  double _savedPrice = 0;
  String? _savedDescription;
  String? _savedVideoUrl;

  @override
  void initState() {
    super.initState();
    _loadExistingDoctorData();
  }

  /// Seeds the form from the doctor's Firestore document, falling back to the
  /// cached session when the document cannot be read.
  ///
  /// The document is the source of truth: an old session may predate the
  /// `price` / `description` fields, and seeding empty boxes from it would
  /// then let a plain *Save* wipe values the doctor already entered.
  /// Documents that never had the fields seed blank boxes, so the doctor can
  /// add them right here.
  Future<void> _loadExistingDoctorData() async {
    final doctorController = ref.read(doctorControllerProvider);
    final currentDoctor = doctorController.currentDoctor;
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
        // Offline or unreadable: the cached session below still fills the
        // form, and saving later re-checks the same document.
        document = null;
      }
    }
    if (!mounted) return;

    final data = document ?? <String, dynamic>{};

    final name = (data['fullname'] ?? currentDoctor.fullname).toString().trim();
    if (name.isNotEmpty) nameController.text = name;

    final degree = (data['highestDegree'] ?? currentDoctor.highestDegree ?? '')
        .toString()
        .trim();
    if (degree.isNotEmpty) degreeController.text = degree;

    final image =
        (data['imageUrl'] ?? data['image'] ?? currentDoctor.image ?? '')
            .toString()
            .trim();
    if (image.isNotEmpty) existingImageUrl = image;

    // ── Price ──
    // `price` first, the legacy `consultationFee` second; a document with
    // neither (created before either field existed) seeds an empty box, which
    // the validator then makes the doctor fill in.
    _savedPrice =
        _parsePrice(data['price']) ?? _parsePrice(data['consultationFee']) ?? 0;
    if (_savedPrice <= 0 && document == null) {
      _savedPrice = currentDoctor.consultationPrice;
    }
    if (_savedPrice > 0) {
      feeController.text = _savedPrice.toStringAsFixed(0);
    }

    // ── Description / intro video ──
    // `null` means "the document does not have the field", which is different
    // from a value the doctor deliberately cleared.
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

    // The seed now lands after the first frame, so rebuild — the text fields
    // track their controllers on their own, but the language chips and the
    // profile-picture preview read state straight from this widget.
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

  @override
  void dispose() {
    nameController.dispose();
    degreeController.dispose();
    feeController.dispose();
    descriptionController.dispose();
    videoUrlController.dispose();
    super.dispose();
  }

  /// Empty is allowed (no intro video), but anything typed must be a real
  /// YouTube link — the same check the patient's booking screen applies.
  String? _validateVideoUrl(String? value) {
    final url = (value ?? '').trim();
    if (url.isEmpty) return null;
    if (AppointmentController.isUsableYoutubeUrl(url)) return null;
    return 'Enter a valid YouTube link, or leave it blank';
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

  /// Required, like the price: this screen is where the login/app-open gate
  /// sends doctors whose profile is missing one of the two fields, so a
  /// blank box must not slip past the form only to fail the verification
  /// that runs after the save.
  String? _validateDescription(String? value) {
    if ((value ?? '').trim().isEmpty) {
      return 'Please add a short description about yourself';
    }
    return null;
  }

  Future<String?> _uploadImage(File imageFile) async {
    try {
      final currentUser = ref.read(userProvider);
      final doctorUid = currentUser?.id ?? 'temp_doctor';
      final result = await FirebaseStorageService.instance
          .uploadDoctorProfileImage(doctorUid: doctorUid, file: imageFile);

      ToastService.instance.showSuccess('Image uploaded successfully');
      return result.downloadUrl;
    } catch (e) {
      ToastService.instance.showError(
        'Failed to upload image: ${e.toString()}',
      );
      setState(() {
        errorText = 'Failed to upload image. Please try again.';
      });
      return null;
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      setState(() {
        isUploading = true;
        errorText = '';
      });

      final XFile? pickedFile = await _picker.pickImage(
        source: source,
        imageQuality: 80,
      );

      if (pickedFile != null) {
        setState(() {
          selectedImage = File(pickedFile.path);
          existingImageUrl = null; // Clear existing URL since we have new image
        });
        ToastService.instance.showSuccess('Image selected successfully');
      }
    } catch (e) {
      setState(() {
        errorText = 'Failed to pick image. Please try again.';
      });
      ToastService.instance.showError('Failed to pick image');
    } finally {
      setState(() {
        isUploading = false;
      });
    }
  }

  Future<void> _confirmRemovePhoto() async {
    final bool? shouldRemove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          'Remove Profile Picture',
          style: TextStyle(
            fontSize: context.fs(16),
            fontWeight: FontWeight.w700,
            color: Colors.grey[800],
          ),
        ),
        content: Text(
          'Are you sure you want to remove your profile picture?',
          style: TextStyle(fontSize: context.fs(13.5), color: Colors.grey[600]),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancel', style: TextStyle(color: Colors.grey[600])),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(
              'Remove',
              style: TextStyle(fontWeight: FontWeight.w600, color: Colors.red),
            ),
          ),
        ],
      ),
    );

    if (shouldRemove == true) {
      // Bust image cache immediately so the default avatar appears instantly
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      setState(() {
        selectedImage = null;
        existingImageUrl = null;
        _isImageRemoved = true;
      });
      ToastService.instance.showInfo('Image removed');
    }
  }

  void _showImageSourceDialog() {
    final hasPhoto =
        selectedImage != null ||
        (existingImageUrl != null && existingImageUrl!.isNotEmpty);

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
                  'Update Profile Picture',
                  style: TextStyle(
                    fontSize: context.fs(15),
                    fontWeight: FontWeight.bold,
                    color: Colors.grey[800],
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _buildImageSourceOption(
                      icon: Icons.camera_alt,
                      label: 'Camera',
                      onTap: () {
                        Navigator.pop(context);
                        _pickImage(ImageSource.camera);
                      },
                    ),
                    _buildImageSourceOption(
                      icon: Icons.photo_library,
                      label: 'Gallery',
                      onTap: () {
                        Navigator.pop(context);
                        _pickImage(ImageSource.gallery);
                      },
                    ),
                    if (hasPhoto)
                      _buildImageSourceOption(
                        icon: Icons.delete_outline,
                        label: 'Remove',
                        iconColor: Colors.red,
                        onTap: () {
                          Navigator.pop(context);
                          _confirmRemovePhoto();
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildImageSourceOption({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color? iconColor,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.grey[50],
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey[200]!),
        ),
        child: Column(
          children: [
            Icon(icon, size: 32, color: iconColor ?? AppColors.primaryRed),
            const SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(
                color: iconColor ?? Colors.grey[700],
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // NEW METHOD: Update existing doctor profile instead of creating new one
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

      // Upload new image if selected
      if (selectedImage != null) {
        ToastService.instance.showInfo('Uploading image...');
        final uploadedUrl = await _uploadImage(selectedImage!);
        if (uploadedUrl != null) {
          imageUrl = uploadedUrl;
          _isImageRemoved = false;
        } else if (mounted) {
          setState(() {
            errorText = 'Failed to upload image. Please try again.';
            isUpdating = false;
          });
          return;
        }
      }

      // UPDATE — a partial update on the existing document id. Only the keys
      // below are written, so everything else on the record (payment status,
      // online state, timestamps, ratings, …) is preserved, and a document
      // can never be created twice for the same doctor.
      final firestore = FirebaseFirestore.instance;
      final fee = double.parse(feeController.text.trim());
      final description = descriptionController.text.trim();
      final videoUrl = videoUrlController.text.trim();

      final bool isRemovingImage = _isImageRemoved && selectedImage == null;

      final updates = <String, dynamic>{
        'fullname': nameController.text.trim(),
        'highestDegree': degreeController.text.trim(),
        // Price is written to both spellings: `price` is the field every
        // reader prefers now, `consultationFee` is what older builds of the
        // app read. This is how a document created before `price` existed
        // gains it.
        'price': fee,
        'consultationFee': fee,
        'imageUrl': imageUrl,
        'image': imageUrl,
        'profile_image':
            imageUrl, // Explicit null when removed, never string "null"
        if (isRemovingImage) 'remove_profile_image': true,
        DoctorLanguages.field: List<String>.from(_selectedLanguages),
        'updatedAt': FieldValue.serverTimestamp(),
      };

      // Description and the intro link are written only when the doctor
      // actually changed them. Leaving a blank box blank must not stamp an
      // empty value over anything — and clearing a value that was set still
      // writes `''`, because that is an intentional edit.
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

      // Copy rather than reconstruct: the previous field-by-field rebuild left
      // out every field it did not enumerate, so saving here wiped them from
      // the local session.
      final updatedDoctor = currentDoctor.copyWith(
        fullname: nameController.text.trim(),
        highestDegree: degreeController.text.trim(),
        image: imageUrl,
        clearImage: isRemovingImage,
        languages: _selectedLanguages,
        price: fee,
        consultationFee: fee,
        description: description,
        youtubeVideoUrl: videoUrl,
      );

      _isImageRemoved = false;

      // The next save must compare against what was just written, not against
      // the values this screen was opened with.
      _savedPrice = fee;
      _savedDescription = description;
      _savedVideoUrl = videoUrl;

      // Update the controller
      doctorController.updateDoctor(updatedDoctor);

      // Save to local storage
      await _saveUpdatedDoctorToLocalStorage(updatedDoctor);

      if (mounted) {
        // Refresh + verify before the portal is allowed to open: re-read the
        // document and run the same predicate the login / app-open gate uses,
        // so the doctor is only released once `price` and `description` are
        // really back on the record.
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

        // Show success message
        ToastService.instance.showSuccess(
          'Doctor profile updated successfully!',
        );

        // Navigate to doctor portal after a short delay
        await Future.delayed(const Duration(milliseconds: 500));

        if (mounted) {
          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute(
              builder: (context) => const DoctorPortalWrapper(),
            ),
            (route) => false,
          );
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
    final size = MediaQuery.of(context).size;
    final safeAreaPadding = MediaQuery.of(context).padding;
    final double maxWidth = size.width > 500 ? 500 : size.width;

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Container(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Stack(
            children: [
              // Background Decorative Elements
              Positioned(
                top: -size.height * 0.10,
                right: -size.width * 0.20,
                child: Container(
                  width: size.width * 0.6,
                  height: size.width * 0.6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: [
                        AppColors.primaryRed.withOpacity(0.1),
                        AppColors.primaryRed.withOpacity(0.05),
                      ],
                      begin: Alignment.topRight,
                      end: Alignment.bottomLeft,
                    ),
                  ),
                  child: Icon(
                    CupertinoIcons.person_circle,
                    size: 150,
                    color: AppColors.primaryRed.withOpacity(0.08),
                  ),
                ),
              ),

              // Main Content
              SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: CenteredContent(
                  child: Padding(
                    padding: EdgeInsets.only(
                      left: context.rsp(20),
                      right: context.rsp(20),
                      top: safeAreaPadding.top > 0 ? safeAreaPadding.top : 20,
                      bottom: safeAreaPadding.bottom > 0
                          ? safeAreaPadding.bottom + 20
                          : 20,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Back Button with Title
                        Container(
                          margin: const EdgeInsets.only(top: 10, bottom: 10),
                          child: Row(
                            children: [
                              IconButton(
                                onPressed: () {
                                  // Login and app-open push this screen with an
                                  // empty stack behind it, so a plain pop would
                                  // leave a blank route — fall back to the
                                  // sign-in screen while the session is kept.
                                  if (Navigator.of(context).canPop()) {
                                    ToastService.instance.showInfo(
                                      'Going back',
                                    );
                                    Navigator.pop(context);
                                  } else {
                                    Navigator.of(context).pushAndRemoveUntil(
                                      MaterialPageRoute(
                                        builder: (context) =>
                                            const SignInScreen(),
                                      ),
                                      (route) => false,
                                    );
                                  }
                                },
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                                icon: Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: Colors.grey[100],
                                  ),
                                  child: Icon(
                                    Icons.arrow_back_rounded,
                                    color: AppColors.primaryRed,
                                    size: 24,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Text(
                                  'Complete Doctor Profile',
                                  style: TextStyle(
                                    fontSize: context.fs(20),
                                    fontWeight: FontWeight.bold,
                                    color: Colors.grey[800],
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),

                        Padding(
                          padding: const EdgeInsets.only(left: 65, bottom: 30),
                          child: Text(
                            'Please complete your profile to continue',
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.grey[600],
                              height: 1.5,
                            ),
                          ),
                        ),

                        // Profile Picture Section
                        Center(
                          child: Column(
                            children: [
                              if (selectedImage != null ||
                                  existingImageUrl != null)
                                Container(
                                  height: 130,
                                  width: 130,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: AppColors.primaryRed,
                                      width: 3,
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: AppColors.shadowMedium,
                                        blurRadius: 15,
                                        offset: const Offset(0, 5),
                                      ),
                                    ],
                                  ),
                                  child: ClipOval(
                                    child: selectedImage != null
                                        ? Image.file(
                                            selectedImage!,
                                            fit: BoxFit.cover,
                                            width: 130,
                                            height: 130,
                                          )
                                        : (existingImageUrl != null &&
                                                  existingImageUrl!.isNotEmpty
                                              ? Image.network(
                                                  existingImageUrl!,
                                                  fit: BoxFit.cover,
                                                  width: 130,
                                                  height: 130,
                                                  errorBuilder:
                                                      (
                                                        context,
                                                        error,
                                                        stackTrace,
                                                      ) {
                                                        return Icon(
                                                          Icons.person,
                                                          size: 50,
                                                          color:
                                                              Colors.grey[400],
                                                        );
                                                      },
                                                )
                                              : Container()),
                                  ),
                                ),
                              const SizedBox(height: 16),
                              Row(
                                children: [
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      onPressed: isUploading
                                          ? null
                                          : _showImageSourceDialog,
                                      icon: const Icon(
                                        Icons.camera_alt,
                                        size: 18,
                                      ),
                                      label: const Text('Update Photo'),
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: AppColors.primaryRed,
                                        side: BorderSide(
                                          color: AppColors.primaryRed,
                                        ),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            10,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  if (selectedImage != null ||
                                      existingImageUrl != null)
                                    const SizedBox(width: 12),
                                  if (selectedImage != null ||
                                      existingImageUrl != null)
                                    Expanded(
                                      child: OutlinedButton.icon(
                                        onPressed: _confirmRemovePhoto,
                                        icon: const Icon(
                                          Icons.delete,
                                          size: 18,
                                        ),
                                        label: const Text('Remove'),
                                        style: OutlinedButton.styleFrom(
                                          foregroundColor: Colors.red,
                                          side: const BorderSide(
                                            color: Colors.red,
                                          ),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              10,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 30),

                        // Form Fields
                        Form(
                          key: _formKey,
                          child: Column(
                            children: [
                              CustomTextField(
                                controller: nameController,
                                hintText: 'Dr. John Doe',
                                labelText: 'Full Name',
                                prefixIcon: Icons.person_outline,
                                fontSize: 14,
                                keyboardType: TextInputType.name,
                                validator: (value) {
                                  if (value == null || value.trim().isEmpty) {
                                    return 'Please enter your full name';
                                  }
                                  if (value.length < 2) {
                                    return 'Name must be at least 2 characters';
                                  }
                                  return null;
                                },
                              ),
                              const SizedBox(height: 16),
                              CustomTextField(
                                controller: degreeController,
                                hintText: 'MBBS, FCPS',
                                labelText: 'Degree / Credential',
                                prefixIcon: Icons.school_outlined,
                                fontSize: 14,
                                keyboardType: TextInputType.text,
                                validator: (value) {
                                  if (value == null || value.trim().isEmpty) {
                                    return 'Please enter your degree/credential';
                                  }
                                  return null;
                                },
                              ),
                              const SizedBox(height: 22),
                              Container(
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: const Color(0xFFDCE6F2),
                                  ),
                                ),
                                child: DoctorLanguageSelector(
                                  label: 'Languages',
                                  selected: _selectedLanguages,
                                  onChanged: (value) {
                                    setState(() {
                                      _selectedLanguages = value;
                                    });
                                  },
                                  helperText: _selectedLanguages.isEmpty
                                      ? 'Optional — no languages selected yet.'
                                      : 'Tap a language again to remove it.',
                                ),
                              ),
                              const SizedBox(height: 22),

                              // ── Appointment booking fields ──
                              Text(
                                'Appointment Booking',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.grey[800],
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Patients pay this price before requesting an '
                                'appointment. The optional YouTube introduction '
                                'unlocks a 30% discount once they watch it.',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey[600],
                                  height: 1.45,
                                ),
                              ),
                              const SizedBox(height: 16),
                              CustomTextField(
                                controller: feeController,
                                hintText: '1500',
                                labelText: 'Price / Consultation Fee (PKR) *',
                                prefixIcon: Icons.payments_outlined,
                                fontSize: 14,
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                validator: _validateFee,
                              ),
                              const SizedBox(height: 16),
                              CustomTextField(
                                controller: descriptionController,
                                hintText:
                                    'Cardiologist with 12 years of experience',
                                labelText: 'About / Description *',
                                prefixIcon: Icons.notes_outlined,
                                fontSize: 14,
                                keyboardType: TextInputType.text,
                                validator: _validateDescription,
                              ),
                              const SizedBox(height: 16),
                              CustomTextField(
                                controller: videoUrlController,
                                hintText: 'https://www.youtube.com/watch?v=...',
                                labelText: 'YouTube Introduction (optional)',
                                prefixIcon: Icons.ondemand_video_outlined,
                                fontSize: 14,
                                keyboardType: TextInputType.url,
                                validator: _validateVideoUrl,
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 20),

                        if (errorText.isNotEmpty)
                          Container(
                            margin: const EdgeInsets.only(bottom: 16),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.red[50],
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.error_outline,
                                  color: Colors.red,
                                  size: 20,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    errorText,
                                    style: TextStyle(
                                      color: Colors.red,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),

                        // Save/Update Button
                        SizedBox(
                          width: double.infinity,
                          height: 50,
                          child: ElevatedButton(
                            onPressed: (isUploading || isUpdating)
                                ? null
                                : _updateDoctorProfile,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.primaryRed,
                              foregroundColor: Colors.white,
                              elevation: 0,
                              shadowColor: Colors.transparent,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: (isUploading || isUpdating)
                                ? const SizedBox(
                                    width: 24,
                                    height: 24,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Text(
                                        'Save Profile',
                                        style: TextStyle(
                                          fontSize: context.fs(14),
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      const Icon(Icons.save_rounded, size: 20),
                                    ],
                                  ),
                          ),
                        ),

                        const SizedBox(height: 30),
                      ],
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
}
