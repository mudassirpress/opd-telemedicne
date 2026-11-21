import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/features/auth/presentation/providers/user_provider.dart';
import 'package:telemedicine/features/auth/presentation/screens/complete_patient_profile_screen.dart';
import 'package:telemedicine/features/auth/presentation/widgets/auth_ui_components.dart';
import 'package:telemedicine/core/services/card_rate_limiter_service.dart';

/// Screen 3: Sign Up with Card
class SignUpWithCardScreen extends ConsumerStatefulWidget {
  const SignUpWithCardScreen({super.key});

  @override
  ConsumerState<SignUpWithCardScreen> createState() =>
      _SignUpWithCardScreenState();
}

class _SignUpWithCardScreenState extends ConsumerState<SignUpWithCardScreen> {
  final TextEditingController _cardNumberController = TextEditingController();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  bool _isLoading = false;
  String _errorMessage = '';
  bool _isLockedOut = false;
  int _remainingLockoutMinutes = 0;

  @override
  void initState() {
    super.initState();
    _checkLockoutStatus();
  }

  Future<void> _checkLockoutStatus() async {
    final locked = await CardRateLimiterService.instance.isLockedOut();
    if (locked && mounted) {
      final minutes =
          await CardRateLimiterService.instance.getRemainingLockoutMinutes();
      setState(() {
        _isLockedOut = true;
        _remainingLockoutMinutes = minutes;
        _errorMessage =
            'Card verification is temporarily locked ($minutes min remaining) due to too many invalid attempts.';
      });
    }
  }

  @override
  void dispose() {
    _cardNumberController.dispose();
    super.dispose();
  }

  Future<void> _handleVerifyCard() async {
    final locked = await CardRateLimiterService.instance.isLockedOut();
    if (locked) {
      final minutes =
          await CardRateLimiterService.instance.getRemainingLockoutMinutes();
      setState(() {
        _isLockedOut = true;
        _remainingLockoutMinutes = minutes;
        _errorMessage =
            'Card verification is locked. Please try again in $minutes minute(s).';
      });
      ToastService.instance.showError(_errorMessage);
      return;
    }

    if (!_formKey.currentState!.validate()) return;

    final rawCardNumber = _cardNumberController.text.replaceAll(
      RegExp(r'[^0-9]'),
      '',
    );

    if (rawCardNumber.length != 12) {
      setState(() {
        _errorMessage = 'Card Number must be exactly 12 digits';
      });
      ToastService.instance.showWarning('Please enter a 12-digit card number');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });

    try {
      final patientIdController = ref.read(patientIdControllerProvider);
      final result = await patientIdController.verifyPatientId(rawCardNumber);

      if (!mounted) return;

      if (result != null) {
        // Reset rate limiter on successful verification
        await CardRateLimiterService.instance.recordSuccess();

        setState(() {
          _isLoading = false;
          _isLockedOut = false;
        });
        ToastService.instance.showSuccess('Card verified successfully!');

        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => CompletePatientProfileScreen(
              patientIdModel: result,
              isPhoneAuth: false,
            ),
          ),
        );
      } else {
        // Record failed attempt and enforce brute-force protection
        final remaining =
            await CardRateLimiterService.instance.recordFailedAttempt();
        final isNowLocked = remaining == 0;
        final minutes = isNowLocked
            ? CardRateLimiterService.lockoutDuration.inMinutes
            : 0;

        setState(() {
          _isLoading = false;
          _isLockedOut = isNowLocked;
          _remainingLockoutMinutes = minutes;

          if (isNowLocked) {
            _errorMessage =
                'Too many failed attempts. Card verification is locked for $minutes minutes.';
          } else {
            final baseMsg = patientIdController.errorMessage.isNotEmpty
                ? patientIdController.errorMessage
                : 'Invalid Card Number.';
            _errorMessage = '$baseMsg ($remaining attempt(s) remaining)';
          }
        });

        ToastService.instance.showError(_errorMessage);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = 'Error verifying card: ${e.toString()}';
      });
      ToastService.instance.showError(_errorMessage);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F9FC),
      appBar: const AuthAppBar(title: 'Sign Up with Card'),
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
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 6),

                    // Graphic: OPD Telemedicine subscription scratch-card mockup
                    Center(
                      child: Container(
                        constraints: const BoxConstraints(maxHeight: 200),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(
                                0xFF0F233C,
                              ).withValues(alpha: 0.1),
                              blurRadius: 18,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(20),
                          child: Image.asset(
                            'assets/images/card_image.png',
                            fit: BoxFit.contain,
                            errorBuilder: (context, error, stackTrace) {
                              return Container(
                                height: 180,
                                width: double.infinity,
                                decoration: BoxDecoration(
                                  gradient: const LinearGradient(
                                    colors: [
                                      Color(0xFF0E7E75),
                                      Color(0xFF139A8F),
                                    ],
                                  ),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                padding: const EdgeInsets.all(20),
                                child: const Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.credit_card_rounded,
                                      size: 56,
                                      color: Colors.white,
                                    ),
                                    SizedBox(height: 10),
                                    Text(
                                      'Subscription Card\nXXXX XXXX XXXX',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(height: 28),

                    // Section Header: "Enter Card Details"
                    Center(
                      child: Text(
                        'Enter Card Details',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: context.fs(19),
                          fontWeight: FontWeight.w700,
                          color: const Color(0xFF1F2F44),
                        ),
                      ),
                    ),

                    const SizedBox(height: 6),

                    // Helper text: "Scratch your card and enter the 12-digit card number below."
                    Center(
                      child: Text(
                        'Scratch your card and enter the\n12-digit card number below.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: context.fs(13),
                          fontWeight: FontWeight.w500,
                          color: const Color(0xFF657991),
                          height: 1.35,
                        ),
                      ),
                    ),

                    const SizedBox(height: 26),

                    // Text Field: Leading card icon, placeholder "Enter 12-digit Card Number"
                    AuthTextField(
                      controller: _cardNumberController,
                      hintText: 'Enter 12-digit Card Number',
                      prefixIcon: Icons.credit_card_outlined,
                      keyboardType: TextInputType.number,
                      maxLength: 14, // Allows input with spacing if formatted
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(12),
                      ],
                      validator: (value) {
                        final digits = (value ?? '').replaceAll(
                          RegExp(r'[^0-9]'),
                          '',
                        );
                        if (digits.isEmpty) {
                          return 'Please enter your card number';
                        }
                        if (digits.length != 12) {
                          return 'Card number must be exactly 12 digits';
                        }
                        return null;
                      },
                    ),

                    if (_errorMessage.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
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

                    const SizedBox(height: 6),

                    // Button: "Verify Card" with a forward arrow
                    AuthActionButton(
                      text: _isLockedOut
                          ? 'Locked (${_remainingLockoutMinutes}m)'
                          : 'Verify Card',
                      isLoading: _isLoading,
                      onPressed: _isLockedOut ? null : _handleVerifyCard,
                      trailingIcon: Icons.arrow_forward_rounded,
                    ),

                    const SizedBox(height: 22),

                    // Info Notice: Card container with info icon
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEBF3FB),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: const Color(0xFFD0E2F4),
                          width: 1,
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          const Icon(
                            Icons.info_outline_rounded,
                            color: Color(0xFF1E5BB5),
                            size: 22,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Your subscription will be activated after card verification.',
                              style: TextStyle(
                                fontSize: context.fs(12.5),
                                fontWeight: FontWeight.w500,
                                color: const Color(0xFF2C4A6F),
                                height: 1.35,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 16),
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
