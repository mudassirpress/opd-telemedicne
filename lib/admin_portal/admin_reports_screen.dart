import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:telemedicine/admin_portal/admin_ui.dart';
import 'package:telemedicine/auth/auth_provider/user_provider.dart';
import 'package:telemedicine/auth/user_controller/doctor_controller.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/core/services/soft_delete_service.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/data/models/appointment_model.dart';
import 'package:telemedicine/features/appointment/appointment_controller.dart';
import 'package:telemedicine/features/appointment/appointment_ui.dart';
import 'package:telemedicine/features/doctor_video/doctor_video_controller.dart';

/// Admin → Reports: totals for appointments, payments, doctors, patients and
/// assigned videos, built from the same live sources the rest of the portal
/// uses — no new design language, only existing admin widgets.
class AdminReportsScreen extends ConsumerStatefulWidget {
  const AdminReportsScreen({super.key});

  @override
  ConsumerState<AdminReportsScreen> createState() =>
      _AdminReportsScreenState();
}

class _AdminReportsScreenState extends ConsumerState<AdminReportsScreen> {
  late final Stream<List<Map<String, dynamic>>> _doctorsStream;
  late final Stream<List<Map<String, dynamic>>> _patientsStream;
  late final Stream<List<DoctorVideoModel>> _videosStream;

  @override
  void initState() {
    super.initState();
    // Created once so the StreamBuilders subscribe exactly once instead of
    // re-listening to Firestore on every provider-driven rebuild.
    _doctorsStream = ref
        .read(doctorControllerProvider)
        .streamAllDoctorsWithStatus();
    _patientsStream = ref
        .read(patientControllerProvider)
        .streamAllPatientsWithStatus();
    _videosStream = ref.read(doctorVideoControllerProvider).watchAllVideos();
  }

  bool _isSuspended(Map<String, dynamic> user) {
    final status = (user['accountStatus'] ?? 'Active').toString();
    return status != 'Active' || SoftDeleteService.isDeleted(user);
  }

  Widget _loadingRow(BuildContext context, IconData icon, String label) {
    return AdminInfoRow(
      icon: icon,
      label: label,
      value: 'Loading...',
      valueColor: AdminPalette.textMuted,
    );
  }

  Widget _errorRow(BuildContext context, IconData icon, String label) {
    return AdminInfoRow(
      icon: icon,
      label: label,
      value: 'Could not load',
      valueColor: AdminPalette.error,
    );
  }

  @override
  Widget build(BuildContext context) {
    final appointments =
        ref.watch(allAppointmentsProvider).valueOrNull ??
        const <AppointmentModel>[];
    final payments =
        ref.watch(appointmentPaymentsProvider).valueOrNull ??
        const <AppointmentPaymentModel>[];

    final now = DateTime.now();
    final today = DateFormat('yyyy-MM-dd').format(now);

    final activeAppointments = appointments
        .where((a) => AppointmentStatus.isOpen(a.appointmentStatus))
        .length;
    final todaysAppointments = appointments
        .where((a) => a.scheduledDate == today)
        .length;
    final completedAppointments = appointments
        .where((a) => a.appointmentStatus == AppointmentStatus.completed)
        .length;
    final expiredAppointments = appointments
        .where((a) => a.appointmentStatus == AppointmentStatus.expired)
        .length;
    final closedOutAppointments = appointments
        .where(
          (a) =>
              a.appointmentStatus == AppointmentStatus.rejected ||
              a.appointmentStatus == AppointmentStatus.cancelled,
        )
        .length;

    final pendingPayments = payments.where((p) => p.isPending).length;
    final approvedPayments = payments.where((p) => p.isApproved).length;
    final rejectedPayments = payments.where((p) => p.isRejected).length;
    final discountedPayments = payments.where((p) => p.videoWatched).length;
    final collected = payments
        .where((p) => p.isApproved)
        .fold<double>(0, (sum, p) => sum + p.payableAmount);

    return AdminScreen(
      title: 'Reports',
      subtitle: 'Platform activity at a glance',
      showBack: true,
      body: ListView(
        physics: const BouncingScrollPhysics(),
        padding: EdgeInsets.fromLTRB(context.rsp(16), 18, context.rsp(16), 28),
        children: [
          const AdminSectionTitle(
            icon: Icons.event_note_rounded,
            title: 'Appointments',
          ),
          const SizedBox(height: 12),
          AdminCard(
            child: Column(
              children: [
                AdminInfoRow(
                  icon: Icons.event_note_rounded,
                  label: 'Total',
                  value: '${appointments.length}',
                ),
                AdminInfoRow(
                  icon: Icons.event_available_rounded,
                  label: 'Active now',
                  value: '$activeAppointments',
                  valueColor: AdminPalette.success,
                ),
                AdminInfoRow(
                  icon: Icons.today_rounded,
                  label: "Today's",
                  value: '$todaysAppointments',
                ),
                AdminInfoRow(
                  icon: Icons.check_circle_outline_rounded,
                  label: 'Completed',
                  value: '$completedAppointments',
                ),
                AdminInfoRow(
                  icon: Icons.schedule_rounded,
                  label: 'Expired',
                  value: '$expiredAppointments',
                  valueColor: AdminPalette.textMuted,
                ),
                AdminInfoRow(
                  icon: Icons.cancel_outlined,
                  label: 'Rejected or cancelled',
                  value: '$closedOutAppointments',
                  valueColor: AdminPalette.error,
                ),
              ],
            ),
          ),

          const SizedBox(height: 18),
          const AdminSectionTitle(
            icon: Icons.payments_rounded,
            title: 'Payments',
          ),
          const SizedBox(height: 12),
          AdminCard(
            child: Column(
              children: [
                AdminInfoRow(
                  icon: Icons.receipt_long_rounded,
                  label: 'Total submitted',
                  value: '${payments.length}',
                ),
                AdminInfoRow(
                  icon: Icons.pending_actions_rounded,
                  label: 'Pending',
                  value: '$pendingPayments',
                  valueColor: AdminPalette.warning,
                ),
                AdminInfoRow(
                  icon: Icons.check_circle_outline_rounded,
                  label: 'Approved',
                  value: '$approvedPayments',
                  valueColor: AdminPalette.success,
                ),
                AdminInfoRow(
                  icon: Icons.cancel_outlined,
                  label: 'Rejected',
                  value: '$rejectedPayments',
                  valueColor: AdminPalette.error,
                ),
                AdminInfoRow(
                  icon: Icons.payments_rounded,
                  label: 'Collected',
                  value: appointmentAmount(collected),
                  valueColor: AdminPalette.success,
                ),
                AdminInfoRow(
                  icon: Icons.video_library_rounded,
                  label: 'Video discounts',
                  value: '$discountedPayments',
                  valueColor: AdminPalette.brand,
                ),
              ],
            ),
          ),

          const SizedBox(height: 18),
          const AdminSectionTitle(
            icon: Icons.medical_services_outlined,
            title: 'Doctors & Videos',
          ),
          const SizedBox(height: 12),
          StreamBuilder<List<Map<String, dynamic>>>(
            stream: _doctorsStream,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return AdminCard(
                  child: Column(
                    children: [
                      _errorRow(
                        context,
                        Icons.medical_services_outlined,
                        'Total doctors',
                      ),
                    ],
                  ),
                );
              }
              if (!snapshot.hasData) {
                return AdminCard(
                  child: Column(
                    children: [
                      _loadingRow(
                        context,
                        Icons.medical_services_outlined,
                        'Total doctors',
                      ),
                    ],
                  ),
                );
              }
              final doctors = snapshot.data!;
              final online = doctors
                  .where((d) => d['isOnline'] == true && !_isSuspended(d))
                  .length;
              final suspended = doctors.where(_isSuspended).length;
              final active = doctors.length - suspended;

              return AdminCard(
                child: Column(
                  children: [
                    AdminInfoRow(
                      icon: Icons.medical_services_outlined,
                      label: 'Total doctors',
                      value: '${doctors.length}',
                    ),
                    AdminInfoRow(
                      icon: Icons.wifi_rounded,
                      label: 'Online now',
                      value: '$online',
                      valueColor: AdminPalette.success,
                    ),
                    AdminInfoRow(
                      icon: Icons.check_circle_outline_rounded,
                      label: 'Active',
                      value: '$active',
                    ),
                    AdminInfoRow(
                      icon: Icons.block_rounded,
                      label: 'Suspended',
                      value: '$suspended',
                      valueColor: AdminPalette.warning,
                    ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 10),
          StreamBuilder<List<DoctorVideoModel>>(
            stream: _videosStream,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return AdminCard(
                  child: _errorRow(
                    context,
                    Icons.video_library_rounded,
                    'Videos assigned',
                  ),
                );
              }
              if (!snapshot.hasData) {
                return AdminCard(
                  child: _loadingRow(
                    context,
                    Icons.video_library_rounded,
                    'Videos assigned',
                  ),
                );
              }
              final videos = snapshot.data!;
              final activeVideos = videos.where((v) => v.isActive).length;
              return AdminCard(
                child: Column(
                  children: [
                    AdminInfoRow(
                      icon: Icons.video_library_rounded,
                      label: 'Videos assigned',
                      value: '${videos.length}',
                    ),
                    AdminInfoRow(
                      icon: Icons.play_circle_outline_rounded,
                      label: 'Active videos',
                      value: '$activeVideos',
                      valueColor: AdminPalette.success,
                    ),
                  ],
                ),
              );
            },
          ),

          const SizedBox(height: 18),
          const AdminSectionTitle(
            icon: Icons.people_outline_rounded,
            title: 'Patients',
          ),
          const SizedBox(height: 12),
          StreamBuilder<List<Map<String, dynamic>>>(
            stream: _patientsStream,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return AdminCard(
                  child: _errorRow(
                    context,
                    Icons.people_outline_rounded,
                    'Total patients',
                  ),
                );
              }
              if (!snapshot.hasData) {
                return AdminCard(
                  child: _loadingRow(
                    context,
                    Icons.people_outline_rounded,
                    'Total patients',
                  ),
                );
              }
              final patients = snapshot.data!;
              final online = patients
                  .where((p) => p['isOnline'] == true && !_isSuspended(p))
                  .length;
              final suspended = patients.where(_isSuspended).length;

              return AdminCard(
                child: Column(
                  children: [
                    AdminInfoRow(
                      icon: Icons.people_outline_rounded,
                      label: 'Total patients',
                      value: '${patients.length}',
                    ),
                    AdminInfoRow(
                      icon: Icons.wifi_rounded,
                      label: 'Online now',
                      value: '$online',
                      valueColor: AdminPalette.success,
                    ),
                    AdminInfoRow(
                      icon: Icons.block_rounded,
                      label: 'Suspended',
                      value: '$suspended',
                      valueColor: AdminPalette.warning,
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
