import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/core/services/guest_mode_service.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/features/auth/presentation/controllers/doctor_controller.dart';
import 'package:telemedicine/features/auth/presentation/providers/user_provider.dart';
import 'package:telemedicine/features/auth/presentation/widgets/auth_ui_components.dart';
import 'package:telemedicine/features/doctor_portal/presentation/bottom_nav/doctor_portal_wrapper.dart';
import 'package:telemedicine/features/doctors/presentation/screens/update_doctor_profile_screen.dart';

/// Screen 6: Doctor Login
class DoctorLoginScreen extends ConsumerStatefulWidget {
  const DoctorLoginScreen({super.key});

  @override
  ConsumerState<DoctorLoginScreen> createState() => _DoctorLoginScreenState();
}

class _DoctorLoginScreenState extends ConsumerState<DoctorLoginScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  final TextEditingController _doctorIdController = TextEditingController();

  bool _isLoading = false;
  String _errorMessage = '';
  String _identifierError = '';
  String _passwordError = '';

  @override
  void dispose() {
    _doctorIdController.dispose();
    super.dispose();
  }

  Future<void> _handleDoctorLogin() async {
    if (!_formKey.currentState!.validate()) return;

    final identifier = _doctorIdController.text.trim();

    setState(() {
      _isLoading = true;
      _errorMessage = '';
      _identifierError = '';
      _passwordError = '';
    });

    try {
      // Sign out any active patient session first
      await ref.read(patientControllerProvider).signOut();
      if (!mounted) return;

      final doctorController = ref.read(doctorControllerProvider);
      final success = await doctorController.signInDoctorWithCredentials(
        identifier: identifier,
      );

      if (!mounted) return;

      if (success) {
        GuestModeService.exitGuestMode(ref);
        final doctor = doctorController.currentDoctor;

        if (doctor?.role != 'doctor') {
          await doctorController.signOut();
          if (!mounted) return;
          setState(() {
            _errorMessage = 'This account is not registered as a doctor.';
            _isLoading = false;
          });
          ToastService.instance.showError(_errorMessage);
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

        setState(() => _isLoading = false);

        if (!isProfileComplete || missingBookingFields) {
          ToastService.instance.showInfo('Please complete your doctor profile');
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(
              builder: (context) => const UpdateDoctorProfileScreen(),
            ),
            (route) => false,
          );
        } else {
          ToastService.instance.showSuccess('Welcome Dr. ${doctor.fullname}!');
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(
              builder: (context) => const DoctorPortalWrapper(),
            ),
            (route) => false,
          );
        }
      } else {
        String msg = doctorController.errorMessage.trim();
        if (msg.isEmpty) {
          msg =
              'Invalid Doctor credentials. Please check your Doctor ID and Password.';
        }

        String idErr = '';
        String pwdErr = '';

        if (msg.toLowerCase().contains('incorrect password')) {
          pwdErr = 'Incorrect password. Please try again.';
        } else if (msg.toLowerCase().contains('not found')) {
          idErr = 'Doctor account not found with this ID or Mobile Number.';
        }

        setState(() {
          _isLoading = false;
          _errorMessage = msg;
          _identifierError = idErr;
          _passwordError = pwdErr;
        });
        ToastService.instance.showError(_errorMessage);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = 'Doctor sign-in error: ${e.toString()}';
      });
      ToastService.instance.showError(_errorMessage);
    }
  }

  void _showDoctorForgotPasswordDialog() {
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFFE6F0FA),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.medical_services_rounded,
                  color: Color(0xFF062B72),
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Doctor Password Assistance',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1F2F44),
                  ),
                ),
              ),
            ],
          ),
          content: const Text(
            'Doctor accounts are securely managed by hospital administration.\n\n'
            'If you have forgotten your password or Doctor ID, please contact the hospital OPD administrator or IT helpdesk to verify your credentials and reset your security passcode.',
            style: TextStyle(
              fontSize: 13.5,
              color: Color(0xFF657991),
              height: 1.45,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text(
                'Understood',
                style: TextStyle(
                  color: Color(0xFF062B72),
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F9FC),
      appBar: const AuthAppBar(title: 'Doctor Login'),
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

                    // Header Graphic: Doctor illustration with ECG pulse line
                    Container(
                      constraints: const BoxConstraints(maxHeight: 180),
                      alignment: Alignment.center,
                      child: Image.asset(
                        'assets/images/doctor_image.png',
                        fit: BoxFit.contain,
                        errorBuilder: (context, error, stackTrace) {
                          return Container(
                            height: 150,
                            padding: const EdgeInsets.all(20),
                            child: const Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.medical_services_rounded,
                                  size: 60,
                                  color: Color(0xFF062B72),
                                ),
                                SizedBox(height: 8),
                                Icon(
                                  Icons.monitor_heart_outlined,
                                  size: 32,
                                  color: Color(0xFF11B7A8),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),

                    const SizedBox(height: 20),

                    // Header: "Doctor Login"
                    Text(
                      'Doctor Login',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: context.fs(22),
                        fontWeight: FontWeight.w700,
                        color: const Color(0xFF1F2F44),
                        letterSpacing: -0.4,
                      ),
                    ),

                    const SizedBox(height: 6),

                    // Subtitle: "Access your OPD Telemedicine doctor account."
                    Text(
                      'Access your OPD Telemedicine doctor account.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: context.fs(13.5),
                        fontWeight: FontWeight.w500,
                        color: const Color(0xFF657991),
                      ),
                    ),

                    const SizedBox(height: 32),

                    // Form Field 1: Doctor ID / Registered Mobile (Leading user icon)
                    AuthTextField(
                      controller: _doctorIdController,
                      hintText: 'Doctor ID / Registered Mobile',
                      prefixIcon: Icons.person_outline_rounded,
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
                          return 'Please enter your Doctor ID or registered mobile';
                        }
                        return null;
                      },
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

                    const SizedBox(height: 8),

                    // Action Button: "Login" with a forward arrow
                    AuthActionButton(
                      text: 'Login',
                      isLoading: _isLoading,
                      onPressed: _handleDoctorLogin,
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
