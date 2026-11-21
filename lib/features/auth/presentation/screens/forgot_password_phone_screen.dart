// lib/features/auth/presentation/screens/forgot_password_phone_screen.dart

import 'package:flutter/material.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/features/auth/data/services/patient_phone_reset_service.dart';
import 'package:telemedicine/features/auth/presentation/screens/otp_verification_screen.dart';
import 'package:telemedicine/features/auth/presentation/widgets/auth_ui_components.dart';
import 'package:telemedicine/shared/widgets/auth_layout.dart';
import 'package:telemedicine/shared/widgets/international_phone_input.dart';
import 'package:telemedicine/shared/widgets/opd_design_system.dart';

class ForgotPasswordPhoneScreen extends StatefulWidget {
  final String? initialPhone;
  const ForgotPasswordPhoneScreen({super.key, this.initialPhone});

  @override
  State<ForgotPasswordPhoneScreen> createState() =>
      _ForgotPasswordPhoneScreenState();
}

class _ForgotPasswordPhoneScreenState extends State<ForgotPasswordPhoneScreen> {
  final _phoneController = TextEditingController();
  String _normalizedE164Phone = '';
  String _selectedDialCode = '+92';
  bool _isLoading = false;
  String _errorMessage = '';

  @override
  void initState() {
    super.initState();
    if (widget.initialPhone != null && widget.initialPhone!.trim().isNotEmpty) {
      _phoneController.text = widget.initialPhone!.trim();
      _normalizedE164Phone = widget.initialPhone!.trim();
    }
  }

  @override
  void dispose() {
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _handleSendOtp() async {
    final rawPhone = _phoneController.text.trim();
    if (rawPhone.isEmpty) {
      setState(
        () => _errorMessage = 'Please enter your registered phone number',
      );
      ToastService.instance.showWarning('Please enter your phone number');
      return;
    }

    final phoneToSend = _normalizedE164Phone.isNotEmpty
        ? _normalizedE164Phone
        : (rawPhone.startsWith('+')
              ? rawPhone
              : '$_selectedDialCode${rawPhone.replaceAll(RegExp(r'^0+'), '')}');

    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });

    await PatientPhoneResetService.instance.sendOtp(
      normalizedPhone: phoneToSend,
      onCodeSent: (verificationId) {
        if (!mounted) return;
        setState(() => _isLoading = false);
        ToastService.instance.showSuccess('Verification code sent via SMS');
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => OtpVerificationScreen(
              phoneNumber: phoneToSend,
              verificationId: verificationId,
              isPasswordReset: true,
            ),
          ),
        );
      },
      onError: (error) {
        if (!mounted) return;
        setState(() {
          _isLoading = false;
          _errorMessage = error;
        });
        ToastService.instance.showError(error);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F9FC),
      appBar: const AuthAppBar(title: 'Forgot Password'),
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: EdgeInsets.symmetric(
            horizontal: context.rsp(20),
            vertical: 16,
          ),
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
                        Icons.lock_reset_rounded,
                        color: Color(0xFF062B72),
                        size: 30,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Reset Your Password',
                      style: TextStyle(
                        fontSize: context.fs(18),
                        fontWeight: FontWeight.w700,
                        color: const Color(0xFF1F2F44),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Enter your registered mobile phone number to receive a 6-digit SMS verification code.',
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
                'Mobile Number',
                style: TextStyle(
                  fontSize: context.fs(13),
                  fontWeight: FontWeight.w600,
                  color: const Color(0xFF1F2F44),
                ),
              ),
              const SizedBox(height: 8),

              // Country Code & Phone Input
              InternationalPhoneInput(
                controller: _phoneController,
                initialIsoCode: 'PK',
                hintText: 'Enter Phone Number',
                enabled: !_isLoading,
                onChanged: (phoneValue) {
                  _normalizedE164Phone = phoneValue.e164;
                  _selectedDialCode = phoneValue.dialCode;
                },
              ),

              if (_errorMessage.isNotEmpty) ...[
                const SizedBox(height: 8),
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

              const SizedBox(height: 24),

              AuthActionButton(
                text: 'Send Verification Code',
                isLoading: _isLoading,
                onPressed: _handleSendOtp,
                trailingIcon: Icons.arrow_forward_rounded,
              ),

              const SizedBox(height: 20),

              // Back to sign in link
              Center(
                child: TextButton.icon(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(
                    Icons.arrow_back_rounded,
                    size: 16,
                    color: Color(0xFF657991),
                  ),
                  label: const Text(
                    'Back to Sign In',
                    style: TextStyle(
                      color: Color(0xFF657991),
                      fontWeight: FontWeight.w600,
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
