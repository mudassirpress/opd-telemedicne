import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:telemedicine/features/auth/presentation/providers/user_provider.dart';
import 'package:telemedicine/features/patients/presentation/patient_portal_wrapper.dart';
import 'package:telemedicine/app/theme/app_theme.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'dart:io';
import 'package:image_picker/image_picker.dart';
import 'package:telemedicine/core/services/firebase_storage_service.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/features/complaints/presentation/submit_complaint_screen.dart';
import 'package:telemedicine/core/services/payment_complaint_visibility_service.dart';
import 'package:telemedicine/shared/widgets/auth_layout.dart';

class PaymentScreen extends ConsumerStatefulWidget {
  const PaymentScreen({super.key});

  @override
  ConsumerState<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends ConsumerState<PaymentScreen> {
  File? paymentImage;
  bool isUploading = false;
  bool isSubmitting = false;
  String errorText = '';
  String successText = '';

  final ImagePicker _picker = ImagePicker();

  // Bank Account Details
  final String bankName = "Bank Alfalah";
  final String accountTitle = "M/S OPD ONLINE";
  final String accountNumber = "PK97ALFH5660005002596400";

  int _selectedPlanIndex =
      0; // 0 = 1 month (300 PKR), 1 = 6 months (1000 PKR), 2 = 1 year (1500 PKR)

  static const List<
    ({
      String planId,
      String title,
      String priceText,
      double amount,
      int durationMonths,
    })
  >
  _plans = [
    (
      planId: 'one_month',
      title: '1 Month',
      priceText: '300 PKR',
      amount: 300,
      durationMonths: 1,
    ),
    (
      planId: 'six_months',
      title: '6 Months',
      priceText: '1,000 PKR',
      amount: 1000,
      durationMonths: 6,
    ),
    (
      planId: 'one_year',
      title: '1 Year',
      priceText: '1,500 PKR',
      amount: 1500,
      durationMonths: 12,
    ),
  ];

  String get paymentAmount => _plans[_selectedPlanIndex].priceText;
  double get amountValue => _plans[_selectedPlanIndex].amount;

  @override
  void initState() {
    super.initState();
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(patientControllerProvider).loadSavedUser(forceRefresh: true);
      }
    });
  }

  @override
  void dispose() {
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
      ),
    );
    super.dispose();
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
          paymentImage = File(pickedFile.path);
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

  void _copyAccountNumber() {
    Clipboard.setData(ClipboardData(text: accountNumber));
    ToastService.instance.showSuccess('Account number copied to clipboard');
  }

  void _copyAccountTitle() {
    Clipboard.setData(ClipboardData(text: accountTitle));
    ToastService.instance.showSuccess('Account title copied to clipboard');
  }

  void _copyAmount() {
    Clipboard.setData(ClipboardData(text: amountValue.toInt().toString()));
    ToastService.instance.showSuccess(
      'Amount $paymentAmount copied to clipboard',
    );
  }

  void _copyBankName() {
    Clipboard.setData(ClipboardData(text: bankName));
    ToastService.instance.showSuccess('Bank name copied to clipboard');
  }

  Future<String?> _uploadImage(File imageFile, {String? paymentId}) async {
    try {
      final user = ref.read(userProvider);
      final patientUid = user?.id ?? 'temp_patient';
      final pId = paymentId ?? 'pay_${DateTime.now().millisecondsSinceEpoch}';
      final result = await FirebaseStorageService.instance.uploadPaymentProof(
        patientUid: patientUid,
        paymentId: pId,
        file: imageFile,
      );

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

  Future<void> _submitImage() async {
    if (paymentImage == null) {
      setState(() {
        errorText = 'Please select an image to upload';
      });
      ToastService.instance.showWarning('Please select an image to upload');
      return;
    }

    setState(() {
      isSubmitting = true;
      errorText = '';
      successText = '';
    });

    try {
      final patientController = ref.read(patientControllerProvider);

      if (!patientController.isLoggedIn() ||
          patientController.currentUser == null) {
        setState(() {
          errorText = 'Session expired. Please login again.';
          isSubmitting = false;
        });
        ToastService.instance.showError('Session expired. Please login again.');
        return;
      }

      ToastService.instance.showInfo('Uploading payment proof...');

      final imageUrl = await _uploadImage(paymentImage!);
      if (!mounted) return;

      if (imageUrl == null) {
        setState(() {
          errorText = 'Failed to upload image. Please try again.';
          isSubmitting = false;
        });
        return;
      }

      ToastService.instance.showInfo('Submitting payment proof...');

      final currentPlan = _plans[_selectedPlanIndex];
      final success = await patientController.submitPaymentProof(
        imageUrl,
        subscriptionPlan: currentPlan.planId,
        durationMonths: currentPlan.durationMonths,
        amount: currentPlan.amount,
      );
      if (!mounted) return;

      if (success) {
        ToastService.instance.showSuccess(
          'Payment proof of $paymentAmount submitted successfully!',
        );

        await Future.delayed(const Duration(milliseconds: 500));
        if (!mounted) return;

        // Clear the whole stack: `pushReplacement` used to leave the
        // SignInScreen underneath, so Back from the portal returned a
        // signed-in patient to the login screen.
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (context) => const PatientPortalWrapper()),
          (Route<dynamic> route) => false,
        );
      } else {
        setState(() {
          errorText = patientController.errorMessage;
          isSubmitting = false;
        });
        ToastService.instance.showError(patientController.errorMessage);
      }
    } catch (e) {
      if (!mounted) return;
      ToastService.instance.showError(
        'Error submitting payment: ${e.toString()}',
      );
      setState(() {
        errorText = 'An error occurred. Please try again.';
        isSubmitting = false;
      });
    }
  }

  void _showImageSourceDialog() {
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
                  'Select Payment Proof',
                  style: TextStyle(
                    fontSize: context.fs(15),
                    fontWeight: FontWeight.bold,
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
            Text(
              label,
              style: TextStyle(
                color: const Color(0xFF1F2F44),
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlanSelector() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFFF0F4FA),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFDCE6F2)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF12263F).withValues(alpha: 0.06),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.card_membership_rounded,
                size: 22,
                color: AppColors.primaryRed,
              ),
              const SizedBox(width: 8),
              Text(
                'Select Subscription Plan',
                style: TextStyle(
                  fontSize: context.fs(14.5),
                  fontWeight: FontWeight.bold,
                  color: const Color(0xFF1F2F44),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              for (int i = 0; i < _plans.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(
                  child: GestureDetector(
                    onTap: () {
                      setState(() {
                        _selectedPlanIndex = i;
                      });
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.symmetric(
                        vertical: 12,
                        horizontal: 6,
                      ),
                      decoration: BoxDecoration(
                        gradient: _selectedPlanIndex == i
                            ? const LinearGradient(
                                colors: [
                                  Color(0xFF183359),
                                  Color(0xFF0F2445),
                                  Color(0xFF08162D),
                                ],
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                              )
                            : const LinearGradient(
                                colors: [
                                  Color(0xFFF3F7FB),
                                  Colors.white,
                                  Color(0xFFF0F4F9),
                                ],
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                              ),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: _selectedPlanIndex == i
                              ? const Color(0xFF183359)
                              : const Color(0xFFDCE6F2),
                          width: _selectedPlanIndex == i ? 1.8 : 1.2,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: _selectedPlanIndex == i
                                ? const Color(
                                    0xFF0F1E32,
                                  ).withValues(alpha: 0.25)
                                : Colors.black.withValues(alpha: 0.03),
                            blurRadius: 6,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _plans[i].title,
                            style: TextStyle(
                              fontSize: context.fs(12),
                              fontWeight: FontWeight.w600,
                              color: _selectedPlanIndex == i
                                  ? Colors.white70
                                  : const Color(0xFF657991),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _plans[i].priceText,
                            style: TextStyle(
                              fontSize: context.fs(13.5),
                              fontWeight: FontWeight.bold,
                              color: _selectedPlanIndex == i
                                  ? Colors.white
                                  : const Color(0xFF1F2F44),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  void _handleBackNavigation() {
    if (Navigator.canPop(context)) {
      Navigator.pop(context);
    } else {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (context) => const PatientPortalWrapper()),
        (Route<dynamic> route) => false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentUser = ref.watch(userProvider);
    final showComplaintButton = PaymentComplaintVisibility.shouldShow(
      currentUser,
    );

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _handleBackNavigation();
        }
      },
      child: Scaffold(
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
                    constraints: BoxConstraints(
                      maxWidth: context.contentMaxWidth,
                    ),
                    child: Column(
                      children: [
                        // Top bar with back button and Help / Complaint
                        Row(
                          children: [
                            CircularBackButton(
                              onPressed: _handleBackNavigation,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                'Payment',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: context.fs(20),
                                  fontWeight: FontWeight.bold,
                                  color: const Color(0xFF1F2F44),
                                  letterSpacing: -0.5,
                                ),
                              ),
                            ),
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
                                      builder: (_) =>
                                          const SubmitComplaintScreen(),
                                    ),
                                  );
                                },
                              ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'Send payment and upload proof for verification',
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w500,
                                color: const Color(0xFF657991),
                                height: 1.4,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),

                        // ===== Subscription Plan Selection Card =====
                        _buildPlanSelector(),

                        const SizedBox(height: 20),

                        // ===== Bank Details Card =====
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF0F4FA),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(color: const Color(0xFFDCE6F2)),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(
                                  0xFF12263F,
                                ).withValues(alpha: 0.06),
                                blurRadius: 12,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    Icons.account_balance_rounded,
                                    size: 22,
                                    color: AppColors.primaryRed,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Bank Details',
                                    style: TextStyle(
                                      fontSize: context.fs(14.5),
                                      fontWeight: FontWeight.bold,
                                      color: const Color(0xFF1F2F44),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 20),

                              // Bank Name
                              _buildDetailRow(
                                label: 'Bank Name',
                                value: bankName,
                                onCopy: _copyBankName,
                              ),
                              _buildDivider(),

                              // Amount
                              _buildDetailRow(
                                label: 'Amount',
                                value: paymentAmount,
                                isHighlighted: true,
                                onCopy: _copyAmount,
                              ),
                              _buildDivider(),

                              // Account Title
                              _buildDetailRow(
                                label: 'Account Title',
                                value: accountTitle,
                                onCopy: _copyAccountTitle,
                              ),
                              _buildDivider(),

                              // Account Number (IBAN)
                              _buildDetailRow(
                                label: 'Account Number',
                                value: accountNumber,
                                isIBAN: true,
                                onCopy: _copyAccountNumber,
                              ),

                              const SizedBox(height: 16),

                              // Info box
                              Container(
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF0F4FA),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: const Color(0xFFDCE6F2),
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.info_outline_rounded,
                                      size: 20,
                                      color: AppColors.primaryRed,
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        'Send exact amount of $paymentAmount and upload transaction screenshot below for verification.',
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w500,
                                          color: const Color(0xFF657991),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 20),

                        // ===== Upload Section Card =====
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
                                  Text(
                                    'Upload Payment Screenshot',
                                    style: TextStyle(
                                      fontSize: context.fs(14),
                                      fontWeight: FontWeight.w600,
                                      color: const Color(0xFF1F2F44),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Text(
                                'After sending $paymentAmount to Bank Alfalah, take a screenshot of the transaction and upload it here for admin verification.',
                                style: TextStyle(
                                  fontSize: context.fs(13),
                                  color: const Color(0xFF657991),
                                ),
                              ),
                              const SizedBox(height: 16),

                              if (paymentImage != null) ...[
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(14),
                                  child: Image.file(
                                    paymentImage!,
                                    height: 200,
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
                                        onPressed: isUploading
                                            ? null
                                            : _showImageSourceDialog,
                                        icon: Icons.refresh_rounded,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: GradientButton(
                                        text: 'Remove',
                                        onPressed: () {
                                          setState(() {
                                            paymentImage = null;
                                          });
                                          ToastService.instance.showInfo(
                                            'Image removed',
                                          );
                                        },
                                        icon: Icons.delete_rounded,
                                      ),
                                    ),
                                  ],
                                ),
                              ] else ...[
                                InkWell(
                                  onTap: isUploading
                                      ? null
                                      : _showImageSourceDialog,
                                  borderRadius: BorderRadius.circular(14),
                                  child: Container(
                                    width: double.infinity,
                                    height: 180,
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(14),
                                      border: Border.all(
                                        color: const Color(0xFFBAC7D8),
                                        width: 1.5,
                                      ),
                                    ),
                                    child: isUploading
                                        ? const Center(
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: Color(0xFF062B72),
                                            ),
                                          )
                                        : Column(
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              Icon(
                                                Icons.cloud_upload_rounded,
                                                size: 50,
                                                color: AppColors.primaryRed
                                                    .withValues(alpha: 0.6),
                                              ),
                                              const SizedBox(height: 12),
                                              Text(
                                                'Tap to upload screenshot',
                                                style: TextStyle(
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.w500,
                                                  color: const Color(
                                                    0xFF657991,
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(height: 8),
                                              Text(
                                                'JPG, PNG up to 5MB',
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  color: const Color(
                                                    0xFF7E90A6,
                                                  ),
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

                        const SizedBox(height: 24),

                        // Error Message
                        if (errorText.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 16),
                            child: Text(
                              errorText,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Colors.red,
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),

                        // Submit Button
                        GradientButton(
                          text: 'Submit Payment Proof',
                          isLoading: isSubmitting,
                          onPressed: isSubmitting ? null : _submitImage,
                          icon: Icons.send_rounded,
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
    );
  }

  Widget _buildDetailRow({
    required String label,
    required String value,
    bool isHighlighted = false,
    bool isIBAN = false,
    VoidCallback? onCopy,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 2,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: const Color(0xFF657991),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  value,
                  style: TextStyle(
                    fontSize: isHighlighted ? context.fs(14) : context.fs(13),
                    fontWeight: isHighlighted || isIBAN
                        ? FontWeight.bold
                        : FontWeight.w600,
                    color: isHighlighted || isIBAN
                        ? AppColors.primaryRed
                        : const Color(0xFF1F2F44),
                    letterSpacing: isIBAN ? 0.5 : 0,
                  ),
                ),
                if (isIBAN) ...[
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE8EDF3),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      'IBAN',
                      style: TextStyle(
                        fontSize: 9,
                        color: AppColors.primaryRed,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (onCopy != null)
            GestureDetector(
              onTap: onCopy,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 7,
                ),
                constraints: const BoxConstraints(minHeight: 40, minWidth: 40),
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
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF0B2041).withValues(alpha: 0.2),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.copy_rounded,
                      size: 14,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      'Copy',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
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

  Widget _buildDivider() {
    return Container(height: 1, color: const Color(0xFFDCE6F2));
  }
}
