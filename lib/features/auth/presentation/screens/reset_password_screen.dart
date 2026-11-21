// lib/features/auth/presentation/screens/reset_password_screen.dart

import 'package:flutter/material.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/features/auth/data/services/patient_phone_reset_service.dart';
import 'package:telemedicine/features/auth/presentation/screens/sign_in_screen.dart';
import 'package:telemedicine/features/auth/presentation/widgets/auth_ui_components.dart';
import 'package:telemedicine/shared/widgets/auth_layout.dart';
import 'package:telemedicine/shared/widgets/opd_design_system.dart';

class ResetPasswordScreen extends StatefulWidget {
  final String phoneNumber;
  const ResetPasswordScreen({super.key, required this.phoneNumber});

  @override
  State<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends State<ResetPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  bool _isLoading = false;
  String _errorMessage = '';

  @override
  void dispose() {
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _handleResetPassword() async {
    if (!_formKey.currentState!.validate()) return;

    final newPass = _newPasswordController.text.trim();
    final confirmPass = _confirmPasswordController.text.trim();

    if (newPass.length < 6) {
      setState(() => _errorMessage = 'Password must be at least 6 characters');
      ToastService.instance.showWarning(
        'Password must be at least 6 characters',
      );
      return;
    }

    if (newPass != confirmPass) {
      setState(() => _errorMessage = 'Passwords do not match');
      ToastService.instance.showError('Passwords do not match');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });

    final success = await PatientPhoneResetService.instance.updatePassword(
      normalizedPhone: widget.phoneNumber,
      newPassword: newPass,
    );

    if (!mounted) return;
    setState(() => _isLoading = false);

    if (success) {
      ToastService.instance.showSuccess('Password updated successfully');
      Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (_) => SignInScreen(initialPhone: widget.phoneNumber),
        ),
        (route) => false,
      );
    } else {
      setState(() {
        _errorMessage = 'Failed to update password. Please try again.';
      });
      ToastService.instance.showError(_errorMessage);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F9FC),
      appBar: const AuthAppBar(title: 'Set New Password'),
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: EdgeInsets.symmetric(
            horizontal: context.rsp(20),
            vertical: 16,
          ),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 12),
                // Header Card
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF0C2959).withValues(alpha: 0.05),
                        blurRadius: 16,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: const Color(0xFFEBF3FB),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: const Icon(
                          Icons.security_rounded,
                          color: Color(0xFF062B72),
                          size: 30,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Create New Password',
                        style: TextStyle(
                          fontSize: context.fs(18),
                          fontWeight: FontWeight.w700,
                          color: const Color(0xFF1F2F44),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Set a strong password for account registered to ${widget.phoneNumber}',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: context.fs(13),
                          color: const Color(0xFF657991),
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 24),

                Text(
                  'New Password',
                  style: TextStyle(
                    fontSize: context.fs(13),
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF1F2F44),
                  ),
                ),
                const SizedBox(height: 8),

                MetallicInput(
                  hintText: 'Enter New Password',
                  icon: Icons.lock_outline_rounded,
                  isPassword: true,
                  controller: _newPasswordController,
                  validator: (val) {
                    if (val == null || val.trim().length < 6) {
                      return 'Password must be at least 6 characters';
                    }
                    return null;
                  },
                ),

                const SizedBox(height: 16),

                Text(
                  'Confirm Password',
                  style: TextStyle(
                    fontSize: context.fs(13),
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF1F2F44),
                  ),
                ),
                const SizedBox(height: 8),

                MetallicInput(
                  hintText: 'Confirm New Password',
                  icon: Icons.lock_outline_rounded,
                  isPassword: true,
                  controller: _confirmPasswordController,
                  validator: (val) {
                    if (val != _newPasswordController.text) {
                      return 'Passwords do not match';
                    }
                    return null;
                  },
                ),

                if (_errorMessage.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Text(
                      _errorMessage,
                      style: const TextStyle(
                        color: Colors.red,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],

                const SizedBox(height: 28),

                AuthActionButton(
                  text: 'Update Password',
                  isLoading: _isLoading,
                  onPressed: _handleResetPassword,
                  trailingIcon: Icons.arrow_forward_rounded,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
