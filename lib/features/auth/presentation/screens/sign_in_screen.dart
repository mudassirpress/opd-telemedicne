import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/features/auth/presentation/providers/user_provider.dart';
import 'package:telemedicine/features/auth/presentation/screens/complete_patient_profile_screen.dart';
import 'package:telemedicine/features/auth/presentation/screens/expired_patient_screen.dart';
import 'package:telemedicine/features/doctors/presentation/screens/update_doctor_profile_screen.dart';
import 'package:telemedicine/features/auth/presentation/controllers/doctor_controller.dart';
import 'package:telemedicine/core/services/auth_routing_service.dart';
import 'package:telemedicine/core/services/device_service.dart';
import 'package:telemedicine/core/services/guest_mode_service.dart';
import 'package:telemedicine/core/services/notification_service.dart';
import 'package:telemedicine/core/services/single_device_session_service.dart';
import 'package:telemedicine/app/theme/app_theme.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/data/models/patient_id_model.dart';
import 'package:telemedicine/data/models/user_model.dart';
import 'package:telemedicine/features/doctor_portal/presentation/bottom_nav/doctor_portal_wrapper.dart';
import 'package:telemedicine/features/patients/presentation/patient_portal_wrapper.dart';
import 'package:telemedicine/features/auth/data/services/patient_phone_auth_service.dart';
import 'package:telemedicine/shared/widgets/auth_layout.dart';
import 'package:telemedicine/shared/widgets/international_phone_input.dart';

class SignInScreen extends ConsumerStatefulWidget {
  final String? initialPhone;
  final int initialLoginMode; // 0 = Patient, 1 = Doctor

  const SignInScreen({super.key, this.initialPhone, this.initialLoginMode = 0});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final GlobalKey<FormState> formkey = GlobalKey<FormState>();
  final PatientPhoneAuthService _phoneAuthService = PatientPhoneAuthService();

  // Mode: 0 = Patient, 1 = Doctor
  int _loginMode = 0;

  // Patient Card toggle (ON = 12-digit card ID, OFF = phone number OTP)
  bool _hasPatientCard = false;

  // OTP Step for Phone Auth
  bool _isOtpStep = false;
  String _activeNormalizedPhone = '';
  int _resendCountdown = 0;
  Timer? _resendTimer;

  // Text Controllers
  final phoneController = TextEditingController();
  final otpController = TextEditingController();
  final patientCardIdController = TextEditingController();
  final doctorIdController = TextEditingController();

  String errorText = '';
  bool isLoading = false;

  String _patientDialCode = '+92';
  String _patientIsoCode = 'PK';

  @override
  void initState() {
    super.initState();
    _loginMode = widget.initialLoginMode;
    if (widget.initialPhone != null && widget.initialPhone!.trim().isNotEmpty) {
      phoneController.text = widget.initialPhone!.trim();
    }
  }

  @override
  void dispose() {
    _resendTimer?.cancel();
    phoneController.dispose();
    otpController.dispose();
    patientCardIdController.dispose();
    doctorIdController.dispose();
    super.dispose();
  }

  void _navigateAndClearStack(Widget screen) {
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (context) => screen),
      (Route<dynamic> route) => false,
    );
  }

  void _startResendTimer([int seconds = 60]) {
    _resendTimer?.cancel();
    setState(() => _resendCountdown = seconds);
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_resendCountdown <= 1) {
        timer.cancel();
        setState(() => _resendCountdown = 0);
      } else {
        setState(() => _resendCountdown--);
      }
    });
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Phone OTP Flow
  // ───────────────────────────────────────────────────────────────────────────

  Future<void> handleSendOtp() async {
    if (!formkey.currentState!.validate()) return;

    final rawPhone = phoneController.text.trim();
    if (rawPhone.isEmpty) {
      setState(() => errorText = 'Please enter your phone number');
      ToastService.instance.showWarning('Please enter your phone number');
      return;
    }

    setState(() {
      isLoading = true;
      errorText = '';
    });

    try {
      final result = await _phoneAuthService.sendLoginOtp(
        rawPhone: rawPhone,
        defaultDialCode: _patientDialCode,
      );

      if (!mounted) return;

      setState(() {
        _activeNormalizedPhone = result.normalizedPhone;
        _isOtpStep = true;
        isLoading = false;
        errorText = '';
      });

      _startResendTimer(result.resendInSeconds);
      ToastService.instance.showSuccess(result.message);
    } on PatientPhoneAuthException catch (e) {
      if (!mounted) return;
      setState(() {
        isLoading = false;
        errorText = e.message;
      });
      ToastService.instance.showError(e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        isLoading = false;
        errorText = 'Failed to send verification code. Please try again.';
      });
      ToastService.instance.showError('Error: ${e.toString()}');
    }
  }

  Future<void> handleVerifyOtp() async {
    final otp = otpController.text.trim();
    if (otp.length != 6) {
      setState(() => errorText = 'Please enter the 6-digit verification code');
      ToastService.instance.showWarning('6-digit code required');
      return;
    }

    setState(() {
      isLoading = true;
      errorText = '';
    });

    try {
      final result = await _phoneAuthService.verifyLoginOtp(
        normalizedPhone: _activeNormalizedPhone,
        otp: otp,
        defaultDialCode: _patientDialCode,
      );

      if (!mounted) return;

      // Ensure Guest Mode is turned off
      GuestModeService.exitGuestMode(ref);

      final patientController = ref.read(patientControllerProvider);

      // Case 1: Existing patient with complete profile
      if (result.isExistingUser &&
          result.existingUser != null &&
          result.isProfileComplete) {
        final user = result.existingUser!;

        // Authoritative single-device session verification and claim
        final currentDeviceId = await DeviceService.getDeviceId();
        final claimResult =
            await SingleDeviceSessionService.validateAndClaimSession(
          collectionName: 'telemedicine_patient',
          documentId: user.id,
          currentDeviceId: currentDeviceId,
          blockSecondLogin: false, // OTP verified on this phone
        );

        if (!mounted) return;

        if (!claimResult.allowed) {
          await patientController.signOut();
          if (!mounted) return;
          setState(() {
            isLoading = false;
            errorText = claimResult.errorMessage ??
                'This account is locked to another device.';
          });
          ToastService.instance.showError(errorText);
          return;
        }

        // Save FCM token for push notifications
        try {
          await NotificationService().saveTokenToFirestore(user.id, user.role);
        } catch (_) {}

        GuestModeService.exitGuestMode(ref);
        patientController.setCurrentUser(user);
        await patientController.loadSavedUser();

        ToastService.instance.showSuccess('Welcome back, ${user.fullname}!');
        AuthRoutingService.navigatePatientPostLogin(
          context,
          user: user,
          clearStack: true,
        );
        return;
      }

      // Case 2: New patient or incomplete profile -> complete profile
      GuestModeService.exitGuestMode(ref);
      if (result.existingUser != null) {
        patientController.setCurrentUser(result.existingUser!);
      }
      final resolvedUid = result.firebaseUser?.uid ?? result.existingUser?.id;
      debugPrint(
        '🔑 [SignInScreen] Phone verified. Navigating to CompletePatientProfileScreen with UID: $resolvedUid',
      );
      ToastService.instance.showSuccess(
        'Phone verified! Please complete your profile.',
      );
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => CompletePatientProfileScreen(
            verifiedPhone: _activeNormalizedPhone,
            patientUid: resolvedUid,
            isPhoneAuth: true,
          ),
        ),
      );
    } on PatientPhoneAuthException catch (e) {
      if (!mounted) return;
      setState(() {
        isLoading = false;
        errorText = e.message;
      });
      ToastService.instance.showError(e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        isLoading = false;
        errorText = 'Verification failed. Please try again.';
      });
      ToastService.instance.showError('Verification error: ${e.toString()}');
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Patient Card Login Flow (12 Digits)
  // ───────────────────────────────────────────────────────────────────────────

  Future<void> handlePatientCardSignIn() async {
    if (!formkey.currentState!.validate()) return;

    final cardId = patientCardIdController.text.trim();
    if (cardId.length != 12) {
      setState(() => errorText = 'Patient Card ID must be exactly 12 digits');
      ToastService.instance.showWarning('12-digit Patient Card ID required');
      return;
    }

    setState(() {
      isLoading = true;
      errorText = '';
    });

    try {
      final patientController = ref.read(patientControllerProvider);
      final result = await patientController.validateAndAuthenticatePatientCard(
        patientId: cardId,
      );

      if (!mounted) return;

      if (result == null ||
          result['status'] == 'not_found' ||
          result['status'] == 'error') {
        setState(() {
          isLoading = false;
          errorText = patientController.errorMessage.isNotEmpty
              ? patientController.errorMessage
              : 'Invalid Patient Card ID';
        });
        ToastService.instance.showError(errorText);
        return;
      }

      final status = result['status'] as String;

      if (status == 'blocked') {
        setState(() {
          isLoading = false;
          errorText = 'This Patient Card has been blocked or revoked.';
        });
        ToastService.instance.showError(errorText);
        return;
      }

      if (status == 'expired') {
        setState(() => isLoading = false);
        ToastService.instance.showError('Your Patient Card has expired.');
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const ExpiredPatientScreen()),
        );
        return;
      }

      // Guest Mode exit
      GuestModeService.exitGuestMode(ref);

      // Card is Available -> Navigate to complete profile with Card Model
      if (status == 'available') {
        setState(() => isLoading = false);
        final cardData = result['cardData'] as Map<String, dynamic>;
        final cardDocId = result['cardDocId'] as String;
        final cardModel = PatientIdModel.fromMap({
          ...cardData,
          'id': cardDocId,
        });

        ToastService.instance.showSuccess(
          'Patient Card verified! Please complete your profile.',
        );
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => CompletePatientProfileScreen(
              patientIdModel: cardModel,
              isPhoneAuth: false,
            ),
          ),
        );
        return;
      }

      // Card is Authenticated -> Logged in directly
      if (status == 'authenticated') {
        final user = result['user'] as UserModel;
        final isComplete = result['isProfileComplete'] == true;

        if (isComplete) {
          final currentDeviceId = await DeviceService.getDeviceId();
          await SingleDeviceSessionService.validateAndClaimSession(
            collectionName: 'telemedicine_patient',
            documentId: user.id,
            currentDeviceId: currentDeviceId,
            blockSecondLogin: false,
          );
          patientController.setCurrentUser(user);
          await patientController.loadSavedUser();

          ToastService.instance.showSuccess('Welcome back, ${user.fullname}!');
          AuthRoutingService.navigatePatientPostLogin(
            context,
            user: user,
            clearStack: true,
          );
        } else {
          ToastService.instance.showInfo(
            'Please finish completing your profile.',
          );
          final cardModel = PatientIdModel(
            id: '',
            patientId: cardId,
            status: 'Assigned',
            batchNumber: '',
            generatedAt: DateTime.now(),
            patientUserId: user.id,
          );
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => CompletePatientProfileScreen(
                patientIdModel: cardModel,
                patientUid: user.id,
                prefilledPhone: user.phoneNumber,
                isPhoneAuth: false,
              ),
            ),
          );
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        isLoading = false;
        errorText = 'Card verification error: ${e.toString()}';
      });
      ToastService.instance.showError(errorText);
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Doctor Login Flow (4 Digits)
  // ───────────────────────────────────────────────────────────────────────────

  Future<void> handleDoctorSignIn() async {
    if (!formkey.currentState!.validate()) return;

    final doctorId = doctorIdController.text.trim();
    if (doctorId.length != 4) {
      setState(() => errorText = 'Doctor ID must be exactly 4 digits');
      ToastService.instance.showWarning('4-digit Doctor ID required');
      return;
    }

    setState(() {
      isLoading = true;
      errorText = '';
    });

    try {
      await ref.read(patientControllerProvider).signOut();
      if (!mounted) return;

      final doctorController = ref.read(doctorControllerProvider);
      final success = await doctorController.signInWithDoctorId(
        doctorId: doctorId,
      );

      if (!mounted) return;

      if (success) {
        GuestModeService.exitGuestMode(ref);
        final doctor = doctorController.currentDoctor;

        if (doctor?.role != 'doctor') {
          await doctorController.signOut();
          if (!mounted) return;
          setState(() {
            errorText = 'This account is not registered as a doctor.';
            isLoading = false;
          });
          ToastService.instance.showError('Invalid doctor account');
          return;
        }

        final bool isProfileComplete =
            doctor?.fullname != null &&
            doctor!.fullname.isNotEmpty &&
            doctor.highestDegree != null &&
            doctor.highestDegree!.isNotEmpty;

        final latestDoctorData = await doctorController.getDoctorProfile(
          doctor!.id,
        );
        if (!mounted) return;

        final latestDoctor = latestDoctorData != null
            ? DoctorController.doctorFromProfileData(latestDoctorData)
            : doctor;
        final bool missingBookingFields =
            DoctorController.isMissingRequiredProfileFields(latestDoctor);

        if (!isProfileComplete || missingBookingFields) {
          ToastService.instance.showInfo('Please complete your doctor profile');
          _navigateAndClearStack(const UpdateDoctorProfileScreen());
        } else {
          ToastService.instance.showSuccess('Welcome Dr. ${doctor.fullname}!');
          _navigateAndClearStack(const DoctorPortalWrapper());
        }
      } else {
        setState(() {
          errorText = doctorController.errorMessage.isNotEmpty
              ? doctorController.errorMessage
              : 'Invalid Doctor ID';
          isLoading = false;
        });
        ToastService.instance.showError(errorText);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        isLoading = false;
        errorText = 'Doctor sign-in error: ${e.toString()}';
      });
      ToastService.instance.showError(errorText);
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Guest Mode Entry
  // ───────────────────────────────────────────────────────────────────────────

  void handleEnterGuestMode() {
    GuestModeService.enterGuestMode(ref);
    ref.read(patientControllerProvider).signOut();
    ToastService.instance.showInfo('Welcome to Guest Mode');
    _navigateAndClearStack(const PatientPortalWrapper());
  }

  // ───────────────────────────────────────────────────────────────────────────
  // UI Builders
  // ───────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEDF2F8),
      body: Stack(
        children: [
          // Background ECG Waveform Watermark
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
                      const SizedBox(height: 8),
                      const LogoCard(),
                      SizedBox(height: context.rsp(20)),

                      // Title & Subtitle
                      Text(
                        _loginMode == 1
                            ? 'Doctor Login'
                            : (_isOtpStep
                                  ? 'Verify OTP'
                                  : (_hasPatientCard
                                        ? 'Patient Card Login'
                                        : 'Patient Login')),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: context.fs(20),
                          fontWeight: FontWeight.bold,
                          color: const Color(0xFF1F2F44),
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text(
                          _loginMode == 1
                              ? 'Enter your 4-digit Doctor ID provided by administration.'
                              : (_isOtpStep
                                    ? 'Enter the 6-digit verification code sent to $_activeNormalizedPhone'
                                    : (_hasPatientCard
                                          ? 'Enter the 12-digit ID printed on your Patient Card.'
                                          : 'Enter your phone number to sign in or get started.')),
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

                      // Patient Card Toggle (Only shown in Patient mode when not on OTP step)
                      if (_loginMode == 0 && !_isOtpStep) ...[
                        _buildPatientCardToggle(),
                        SizedBox(height: context.rsp(16)),
                      ],

                      // Form Fields
                      Form(
                        key: formkey,
                        child: Column(
                          children: [
                            if (_loginMode == 1) ...[
                              // Doctor Mode
                              _buildDoctorFields(),
                            ] else if (_isOtpStep) ...[
                              // OTP Step
                              _buildOtpFields(),
                            ] else if (_hasPatientCard) ...[
                              // Patient Card Mode
                              _buildPatientCardFields(),
                            ] else ...[
                              // Phone OTP Mode
                              _buildPhoneFields(),
                            ],

                            if (errorText.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: Text(
                                  errorText,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: Colors.red,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),

                            SizedBox(height: context.rsp(20)),

                            // Action Button
                            _buildActionButton(),

                            SizedBox(height: context.rsp(16)),

                            // Alternate Actions & Footer
                            _buildAlternateActions(),
                          ],
                        ),
                      ),
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

  // --- "Do you have a Patient Card?" Toggle ---
  Widget _buildPatientCardToggle() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFE9F0F8),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFBACADB)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Row(
              children: [
                Icon(
                  Icons.badge_rounded,
                  size: 20,
                  color: _hasPatientCard
                      ? AppColors.primaryRed
                      : const Color(0xFF384C66),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Do you have a Patient Card?',
                    style: TextStyle(
                      fontSize: context.fs(13.5),
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFF1F2F44),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Switch(
            value: _hasPatientCard,
            activeThumbColor: Colors.white,
            activeTrackColor: AppColors.primaryRed,
            inactiveThumbColor: Colors.white,
            inactiveTrackColor: const Color(0xFFCAD6E4),
            onChanged: (val) {
              setState(() {
                _hasPatientCard = val;
                errorText = '';
              });
            },
          ),
        ],
      ),
    );
  }

  // --- Phone Fields ---
  Widget _buildPhoneFields() {
    return InternationalPhoneInput(
      controller: phoneController,
      initialIsoCode: _patientIsoCode,
      hintText: 'Phone Number',
      enabled: !isLoading,
      onChanged: (val) {
        _patientDialCode = val.dialCode;
        _patientIsoCode = val.isoCode;
      },
    );
  }

  // --- OTP Verification Fields ---
  Widget _buildOtpFields() {
    return Column(
      children: [
        _buildMetallicInput(
          hintText: '6-Digit Verification Code',
          icon: Icons.lock_outline_rounded,
          keyboardType: TextInputType.number,
          controller: otpController,
          maxLength: 6,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(6),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            TextButton(
              onPressed: () {
                setState(() {
                  _isOtpStep = false;
                  otpController.clear();
                  errorText = '';
                });
              },
              child: Text(
                'Change Number',
                style: TextStyle(
                  fontSize: context.fs(12.5),
                  color: const Color(0xFF163B6E),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            TextButton(
              onPressed: _resendCountdown == 0 ? handleSendOtp : null,
              child: Text(
                _resendCountdown > 0
                    ? 'Resend in ${_resendCountdown}s'
                    : 'Resend Code',
                style: TextStyle(
                  fontSize: context.fs(12.5),
                  color: _resendCountdown == 0
                      ? AppColors.primaryRed
                      : const Color(0xFF7E90A6),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // --- Patient Card Fields (12 Digits) ---
  Widget _buildPatientCardFields() {
    return _buildMetallicInput(
      hintText: '12-Digit Patient Card ID',
      icon: Icons.badge_rounded,
      keyboardType: TextInputType.number,
      controller: patientCardIdController,
      maxLength: 12,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(12),
      ],
    );
  }

  // --- Doctor Fields (4 Digits) ---
  Widget _buildDoctorFields() {
    return _buildMetallicInput(
      hintText: '4-Digit Doctor ID',
      icon: Icons.medical_services_rounded,
      keyboardType: TextInputType.number,
      controller: doctorIdController,
      maxLength: 4,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(4),
      ],
    );
  }

  // --- Metallic Beveled Input ---
  Widget _buildMetallicInput({
    required String hintText,
    required IconData icon,
    TextInputType? keyboardType,
    int? maxLength,
    List<TextInputFormatter>? inputFormatters,
    TextEditingController? controller,
    String? Function(String?)? validator,
  }) {
    return MetallicInput(
      hintText: hintText,
      icon: icon,
      keyboardType: keyboardType,
      maxLength: maxLength,
      inputFormatters: inputFormatters,
      controller: controller,
      validator: validator ??
          (value) {
            if (value == null || value.trim().isEmpty) {
              return 'Required';
            }
            return null;
          },
    );
  }

  // --- Action Button ---
  Widget _buildActionButton() {
    String label = 'Continue';
    VoidCallback? action;

    if (_loginMode == 1) {
      label = 'Sign In as Doctor';
      action = handleDoctorSignIn;
    } else if (_isOtpStep) {
      label = 'Verify Code';
      action = handleVerifyOtp;
    } else if (_hasPatientCard) {
      label = 'Continue with Card';
      action = handlePatientCardSignIn;
    } else {
      label = 'Send OTP';
      action = handleSendOtp;
    }

    return Container(
      height: 52,
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
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: const Color(0xFF132D56)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0B2041).withValues(alpha: 0.32),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.transparent,
          shadowColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(26),
          ),
        ),
        onPressed: isLoading ? null : action,
        child: isLoading
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: context.fs(14.5),
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Icon(
                    Icons.arrow_forward_rounded,
                    color: Colors.white,
                    size: 18,
                  ),
                ],
              ),
      ),
    );
  }

  // --- Alternate Actions (Doctor Login & Guest Mode) ---
  Widget _buildAlternateActions() {
    return Column(
      children: [
        const SizedBox(height: 10),

        // Doctor Login or Back to Patient Login Button
        if (_loginMode == 0) ...[
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              side: const BorderSide(color: Color(0xFFBAC7D8), width: 1.2),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(22),
              ),
              backgroundColor: Colors.white.withValues(alpha: 0.7),
            ),
            onPressed: () {
              setState(() {
                _loginMode = 1;
                errorText = '';
              });
            },
            icon: const Icon(
              Icons.medical_services_rounded,
              size: 18,
              color: Color(0xFF163B6E),
            ),
            label: Text(
              'Doctor Login',
              style: TextStyle(
                fontSize: context.fs(13.5),
                fontWeight: FontWeight.w600,
                color: const Color(0xFF163B6E),
              ),
            ),
          ),
        ] else ...[
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              side: const BorderSide(color: Color(0xFFBAC7D8), width: 1.2),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(22),
              ),
              backgroundColor: Colors.white.withValues(alpha: 0.7),
            ),
            onPressed: () {
              setState(() {
                _loginMode = 0;
                errorText = '';
              });
            },
            icon: const Icon(
              Icons.person_rounded,
              size: 18,
              color: Color(0xFF163B6E),
            ),
            label: Text(
              'Back to Patient Login',
              style: TextStyle(
                fontSize: context.fs(13.5),
                fontWeight: FontWeight.w600,
                color: const Color(0xFF163B6E),
              ),
            ),
          ),
        ],

        const SizedBox(height: 16),

        // Guest Mode Option
        GestureDetector(
          onTap: handleEnterGuestMode,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.explore_outlined,
                  size: 16,
                  color: const Color(0xFF657991),
                ),
                const SizedBox(width: 6),
                Text(
                  'Continue as Guest',
                  style: TextStyle(
                    fontSize: context.fs(13),
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF657991),
                    decoration: TextDecoration.underline,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
