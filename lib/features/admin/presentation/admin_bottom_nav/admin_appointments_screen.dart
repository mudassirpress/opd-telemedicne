import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/features/admin/presentation/admin_design_system.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/features/appointments/presentation/appointment_controller.dart';
import 'package:telemedicine/features/appointments/presentation/appointment_status_widgets.dart';

/// Admin → Appointments: every appointment, newest first, using the same
/// patient/doctor card language.
class AdminAppointmentsScreen extends ConsumerWidget {
  const AdminAppointmentsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appointmentsAsync = ref.watch(allAppointmentsProvider);

    return AdminScreen(
      title: 'Appointments',
      subtitle: 'All patient appointments across doctors',
      showBack: true,
      body: appointmentsAsync.when(
        loading: () => const AdminLoading(label: 'Loading appointments...'),
        error: (_, __) => const AdminErrorState(
          message: 'Could not load appointments.',
        ),
        data: (appointments) {
          final sorted = [...appointments]..sort(
              (a, b) => (b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0))
                  .compareTo(
                      a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0)),
            );
          if (sorted.isEmpty) {
            return const AdminEmptyState(
              icon: Icons.event_busy_rounded,
              title: 'No appointments yet',
            );
          }
          return ListView.separated(
            padding: EdgeInsets.all(context.rsp(16)),
            itemCount: sorted.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              final a = sorted[index];
              return AdminCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            a.patientName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AdminTextStyles.heading(
                                size: context.fs(13.5)),
                          ),
                        ),
                        AppointmentStatusPill(status: a.appointmentStatus),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Dr. ${a.doctorName}',
                      style: AdminTextStyles.body(size: context.fs(12.5)),
                    ),
                    const SizedBox(height: 8),
                    AdminInfoRow(
                      icon: Icons.calendar_today_rounded,
                      label: 'Date',
                      value: a.scheduledDate.isEmpty
                          ? 'Not scheduled'
                          : a.scheduledDate,
                    ),
                    AdminInfoRow(
                      icon: Icons.schedule_rounded,
                      label: 'Time',
                      value: a.scheduledStartTime.isEmpty
                          ? 'Not set'
                          : '${a.scheduledStartTime} - ${a.scheduledEndTime}',
                    ),
                    AdminInfoRow(
                      icon: Icons.payments_rounded,
                      label: 'Amount',
                      value: appointmentAmount(a.payableAmount),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
