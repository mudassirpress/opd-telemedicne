import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:telemedicine/auth/auth_provider/user_provider.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/data/models/appointment_model.dart';
import 'package:telemedicine/features/appointment/appointment_controller.dart';
import 'package:telemedicine/features/appointment/appointment_request_screen.dart';
import 'package:telemedicine/shared/widgets/auth_layout.dart';
import 'package:telemedicine/shared/widgets/opd_design.dart';

/// Step two of the booking flow: pay the consultation fee and upload proof.
///
/// The record id is `{patientId}_{doctorId}`, so re-submitting after a
/// rejection overwrites the rejected attempt instead of creating a second one.
class AppointmentPaymentScreen extends ConsumerStatefulWidget {
  const AppointmentPaymentScreen({super.key, required this.doctorId});

  final String doctorId;

  @override
  ConsumerState<AppointmentPaymentScreen> createState() =>
      _AppointmentPaymentScreenState();
}

class _AppointmentPaymentScreenState
    extends ConsumerState<AppointmentPaymentScreen> {
  File? _proof;
  bool _picking = false;
  bool _submitting = false;
  String _error = '';

  final ImagePicker _picker = ImagePicker();

  // Same account the existing subscription payment uses.
  final String _bankName = 'Bank Alfalah';
  final String _accountTitle = 'M/S OPD ONLINE';
  final String _accountNumber = 'PK97ALFH5660005002596400';

  @override
  void initState() {
    super.initState();
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
      ),
    );
  }

  Future<void> _pickImage(ImageSource source) async {
    setState(() => _picking = true);
    try {
      final picked = await _picker.pickImage(source: source, imageQuality: 80);
      if (picked != null) {
        setState(() => _proof = File(picked.path));
        ToastService.instance.showSuccess('Image selected');
      }
    } catch (_) {
      ToastService.instance.showError('Failed to pick image');
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  void _showImageSourceDialog() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      backgroundColor: Colors.white,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
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
                  _sourceOption(
                    icon: Icons.camera_alt,
                    label: 'Camera',
                    onTap: () {
                      Navigator.pop(context);
                      _pickImage(ImageSource.camera);
                    },
                  ),
                  _sourceOption(
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
      ),
    );
  }

  Widget _sourceOption({
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
            Icon(icon, size: 32, color: const Color(0xFF062B72)),
            const SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: context.fs(13),
                color: const Color(0xFF1F2F44),
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _submit() async {
    final user = ref.read(userProvider);
    final doctor = ref.read(doctorBookingProvider(widget.doctorId)).valueOrNull;
    final watched = ref
            .read(appointmentVideoWatchedProvider(widget.doctorId))
            .valueOrNull ??
        false;

    if (user == null) {
      ToastService.instance.showError('Session expired. Please login again.');
      return;
    }
    if (doctor == null) {
      ToastService.instance.showError('Doctor information is missing.');
      return;
    }
    if (_proof == null) {
      setState(() => _error = 'Please attach your payment screenshot.');
      ToastService.instance.showWarning('Please attach your payment screenshot');
      return;
    }

    setState(() {
      _submitting = true;
      _error = '';
    });

    try {
      ToastService.instance.showInfo('Uploading payment proof...');
      final url = await ref
          .read(appointmentControllerProvider)
          .uploadProof(_proof!);
      if (!mounted) return;
      if (url == null) {
        setState(() {
          _error = 'Could not upload the image. Please try again.';
          _submitting = false;
        });
        return;
      }

      final error = await ref
          .read(appointmentControllerProvider)
          .submitAppointmentPayment(
            patient: user,
            doctor: doctor,
            videoWatched: watched,
            proofUrl: url,
          );

      if (!mounted) return;
      setState(() {
        _submitting = false;
        _proof = null;
      });

      if (error != null) {
        setState(() => _error = error);
        ToastService.instance.showError(error);
      } else {
        ToastService.instance.showSuccess('Payment proof submitted');
      }
    } catch (e) {
      debugPrint('Error submitting payment: $e');
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = 'Something went wrong. Please try again.';
      });
      ToastService.instance.showError('Could not submit the payment');
    }
  }

  void _copy(String value, String label) {
    Clipboard.setData(ClipboardData(text: value));
    ToastService.instance.showSuccess('$label copied to clipboard');
  }

  @override
  Widget build(BuildContext context) {
    final doctorAsync = ref.watch(doctorBookingProvider(widget.doctorId));
    final watched = ref
            .watch(appointmentVideoWatchedProvider(widget.doctorId))
            .valueOrNull ??
        false;
    final payment =
        ref.watch(appointmentPaymentProvider(widget.doctorId)).valueOrNull;

    // A failed doctor read used to be collapsed by `.valueOrNull` into a
    // permanent "Loading payment details…" spinner. Surface it instead.
    if (doctorAsync.hasError) {
      return OpdScreenShell(
        title: 'Consultation Payment',
        subtitle: 'Could not load the fee',
        child: OpdEmptyState(
          icon: Icons.wifi_off_rounded,
          title: 'Could not load payment details',
          subtitle: 'Check your connection and try again.',
          action: TextButton(
            onPressed: () =>
                ref.invalidate(doctorBookingProvider(widget.doctorId)),
            child: const Text('Retry'),
          ),
        ),
      );
    }

    final doctor = doctorAsync.valueOrNull;
    // `null` after loading finished and without an error means the doctor
    // document does not exist — an empty state, not an endless spinner.
    if (doctor == null) {
      if (!doctorAsync.isLoading) {
        return OpdScreenShell(
          title: 'Consultation Payment',
          subtitle: 'Doctor not found',
          child: const OpdEmptyState(
            icon: Icons.person_search_rounded,
            title: 'Doctor not found',
            subtitle: 'This doctor may no longer be available.',
          ),
        );
      }
      return OpdScreenShell(
        title: 'Consultation Payment',
        subtitle: 'Loading...',
        child: const OpdInlineLoader(label: 'Loading payment details...'),
      );
    }

    final pricing = AppointmentController.pricingFor(
      doctor: doctor,
      videoWatched: watched,
    );

    return OpdScreenShell(
      title: 'Consultation Payment',
      subtitle: 'Send the fee and upload your transaction screenshot.',
      bottom: _buildBottomAction(payment),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Price summary ──
          const OpdSectionLabel('Amount payable'),
          OpdCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Column(
              children: [
                OpdDetailRow(
                  icon: Icons.medical_services_rounded,
                  label: 'Dr. ${(doctor['fullname'] ?? '').toString()}',
                  value: pricing.feeLabel,
                ),
                OpdDetailRow(
                  icon: Icons.payments_rounded,
                  label: 'Original Fee',
                  value: pricing.feeLabel,
                ),
                OpdDetailRow(
                  icon: Icons.ondemand_video_rounded,
                  label: '30% Video Discount',
                  value: pricing.discountApplied
                      ? pricing.discountLabel
                      : 'Not unlocked',
                ),
                OpdDetailRow(
                  icon: Icons.savings_rounded,
                  label: 'You Save',
                  value: pricing.discountApplied
                      ? pricing.format(pricing.discountAmount)
                      : 'Not unlocked',
                ),
                const Divider(height: 1, color: Color(0xFFDCE6F2)),
                OpdDetailRow(
                  icon: Icons.account_balance_wallet_rounded,
                  label: 'Final Amount',
                  value: pricing.payableLabel,
                ),
              ],
            ),
          ),

          const SizedBox(height: 18),
          const OpdSectionLabel('Bank details'),
          OpdCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Column(
              children: [
                _bankRow('Bank Name', _bankName, () => _copy(_bankName, 'Bank name')),
                const Divider(height: 1, color: Color(0xFFDCE6F2)),
                _bankRow(
                  'Account Title',
                  _accountTitle,
                  () => _copy(_accountTitle, 'Account title'),
                ),
                const Divider(height: 1, color: Color(0xFFDCE6F2)),
                _bankRow(
                  'Account Number (IBAN)',
                  _accountNumber,
                  () => _copy(_accountNumber, 'Account number'),
                ),
                const Divider(height: 1, color: Color(0xFFDCE6F2)),
                _bankRow(
                  'Amount',
                  pricing.payableLabel,
                  () => _copy(pricing.payableAmount.toStringAsFixed(0), 'Amount'),
                  highlighted: true,
                ),
              ],
            ),
          ),

          const SizedBox(height: 10),
          OpdInfoPanel(
            icon: Icons.info_outline_rounded,
            title: 'Send the exact amount',
            description:
                'Transfer ${pricing.payableLabel} to the account above, then '
                'upload the transaction screenshot below for admin approval.',
          ),

          const SizedBox(height: 18),
          OpdSectionLabel('Payment status'),
          _buildStatusCard(payment),

          if (payment == null || payment.isRejected) ...[
            const SizedBox(height: 18),
            const OpdSectionLabel('Upload payment screenshot'),
            _buildUploader(),
          ],

          if (payment != null && payment.isApproved) ...[
            const SizedBox(height: 18),
            OpdInfoPanel(
              icon: Icons.verified_rounded,
              title: 'Payment approved',
              description:
                  'Your payment has been verified. Send your appointment '
                  'request to Dr. ${payment.doctorName} next.',
              accent: const Color(0xFF1E8E5A),
            ),
          ],

          if (_error.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(
              _error,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                color: const Color(0xFFD64545),
              ),
            ),
          ],
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildBottomAction(AppointmentPaymentModel? payment) {
    if (payment != null && payment.isApproved) {
      return GradientButton(
        text: 'Send Appointment Request',
        icon: Icons.send_rounded,
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => AppointmentRequestScreen(
              doctorId: widget.doctorId,
              payment: payment,
            ),
          ),
        ),
      );
    }

    if (payment != null && payment.isPending) {
      return const GradientButton(
        text: 'Waiting for admin approval',
        icon: Icons.hourglass_top_rounded,
        onPressed: null,
      );
    }

    return GradientButton(
      text: _submitting ? 'Submitting...' : 'Submit Payment Proof',
      icon: Icons.send_rounded,
      isLoading: _submitting,
      onPressed: _submitting ? null : _submit,
    );
  }

  Widget _buildStatusCard(AppointmentPaymentModel? payment) {
    if (payment == null) {
      return const OpdInfoPanel(
        icon: Icons.upload_file_rounded,
        title: 'No payment submitted yet',
        description: 'Upload your transaction screenshot to start verification.',
        accent: Color(0xFF7E90A6),
      );
    }

    final color = payment.isApproved
        ? const Color(0xFF1E8E5A)
        : payment.isRejected
            ? const Color(0xFFD64545)
            : const Color(0xFFE9A400);

    final title = payment.isApproved
        ? 'Payment approved'
        : payment.isRejected
            ? 'Payment rejected'
            : 'Awaiting admin approval';

    final body = payment.isApproved
        ? 'Verified on ${payment.reviewedAt != null ? _formatDate(payment.reviewedAt!) : 'a recent date'}.'
        : payment.isRejected
            ? (payment.rejectionReason?.isNotEmpty ?? false)
                ? 'Reason: ${payment.rejectionReason}'
                : 'Please review the details and submit again.'
            : 'Your proof is with the admin team. This screen updates '
                'automatically once a decision is made.';

    return OpdCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(13),
                  border: Border.all(color: color.withValues(alpha: 0.35)),
                ),
                child: Icon(
                  payment.isApproved
                      ? Icons.check_circle_rounded
                      : payment.isRejected
                          ? Icons.cancel_rounded
                          : Icons.hourglass_top_rounded,
                  size: 20,
                  color: color,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: context.fs(14),
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF1F2F44),
                  ),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(30),
                  border: Border.all(color: color.withValues(alpha: 0.35)),
                ),
                child: Text(
                  payment.isApproved
                      ? 'APPROVED'
                      : payment.isRejected
                          ? 'REJECTED'
                          : 'PENDING',
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color: color,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            body,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
              color: const Color(0xFF657991),
              height: 1.4,
            ),
          ),
          if (payment.paymentImage != null &&
              payment.paymentImage!.isNotEmpty) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: CachedNetworkImage(
                imageUrl: payment.paymentImage!,
                height: 160,
                width: double.infinity,
                fit: BoxFit.cover,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildUploader() {
    if (_proof != null) {
      return Column(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Image.file(
              _proof!,
              height: 190,
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
                  icon: Icons.refresh_rounded,
                  onPressed: _picking ? null : _showImageSourceDialog,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: GradientButton(
                  text: 'Remove',
                  icon: Icons.delete_rounded,
                  onPressed: () => setState(() => _proof = null),
                ),
              ),
            ],
          ),
        ],
      );
    }

    return InkWell(
      onTap: _picking ? null : _showImageSourceDialog,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: double.infinity,
        height: 170,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFFBAC7D8), width: 1.5),
        ),
        child: _picking
            ? const Center(
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Color(0xFF062B72),
                ),
              )
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.cloud_upload_rounded,
                    size: 46,
                    color: const Color(0xFF062B72).withValues(alpha: 0.6),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Tap to upload screenshot',
                    style: TextStyle(
                      fontSize: context.fs(13),
                      fontWeight: FontWeight.w500,
                      color: const Color(0xFF657991),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'JPG, PNG up to 5MB',
                    style: TextStyle(
                      fontSize: 11,
                      color: const Color(0xFF7E90A6),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _bankRow(
    String label,
    String value,
    VoidCallback onCopy, {
    bool highlighted = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                color: const Color(0xFF657991),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Flexible(
            child: Text(
              value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: TextStyle(
                fontSize: highlighted ? context.fs(14.5) : context.fs(13),
                fontWeight: FontWeight.w700,
                color: highlighted
                    ? const Color(0xFF062B72)
                    : const Color(0xFF1F2F44),
              ),
            ),
          ),
          const SizedBox(width: 10),
          GestureDetector(
            onTap: onCopy,
            child: Container(
              constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [
                    Color(0xFF284F85),
                    Color(0xFF15386A),
                    Color(0xFF0D264E),
                  ],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
                borderRadius: BorderRadius.circular(9),
              ),
              child: const Icon(Icons.copy_rounded, size: 13, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime date) {
    return '${date.day}/${date.month}/${date.year}';
  }
}
