import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/admin_portal/admin_ui.dart';
import 'package:telemedicine/auth/auth_provider/user_provider.dart';
import 'package:telemedicine/auth/auth_screen/sign_in_screen.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/core/utils/responsive.dart';

class AdminSettingsScreen extends ConsumerStatefulWidget {
  const AdminSettingsScreen({super.key});

  @override
  ConsumerState<AdminSettingsScreen> createState() => _AdminSettingsScreenState();
}

class _AdminSettingsScreenState extends ConsumerState<AdminSettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final adminUser = ref.watch(userProvider);

    return AdminScreen(
      title: 'Settings',
      subtitle: 'Manage your account and admin tools',
      body: SingleChildScrollView(
        padding: EdgeInsets.all(context.rsp(16)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Admin Profile Card
            AdminCard(
              padding: EdgeInsets.symmetric(
                vertical: context.rsp(24),
                horizontal: context.rsp(20),
              ),
              child: Column(
                children: [
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: AdminPalette.brand.withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: AdminPalette.brand.withValues(alpha: 0.25),
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      (adminUser?.fullname ?? 'A')[0].toUpperCase(),
                      style: TextStyle(
                        fontSize: context.fs(20),
                        fontWeight: FontWeight.w600,
                        color: AdminPalette.brand,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    adminUser?.fullname ?? 'Admin',
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AdminTextStyles.title(size: context.fs(15)),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    adminUser?.phoneNumber ?? '',
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AdminTextStyles.body(size: context.fs(13)),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      gradient: AdminPalette.selectedGradient,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: AdminPalette.brandBorder),
                      boxShadow: [
                        BoxShadow(
                          color: AdminPalette.brandShadow.withValues(alpha: 0.2),
                          blurRadius: 8,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: Text(
                      'Administrator',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            AdminSectionLabel('Account', padding: const EdgeInsets.only(bottom: 8, left: 4)),
            _buildSettingsItem(
              icon: Icons.person_outline,
              title: 'Profile',
              subtitle: 'View and edit your profile',
              onTap: () {
                ToastService.instance.showInfo('Profile settings');
              },
            ),
            _buildSettingsItem(
              icon: Icons.lock_outline,
              title: 'Change Password',
              subtitle: 'Update your password',
              onTap: () {
                ToastService.instance.showInfo('Password change');
              },
            ),

            const SizedBox(height: 16),
            AdminSectionLabel('Application', padding: const EdgeInsets.only(bottom: 8, left: 4)),
            _buildSettingsItem(
              icon: Icons.info_outline,
              title: 'About',
              subtitle: 'App version and information',
              onTap: () {
                _showAboutDialog();
              },
            ),
            _buildSettingsItem(
              icon: Icons.help_outline,
              title: 'Help & Support',
              subtitle: 'Get help with the application',
              onTap: () {
                ToastService.instance.showInfo('Help & Support');
              },
            ),

            const SizedBox(height: 16),
            AdminSectionLabel('Admin Actions', padding: const EdgeInsets.only(bottom: 8, left: 4)),
            _buildSettingsItem(
              icon: Icons.admin_panel_settings_outlined,
              title: 'Manage Admin Access',
              subtitle: 'Control admin permissions',
              onTap: () {
                ToastService.instance.showInfo('Admin access management');
              },
            ),
            _buildSettingsItem(
              icon: Icons.notifications_none_outlined,
              title: 'Notification Settings',
              subtitle: 'Configure notification preferences',
              onTap: () {
                ToastService.instance.showInfo('Notification settings');
              },
            ),

            const SizedBox(height: 24),

            // Logout Button
            AdminPrimaryButton(
              label: 'Logout',
              icon: Icons.logout_rounded,
              onPressed: _logout,
            ),

            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildSettingsItem({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return AdminCard(
      margin: const EdgeInsets.only(bottom: 8),
      radius: 14,
      padding: EdgeInsets.zero,
      child: ListTile(
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: AdminPalette.brand.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: AdminPalette.brand, size: 20),
        ),
        title: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: context.fs(14),
            fontWeight: FontWeight.w600,
            color: AdminPalette.textPrimary,
          ),
        ),
        subtitle: Text(
          subtitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: context.fs(12),
            color: AdminPalette.textMuted,
          ),
        ),
        trailing: Icon(
          Icons.chevron_right,
          color: AdminPalette.textMuted,
          size: 20,
        ),
        onTap: onTap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );
  }

  void _showAboutDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'About',
          style: AdminTextStyles.title(size: context.fs(16)),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Telemedicine App',
                style: AdminTextStyles.heading(size: context.fs(14)),
              ),
              const SizedBox(height: 8),
              Text(
                'Version 1.0.6 (6)',
                style: AdminTextStyles.body(size: context.fs(13)),
              ),
              const SizedBox(height: 8),
              Text(
                'Admin Portal for managing doctors, patients, and application settings.',
                style: AdminTextStyles.body(size: context.fs(13)),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              'OK',
              style: TextStyle(
                color: AdminPalette.brand,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _logout() async {
    final shouldLogout = await showAdminConfirmDialog(
      context: context,
      title: 'Logout',
      content: 'Are you sure you want to logout?',
      confirmLabel: 'Logout',
      confirmColor: AdminPalette.error,
    );

    if (shouldLogout == true) {
      ToastService.instance.showInfo('Logging out...');
      final controller = ref.read(patientControllerProvider);
      await controller.signOut();
      if (mounted) {
        ToastService.instance.showSuccess('Logged out successfully');
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => const SignInScreen()),
        );
      }
    }
  }
}