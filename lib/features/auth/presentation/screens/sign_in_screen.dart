import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:telemedicine/core/services/auth_routing_service.dart';
import 'package:telemedicine/core/services/guest_mode_service.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/features/auth/data/services/patient_password_reset_service.dart';
import 'package:telemedicine/features/auth/data/services/phone_auth_service.dart';
import 'package:telemedicine/features/auth/presentation/providers/user_provider.dart';
import 'package:telemedicine/features/auth/presentation/screens/complete_patient_profile_screen.dart';
import 'package:telemedicine/features/auth/presentation/screens/expired_patient_screen.dart';
import 'package:telemedicine/features/auth/presentation/screens/forgot_password_phone_screen.dart';
import 'package:telemedicine/features/auth/presentation/screens/otp_verification_screen.dart';
import 'package:telemedicine/features/auth/presentation/widgets/auth_ui_components.dart';
import 'package:telemedicine/features/patients/presentation/patient_portal_wrapper.dart';
import 'package:telemedicine/shared/widgets/auth_layout.dart';

/// Screen 5: Sign In (Patient)
class SignInScreen extends ConsumerStatefulWidget {
  final String? initialPhone;
  final int initialLoginMode; // Kept for backwards compatibility

  const SignInScreen({super.key, this.initialPhone, this.initialLoginMode = 0});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  final TextEditingController _identifierController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  bool _rememberMe = true;
  bool _isLoading = false;
  String _errorMessage = '';
  String _identifierError = '';
  String _passwordError = '';

  @override
  void initState() {
    super.initState();
    _loadSavedCredentials();
    if (widget.initialPhone != null && widget.initialPhone!.trim().isNotEmpty) {
      _identifierController.text = widget.initialPhone!.trim();
    }
  }

  Future<void> _loadSavedCredentials() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedId = prefs.getString('saved_patient_identifier');
      if (savedId != null && savedId.isNotEmpty && mounted) {
        setState(() {
          _identifierController.text = savedId;
          _rememberMe = true;
        });
      }
    } catch (_) {}
  }

  Future<void> _saveCredentials(String identifier) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_rememberMe) {
        await prefs.setString('saved_patient_identifier', identifier);
      } else {
        await prefs.remove('saved_patient_identifier');
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _identifierController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _handleSignIn() async {
    if (!_formKey.currentState!.validate()) return;

    final identifier = _identifierController.text.trim();
    final password = _passwordController.text.trim();

    setState(() {
      _isLoading = true;
      _errorMessage = '';
      _identifierError = '';
      _passwordError = '';
    });

    try {
      final patientController = ref.read(patientControllerProvider);
      bool success = false;
      bool attemptedPhone = false;

      final cleanId = identifier.replaceAll(RegExp(r'[\s\-]'), '');

      // 1. If identifier looks like a phone number, try phone sign in first
      if (cleanId.startsWith('+92') ||
          cleanId.startsWith('03') ||
          (cleanId.length >= 10 &&
              cleanId.length <= 11 &&
              RegExp(r'^\d+$').hasMatch(cleanId))) {
        attemptedPhone = true;
        success = await patientController.signIn(
          phoneNumber: cleanId,
          password: password,
        );
      }

      // 2. If phone login did not succeed or identifier is a card/patient ID, try card ID login
      // only if phone lookup didn't find the user (don't overwrite password mismatch or account lock errors)
      if (!success &&
          (!attemptedPhone ||
              patientController.errorMessage.toLowerCase().contains(
                'no user found',
              ))) {
        final cardRes = await patientController.signInWithPatientCardId(
          cardId: cleanId,
        );
        if (cardRes.success && cardRes.user != null) {
          success = true;
        }
      }

      // 3. Fallback: try phone login with raw identifier if not attempted yet
      if (!success && !attemptedPhone) {
        success = await patientController.signIn(
          phoneNumber: cleanId,
          password: password,
        );
      }

      if (!mounted) return;

      if (success) {
        await _saveCredentials(identifier);
        GuestModeService.exitGuestMode(ref);

        final user = patientController.currentUser;
        setState(() => _isLoading = false);

        if (user != null) {
          AuthRoutingService.navigatePatientPostLogin(
            context,
            user: user,
            clearStack: true,
          );
        } else {
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(
              builder: (context) => const PatientPortalWrapper(),
            ),
            (route) => false,
          );
        }
      } else {
        String msg = patientController.errorMessage.trim();
        if (msg.isEmpty) {
          msg =
              'Invalid credentials. Please verify your Mobile / Patient ID and Password.';
        }

        String idErr = '';
        String pwdErr = '';

        if (msg.toLowerCase().contains('incorrect password')) {
          pwdErr = 'Incorrect password. Please try again.';
          msg = 'Incorrect password. Please check your password.';
        } else if (msg.toLowerCase().contains('no user found') ||
            msg.toLowerCase().contains('invalid patient card id') ||
            msg.toLowerCase().contains('not found')) {
          idErr = 'Account not found with this Mobile Number or Patient ID.';
          msg =
              'No patient account found with this Mobile Number or Patient ID.';
        }

        setState(() {
          _isLoading = false;
          _errorMessage = msg;
          _identifierError = idErr;
          _passwordError = pwdErr;
        });
        ToastService.instance.showError(msg);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = 'Sign in error: ${e.toString()}';
      });
      ToastService.instance.showError(_errorMessage);
    }
  }

  void _showForgotPasswordDialog() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ForgotPasswordPhoneScreen(
          initialPhone: _identifierController.text.trim(),
        ),
      ),
    );
  }

  void _showSignInWithOtpDialog() {
    final phoneOtpController = TextEditingController(
      text: _identifierController.text.trim(),
    );
    bool isSending = false;
    String otpError = '';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                left: 24,
                right: 24,
                top: 20,
                bottom: MediaQuery.of(context).viewInsets.bottom + 24,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.grey[300],
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    'Sign In with OTP',
                    style: TextStyle(
                      fontSize: context.fs(18),
                      fontWeight: FontWeight.w700,
                      color: const Color(0xFF1F2F44),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Enter your registered phone number to receive a 6-digit one-time code.',
                    style: TextStyle(
                      fontSize: context.fs(13),
                      color: const Color(0xFF657991),
                    ),
                  ),
                  const SizedBox(height: 18),
                  AuthTextField(
                    controller: phoneOtpController,
                    hintText: 'Phone Number (e.g. 03XXXXXXXXX)',
                    prefixIcon: Icons.phone_android_rounded,
                    keyboardType: TextInputType.phone,
                  ),
                  if (otpError.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Text(
                        otpError,
                        style: const TextStyle(color: Colors.red, fontSize: 12),
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  AuthActionButton(
                    text: 'Send Verification Code',
                    isLoading: isSending,
                    onPressed: () async {
                      final rawPhone = phoneOtpController.text.trim();
                      if (rawPhone.isEmpty) {
                        setModalState(
                          () => otpError = 'Please enter phone number',
                        );
                        return;
                      }

                      String normalizedPhone = rawPhone;
                      if (!normalizedPhone.startsWith('+')) {
                        if (normalizedPhone.startsWith('0')) {
                          normalizedPhone =
                              '+92${normalizedPhone.substring(1)}';
                        } else {
                          normalizedPhone = '+92$normalizedPhone';
                        }
                      }

                      setModalState(() {
                        isSending = true;
                        otpError = '';
                      });

                      try {
                        await PhoneAuthService.instance.sendOtp(
                          phoneNumber: normalizedPhone,
                          onCodeSent:
                              (String verificationId, int? resendToken) {
                                if (!mounted) return;
                                Navigator.pop(ctx);
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => OtpVerificationScreen(
                                      phoneNumber: normalizedPhone,
                                      rawPhone: rawPhone,
                                      verificationId: verificationId,
                                      resendToken: resendToken,
                                    ),
                                  ),
                                );
                              },
                          onVerificationFailed: (e) {
                            setModalState(() {
                              isSending = false;
                              otpError = e.message ?? 'Verification failed';
                            });
                          },
                          onVerificationCompleted: (_) {},
                          onCodeAutoRetrievalTimeout: (_) {},
                        );
                      } catch (e) {
                        setModalState(() {
                          isSending = false;
                          otpError = e.toString();
                        });
                      }
                    },
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F9FC),
      appBar: const AuthAppBar(title: 'Sign In'),
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
                    // Header: "Welcome Back"
                    Center(
                      child: Text(
                        'Welcome Back',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: context.fs(22),
                          fontWeight: FontWeight.w700,
                          color: const Color(0xFF1F2F44),
                          letterSpacing: -0.4,
                        ),
                      ),
                    ),

                    const SizedBox(height: 6),

                    // Subtitle: "Sign in to your patient account."
                    Center(
                      child: Text(
                        'Sign in to your patient account.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: context.fs(13.5),
                          fontWeight: FontWeight.w500,
                          color: const Color(0xFF657991),
                        ),
                      ),
                    ),

                    const SizedBox(height: 32),

                    // Form Field 1: Mobile Number or Patient ID (Leading phone icon)
                    AuthTextField(
                      controller: _identifierController,
                      hintText: 'Mobile Number or Patient ID',
                      prefixIcon: Icons.phone_outlined,
                      keyboardType: TextInputType.text,
                      errorText: _identifierError.isNotEmpty
                          ? _identifierError
                          : null,
                      onChanged: (val) {
                        if (_identifierError.isNotEmpty ||
                            _errorMessage.isNotEmpty) {
                          setState(() {
                            _identifierError = '';
                            _errorMessage = '';
                          });
                        }
                      },
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Please enter your Mobile Number or Patient ID';
                        }
                        return null;
                      },
                    ),

                    // Form Field 2: Password (Leading lock icon, trailing visibility toggle)
                    AuthTextField(
                      controller: _passwordController,
                      hintText: 'Password',
                      prefixIcon: Icons.lock_outline_rounded,
                      isPassword: true,
                      errorText: _passwordError.isNotEmpty
                          ? _passwordError
                          : null,
                      onChanged: (val) {
                        if (_passwordError.isNotEmpty ||
                            _errorMessage.isNotEmpty) {
                          setState(() {
                            _passwordError = '';
                            _errorMessage = '';
                          });
                        }
                      },
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Please enter your password';
                        }
                        return null;
                      },
                    ),

                    // Controls Row: "Remember Me" checkbox on the left, "Forgot Password?" text button on the right
                    Padding(
                      padding: const EdgeInsets.only(top: 2, bottom: 20),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 22,
                                height: 22,
                                child: Checkbox(
                                  value: _rememberMe,
                                  activeColor: const Color(0xFF0F3260),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  onChanged: (val) {
                                    setState(() {
                                      _rememberMe = val ?? false;
                                    });
                                  },
                                ),
                              ),
                              const SizedBox(width: 8),
                              GestureDetector(
                                onTap: () {
                                  setState(() {
                                    _rememberMe = !_rememberMe;
                                  });
                                },
                                child: Text(
                                  'Remember Me',
                                  style: TextStyle(
                                    fontSize: context.fs(13),
                                    fontWeight: FontWeight.w500,
                                    color: const Color(0xFF4A607A),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          TextButton(
                            onPressed: _showForgotPasswordDialog,
                            style: TextButton.styleFrom(
                              padding: EdgeInsets.zero,
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: Text(
                              'Forgot Password?',
                              style: TextStyle(
                                fontSize: context.fs(13),
                                fontWeight: FontWeight.w600,
                                color: const Color(0xFF1E5BB5),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    if (_errorMessage.isNotEmpty) ...[
                      Container(
                        margin: const EdgeInsets.only(bottom: 16),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF0F0),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: const Color(0xFFFCA5A5),
                            width: 1.2,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(
                                0xFFDC2626,
                              ).withValues(alpha: 0.06),
                              blurRadius: 8,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Padding(
                              padding: EdgeInsets.only(top: 1),
                              child: Icon(
                                Icons.error_outline_rounded,
                                color: Color(0xFFDC2626),
                                size: 20,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                _errorMessage,
                                style: TextStyle(
                                  color: const Color(0xFF991B1B),
                                  fontSize: context.fs(13),
                                  fontWeight: FontWeight.w600,
                                  height: 1.35,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],

                    // Action Button: "Sign In" with a forward arrow
                    AuthActionButton(
                      text: 'Sign In',
                      isLoading: _isLoading,
                      onPressed: _handleSignIn,
                      trailingIcon: Icons.arrow_forward_rounded,
                    ),

                    const SizedBox(height: 20),
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
