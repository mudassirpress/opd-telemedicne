import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/features/admin/presentation/admin_bottom_nav/admin_settings_screen.dart';
import 'package:telemedicine/features/admin/presentation/admin_chat_management_screen.dart';
import 'package:telemedicine/features/admin/presentation/admin_reports_screen.dart';
import 'package:telemedicine/features/admin/presentation/admin_design_system.dart';
import 'package:telemedicine/features/admin/presentation/create_doctor_id/create_doctor_id_screen.dart';
import 'package:telemedicine/features/admin/presentation/doctor_online_history/doctor_online_history_screen.dart';
import 'package:telemedicine/features/admin/presentation/doctor_videos/admin_doctor_videos_screen.dart';
import 'package:telemedicine/features/admin/presentation/notifications/admin_reactivation_screen.dart';
import 'package:telemedicine/features/admin/presentation/notifications/admin_payment_screen.dart';
import 'package:telemedicine/features/admin/presentation/patient_id_management/patient_id_management_screen.dart';
import 'package:telemedicine/core/providers/badge_providers.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/shared/widgets/badge_indicator.dart';

import 'package:telemedicine/features/admin/presentation/notifications/admin_notifications_screen.dart';
import 'package:telemedicine/features/complaints/presentation/payment_complaint_service.dart';

/// Admin → More: every secondary admin destination behind one list, same
/// card style as the rest of the portal.
class AdminMoreScreen extends ConsumerWidget {
  const AdminMoreScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pendingPayments = ref.watch(adminPendingPaymentsCountProvider);
    final pendingReactivations =
        ref.watch(adminPendingReactivationsCountProvider).valueOrNull ?? 0;
    final unreadNotifications =
        ref.watch(adminUnreadNotificationsCountProvider).valueOrNull ?? 0;

    final items = <(String, IconData, Widget, int)>[
      (
        'Notifications',
        Icons.notifications_rounded,
        const AdminNotificationsScreen(),
        unreadNotifications,
      ),
      (
        'Doctors',
        Icons.medical_services_outlined,
        const AdminChatManagementScreen(),
        0,
      ),
      (
        'Payments',
        Icons.payment_rounded,
        const AdminPaymentScreen(),
        pendingPayments,
      ),
      (
        'Patient IDs',
        Icons.badge_rounded,
        const PatientIdManagementScreen(),
        0,
      ),
      (
        'Doctor Videos',
        Icons.video_library_rounded,
        const AdminDoctorVideosScreen(),
        0,
      ),
      (
        'Reactivation',
        Icons.replay_circle_filled_rounded,
        const AdminReactivationScreen(),
        pendingReactivations,
      ),
      ('Online History', Icons.history_rounded, DoctorOnlineHistoryScreen(), 0),
      ('Reports', Icons.assessment_rounded, const AdminReportsScreen(), 0),
      (
        'Create Doctor ID',
        Icons.person_add_alt_1_rounded,
        CreateDoctorIdScreen(),
        0,
      ),
      ('Settings', Icons.settings_rounded, const AdminSettingsScreen(), 0),
    ];

    return AdminScreen(
      title: 'More',
      subtitle: 'Doctors, payments, reports and tools',
      body: ListView.separated(
        padding: EdgeInsets.all(context.rsp(16)),
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          final item = items[index];
          final badgeCount = item.$4;

          return GestureDetector(
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => item.$3),
              );
              ToastService.instance.showInfo('Opening ${item.$1}');
            },
            child: AdminCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: AdminPalette.brand.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: BadgeIndicator(
                      count: badgeCount,
                      offset: const Offset(-2, -2),
                      child: Icon(item.$2, color: AdminPalette.brand, size: 20),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      item.$1,
                      style: TextStyle(
                        fontSize: context.fs(13.5),
                        fontWeight: FontWeight.w600,
                        color: AdminPalette.textPrimary,
                      ),
                    ),
                  ),
                  if (badgeCount > 0) ...[
                    BadgeIndicator(count: badgeCount),
                    const SizedBox(width: 8),
                  ],
                  const Icon(
                    Icons.chevron_right_rounded,
                    color: AdminPalette.textMuted,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
