import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/core/services/auth_routing_service.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/features/auth/presentation/providers/user_provider.dart';
import 'package:telemedicine/features/auth/presentation/widgets/auth_ui_components.dart';
import 'package:telemedicine/shared/widgets/auth_layout.dart';

/// Screen 4: Sign Up without Card
class SignUpWithoutCardScreen extends ConsumerStatefulWidget {
  const SignUpWithoutCardScreen({super.key});

  @override
  ConsumerState<SignUpWithoutCardScreen> createState() =>
      _SignUpWithoutCardScreenState();
}

class _SignUpWithoutCardScreenState
    extends ConsumerState<SignUpWithoutCardScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  final TextEditingController _fullNameController = TextEditingController();
  final TextEditingController _mobileNumberController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmPasswordController =
      TextEditingController();

  bool _agreeToTerms = false;
  bool _isLoading = false;
  String _errorMessage = '';

  @override
  void dispose() {
    _fullNameController.dispose();
    _mobileNumberController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _handleCreateAccount() async {
    if (!_formKey.currentState!.validate()) return;

    if (!_agreeToTerms) {
      setState(() {
        _errorMessage =
            'Please accept the Terms & Conditions and Privacy Policy.';
      });
      ToastService.instance.showWarning(
        'Please agree to the Terms & Conditions and Privacy Policy',
      );
      return;
    }

    final fullName = _fullNameController.text.trim();
    final mobileNumber = _mobileNumberController.text.trim();
    final password = _passwordController.text.trim();

    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });

    try {
      final patientController = ref.read(patientControllerProvider);
      final success = await patientController.signUp(
        fullname: fullName,
        phoneNumber: mobileNumber,
        password: password,
      );

      if (!mounted) return;

      if (success) {
        setState(() => _isLoading = false);
        ToastService.instance.showSuccess(
          'Account created successfully! Welcome, $fullName.',
        );

        final user = patientController.currentUser;
        if (user != null) {
          AuthRoutingService.navigatePatientPostLogin(
            context,
            user: user,
            clearStack: true,
          );
        } else {
          Navigator.of(context).pop();
        }
      } else {
        setState(() {
          _isLoading = false;
          _errorMessage = patientController.errorMessage.isNotEmpty
              ? patientController.errorMessage
              : 'Failed to create account. Please try again.';
        });
        ToastService.instance.showError(_errorMessage);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = 'Sign up error: ${e.toString()}';
      });
      ToastService.instance.showError(_errorMessage);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F9FC),
      appBar: const AuthAppBar(title: 'Sign Up without Card'),
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: EdgeInsets.symmetric(
            horizontal: context.rsp(20),
            vertical: 12,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const SizedBox(height: 8),
                    const LogoCard(),
                    const SizedBox(height: 20),
                    // Header: "Create Your Account"
                    Center(
                      child: Text(
                        'Create Your Account',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: context.fs(21),
                          fontWeight: FontWeight.w700,
                          color: const Color(0xFF1F2F44),
                          letterSpacing: -0.4,
                        ),
                      ),
                    ),

                    const SizedBox(height: 6),

                    // Subtitle: "Enter your details to get started."
                    Center(
                      child: Text(
                        'Enter your details to get started.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: context.fs(13.5),
                          fontWeight: FontWeight.w500,
                          color: const Color(0xFF657991),
                        ),
                      ),
                    ),

                    const SizedBox(height: 28),

                    // Form Field 1: Full Name (Leading person icon)
                    AuthTextField(
                      controller: _fullNameController,
                      hintText: 'Full Name',
                      prefixIcon: Icons.person_outline_rounded,
                      keyboardType: TextInputType.name,
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Please enter your full name';
                        }
                        if (value.trim().length < 2) {
                          return 'Name must be at least 2 characters';
                        }
                        return null;
                      },
                    ),

                    // Form Field 2: Mobile Number (Leading phone icon)
                    // Note: Replaced optional email input with primary mobile phone input
                    AuthTextField(
                      controller: _mobileNumberController,
                      hintText: 'Mobile Number',
                      prefixIcon: Icons.phone_outlined,
                      keyboardType: TextInputType.phone,
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                          RegExp(r'[\d\+\s\-]'),
                        ),
                      ],
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Please enter your mobile number';
                        }
                        final cleanDigits = value.replaceAll(
                          RegExp(r'[^0-9]'),
                          '',
                        );
                        if (cleanDigits.length < 10 ||
                            cleanDigits.length > 15) {
                          return 'Please enter a valid mobile number (10-15 digits)';
                        }
                        return null;
                      },
                    ),

                    // Form Field 3: Password (Leading lock icon, trailing visibility toggle)
                    AuthTextField(
                      controller: _passwordController,
                      hintText: 'Create Password',
                      prefixIcon: Icons.lock_outline_rounded,
                      isPassword: true,
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Please enter a password';
                        }
                        if (value.trim().length < 6) {
                          return 'Password must be at least 6 characters';
                        }
                        return null;
                      },
                    ),

                    // Form Field 4: Confirm Password (Leading lock icon, trailing visibility toggle)
                    AuthTextField(
                      controller: _confirmPasswordController,
                      hintText: 'Confirm Password',
                      prefixIcon: Icons.lock_outline_rounded,
                      isPassword: true,
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Please confirm your password';
                        }
                        if (value.trim() != _passwordController.text.trim()) {
                          return 'Passwords do not match';
                        }
                        return null;
                      },
                    ),

                    // Checkbox Row: "I agree to the Terms & Conditions and Privacy Policy"
                    Padding(
                      padding: const EdgeInsets.only(top: 2, bottom: 20),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          SizedBox(
                            width: 24,
                            height: 24,
                            child: Checkbox(
                              value: _agreeToTerms,
                              activeColor: const Color(0xFF0B7D74),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(5),
                              ),
                              onChanged: (val) {
                                setState(() {
                                  _agreeToTerms = val ?? false;
                                  if (_agreeToTerms) _errorMessage = '';
                                });
                              },
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: RichText(
                              text: TextSpan(
                                text: 'I agree to the ',
                                style: TextStyle(
                                  fontSize: context.fs(12.5),
                                  color: const Color(0xFF4A607A),
                                  fontWeight: FontWeight.w500,
                                ),
                                children: [
                                  TextSpan(
                                    text: 'Terms & Conditions',
                                    style: const TextStyle(
                                      color: Color(0xFF0B7D74),
                                      fontWeight: FontWeight.w700,
                                      decoration: TextDecoration.underline,
                                    ),
                                    recognizer: TapGestureRecognizer()
                                      ..onTap = () {
                                        TermsAndPrivacyModal.show(
                                          context,
                                          isPrivacyPolicy: false,
                                        );
                                      },
                                  ),
                                  const TextSpan(text: ' and '),
                                  TextSpan(
                                    text: 'Privacy Policy',
                                    style: const TextStyle(
                                      color: Color(0xFF0B7D74),
                                      fontWeight: FontWeight.w700,
                                      decoration: TextDecoration.underline,
                                    ),
                                    recognizer: TapGestureRecognizer()
                                      ..onTap = () {
                                        TermsAndPrivacyModal.show(
                                          context,
                                          isPrivacyPolicy: true,
                                        );
                                      },
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    if (_errorMessage.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: Center(
                          child: Text(
                            _errorMessage,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.red,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                    ],

                    // Button: "Create Account" with a forward arrow
                    AuthActionButton(
                      text: 'Create Account',
                      isLoading: _isLoading,
                      onPressed: _handleCreateAccount,
                      trailingIcon: Icons.arrow_forward_rounded,
                    ),

                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
