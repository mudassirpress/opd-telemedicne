import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:telemedicine/admin_portal/admin_ui.dart';
import 'package:telemedicine/admin_portal/notification/payment_approve_noti.dart';
import 'package:telemedicine/admin_portal/notifications/admin_complaint_detail_screen.dart';
import 'package:telemedicine/core/theme/app_theme.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/data/models/admin_notification_model.dart';
import 'package:telemedicine/features/complaint/payment_complaint_service.dart';

class AdminNotificationsScreen extends ConsumerStatefulWidget {
  const AdminNotificationsScreen({super.key});

  @override
  ConsumerState<AdminNotificationsScreen> createState() =>
      _AdminNotificationsScreenState();
}

class _AdminNotificationsScreenState
    extends ConsumerState<AdminNotificationsScreen> {
  int _selectedFilter = 0; // 0 = All, 1 = Unread, 2 = Complaints

  @override
  Widget build(BuildContext context) {
    final notificationsAsync = ref.watch(adminNotificationsStreamProvider);

    return AdminScreen(
      title: 'Notifications & Complaints',
      subtitle: 'Patient payment inquiries and updates',
      body: Column(
        children: [
          // Filter chips
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: context.rsp(16),
              vertical: 12,
            ),
            child: Row(
              children: [
                _buildFilterChip(0, 'All'),
                const SizedBox(width: 8),
                _buildFilterChip(1, 'Unread'),
                const SizedBox(width: 8),
                _buildFilterChip(2, 'Complaints'),
              ],
            ),
          ),
          Expanded(
            child: notificationsAsync.when(
              loading: () =>
                  const AdminLoading(label: 'Loading notifications...'),
              error: (err, _) => Center(
                child: Text('Error loading notifications: $err'),
              ),
              data: (notifications) {
                var filtered = notifications;
                if (_selectedFilter == 1) {
                  filtered = filtered.where((n) => !n.isRead).toList();
                } else if (_selectedFilter == 2) {
                  filtered = filtered
                      .where((n) => n.type == 'payment_complaint')
                      .toList();
                }

                if (filtered.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.notifications_none_rounded,
                            size: 56,
                            color: AdminPalette.textMuted,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            _selectedFilter == 1
                                ? 'No Unread Notifications'
                                : 'No Notifications Yet',
                            style: TextStyle(
                              fontSize: context.fs(16),
                              fontWeight: FontWeight.bold,
                              color: AdminPalette.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Incoming patient payment complaints and status alerts will appear here.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: context.fs(13),
                              color: AdminPalette.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }

                return ListView.separated(
                  padding: EdgeInsets.all(context.rsp(16)),
                  itemCount: filtered.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final item = filtered[index];
                    return _buildNotificationCard(context, item);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip(int index, String label) {
    final isSelected = _selectedFilter == index;
    return GestureDetector(
      onTap: () => setState(() => _selectedFilter = index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: isSelected
              ? AdminPalette.brand
              : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? AdminPalette.brand : AdminPalette.divider,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: context.fs(12.5),
            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
            color: isSelected ? Colors.white : AdminPalette.textSecondary,
          ),
        ),
      ),
    );
  }

  Widget _buildNotificationCard(
      BuildContext context, AdminNotificationModel item) {
    final dateStr = DateFormat('MMM d, h:mm a').format(item.createdAt);

    return GestureDetector(
      onTap: () async {
        final nav = Navigator.of(context);
        // Mark notification as read
        if (!item.isRead) {
          await ref
              .read(paymentComplaintServiceProvider)
              .markNotificationAsRead(item.notificationId);
        }

        if (!mounted) return;

        // Route based on notification type
        if (item.isComplaint || item.type == 'payment_complaint') {
          nav.push(
            MaterialPageRoute(
              builder: (_) => AdminComplaintDetailScreen(
                complaintId: item.complaintId,
                initialNotification: item,
              ),
            ),
          );
        } else {
          final isAppt = item.type.contains('appointment');
          nav.push(
            MaterialPageRoute(
              builder: (_) => AdminPaymentScreen(
                focusPatientId: item.patientUid.isNotEmpty ? item.patientUid : item.patientId,
                focusPaymentId: item.paymentId,
                initialSegment: isAppt
                    ? AdminPaymentSegment.appointment
                    : AdminPaymentSegment.account,
              ),
            ),
          );
        }
      },
      child: AdminCard(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Status avatar / unread dot
            Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: item.isRead
                        ? AdminPalette.brand.withValues(alpha: 0.08)
                        : AppColors.primaryRed.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.support_agent_rounded,
                    color: item.isRead
                        ? AdminPalette.brand
                        : AppColors.primaryRed,
                    size: 22,
                  ),
                ),
                if (!item.isRead)
                  Positioned(
                    top: -2,
                    right: -2,
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: const BoxDecoration(
                        color: Colors.red,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          item.patientName,
                          style: TextStyle(
                            fontSize: context.fs(14),
                            fontWeight: item.isRead
                                ? FontWeight.w600
                                : FontWeight.bold,
                            color: AdminPalette.textPrimary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        dateStr,
                        style: TextStyle(
                          fontSize: context.fs(11),
                          color: AdminPalette.textMuted,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  if (item.category != null && item.category!.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.only(bottom: 4),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: AdminPalette.brand.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        item.category!,
                        style: TextStyle(
                          fontSize: context.fs(10.5),
                          fontWeight: FontWeight.w600,
                          color: AdminPalette.brand,
                        ),
                      ),
                    ),
                  Text(
                    item.body,
                    style: TextStyle(
                      fontSize: context.fs(12.5),
                      color: item.isRead
                          ? AdminPalette.textMuted
                          : AdminPalette.textSecondary,
                      height: 1.35,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (item.paymentStatus != null ||
                      (item.paymentId != null && item.paymentId!.isNotEmpty)) ...[
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        if (item.paymentStatus != null)
                          Text(
                            'Status: ${item.paymentStatus!.toUpperCase()}',
                            style: TextStyle(
                              fontSize: context.fs(11),
                              fontWeight: FontWeight.w600,
                              color: item.paymentStatus == 'approved'
                                  ? Colors.green[700]
                                  : (item.paymentStatus == 'pending'
                                      ? Colors.orange[800]
                                      : Colors.red[700]),
                            ),
                          ),
                        if (item.paymentId != null &&
                            item.paymentId!.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Text(
                            '•  Ref: ${item.paymentId}',
                            style: TextStyle(
                              fontSize: context.fs(11),
                              color: AdminPalette.textMuted,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 4),
            const Icon(
              Icons.chevron_right_rounded,
              color: AdminPalette.textMuted,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }
}
