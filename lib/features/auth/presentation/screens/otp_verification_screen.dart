import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/features/auth/presentation/providers/user_provider.dart';
import 'package:telemedicine/features/auth/presentation/screens/complete_patient_profile_screen.dart';
import 'package:telemedicine/core/services/auth_routing_service.dart';
import 'package:telemedicine/app/theme/app_theme.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/features/patients/presentation/patient_portal_wrapper.dart';
import 'package:telemedicine/features/auth/data/services/phone_auth_service.dart';
import 'package:telemedicine/shared/widgets/auth_layout.dart';

/// Screen for verifying the 6-digit SMS OTP sent via Firebase Phone Authentication.
class OtpVerificationScreen extends ConsumerStatefulWidget {
  final String phoneNumber;
  final String rawPhone;
  final String verificationId;
  final int? resendToken;

  const OtpVerificationScreen({
    super.key,
    required this.phoneNumber,
    required this.rawPhone,
    required this.verificationId,
    this.resendToken,
  });

  @override
  ConsumerState<OtpVerificationScreen> createState() =>
      _OtpVerificationScreenState();
}

class _OtpVerificationScreenState extends ConsumerState<OtpVerificationScreen> {
  final TextEditingController _otpController = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  late String _verificationId;
  int? _resendToken;

  bool _isVerifying = false;
  bool _isResending = false;
  int _countdown = 60;
  Timer? _timer;
  String _errorMessage = '';

  @override
  void initState() {
    super.initState();
    _verificationId = widget.verificationId;
    _resendToken = widget.resendToken;
    _startCountdown();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _otpController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _startCountdown() {
    _timer?.cancel();
    setState(() {
      _countdown = 60;
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_countdown > 0) {
        if (mounted) {
          setState(() {
            _countdown--;
          });
        }
      } else {
        timer.cancel();
      }
    });
  }

  Future<void> _resendOtp() async {
    if (_countdown > 0 || _isResending) return;

    setState(() {
      _isResending = true;
      _errorMessage = '';
    });

    try {
      await PhoneAuthService.instance.sendOtp(
        phoneNumber: widget.phoneNumber,
        resendToken: _resendToken,
        onCodeSent: (String newVerificationId, int? token) {
          if (!mounted) return;
          setState(() {
            _verificationId = newVerificationId;
            _resendToken = token;
            _isResending = false;
          });
          _startCountdown();
          ToastService.instance.showSuccess(
            'A new verification code has been sent.',
          );
        },
        onVerificationFailed: (FirebaseAuthException e) {
          if (!mounted) return;
          setState(() {
            _isResending = false;
            _errorMessage = e.message ?? 'Failed to resend verification code.';
          });
          ToastService.instance.showError(_errorMessage);
        },
        onVerificationCompleted: (PhoneAuthCredential credential) async {
          if (!mounted) return;
          await _onInstantVerification(credential);
        },
        onCodeAutoRetrievalTimeout: (String newVerificationId) {
          if (mounted) {
            _verificationId = newVerificationId;
          }
        },
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isResending = false;
        _errorMessage = 'Error resending code: ${e.toString()}';
      });
      ToastService.instance.showError(_errorMessage);
    }
  }

  Future<void> _onInstantVerification(PhoneAuthCredential credential) async {
    try {
      setState(() => _isVerifying = true);
      final userCredential = await PhoneAuthService.instance
          .signInWithCredential(credential);
      final firebaseUser = userCredential.user;
      if (firebaseUser != null) {
        await _handlePostAuth(firebaseUser);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isVerifying = false;
          _errorMessage = 'Instant verification failed: ${e.toString()}';
        });
      }
    }
  }

  Future<void> _verifyOtp() async {
    final code = _otpController.text.trim();
    if (code.length != 6) {
      setState(() {
        _errorMessage = 'Please enter a valid 6-digit code';
      });
      ToastService.instance.showWarning('Please enter a 6-digit code');
      return;
    }

    setState(() {
      _isVerifying = true;
      _errorMessage = '';
    });

    try {
      final userCredential = await PhoneAuthService.instance.verifyOtp(
        verificationId: _verificationId,
        smsCode: code,
      );

      final firebaseUser = userCredential.user;
      if (firebaseUser == null) {
        throw Exception('User authentication failed.');
      }

      await _handlePostAuth(firebaseUser);
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _isVerifying = false;
        if (e.code == 'invalid-verification-code') {
          _errorMessage = 'Invalid code. Please check the SMS and try again.';
        } else if (e.code == 'session-expired') {
          _errorMessage =
              'The verification code has expired. Please request a new code.';
        } else {
          _errorMessage = e.message ?? 'Verification failed. Please try again.';
        }
      });
      ToastService.instance.showError(_errorMessage);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isVerifying = false;
        _errorMessage = 'Verification error: ${e.toString()}';
      });
      ToastService.instance.showError(_errorMessage);
    }
  }

  Future<void> _handlePostAuth(User firebaseUser) async {
    final patientController = ref.read(patientControllerProvider);

    final result = await patientController.signInWithFirebasePhoneUser(
      firebaseUser: firebaseUser,
      rawPhone: widget.rawPhone,
      normalizedPhone: widget.phoneNumber,
    );

    if (!mounted) return;

    if (!result.success) {
      setState(() {
        _isVerifying = false;
        _errorMessage = result.errorMessage ?? 'Authentication failed.';
      });
      ToastService.instance.showError(_errorMessage);
      return;
    }

    ToastService.instance.showSuccess('Phone number verified successfully!');

    if (result.needsProfileCompletion) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (context) => CompletePatientProfileScreen(
            patientIdModel: null,
            prefilledPhone: widget.phoneNumber,
            verifiedPhone: widget.phoneNumber,
            patientUid: firebaseUser.uid,
            isPhoneAuth: true,
          ),
        ),
        (route) => false,
      );
    } else {
      final user = result.user ?? patientController.currentUser;
      if (user != null) {
        AuthRoutingService.navigatePatientPostLogin(
          context,
          user: user,
          clearStack: true,
        );
      } else {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (context) => const PatientPortalWrapper()),
          (route) => false,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthScreenLayout(
      title: 'Verification Code',
      subtitle: 'Enter the 6-digit SMS code sent to\n${widget.phoneNumber}',
      child: Column(
        children: [
          // 6-digit Code Entry
          Container(
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
              borderRadius: BorderRadius.circular(30),
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
              height: 52,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFFF3F7FB), Colors.white, Color(0xFFF0F4F9)],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
                borderRadius: BorderRadius.circular(27),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.sms_rounded,
                    color: Color(0xFF0E274D),
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _otpController,
                      focusNode: _focusNode,
                      keyboardType: TextInputType.number,
                      textAlign: TextAlign.center,
                      maxLength: 6,
                      style: TextStyle(
                        fontSize: context.fs(22),
                        fontWeight: FontWeight.bold,
                        letterSpacing: 10.0,
                        color: const Color(0xFF1E2F44),
                      ),
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: InputDecoration(
                        hintText: '• • • • • •',
                        hintStyle: TextStyle(
                          color: const Color(0xFF9AAEC4),
                          fontSize: context.fs(20),
                          letterSpacing: 8.0,
                        ),
                        border: InputBorder.none,
                        counterText: '',
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                      onChanged: (val) {
                        if (val.trim().length == 6) {
                          _verifyOtp();
                        }
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),

          if (_errorMessage.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _errorMessage,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.red,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),

          SizedBox(height: context.rsp(22)),

          // Verify Button
          GradientButton(
            text: 'Verify & Continue',
            isLoading: _isVerifying,
            onPressed: _verifyOtp,
            icon: Icons.check_circle_rounded,
          ),

          SizedBox(height: context.rsp(20)),

          // Resend Code and Change Number Row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  'Change Number',
                  style: TextStyle(
                    fontSize: context.fs(13),
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF657991),
                  ),
                ),
              ),
              TextButton(
                onPressed: _countdown == 0 ? _resendOtp : null,
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: _isResending
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(
                        _countdown > 0
                            ? 'Resend Code in ${_countdown}s'
                            : 'Resend Code',
                        style: TextStyle(
                          fontSize: context.fs(13),
                          fontWeight: FontWeight.bold,
                          color: _countdown == 0
                              ? AppColors.primaryRed
                              : const Color(0xFF8899AC),
                        ),
                      ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
