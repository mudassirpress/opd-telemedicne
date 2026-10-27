import 'dart:io';
import 'package:telemedicine/core/services/firebase_storage_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:telemedicine/auth/auth_provider/user_provider.dart';
import 'package:telemedicine/auth/auth_screen/sign_in_screen.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/core/theme/app_theme.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/features/complaint/submit_complaint_screen.dart';
import 'package:telemedicine/core/services/payment_complaint_visibility_service.dart';
import 'package:telemedicine/shared/widgets/auth_layout.dart';

class ExpiredPatientScreen extends ConsumerStatefulWidget {
  const ExpiredPatientScreen({super.key, this.isExpiringSoon = false});

  /// Renders the same reactivation / payment-proof form as a warning, for a
  /// patient whose account is still VALID but inside its final month.
  ///
  /// The only differences are presentational: the title, the copy, and popping
  /// back to the app on submit instead of holding the patient here. The
  /// submission path is identical — `submitReactivationPaymentProof`, the same
  /// upload folder and the same admin approval queue.
  ///
  /// This exists so the expiry warning can offer a real action without
  /// destroying an active session: the expired flow is terminal by design
  /// (the session is already cleared by `expirePatientSession()`), which is
  /// exactly wrong for a patient who still has a month left.
  final bool isExpiringSoon;

  @override
  ConsumerState<ExpiredPatientScreen> createState() =>
      _ExpiredPatientScreenState();
}

class _ExpiredPatientScreenState extends ConsumerState<ExpiredPatientScreen> {
  File? _paymentImage;
  bool _isSubmitting = false;
  bool _hasPendingRequest = false;

  final ImagePicker _picker = ImagePicker();


  @override
  void initState() {
    super.initState();
    _checkPendingRequest();
  }

  Future<void> _checkPendingRequest() async {
    final controller = ref.read(patientControllerProvider);
    final hasPending = await controller.hasPendingReactivationRequest();
    if (mounted) {
      setState(() {
        _hasPendingRequest = hasPending;
      });
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final XFile? pickedFile = await _picker.pickImage(
        source: source,
        imageQuality: 80,
      );
      if (!mounted) return;
      if (pickedFile != null) {
        setState(() {
          _paymentImage = File(pickedFile.path);
        });
        ToastService.instance.showSuccess('Image selected');
      }
    } catch (e) {
      ToastService.instance.showError('Failed to pick image');
    }
  }

  Future<String?> _uploadImage(File imageFile, {String? paymentId}) async {
    try {
      final user = ref.read(userProvider);
      final patientUid = user?.id ?? 'temp_patient';
      final pId = paymentId ?? 'react_${DateTime.now().millisecondsSinceEpoch}';
      final result = await FirebaseStorageService.instance.uploadPaymentProof(
        patientUid: patientUid,
        paymentId: pId,
        file: imageFile,
      );
      return result.downloadUrl;
    } catch (e) {
      debugPrint('Failed to upload image: $e');
      ToastService.instance.showError('Something went wrong. Please try again.');
      return null;
    }
  }

  Future<void> _submitPaymentProof() async {
    if (_paymentImage == null) {
      ToastService.instance.showWarning('Please select a payment proof image');
      return;
    }

    setState(() => _isSubmitting = true);

    final controller = ref.read(patientControllerProvider);

    try {
      ToastService.instance.showInfo('Uploading payment proof...');

      final imageUrl = await _uploadImage(_paymentImage!);
      if (!mounted) return;
      if (imageUrl == null) {
        setState(() => _isSubmitting = false);
        return;
      }

      ToastService.instance.showInfo('Submitting reactivation request...');

      final success = await controller.submitReactivationPaymentProof(
        paymentProofUrl: imageUrl,
      );

      if (!mounted) return;

      if (success) {
        ToastService.instance.showSuccess(
          'Payment proof submitted! Waiting for admin approval.',
        );

        // Warning flow: the account is still valid, so hand control straight
        // back to the app instead of trapping the patient on a terminal
        // "Account Expired" screen.
        if (widget.isExpiringSoon) {
          if (mounted) Navigator.pop(context, true);
          return;
        }

        setState(() {
          _hasPendingRequest = true;
          _isSubmitting = false;
        });
      } else {
        ToastService.instance.showError(
          controller.errorMessage.isNotEmpty
              ? controller.errorMessage
              : 'Failed to submit',
        );
        setState(() => _isSubmitting = false);
      }
    } catch (e) {
      debugPrint('Error submitting payment proof: $e');
      if (!mounted) return;
      ToastService.instance.showError('Something went wrong. Please try again.');
      setState(() => _isSubmitting = false);
    }
  }

  void _showImageSourceDialog() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
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
                  'Select Payment Proof',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: context.fs(15),
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _buildImageOption(
                      icon: Icons.camera_alt,
                      label: 'Camera',
                      onTap: () {
                        Navigator.pop(context);
                        _pickImage(ImageSource.camera);
                      },
                    ),
                    _buildImageOption(
                      icon: Icons.photo_library,
                      label: 'Gallery',
                      onTap: () {
                        Navigator.pop(context);
                        _pickImage(ImageSource.gallery);
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

  Widget _buildImageOption({
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
          color: const Color(0xFFF0F4FA),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFDCE6F2)),
        ),
        child: Column(
          children: [
            Icon(icon, size: 32, color: AppColors.primaryRed),
            const SizedBox(height: 8),
            Text(label, style: TextStyle(fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }

  Future<void> _logout() async {
    final controller = ref.read(patientControllerProvider);
    await controller.signOut();
    if (mounted) {
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const SignInScreen()),
        (route) => false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentUser = ref.watch(userProvider);
    final patientId = currentUser?.patientId ?? 'N/A';
    final showComplaintButton = PaymentComplaintVisibility.shouldShow(currentUser);

    return Scaffold(
      backgroundColor: const Color(0xFFEDF2F8),
      body: Stack(
        children: [
          // Background ECG Watermark
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
                physics: const BouncingScrollPhysics(),
                padding: EdgeInsets.symmetric(
                  horizontal: context.rsp(20),
                  vertical: 16,
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: Column(
                    children: [
                      // Top bar with complaint button and logout
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          if (showComplaintButton)
                            IconButton(
                              icon: Container(
                                padding: const EdgeInsets.all(8),
                                decoration: const BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Color(0xFFE8EDF3),
                                ),
                                child: Icon(
                                  Icons.help_outline_rounded,
                                  color: AppColors.primaryRed,
                                  size: 20,
                                ),
                              ),
                              tooltip: 'Help / Complaint',
                              onPressed: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => const SubmitComplaintScreen(),
                                  ),
                                );
                              },
                            )
                          else
                            const SizedBox.shrink(),
                          IconButton(
                            onPressed: _logout,
                            icon: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: Color(0xFFE8EDF3),
                              ),
                              child: const Icon(
                                Icons.logout_rounded,
                                color: Color(0xFF062B72),
                                size: 20,
                              ),
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 4),
                      const LogoCard(),
                      SizedBox(height: context.rsp(20)),

                      // Title
                      Text(
                        widget.isExpiringSoon
                            ? 'Account Expiring Soon'
                            : 'Account Expired',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: context.fs(20),
                          fontWeight: FontWeight.bold,
                          color: const Color(0xFF1F2F44),
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 6),

                      // Patient ID Badge
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF0F4FA),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: const Color(0xFFDCE6F2)),
                        ),
                        child: Text(
                          'Patient ID: $patientId',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: context.fs(13.5),
                            fontWeight: FontWeight.w600,
                            color: const Color(0xFF1F2F44),
                            letterSpacing: 1,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),

                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Text(
                          widget.isExpiringSoon
                              ? AccountExpiry.warningMessage
                              : 'Your Patient ID validity period has ended. '
                                  'Please submit a new payment proof to '
                                  'reactivate your account.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: context.fs(13),
                            fontWeight: FontWeight.w500,
                            color: const Color(0xFF657991),
                            height: 1.4,
                          ),
                        ),
                      ),
                      SizedBox(height: context.rsp(20)),

                      if (_hasPendingRequest) ...[
                        // Pending request state
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF0F4FA),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(color: const Color(0xFFDCE6F2)),
                          ),
                          child: Column(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFE8EDF3),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  Icons.pending_actions_rounded,
                                  color: AppColors.primaryRed,
                                  size: 36,
                                ),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                'Payment Proof Under Review',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: context.fs(14.5),
                                  fontWeight: FontWeight.bold,
                                  color: const Color(0xFF1F2F44),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Your reactivation request is being reviewed by the admin. Please wait for approval.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: const Color(0xFF657991),
                                ),
                              ),
                              const SizedBox(height: 12),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFE8EDF3),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Text(
                                  'Status: PENDING',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.primaryRed,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ] else ...[
                        // Payment proof submission
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF0F4FA),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(color: const Color(0xFFDCE6F2)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    Icons.upload_file_rounded,
                                    color: AppColors.primaryRed,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: Text(
                                      'Submit Payment Proof',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: context.fs(14.5),
                                        fontWeight: FontWeight.w600,
                                        color: const Color(0xFF1F2F44),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Text(
                                'Upload a screenshot of your payment transaction for admin verification.',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: const Color(0xFF657991),
                                ),
                              ),
                              const SizedBox(height: 16),

                              if (_paymentImage != null) ...[
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(14),
                                  child: Image.file(
                                    _paymentImage!,
                                    height: 180,
                                    width: double.infinity,
                                    fit: BoxFit.cover,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Row(
                                  children: [
                                    Expanded(
                                      child: GradientButton(
                                        text: 'Change',
                                        onPressed: _showImageSourceDialog,
                                        icon: Icons.refresh_rounded,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: GradientButton(
                                        text: 'Remove',
                                        onPressed: () =>
                                            setState(() => _paymentImage = null),
                                        icon: Icons.delete_rounded,
                                      ),
                                    ),
                                  ],
                                ),
                              ] else ...[
                                InkWell(
                                  onTap: _showImageSourceDialog,
                                  borderRadius: BorderRadius.circular(14),
                                  child: Container(
                                    width: double.infinity,
                                    height: 150,
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(14),
                                      border: Border.all(
                                        color: const Color(0xFFBAC7D8),
                                        width: 1.5,
                                      ),
                                    ),
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Icon(
                                          Icons.cloud_upload_rounded,
                                          size: 48,
                                          color: AppColors.primaryRed.withValues(alpha: 0.6),
                                        ),
                                        const SizedBox(height: 8),
                                        Text(
                                          'Tap to upload payment proof',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            fontSize: context.fs(13.5),
                                            color: const Color(0xFF657991),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),

                        SizedBox(height: context.rsp(16)),

                        // Submit button
                        GradientButton(
                          text: 'Submit Payment Proof',
                          isLoading: _isSubmitting,
                          onPressed:
                              (_isSubmitting || _paymentImage == null)
                                  ? null
                                  : _submitPaymentProof,
                          icon: Icons.send_rounded,
                        ),
                      ],

                      SizedBox(height: context.rsp(16)),

                      // Logout text
                      GestureDetector(
                        onTap: _logout,
                        behavior: HitTestBehavior.opaque,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                          child: Text(
                            'Logout',
                            style: TextStyle(
                              color: const Color(0xFF556980),
                              fontSize: context.fs(13.5),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),

                      SizedBox(height: context.rsp(16)),
 
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
