import 'package:flutter/material.dart';
import 'package:telemedicine/app/theme/app_theme.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/features/auth/presentation/screens/doctor_login_screen.dart';
import 'package:telemedicine/features/auth/presentation/screens/sign_in_screen.dart';
import 'package:telemedicine/features/auth/presentation/screens/sign_up_selection_screen.dart';
import 'package:telemedicine/features/auth/presentation/widgets/auth_ui_components.dart';

/// Screen 1: Landing / Welcome Screen
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F9FC),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: EdgeInsets.symmetric(
                horizontal: context.rsp(20),
                vertical: 12,
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      const SizedBox(height: 8),

                      // Header: App logo centered at the top
                      Image.asset(
                        'assets/images/opd online.png',
                        height: 52,
                        fit: BoxFit.contain,
                        errorBuilder: (context, error, stackTrace) {
                          return Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(
                                Icons.local_hospital_rounded,
                                color: Color(0xFF062B72),
                                size: 30,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'OPD TELEMEDICINE',
                                style: TextStyle(
                                  fontSize: context.fs(18),
                                  fontWeight: FontWeight.bold,
                                  color: const Color(0xFF062B72),
                                ),
                              ),
                            ],
                          );
                        },
                      ),

                      const SizedBox(height: 16),

                      // Hero Section: Graphic/banner featuring medical professionals
                      Container(
                        width: double.infinity,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF0F233C).withValues(alpha: 0.06),
                              blurRadius: 16,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(20),
                          child: Image.asset(
                            'assets/images/wellcome_image.png',
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) {
                              return Container(
                                height: 210,
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                padding: const EdgeInsets.all(20),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    const Icon(
                                      Icons.medical_services_rounded,
                                      size: 54,
                                      color: Color(0xFF062B72),
                                    ),
                                    const SizedBox(height: 12),
                                    Text(
                                      '24/7 Online Doctors for You & Your Family',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        fontSize: context.fs(17),
                                        fontWeight: FontWeight.bold,
                                        color: const Color(0xFF1F2F44),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                      ),

                      const SizedBox(height: 20),

                      // Services Feature Grid (4 horizontal icon badges)
                      _buildServicesGrid(context),

                      const SizedBox(height: 26),

                      // Call-to-Action Buttons
                      // Primary Button: "Sign Up" (Subtitle: "Create a new account") -> Screen 2
                      _buildPrimarySignUpButton(context),

                      const SizedBox(height: 12),

                      // Outlined/Secondary Button: "Sign In" (Subtitle: "Already have an account?") -> Screen 5
                      _buildSecondarySignInButton(context),

                      const SizedBox(height: 12),

                      // Tertiary Button: "Doctor Login" with a stethoscope/doctor icon and forward arrow -> Screen 6
                      _buildTertiaryDoctorLoginButton(context),

                      const SizedBox(height: 16),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  // Services Feature Grid (4 horizontal icon badges)
  Widget _buildServicesGrid(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildServiceBadge(
            context: context,
            icon: Icons.phone_in_talk_rounded,
            title: '24/7\nDoctor\nConsultation',
          ),
          _buildServiceBadge(
            context: context,
            icon: Icons.assignment_outlined,
            title: 'Digital\nMedical\nRecords',
          ),
          _buildServiceBadge(
            context: context,
            icon: Icons.science_outlined,
            title: 'Lab &\nRadiology\nReports',
          ),
          _buildServiceBadge(
            context: context,
            customWidget: const ToothIcon(size: 22, color: Color(0xFF0E9A8E)),
            title: 'Dental\nConsultation\n(BDS)',
          ),
        ],
      ),
    );
  }

  Widget _buildServiceBadge({
    required BuildContext context,
    IconData? icon,
    Widget? customWidget,
    required String title,
  }) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: const Color(0xFFE4F4F3),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: const Color(0xFFBFE5E0),
                  width: 1,
                ),
              ),
              alignment: Alignment.center,
              child: customWidget ??
                  Icon(
                    icon,
                    size: 24,
                    color: const Color(0xFF0E9A8E),
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              title,
              textAlign: TextAlign.center,
              maxLines: 3,
              style: TextStyle(
                fontSize: context.fs(11),
                fontWeight: FontWeight.w600,
                color: const Color(0xFF1F2F44),
                height: 1.25,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Primary Button: "Sign Up" (Subtitle: "Create a new account") -> Navigate to Screen 2
  Widget _buildPrimarySignUpButton(BuildContext context) {
    return Container(
      height: 56,
      width: double.infinity,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [
            Color(0xFF0B7D74),
            Color(0xFF0E968C),
            Color(0xFF10A89C),
          ],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0B7D74).withValues(alpha: 0.35),
            blurRadius: 12,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(28),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const SignUpSelectionScreen(),
              ),
            );
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.2),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.person_add_rounded,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Text(
                        'Sign Up',
                        style: TextStyle(
                          fontSize: context.fs(16),
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                          letterSpacing: 0.2,
                        ),
                      ),
                      Text(
                        'Create a new account',
                        style: TextStyle(
                          fontSize: context.fs(11.5),
                          fontWeight: FontWeight.w400,
                          color: Colors.white.withValues(alpha: 0.85),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 34), // Keeps text centered relative to left icon
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Outlined/Secondary Button: "Sign In" (Subtitle: "Already have an account?") -> Navigate to Screen 5
  Widget _buildSecondarySignInButton(BuildContext context) {
    return Container(
      height: 56,
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(
          color: const Color(0xFFC8D6E5),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0F233C).withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(28),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const SignInScreen(),
              ),
            );
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(7),
                  decoration: const BoxDecoration(
                    color: Color(0xFFEBF1F7),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.login_rounded,
                    color: Color(0xFF1F2F44),
                    size: 20,
                  ),
                ),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Text(
                        'Sign In',
                        style: TextStyle(
                          fontSize: context.fs(16),
                          fontWeight: FontWeight.w700,
                          color: const Color(0xFF1F2F44),
                          letterSpacing: 0.2,
                        ),
                      ),
                      Text(
                        'Already have an account?',
                        style: TextStyle(
                          fontSize: context.fs(11.5),
                          fontWeight: FontWeight.w400,
                          color: const Color(0xFF657991),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 34),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Tertiary Button: "Doctor Login" with a stethoscope/doctor icon and forward arrow -> Navigate to Screen 6
  Widget _buildTertiaryDoctorLoginButton(BuildContext context) {
    return Container(
      height: 52,
      width: double.infinity,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [
            Color(0xFF0E3261),
            Color(0xFF092244),
            Color(0xFF051730),
          ],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
        borderRadius: BorderRadius.circular(26),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF061A34).withValues(alpha: 0.35),
            blurRadius: 12,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(26),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const DoctorLoginScreen(),
              ),
            );
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                const Icon(
                  Icons.medical_services_outlined,
                  color: Colors.white,
                  size: 20,
                ),
                Expanded(
                  child: Text(
                    'Doctor Login',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: context.fs(15),
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
                const Icon(
                  Icons.arrow_forward_rounded,
                  color: Colors.white,
                  size: 18,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

