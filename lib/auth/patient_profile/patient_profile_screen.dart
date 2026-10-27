import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/core/services/firebase_storage_service.dart';
import 'package:telemedicine/auth/auth_provider/user_provider.dart';
import 'package:telemedicine/auth/auth_screen/sign_in_screen.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/shared/widgets/auth_layout.dart';
import 'package:image_picker/image_picker.dart';

class PatientProfileScreen extends ConsumerStatefulWidget {
  const PatientProfileScreen({super.key});

  @override
  ConsumerState<PatientProfileScreen> createState() =>
      _PatientProfileScreenState();
}

class _PatientProfileScreenState extends ConsumerState<PatientProfileScreen>
    with AutomaticKeepAliveClientMixin {
  final TextEditingController nameController = TextEditingController();
  final TextEditingController phoneNumberController = TextEditingController();
  final TextEditingController highestDegreeController = TextEditingController();

  File? selectedImage;
  bool isUploading = false;
  bool isSaving = false;
  String errorText = '';
  String? currentImageUrl;
  String? selectedGender;

  final _formKey = GlobalKey<FormState>();
  final ImagePicker _picker = ImagePicker();



  @override
  bool get wantKeepAlive => true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loadUserData();
  }

  @override
  void dispose() {
    nameController.dispose();
    phoneNumberController.dispose();
    highestDegreeController.dispose();
    super.dispose();
  }

  void _loadUserData() {
    final currentUser = ref.read(userProvider);
    if (currentUser != null) {
      nameController.text = currentUser.fullname;
      phoneNumberController.text = currentUser.phoneNumber ?? '';
      highestDegreeController.text = currentUser.highestDegree ?? '';
      currentImageUrl = currentUser.image;
      selectedGender = currentUser.gender;
    }
  }

  Future<String?> _uploadImage(File imageFile) async {
    try {
      final currentUser = ref.read(userProvider);
      final uid = currentUser?.id ?? 'temp_patient';
      final result =
          await FirebaseStorageService.instance.uploadPatientProfileImage(
        patientUid: uid,
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

  void _showImageSourceDialog() {
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
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _saveProfile() async {
    if (!_formKey.currentState!.validate()) return;

    final currentUser = ref.read(userProvider);
    if (currentUser == null) {
      ToastService.instance.showError('No user logged in');
      return;
    }

    setState(() {
      isSaving = true;
      errorText = '';
    });

    try {
      final patientController = ref.read(patientControllerProvider);
      String? uploadedImageUrl = currentImageUrl;

      if (selectedImage != null) {
        ToastService.instance.showInfo('Uploading...');
        final uploadedUrl = await _uploadImage(selectedImage!);
        if (uploadedUrl != null) {
          uploadedImageUrl = uploadedUrl;
        }
      }

      final success = await patientController.updateUserProfile(
        image: uploadedImageUrl,
        fullname: nameController.text.trim(),
        gender: selectedGender,
      );

      if (success && mounted) {
        ToastService.instance.showSuccess('Profile updated!');
        ref.invalidate(userProvider);
        await Future.delayed(const Duration(milliseconds: 300));
        if (mounted) {
          Navigator.pop(context);
        }
      } else if (mounted) {
        ToastService.instance.showError(patientController.errorMessage);
      }
    } catch (e) {
      ToastService.instance.showError('Update failed');
    } finally {
      if (mounted) {
        setState(() {
          isSaving = false;
        });
      }
    }
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
            child: Text(
              'Cancel',
              style: TextStyle(
                color: const Color(0xFF6B7B8D),
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(
              'Logout',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );

    if (shouldLogout != true) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(
        child: CircularProgressIndicator(color: Color(0xFF062B72)),
      ),
    );

    try {
      final patientController = ref.read(patientControllerProvider);
      await patientController.signOut();
      if (mounted) {
        Navigator.pop(context);
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (context) => const SignInScreen()),
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.red[700]),
            const SizedBox(width: 8),
            Text(
              'Delete Account',
              style: TextStyle(
                fontSize: context.fs(15),
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
              'Your account will be deactivated and you will no longer be able '
              'to sign in.',
              style: TextStyle(
                fontSize: context.fs(13),
                color: const Color(0xFF6B7B8D),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Your chats, prescriptions, reports, payment records and other '
              'history are preserved on file and are not erased.',
              style: TextStyle(
                fontSize: 13,
                color: const Color(0xFF6B7B8D),
                height: 1.4,
              ),
            ),
            const SizedBox(height: 16),
            MetallicInput(
              hintText: 'Enter password',
              icon: Icons.lock_rounded,
              isPassword: true,
              controller: passwordController,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(
              'Cancel',
              style: TextStyle(
                color: const Color(0xFF6B7B8D),
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(
              'Delete',
              style: TextStyle(fontWeight: FontWeight.w600),
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
          'Account deleted. Your records have been preserved.',
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

    return Scaffold(
      backgroundColor: const Color(0xFFEDF2F8),
      body: Stack(
        children: [
          // ECG Watermark - Top Right (matching Sign In)
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

          // Main Content
          SafeArea(
            child: Column(
              children: [
                // Top Bar with Back Button
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

                // Scrollable Content
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

                          // Avatar Section
                          _buildAvatarSection(currentUser),
                          const SizedBox(height: 28),

                          // Title
                          Text(
                            'Personal Information',
                            style: TextStyle(
                              fontSize: context.fs(20),
                              fontWeight: FontWeight.bold,
                              color: const Color(0xFF1F2F44),
                              letterSpacing: -0.5,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Update your personal details and profile picture.',
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w500,
                              color: const Color(0xFF657991),
                              height: 1.4,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 28),

                          // Form Fields
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
                                  hintText: 'Phone Number',
                                  icon: Icons.phone_rounded,
                                  keyboardType: TextInputType.phone,
                                  controller: phoneNumberController,
                                  showLabel: true,
                                  labelText: 'Phone Number',
                                  enabled: false,
                                  validator: (value) =>
                                      value?.trim().isEmpty ?? true
                                          ? 'Required'
                                          : null,
                                ),
                                const SizedBox(height: 16),
                                GenderDropdownField(
                                  value: selectedGender,
                                  showLabel: true,
                                  labelText: 'Gender',
                                  onChanged: (val) {
                                    setState(() {
                                      selectedGender = val;
                                    });
                                  },
                                  validator: (val) =>
                                      (val == null || val.isEmpty)
                                          ? 'Please select your gender'
                                          : null,
                                ),
                                if (currentUser.role == 'doctor') ...[
                                  const SizedBox(height: 16),
                                  MetallicInput(
                                    hintText: 'Highest Degree',
                                    icon: Icons.school_rounded,
                                    controller: highestDegreeController,
                                    showLabel: true,
                                    labelText: 'Highest Degree',
                                  ),
                                ],
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

                          // Action Buttons
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

  Widget _buildAvatarSection(dynamic currentUser) {
    return GestureDetector(
      onTap: _showImageSourceDialog,
      child: Stack(
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
              decoration: BoxDecoration(
                gradient: const LinearGradient(
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
                                errorBuilder: (_, __, ___) => const Icon(
                                  Icons.person_rounded,
                                  size: 50,
                                  color: Color(0xFF8FA4BD),
                                ),
                              )
                            : const Icon(
                                Icons.person_rounded,
                                size: 50,
                                color: Color(0xFF8FA4BD),
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
        ],
      ),
    );
  }

  Widget _buildActionButtons() {
    return Column(
      children: [
        // Logout Button
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
        const SizedBox(height: 16),

        // Delete Account Button
        GestureDetector(
          onTap: _deleteAccount,
          child: Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Colors.red.withValues(alpha: 0.12),
                  Colors.red.withValues(alpha: 0.06),
                  Colors.red.withValues(alpha: 0.12),
                ],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
              borderRadius: BorderRadius.circular(30),
              border: Border.all(
                color: Colors.red.withValues(alpha: 0.4),
                width: 1.5,
              ),
            ),
            child: Container(
              height: 48,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.white,
                    Colors.red.withValues(alpha: 0.03),
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
                    Icons.delete_outline_rounded,
                    color: Colors.red[700],
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Delete Account',
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
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 96,
                      height: 96,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: const LinearGradient(
                          colors: [Color(0xFFE2E8F0), Color(0xFFCBD5E1)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        border: Border.all(color: const Color(0xFF94A3B8), width: 2),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.08),
                            blurRadius: 16,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.person_outline_rounded,
                        size: 52,
                        color: Color(0xFF475569),
                      ),
                    ),
                    const SizedBox(height: 20),
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
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
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
                    const SizedBox(height: 18),
                    Text(
                      'You are currently browsing as a guest. Log in to access room chat, doctor messaging, voice calling, appointment booking, and your medical profile.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: context.fs(13),
                        color: const Color(0xFF6B7B8D),
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 32),
                    Container(
                      width: double.infinity,
                      height: 52,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(26),
                        gradient: const LinearGradient(
                          colors: [Color(0xFF001B48), Color(0xFF02457A)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF001B48).withValues(alpha: 0.3),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(26),
                          onTap: () {
                            Navigator.pushAndRemoveUntil(
                              context,
                              MaterialPageRoute(builder: (_) => const SignInScreen()),
                              (route) => false,
                            );
                          },
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.login_rounded, color: Colors.white, size: 20),
                              const SizedBox(width: 10),
                              Text(
                                'Sign In / Register',
                                style: TextStyle(
                                  fontSize: context.fs(15),
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
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
