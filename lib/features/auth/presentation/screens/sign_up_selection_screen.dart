import 'package:flutter/material.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/features/auth/presentation/screens/sign_up_with_card_screen.dart';
import 'package:telemedicine/features/auth/presentation/screens/sign_up_without_card_screen.dart';
import 'package:telemedicine/features/auth/presentation/widgets/auth_ui_components.dart';
import 'package:telemedicine/shared/widgets/auth_layout.dart';

/// Screen 2: Sign Up Selection Screen (Patient)
class SignUpSelectionScreen extends StatelessWidget {
  const SignUpSelectionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F9FC),
      appBar: const AuthAppBar(title: 'Sign Up'),
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const SizedBox(height: 8),
                  const LogoCard(),

                  const SizedBox(height: 20),

                  // Title: "Create Your Patient Account"
                  Text(
                    'Create Your Patient Account',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: context.fs(20),
                      fontWeight: FontWeight.w700,
                      color: const Color(0xFF1F2F44),
                      letterSpacing: -0.4,
                    ),
                  ),

                  const SizedBox(height: 6),

                  // Subtitle: "Choose how you would like to sign up."
                  Text(
                    'Choose how you would like to sign up.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: context.fs(13.5),
                      fontWeight: FontWeight.w500,
                      color: const Color(0xFF657991),
                    ),
                  ),

                  const SizedBox(height: 28),

                  // Selection Options (Clickable card tiles with trailing chevron arrows)
                  // Card 1: "Sign Up with Card" -> Navigate to Screen 3
                  _buildOptionCard(
                    context: context,
                    icon: Icons.credit_card_rounded,
                    iconBgColor: const Color(0xFFE2F5F3),
                    iconColor: const Color(0xFF0E9A8E),
                    title: 'Sign Up with Card',
                    description:
                        'I have an OPD Telemedicine subscription card (scratch card)',
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const SignUpWithCardScreen(),
                        ),
                      );
                    },
                  ),

                  const SizedBox(height: 16),

                  // Card 2: "Sign Up without Card" -> Navigate to Screen 4
                  _buildOptionCard(
                    context: context,
                    icon: Icons.person_add_rounded,
                    iconBgColor: const Color(0xFFE6EFFB),
                    iconColor: const Color(0xFF1E5BB5),
                    title: 'Sign Up without Card',
                    description:
                        'I don\'t have a card and want to create a new account',
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const SignUpWithoutCardScreen(),
                        ),
                      );
                    },
                  ),

                  const SizedBox(height: 36),

                  // Footer: Healthcare family/stethoscope graphic illustration at the bottom
                  Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(maxHeight: 190),
                    alignment: Alignment.center,
                    child: Image.asset(
                      'assets/images/signup_image.png',
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stackTrace) {
                        return Container(
                          padding: const EdgeInsets.all(24),
                          child: Icon(
                            Icons.family_restroom_rounded,
                            size: 80,
                            color: const Color(
                              0xFF062B72,
                            ).withValues(alpha: 0.3),
                          ),
                        );
                      },
                    ),
                  ),

                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildOptionCard({
    required BuildContext context,
    required IconData icon,
    required Color iconBgColor,
    required Color iconColor,
    required String title,
    required String description,
    required VoidCallback onTap,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFD6E3F0), width: 1.2),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0F233C).withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            child: Row(
              children: [
                // Icon Box
                Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(
                    color: iconBgColor,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(icon, size: 24, color: iconColor),
                ),
                const SizedBox(width: 14),

                // Title and Subtitle
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: context.fs(15),
                          fontWeight: FontWeight.w700,
                          color: const Color(0xFF1F2F44),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        description,
                        style: TextStyle(
                          fontSize: context.fs(12),
                          fontWeight: FontWeight.w400,
                          color: const Color(0xFF657991),
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),

                // Trailing Chevron
                const Icon(
                  Icons.chevron_right_rounded,
                  size: 24,
                  color: Color(0xFF8FA3B8),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
