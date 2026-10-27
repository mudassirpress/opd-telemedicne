import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import 'package:telemedicine/admin_portal/admin_ui.dart';
import 'package:telemedicine/auth/user_controller/doctor_controller.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';

class CreateDcotorId extends ConsumerStatefulWidget {
  const CreateDcotorId({super.key});

  @override
  ConsumerState<CreateDcotorId> createState() => _CreateDcotorIdState();
}

class _CreateDcotorIdState extends ConsumerState<CreateDcotorId> {
  final TextEditingController doctorIdController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool isLoading = false;
  String errorText = '';
  String successMessage = '';
  String lastCreatedDoctorId = '';
  bool showShareCard = false;

  @override
  void dispose() {
    doctorIdController.dispose();
    super.dispose();
  }

  Future<void> createDoctor() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      isLoading = true;
      errorText = '';
      successMessage = '';
      showShareCard = false;
    });

    try {
      final doctorId = doctorIdController.text.trim();

      // Check internet connection first
      final hasConnection = await checkInternetConnection();
      if (!mounted) return;
      if (!hasConnection) {
        setState(() {
          errorText = 'No internet connection. Please check your network.';
          isLoading = false;
        });
        ToastService.instance.showError('No internet connection');
        return;
      }

      // Add timeout to Firestore operations
      final snapshot = await FirebaseFirestore.instance
          .collection('telemedicine_doctors')
          .where('doctorId', isEqualTo: doctorId)
          .where('isActive', isEqualTo: true)
          .get()
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () {
              throw TimeoutException('Firestore operation timed out');
            },
          );

      if (!mounted) return;

      if (snapshot.docs.isNotEmpty) {
        setState(() {
          errorText = 'Doctor ID already exists ❌';
          isLoading = false;
        });
        HapticFeedback.heavyImpact();
        ToastService.instance.showError('Doctor ID already exists');
        return;
      }

      final doctorRef = FirebaseFirestore.instance
          .collection('telemedicine_doctors')
          .doc();

      await doctorRef
          .set({
            'id': doctorRef.id,
            'doctorId': doctorId,
            'fullname': '',
            'highestDegree': '',
            // Consultation price + profile description. The doctor fills both
            // in from Update Profile; seeding them here means the document
            // always carries the keys instead of relying on readers to cope.
            'price': 0.0,
            'consultationFee': 0.0,
            'description': '',
            'phoneNumber': '',
            'imageUrl': '',
            'createdAt': FieldValue.serverTimestamp(),
            'updatedAt': FieldValue.serverTimestamp(),
            'isActive': true,
            'role': 'doctor',
            'isOnline': false,
            'lastSeen': null,
            'totalPatients': 0,
            'consultations': 0,
            'rating': 0.0,
            'totalRatings': 0,
            'fcmToken': null,
            'tokenUpdatedAt': null,
            'password': '',
          })
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () {
              throw TimeoutException('Firestore write operation timed out');
            },
          );

      if (!mounted) return;

      HapticFeedback.lightImpact();

      setState(() {
        successMessage = 'Doctor ID Created Successfully!';
        lastCreatedDoctorId = doctorId;
        showShareCard = true;
        doctorIdController.clear();
        isLoading = false;
      });

      ToastService.instance.showSuccess('Doctor ID created successfully!');

      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) {
          setState(() => successMessage = '');
        }
      });
    } on TimeoutException catch (e) {
      print('Timeout error: $e');
      if (!mounted) return;
      setState(() {
        errorText =
            'Connection timeout. Please check your internet and try again.';
        isLoading = false;
      });
      ToastService.instance.showError('Connection timeout');
    } catch (e) {
      print('Error creating doctor: $e');
      if (!mounted) return;
      setState(() {
        errorText = 'Something went wrong. Please try again.';
        isLoading = false;
      });
      HapticFeedback.heavyImpact();
      ToastService.instance.showError('Something went wrong. Please try again.');
    } finally {
      if (mounted) {
        setState(() => isLoading = false);
      }
    }
  }

  // Helper method to check internet connection
  Future<bool> checkInternetConnection() async {
    try {
      final result = await InternetAddress.lookup('google.com');
      return result.isNotEmpty && result[0].rawAddress.isNotEmpty;
    } on SocketException catch (_) {
      return false;
    }
  }

  /// 🔄 AUTO GENERATE
  Future<void> generateId() async {
    setState(() => isLoading = true);

    final controller = ref.read(doctorControllerProvider);
    // try/finally: `generateUniqueDoctorId()` runs an unguarded Firestore
    // `.get()`; offline it threw and `isLoading` stayed true, which disables
    // BOTH this tile and the Create button — locking the admin out of the
    // whole screen.
    String id = '';
    try {
      id = await controller.generateUniqueDoctorId();
    } catch (e) {
      if (!mounted) return;
      setState(() => isLoading = false);
      ToastService.instance.showError(
        'Could not generate an ID. Check your connection.',
      );
      return;
    }

    if (!mounted) return;

    HapticFeedback.mediumImpact();

    setState(() {
      doctorIdController.text = id;
      isLoading = false;
    });

    FocusScope.of(context).unfocus();
    ToastService.instance.showSuccess('Unique ID generated');
  }

  /// 📤 SHARE DOCTOR ID
  Future<void> shareDoctorId() async {
    if (lastCreatedDoctorId.isEmpty) return;

    final String message =
        '''
🏥 *DOCTOR CREDENTIALS* 🏥

━━━━━━━━━━━━━━━━━━━━━
👨‍⚕️ *Doctor ID:* $lastCreatedDoctorId
━━━━━━━━━━━━━━━━━━━━━

📱 *Platform:* Telemedicine

✅ *Next Steps:*
• Login using this ID
• Complete your profile
• Start consulting patients

📞 *Support:* Contact admin for assistance

━━━━━━━━━━━━━━━━━━━━━
*Generated: Telemedicine Admin Panel*
    ''';

    try {
      await Share.share(message, subject: 'Doctor ID: $lastCreatedDoctorId');
      HapticFeedback.lightImpact();
      ToastService.instance.showSuccess('Shared successfully!');
    } catch (e) {
      ToastService.instance.showError('Failed to share');
    }
  }

  /// 📤 SHARE ON WHATSAPP
  Future<void> shareOnWhatsApp() async {
    if (lastCreatedDoctorId.isEmpty) return;

    final String message =
        '''
🏥 *DOCTOR CREDENTIALS* 🏥

━━━━━━━━━━━━━━━━━━━━━
👨‍⚕️ *Doctor ID:* $lastCreatedDoctorId
━━━━━━━━━━━━━━━━━━━━━

📱 *Platform:* Telemedicine App

✅ *Next Steps:*
• Login using this ID
• Complete your profile
• Start consulting patients

📞 *Support:* Contact admin for assistance

━━━━━━━━━━━━━━━━━━━━━
*Generated: Telemedicine Admin Panel*
    ''';

    try {
      await Share.share(message, subject: 'Doctor ID: $lastCreatedDoctorId');
      HapticFeedback.lightImpact();
      ToastService.instance.showSuccess('Opening share options');
    } catch (e) {
      ToastService.instance.showError('Failed to share on WhatsApp');
    }
  }

  /// 📋 COPY TO CLIPBOARD
  void copyToClipboard() {
    if (lastCreatedDoctorId.isEmpty) return;

    Clipboard.setData(ClipboardData(text: lastCreatedDoctorId));
    ToastService.instance.showSuccess('Doctor ID copied to clipboard!');
    HapticFeedback.lightImpact();
  }

  @override
  Widget build(BuildContext context) {
    return AdminScreen(
      showBack: true,
      title: 'Create Doctor ID',
      subtitle: 'Generate a unique credential for a new doctor',
      body: SingleChildScrollView(
        padding: EdgeInsets.all(context.rsp(16)),
        child: CenteredContent(
          child: Column(
            children: [
              const SizedBox(height: 8),
              _buildFormCard(),
              SizedBox(height: context.rsp(16)),
              if (showShareCard) _buildShareCard(),
              SizedBox(height: context.rsp(16)),
              _buildInfoCard(),
            ],
          ),
        ),
      ),
    );
  }

  /// 📦 FORM CARD
  Widget _buildFormCard() {
    return AdminCard(
      padding: EdgeInsets.all(context.rsp(20)),
      radius: 22,
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Doctor Information',
              style: AdminTextStyles.title(size: context.fs(16.5)),
            ),
            const SizedBox(height: 8),
            Text(
              'Create a unique 4-digit ID for the doctor',
              style: AdminTextStyles.body(size: context.fs(13)),
            ),
            SizedBox(height: context.rsp(16)),
            _buildDoctorIdField(),
            SizedBox(height: context.rsp(16)),
            if (errorText.isNotEmpty) _buildErrorWidget(),
            if (successMessage.isNotEmpty) _buildSuccessWidget(),
            const SizedBox(height: 16),
            _buildCreateButton(),
          ],
        ),
      ),
    );
  }

  /// 🧾 INPUT FIELD
  Widget _buildDoctorIdField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MetallicInput(
          controller: doctorIdController,
          hintText: 'Enter 4-digit ID',
          labelText: 'Doctor ID',
          showLabel: true,
          icon: Icons.badge_outlined,
          keyboardType: TextInputType.phone,
          maxLength: 4,
          validator: (value) {
            if (value == null || value.trim().isEmpty) {
              return 'Doctor ID is required';
            }
            return null;
          },
        ),
        const SizedBox(height: 12),
        GestureDetector(
          onTap: isLoading ? null : generateId,
          child: Container(
            height: 46,
            decoration: BoxDecoration(
              gradient: AdminPalette.unselectedSegmentGradient,
              borderRadius: BorderRadius.circular(23),
              border: Border.all(color: AdminPalette.segmentBorder),
            ),
            alignment: Alignment.center,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.auto_awesome,
                  size: 18,
                  color: AdminPalette.unselectedText,
                ),
                const SizedBox(width: 8),
                Text(
                  'Generate Unique ID',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: context.fs(13),
                    color: AdminPalette.unselectedText,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 🚀 CREATE BUTTON
  Widget _buildCreateButton() {
    return AdminPrimaryButton(
      label: isLoading ? 'Creating...' : 'Create Doctor Account',
      leadingIcon: isLoading ? null : Icons.person_add_alt_1_rounded,
      isLoading: isLoading,
      onPressed: createDoctor,
      height: context.rsp(48),
    );
  }

  /// ❌ ERROR WIDGET
  Widget _buildErrorWidget() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AdminPalette.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AdminPalette.error.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: AdminPalette.error, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              errorText,
              style: TextStyle(
                color: AdminPalette.error,
                fontSize: context.fs(13),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// ✅ SUCCESS WIDGET
  Widget _buildSuccessWidget() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AdminPalette.success.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AdminPalette.success.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.check_circle, color: AdminPalette.success, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              successMessage,
              style: TextStyle(
                color: AdminPalette.success,
                fontSize: context.fs(13),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 📤 SHARE CARD
  Widget _buildShareCard() {
    return TweenAnimationBuilder(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 500),
      builder: (context, double value, child) {
        return Transform.scale(
          scale: value,
          child: Opacity(opacity: value, child: child),
        );
      },
      child: Container(
        padding: EdgeInsets.all(context.rsp(16)),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              AdminPalette.success.withValues(alpha: 0.10),
              AdminPalette.brandLight.withValues(alpha: 0.10),
              Colors.white,
            ],
          ),
          borderRadius: BorderRadius.circular(22),
          boxShadow: [
            BoxShadow(
              color: AdminPalette.cardShadow.withValues(alpha: 0.12),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
          border: Border.all(color: AdminPalette.infoBorder, width: 1.2),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AdminPalette.success.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(
                    Icons.share,
                    color: AdminPalette.success,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Share Credentials',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AdminTextStyles.title(
                      size: context.fs(15),
                      color: AdminPalette.success,
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(height: context.rsp(16)),
            Container(
              padding: EdgeInsets.all(context.rsp(14)),
              decoration: BoxDecoration(
                gradient: AdminPalette.cardGradient,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AdminPalette.cardBorder),
                boxShadow: [
                  BoxShadow(
                    color: AdminPalette.cardShadow.withValues(alpha: 0.08),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Generated Doctor ID',
                          style: AdminTextStyles.small(size: 12),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          lastCreatedDoctorId,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: context.fs(20),
                            color: AdminPalette.brand,
                            letterSpacing: 2,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    decoration: BoxDecoration(
                      color: AdminPalette.brand.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: IconButton(
                      onPressed: copyToClipboard,
                      icon: const Icon(
                        Icons.copy,
                        color: AdminPalette.brand,
                      ),
                      tooltip: 'Copy ID',
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: context.rsp(16)),
            Row(
              children: [
                Expanded(
                  child: _buildShareButton(
                    icon: Icons.share,
                    label: 'Share',
                    color: AdminPalette.brand,
                    onPressed: shareDoctorId,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildShareButton(
                    icon: Icons.message,
                    label: 'WhatsApp',
                    color: AdminPalette.success,
                    onPressed: shareOnWhatsApp,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 🔘 SHARE BUTTON
  Widget _buildShareButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onPressed,
  }) {
    return ElevatedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 20),
      label: Text(
        label,
        style: TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: context.fs(13.5),
        ),
      ),
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        foregroundColor: Colors.white,
        padding: EdgeInsets.symmetric(vertical: context.rsp(12)),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        elevation: 0,
      ),
    );
  }

  /// ℹ️ INFO CARD
  Widget _buildInfoCard() {
    return AdminInfoBanner(
      icon: Icons.info_outline,
      title: 'How it works',
      message:
          'Doctor will use this ID to login. Share credentials securely via WhatsApp or other platforms.',
    );
  }
}