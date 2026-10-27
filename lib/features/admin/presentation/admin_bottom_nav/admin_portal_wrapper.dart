import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/features/admin/presentation/admin_bottom_nav/admin_appointments_screen.dart';
import 'package:telemedicine/features/admin/presentation/admin_bottom_nav/admin_doctors_patients_screen.dart';
import 'package:telemedicine/features/admin/presentation/admin_bottom_nav/admin_more_screen.dart';
import 'package:telemedicine/features/admin/presentation/admin_portal_screen.dart';
import 'package:telemedicine/features/admin/presentation/admin_design_system.dart';
import 'package:telemedicine/features/auth/presentation/providers/user_provider.dart';
import 'package:telemedicine/features/auth/presentation/screens/sign_in_screen.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/providers/badge_providers.dart';
import 'package:telemedicine/shared/widgets/badge_indicator.dart';

class AdminPortalWrapper extends ConsumerStatefulWidget {
  const AdminPortalWrapper({super.key});

  @override
  ConsumerState<AdminPortalWrapper> createState() =>
      _AdminPortalWrapperState();
}

class _AdminPortalWrapperState extends ConsumerState<AdminPortalWrapper> {
  int _currentIndex = 0;

  final List<Widget> _screens = const [
    AdminPortalScreen(),
    AdminAppointmentsScreen(),
    AdminDoctorsPatientsScreen(),
    AdminMoreScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    // Defense-in-depth: the sign-in and splash screens already check the role
    // before navigating here, but this wrapper is also reachable via deep
    // links / notification taps / an expired cached session whose role field
    // was edited. Without this guard a patient or doctor could sit on the full
    // admin UI (which reads every collection) just by landing on the screen.
    final currentRole = ref.watch(userProvider.select((u) => u?.role));
    if (currentRole != 'admin') {
      return _buildNotAuthorized();
    }

    return Scaffold(
      backgroundColor: AdminPalette.background,
      body: IndexedStack(
        index: _currentIndex,
        children: _screens,
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: AdminPalette.divider.withValues(alpha: 0.4))),
          boxShadow: [
            BoxShadow(
              color: AdminPalette.cardShadow.withValues(alpha: 0.12),
              blurRadius: 16,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
            child: Row(
              children: [
                Expanded(child: _buildNavItem(0, Icons.dashboard_rounded, 'Dashboard')),
                Expanded(
                  child: _buildNavItem(
                    1,
                    Icons.event_note_rounded,
                    'Appointments',
                    badgeCount: ref.watch(adminPendingAppointmentsCountProvider),
                  ),
                ),
                Expanded(child: _buildNavItem(2, Icons.people_rounded, 'Users')),
                Expanded(
                  child: _buildNavItem(
                    3,
                    Icons.more_horiz_rounded,
                    'More',
                    badgeCount: ref.watch(adminMoreMenuBadgeCountProvider),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNotAuthorized() {
    return Scaffold(
      backgroundColor: AdminPalette.background,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: context.rsp(32)),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 84,
                  height: 84,
                  decoration: BoxDecoration(
                    color: AdminPalette.error.withValues(alpha: 0.08),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.lock_outline_rounded,
                    size: 38,
                    color: AdminPalette.error,
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  'Admin access required',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: context.fs(16),
                    fontWeight: FontWeight.w600,
                    color: AdminPalette.textPrimary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'This account is not an administrator. Sign in with an admin account to continue.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: context.fs(13),
                    color: AdminPalette.textMuted,
                  ),
                ),
                const SizedBox(height: 22),
                AdminSolidButton(
                  label: 'Sign in as admin',
                  icon: Icons.login_rounded,
                  color: AdminPalette.brand,
                  onPressed: () => Navigator.pushAndRemoveUntil(
                    context,
                    MaterialPageRoute(builder: (context) => const SignInScreen()),
                    (route) => false,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNavItem(
    int index,
    IconData icon,
    String label, {
    int badgeCount = 0,
  }) {
    final isSelected = _currentIndex == index;

    return GestureDetector(
      onTap: () => setState(() => _currentIndex = index),
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeInOut,
        padding: EdgeInsets.symmetric(horizontal: context.rsp(8), vertical: 6),
        decoration: isSelected
            ? BoxDecoration(
                gradient: AdminPalette.selectedGradient,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: AdminPalette.brandShadow.withValues(alpha: 0.3),
                    blurRadius: 8,
                    offset: const Offset(0, 3),
                  ),
                ],
              )
            : null,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            BadgeIndicator(
              count: badgeCount,
              offset: const Offset(-8, -4),
              child: Icon(
                icon,
                size: 22,
                color: isSelected ? Colors.white : AdminPalette.textMuted,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: context.fs(11),
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                color: isSelected ? Colors.white : AdminPalette.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}