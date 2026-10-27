import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/core/services/firebase_storage_service.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:telemedicine/data/models/user_model.dart';
import 'package:telemedicine/features/auth/presentation/providers/user_provider.dart';
import 'package:telemedicine/features/auth/presentation/controllers/doctor_controller.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/shared/widgets/auth_layout.dart';
import 'package:telemedicine/shared/widgets/language_field.dart';
import 'package:telemedicine/features/auth/presentation/screens/sign_in_screen.dart';

class DoctorProfileScreen extends ConsumerStatefulWidget {
  const DoctorProfileScreen({super.key});

  @override
  ConsumerState<DoctorProfileScreen> createState() =>
      _DoctorProfileScreenState();
}

class _DoctorProfileScreenState extends ConsumerState<DoctorProfileScreen> {
  final TextEditingController nameController = TextEditingController();
  final TextEditingController highestDegreeController = TextEditingController();

  /// The two fields patients read on the doctor detail screen before booking:
  /// what the consultation costs and who the doctor is.
  final TextEditingController priceController = TextEditingController();
  final TextEditingController descriptionController = TextEditingController();

  File? selectedImage;
  bool isUploading = false;
  bool isSaving = false;
  String errorText = '';
  String? currentImageUrl;
  bool _isImageRemoved = false;
  bool isOnline = false;

  /// Price / description exactly as stored on the document when the screen
  /// opened. `null` description means the document never carried the field —
  /// a blank box that was never touched must not be saved as `''`.
  double _savedPrice = 0;
  String? _savedDescription;

  /// Languages currently shown in the picker.
  List<String> _selectedLanguages = <String>[];

  /// Set once the doctor touches the picker. A live Firestore snapshot then
  /// stops overwriting the chips, so a background update cannot silently undo
  /// a selection that has not been saved yet. Cleared on save and whenever the
  /// doctor loads a genuinely different value from the server.
  bool _languagesDirty = false;

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>?
      _doctorProfileSub;

  final _formKey = GlobalKey<FormState>();
  final ImagePicker _picker = ImagePicker();



  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadDoctorData();
      _loadOnlineStatus();
      _listenToDoctorProfile();
    });
  }

  @override
  void dispose() {
    _doctorProfileSub?.cancel();
    nameController.dispose();
    highestDegreeController.dispose();
    priceController.dispose();
    descriptionController.dispose();
    super.dispose();
  }

  void _loadDoctorData() {
    final doctor = ref.read(doctorControllerProvider).currentDoctor;
    if (doctor != null) {
      nameController.text = doctor.fullname;
      highestDegreeController.text = doctor.highestDegree ?? '';
      currentImageUrl = doctor.image;
      _selectedLanguages = List<String>.of(doctor.languages);
      _languagesDirty = false;

      // `0` / `null` is the normal state for a doctor created before these
      // fields existed: the boxes simply start empty so they can be filled in.
      _savedPrice = doctor.consultationPrice;
      if (_savedPrice > 0) {
        priceController.text = _savedPrice.toStringAsFixed(0);
      }
      _savedDescription = doctor.description;
      descriptionController.text = doctor.description ?? '';
    }
  }

  /// Applies a live snapshot of the doctor's own document to the picker.
  ///
  /// Ignored while [_languagesDirty] so an unsaved edit is not clobbered.
  /// Driven by a subscription rather than a `StreamBuilder` because the sync
  /// calls `setState`, which is illegal during a build.
  void _syncLanguagesFromSnapshot(Map<String, dynamic>? data) {
    if (data == null || _languagesDirty) return;
    final incoming = DoctorLanguages.parse(
      data[DoctorLanguages.field] ?? data[DoctorLanguages.legacyField],
    );
    if (_sameLanguages(incoming, _selectedLanguages)) return;
    if (!mounted) return;
    setState(() {
      _selectedLanguages = incoming;
    });
  }

  /// Watches the doctor's own document so the Languages section always shows
  /// the latest committed value — e.g. after an edit made on another device,
  /// or right after [UpdateDoctorProfileScreen] writes it.
  void _listenToDoctorProfile() {
    final doctor = ref.read(doctorControllerProvider).currentDoctor;
    if (doctor == null || doctor.id.isEmpty) return;

    _doctorProfileSub?.cancel();
    _doctorProfileSub = FirebaseFirestore.instance
        .collection('telemedicine_doctors')
        .doc(doctor.id)
        .snapshots()
        .listen(
          (snapshot) => _syncLanguagesFromSnapshot(snapshot.data()),
          // A failed listener must not break the screen: the cached session
          // value loaded in `_loadDoctorData` remains on screen.
          onError: (_) {},
        );
  }

  static bool _sameLanguages(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _onLanguagesChanged(List<String> value) {
    setState(() {
      _selectedLanguages = value;
      _languagesDirty = true;
    });
  }

  void _loadOnlineStatus() {
    final doctorController = ref.read(doctorControllerProvider);
    setState(() {
      isOnline = doctorController.isDoctorOnline;
    });
  }

  Future<String?> _uploadImage(File imageFile) async {
    try {
      final currentUser = ref.read(userProvider);
      final doctorUid = currentUser?.id ?? 'temp_doctor';
      final result =
          await FirebaseStorageService.instance.uploadDoctorProfileImage(
        doctorUid: doctorUid,
        file: imageFile,
      );
      ToastService.instance.showSuccess('Image uploaded');
      return result.downloadUrl;
    } catch (e) {
      ToastService.instance.showError('Upload failed: ${e.toString()}');
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
        });
      }
    } catch (e) {
      setState(() {
        errorText = 'Failed to pick image';
      });
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
            color: const Color(0xFF1F2F44),
          ),
        ),
        content: Text(
          'Are you sure you want to remove your profile picture?',
          style: TextStyle(
            fontSize: context.fs(13.5),
            color: const Color(0xFF6B7B8D),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(
              'Cancel',
              style: TextStyle(
                color: const Color(0xFF6B7B8D),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(
              'Remove',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: Colors.red,
              ),
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
        currentImageUrl = null;
        _isImageRemoved = true;
      });
      ToastService.instance.showInfo('Profile picture removed');
    }
  }

  void _showImageSourceDialog() {
    final hasPhoto = selectedImage != null ||
        (currentImageUrl != null && currentImageUrl!.isNotEmpty);

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (BuildContext context) {
        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFD6E4F0),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    'Profile Picture',
                    style: TextStyle(
                      fontSize: context.fs(15),
                      fontWeight: FontWeight.w700,
                      color: const Color(0xFF1F2F44),
                    ),
                  ),
                ),
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
                  title: Text(
                    'Take Photo',
                    style: TextStyle(
                      color: const Color(0xFF1F2F44),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  onTap: () {
                    Navigator.pop(context);
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
                  title: Text(
                    'Choose from Gallery',
                    style: TextStyle(
                      color: const Color(0xFF1F2F44),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    _pickImage(ImageSource.gallery);
                  },
                ),
                if (hasPhoto)
                  ListTile(
                    leading: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFEBEE),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(
                        Icons.delete_outline_rounded,
                        color: Colors.red,
                      ),
                    ),
                    title: Text(
                      'Remove Photo',
                      style: TextStyle(
                        color: Colors.red,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    onTap: () {
                      Navigator.pop(context);
                      _confirmRemovePhoto();
                    },
                  ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _toggleOnlineStatus() async {
    final doctorController = ref.read(doctorControllerProvider);
    final targetStatus = !isOnline;

    if (targetStatus) {
      ToastService.instance.showInfo('Verifying network reachability...');
    }

    final success = await doctorController.updateDoctorPresence(targetStatus);

    if (mounted) {
      setState(() {
        isOnline = doctorController.isDoctorOnline;
      });

      if (success) {
        if (targetStatus) {
          ToastService.instance.showSuccess('You are now online and ready for calls');
        } else {
          ToastService.instance.showInfo('You are now offline');
        }
      } else {
        if (targetStatus) {
          ToastService.instance.showWarning(
            'Unable to go online: Active internet connection or data package not detected.',
          );
        }
      }
    }
  }

  Future<void> _saveProfile() async {
    if (!_formKey.currentState!.validate()) return;

    // Price is optional here: a doctor who never set one can still fix their
    // name or degree. Anything typed must be a real amount, because the
    // booking flow refuses to charge `0`.
    final rawPrice = priceController.text.trim();
    double? price;
    if (rawPrice.isNotEmpty) {
      price = double.tryParse(rawPrice);
      if (price == null || price <= 0 || price > 1000000) {
        setState(() {
          errorText = 'Enter a valid consultation price (greater than 0)';
        });
        ToastService.instance.showError('Enter a valid consultation price');
        return;
      }
    }

    // Written only when it actually differs, so a blank box on an old profile
    // cannot stamp `''` over a description that is already stored.
    final description = descriptionController.text.trim();
    final descriptionChanged = description != (_savedDescription ?? '').trim();

    final doctorController = ref.read(doctorControllerProvider);
    final currentDoctor = doctorController.currentDoctor;

    if (currentDoctor == null) {
      ToastService.instance.showError('No doctor logged in');
      return;
    }

    setState(() {
      isSaving = true;
      errorText = '';
    });

    try {
      String? uploadedImageUrl = _isImageRemoved ? null : currentImageUrl;

      if (selectedImage != null) {
        ToastService.instance.showInfo('Uploading...');
        final uploadedUrl = await _uploadImage(selectedImage!);
        if (!mounted) return;
        if (uploadedUrl != null) {
          uploadedImageUrl = uploadedUrl;
          _isImageRemoved = false;
        } else {
          throw Exception('Failed to upload image');
        }
      }

      final bool isRemovingImage = _isImageRemoved && selectedImage == null;

      final updateData = {
        'fullname': nameController.text.trim(),
        'highestDegree': highestDegreeController.text.trim(),
        'imageUrl': uploadedImageUrl,
        'image': uploadedImageUrl,
        'profile_image': uploadedImageUrl, // Explicit null when removed, never string "null"
        if (isRemovingImage) 'remove_profile_image': true,
        // A plain list: `DoctorLanguages.parse` hands back an unmodifiable
        // view, which is fine for the model but not something to hand to the
        // Firestore encoder.
        DoctorLanguages.field: List<String>.from(_selectedLanguages),
        if (price != null) ...{
          // Both spellings: `price` is what the app reads now, the legacy key
          // keeps older builds and hand-written queries working.
          'price': price,
          'consultationFee': price,
        },
        if (descriptionChanged) 'description': description,
        'updatedAt': FieldValue.serverTimestamp(),
      };

      await FirebaseFirestore.instance
          .collection('telemedicine_doctors')
          .doc(currentDoctor.id)
          .update(updateData);
      if (!mounted) return;

      if (isRemovingImage) {
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();
      }

      // Copy instead of rebuilding field-by-field: the old reconstruction left
      // out `paymentStatus`, `isDeleted`, `age`, `gender`, `expiryDate` and the
      // rest, so every save was silently wiping them from the local session.
      final updatedDoctor = currentDoctor.copyWith(
        fullname: nameController.text.trim(),
        highestDegree: highestDegreeController.text.trim(),
        image: uploadedImageUrl,
        clearImage: isRemovingImage,
        languages: _selectedLanguages,
        price: price,
        consultationFee: price,
        description: descriptionChanged ? description : null,
      );

      if (price != null) {
        _savedPrice = price;
      }
      if (descriptionChanged) {
        _savedDescription = description;
      }

      await _saveDoctorToLocalStorage(updatedDoctor);
      if (!mounted) return;
      doctorController.updateDoctor(updatedDoctor);

      _isImageRemoved = false;
      currentImageUrl = uploadedImageUrl;
      _languagesDirty = false;
      ref.invalidate(userProvider);

      ToastService.instance.showSuccess('Profile updated!');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Row(
            children: [
              Icon(Icons.check_circle_outline, color: Colors.white, size: 20),
              SizedBox(width: 8),
              Text('Profile updated successfully!'),
            ],
          ),
          backgroundColor: Color(0xFF2E7D32),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 3),
        ),
      );

      // Safe navigation: If embedded in DoctorPortalWrapper (bottom nav), popping
      // would pop the root portal wrapper and leave an empty black screen.
      // Only pop if this screen was pushed onto an existing route stack.
      if (Navigator.of(context).canPop()) {
        Navigator.pop(context, true);
      } else {
        // Refresh local state without popping
        setState(() {
          currentImageUrl = uploadedImageUrl;
          selectedImage = null;
        });
      }
    } catch (e) {
      if (!mounted) return;
      ToastService.instance.showError('Update failed');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.error_outline, color: Colors.white, size: 20),
              const SizedBox(width: 8),
              Expanded(child: Text('Update failed: ${e.toString()}')),
            ],
          ),
          backgroundColor: const Color(0xFFD32F2F),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          isSaving = false;
        });
      }
    }
  }

  Future<void> _saveDoctorToLocalStorage(UserModel doctor) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('current_doctor', json.encode(doctor.toMap()));
  }

  Future<void> _logout() async {
    final shouldLogout = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          'Logout',
          style: TextStyle(
            fontSize: context.fs(15),
            fontWeight: FontWeight.w700,
            color: const Color(0xFF1F2F44),
          ),
        ),
        content: Text(
          'Are you sure you want to logout?',
          style: TextStyle(
            fontSize: context.fs(13),
            color: const Color(0xFF6B7B8D),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text(
              'Cancel',
              style: TextStyle(
                color: Color(0xFF6B7B8D),
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text(
              'Logout',
              style: TextStyle(fontWeight: FontWeight.w600),
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
      builder: (context) => const Center(
        child: CircularProgressIndicator(color: Color(0xFF062B72)),
      ),
    );

    try {
      final doctorController = ref.read(doctorControllerProvider);
      try {
        if (doctorController.currentDoctor != null) {
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
        }
      } catch (_) {}

      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('current_doctor');
      await doctorController.signOut();

      ToastService.instance.showSuccess('Logged out successfully');
      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (context) => const SignInScreen()),
          (route) => false,
        );
      }
    } catch (e) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('current_doctor');
      ToastService.instance.showSuccess('Logged out');
      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (context) => const SignInScreen()),
          (route) => false,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final doctorController = ref.watch(doctorControllerProvider);
    final currentDoctor = doctorController.currentDoctor;

    if (currentDoctor == null) {
      // `_currentDoctor` is nulled by sign-out and by controller error paths,
      // and this screen is a live tab of the doctor portal — an unlabelled
      // spinner left the doctor staring at a blank screen with no way out.
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
              Text(
                'Session ended',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: const Color(0xFF1F2F44),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Please sign in again to manage your profile.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: const Color(0xFF657991),
                ),
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: () => Navigator.pushAndRemoveUntil(
                  context,
                  MaterialPageRoute(builder: (context) => const SignInScreen()),
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
            child: Column(
              children: [
                Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: context.rsp(20),
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Edit Profile',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: context.fs(16),
                            fontWeight: FontWeight.w700,
                            color: const Color(0xFF1F2F44),
                          ),
                        ),
                      ),
                      if (isSaving)
                        const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Color(0xFF062B72),
                          ),
                        )
                      else
                        GestureDetector(
                          onTap: _saveProfile,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                colors: [
                                  Color(0xFF284F85),
                                  Color(0xFF15386A),
                                  Color(0xFF0D264E),
                                  Color(0xFF081938),
                                ],
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                              ),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: const Color(0xFF132D56),
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFF0B2041)
                                      .withValues(alpha: 0.32),
                                  blurRadius: 12,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: Text(
                              'Save',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    padding: EdgeInsets.symmetric(
                      horizontal: context.rsp(20),
                      vertical: 8,
                    ),
                    child: CenteredContent(
                      child: Column(
                        children: [
                          const SizedBox(height: 8),
                          _buildAvatarSection(),
                          const SizedBox(height: 28),
                          Text(
                            'Doctor Information',
                            style: TextStyle(
                              fontSize: context.fs(20),
                              fontWeight: FontWeight.bold,
                              color: const Color(0xFF1F2F44),
                              letterSpacing: -0.5,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Update your professional details and profile picture.',
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w500,
                              color: const Color(0xFF657991),
                              height: 1.4,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 24),
                          _buildDoctorIdCard(currentDoctor),
                          const SizedBox(height: 24),
                          _buildOnlineStatusCard(),
                          const SizedBox(height: 24),
                          Form(
                            key: _formKey,
                            child: Column(
                              children: [
                                MetallicInput(
                                  hintText: 'Full Name',
                                  icon: Icons.person_rounded,
                                  controller: nameController,
                                  showLabel: true,
                                  labelText: 'Full Name',
                                  validator: (value) =>
                                      value?.trim().isEmpty ?? true
                                          ? 'Required'
                                          : null,
                                ),
                                const SizedBox(height: 16),
                                MetallicInput(
                                  hintText: 'Highest Degree',
                                  icon: Icons.school_rounded,
                                  controller: highestDegreeController,
                                  showLabel: true,
                                  labelText: 'Highest Degree',
                                ),
                                const SizedBox(height: 16),
                                MetallicInput(
                                  hintText: '1500',
                                  icon: Icons.payments_outlined,
                                  controller: priceController,
                                  showLabel: true,
                                  labelText: 'Price (PKR)',
                                  keyboardType: const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                                ),
                                const SizedBox(height: 16),
                                MetallicInput(
                                  hintText: 'Cardiologist with 12 years of experience',
                                  icon: Icons.notes_outlined,
                                  controller: descriptionController,
                                  showLabel: true,
                                  labelText: 'About / Description',
                                ),
                                const SizedBox(height: 22),
                                _buildLanguagesSection(),
                              ],
                            ),
                          ),
                          if (errorText.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 16),
                              child: Text(
                                errorText,
                                style: TextStyle(
                                  color: Colors.red,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          const SizedBox(height: 32),
                          _buildActionButtons(),
                          const SizedBox(height: 24),
                           
                        ],
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

  Widget _buildLanguagesSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFDCE6F2)),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF0F233C).withValues(alpha: 0.06),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF0F4FA),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.translate_rounded,
                      color: Color(0xFF062B72),
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Languages',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: const Color(0xFF1F2F44),
                          ),
                        ),
                        Text(
                          _selectedLanguages.isEmpty
                              ? 'None selected yet'
                              : '${_selectedLanguages.length} selected',
                          style: TextStyle(
                            fontSize: 12,
                            color: const Color(0xFF657991),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              DoctorLanguageSelector(
                selected: _selectedLanguages,
                onChanged: _onLanguagesChanged,
                helperText:
                    'Tap to add or remove a language. Patients see these on '
                    'your contact card in chat.',
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAvatarSection() {
    final hasPhoto = selectedImage != null ||
        (currentImageUrl != null && currentImageUrl!.isNotEmpty);

    final name = nameController.text.trim();
    final cleanName = name.replaceFirst(RegExp(r'^Dr\.?\s*', caseSensitive: false), '').trim();
    final initial = cleanName.isNotEmpty ? cleanName[0].toUpperCase() : (name.isNotEmpty ? name[0].toUpperCase() : 'D');

    return GestureDetector(
      onTap: _showImageSourceDialog,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 120,
            height: 120,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [
                  Color(0xFFE3EAF2),
                  Color(0xFFF5F8FC),
                  Color(0xFFE2E9F2),
                ],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFFBAC7D8), width: 1.5),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF0F233C).withValues(alpha: 0.08),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Color(0xFFF3F7FB),
                    Colors.white,
                    Color(0xFFF0F4F9),
                  ],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
                shape: BoxShape.circle,
              ),
              child: ClipOval(
                child: isUploading
                    ? const Center(
                        child: CircularProgressIndicator(
                          color: Color(0xFF062B72),
                        ),
                      )
                    : selectedImage != null
                        ? Image.file(selectedImage!, fit: BoxFit.cover)
                        : currentImageUrl != null &&
                                currentImageUrl!.isNotEmpty
                            ? Image.network(
                                currentImageUrl!,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => Center(
                                  child: Text(
                                    initial,
                                    style: TextStyle(
                                      fontSize: 44,
                                      fontWeight: FontWeight.bold,
                                      color: const Color(0xFF15386A),
                                    ),
                                  ),
                                ),
                              )
                            : Center(
                                child: Text(
                                  initial,
                                  style: TextStyle(
                                    fontSize: 44,
                                    fontWeight: FontWeight.bold,
                                    color: const Color(0xFF15386A),
                                  ),
                                ),
                              ),
              ),
            ),
          ),
          Positioned(
            bottom: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [
                    Color(0xFF284F85),
                    Color(0xFF15386A),
                    Color(0xFF0D264E),
                    Color(0xFF081938),
                  ],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
                shape: BoxShape.circle,
                border: Border.all(
                  color: const Color(0xFF132D56),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF0B2041).withValues(alpha: 0.32),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: const Icon(
                Icons.camera_alt_rounded,
                color: Colors.white,
                size: 16,
              ),
            ),
          ),
          if (hasPhoto)
            Positioned(
              top: 0,
              right: 0,
              child: GestureDetector(
                onTap: _confirmRemovePhoto,
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: Colors.red.shade600,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Colors.white,
                      width: 2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.red.withValues(alpha: 0.35),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.delete_outline_rounded,
                    color: Colors.white,
                    size: 14,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDoctorIdCard(UserModel doctor) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [
            Color(0xFF284F85),
            Color(0xFF15386A),
            Color(0xFF0D264E),
            Color(0xFF081938),
          ],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF132D56)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0B2041).withValues(alpha: 0.32),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.badge_rounded,
              color: Colors.white,
              size: 22,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Doctor ID',
                  style: TextStyle(
                    color: const Color(0xFF8FA4BD),
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  doctor.doctorId ?? 'Not assigned',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: context.fs(15),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: () {
              final doctorId = doctor.doctorId ?? '';
              if (doctorId.isNotEmpty) {
                Clipboard.setData(ClipboardData(text: doctorId));
                ToastService.instance.showSuccess('Doctor ID copied!');
              }
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              constraints: const BoxConstraints(minHeight: 40, minWidth: 40),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.copy_rounded, size: 14, color: Colors.white),
                  const SizedBox(width: 4),
                  Text(
                    'Copy',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOnlineStatusCard() {
    return GestureDetector(
      onTap: _toggleOnlineStatus,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFDCE6F2)),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF0F233C).withValues(alpha: 0.06),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: isOnline
                    ? const Color(0xFF4CAF50).withValues(alpha: 0.1)
                    : const Color(0xFFBDBDBD).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                isOnline ? Icons.wifi_rounded : Icons.wifi_off_rounded,
                color: isOnline
                    ? const Color(0xFF4CAF50)
                    : const Color(0xFFBDBDBD),
                size: 22,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Online Status',
                    style: TextStyle(
                      color: const Color(0xFF1F2F44),
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    isOnline
                        ? 'You are visible to patients'
                        : 'You are offline',
                    style: TextStyle(
                      color: const Color(0xFF657991),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              width: 48,
              height: 28,
              decoration: BoxDecoration(
                color: isOnline
                    ? const Color(0xFF4CAF50)
                    : const Color(0xFFBDBDBD),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Stack(
                children: [
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 200),
                    left: isOpen ? 22 : 2,
                    top: 2,
                    child: Container(
                      width: 24,
                      height: 24,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool get isOpen => isOnline;

  Widget _buildActionButtons() {
    return Column(
      children: [
        GestureDetector(
          onTap: _logout,
          child: Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Colors.red.withValues(alpha: 0.08),
                  Colors.red.withValues(alpha: 0.04),
                  Colors.red.withValues(alpha: 0.08),
                ],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
              borderRadius: BorderRadius.circular(30),
              border: Border.all(
                color: Colors.red.withValues(alpha: 0.3),
                width: 1.5,
              ),
            ),
            child: Container(
              height: 48,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.white,
                    Colors.red.withValues(alpha: 0.02),
                    Colors.white,
                  ],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
                borderRadius: BorderRadius.circular(27),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.logout_rounded,
                    color: Colors.red[700],
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Logout',
                    style: TextStyle(
                      fontSize: context.fs(14),
                      fontWeight: FontWeight.w600,
                      color: Colors.red[700],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
