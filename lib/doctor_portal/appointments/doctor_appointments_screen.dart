import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/admin_portal/admin_ui.dart';
import 'package:telemedicine/auth/auth_provider/user_provider.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/data/models/appointment_model.dart';
import 'package:telemedicine/doctor_portal/appointments/confirm_appointment_screen.dart';
import 'package:telemedicine/features/appointment/appointment_controller.dart';
import 'package:telemedicine/features/appointment/appointment_detail_screen.dart';
import 'package:telemedicine/features/appointment/appointment_ui.dart';
import 'package:telemedicine/home_widget/chat_call/chat/chat_screen.dart';
import 'package:telemedicine/shared/widgets/opd_design.dart';

/// The doctor's appointment queue — one of the four tabs in the doctor bottom
/// navigation.
///
/// Rendered inside `DoctorPortalWrapper`'s `IndexedStack`, so it owns its own
/// header instead of an `AppBar`.
class DoctorAppointmentsScreen extends ConsumerStatefulWidget {
  const DoctorAppointmentsScreen({super.key});

  @override
  ConsumerState<DoctorAppointmentsScreen> createState() =>
      _DoctorAppointmentsScreenState();
}

class _DoctorAppointmentsScreenState
    extends ConsumerState<DoctorAppointmentsScreen> {
  String _filter = AppointmentStatus.requested;

  @override
  void initState() {
    super.initState();
    // Close anything whose scheduled end already elapsed. Idempotent, and both
    // sides may run it, so it is deliberately fire-and-forget.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final user = ref.read(userProvider);
      if (user != null && user.role == UserRoles.doctor) {
        ref.read(appointmentControllerProvider).finalizeExpiredAppointments(
              userId: user.id,
              isDoctor: true,
            );
      }
    });
  }

  bool _matches(AppointmentModel appointment) {
    switch (_filter) {
      case 'all':
        return true;
      case AppointmentStatus.completed:
        return appointment.isCompleted;
      case AppointmentStatus.confirmed:
        return appointment.isConfirmed &&
            appointment.appointmentStatus != AppointmentStatus.active;
      case AppointmentStatus.requested:
        return appointment.isRequested;
      case AppointmentStatus.noShow:
        return appointment.isNoShow;
      case AppointmentStatus.cancelled:
        return appointment.isCancelled;
      case 'live':
        return AppointmentStatus.isOpen(appointment.appointmentStatus) &&
            (appointment.appointmentStatus == AppointmentStatus.active ||
                AppointmentPhase.isLive(
                    appointmentDisplayPhase(appointment)));
      default:
        return appointment.appointmentStatus == _filter;
    }
  }

  @override
  Widget build(BuildContext context) {
    final appointmentsAsync = ref.watch(myAppointmentsProvider);

    return Scaffold(
      backgroundColor: AdminPalette.background,
      body: Stack(
        children: [
          Positioned(
            top: 20,
            right: 0,
            child: Opacity(
              opacity: 0.12,
              child: CustomPaint(
                size: const Size(220, 160),
                painter: ECGWatermarkPainter(),
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(context.rsp(20), 14, context.rsp(20), 0),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 440),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Appointments',
                            style: TextStyle(
                              fontSize: context.fs(20),
                              fontWeight: FontWeight.bold,
                              color: AdminPalette.textPrimary,
                              letterSpacing: -0.5,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Set the date and time for each request. A pinned '
                            'message is posted to the patient chat.',
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w500,
                              color: AdminPalette.textSecondary,
                              height: 1.4,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: context.rsp(20)),
                  child: SizedBox(
                    width: double.infinity,
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _chip('Requested', AppointmentStatus.requested),
                        _chip('Confirmed', AppointmentStatus.confirmed),
                        _chip('Live', 'live'),
                        _chip('Completed', AppointmentStatus.completed),
                        _chip('No Show', AppointmentStatus.noShow),
                        _chip('Cancelled', AppointmentStatus.cancelled),
                        _chip('Expired', AppointmentStatus.expired),
                        _chip('All', 'all'),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: context.rsp(20)),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 440),
                        child: appointmentsAsync.when(
                          loading: () => const OpdInlineLoader(
                            label: 'Loading appointments...',
                          ),
                          error: (_, __) => const OpdEmptyState(
                            icon: Icons.wifi_off_rounded,
                            title: 'Could not load appointments',
                            subtitle: 'Check your connection and try again.',
                          ),
                          data: (appointments) {
                            final filtered =
                                appointments.where(_matches).toList()
                                  ..sort((a, b) {
                                    bool isLive(AppointmentModel a) =>
                                        a.appointmentStatus ==
                                                AppointmentStatus.active ||
                                            (a.isConfirmed &&
                                                a.hasSchedule &&
                                                AppointmentPhase.isLive(
                                                    appointmentDisplayPhase(
                                                        a)));
                                    final aLive = isLive(a);
                                    final bLive = isLive(b);
                                    if (aLive != bLive) return aLive ? -1 : 1;
                                    final aTime = a.requestedAt ?? a.createdAt;
                                    final bTime = b.requestedAt ?? b.createdAt;
                                    if (aTime == null && bTime == null) {
                                      return 0;
                                    }
                                    if (aTime == null) return 1;
                                    if (bTime == null) return -1;
                                    return bTime.compareTo(aTime);
                                  });

                            if (filtered.isEmpty) {
                              return OpdEmptyState(
                                icon: Icons.event_available_rounded,
                                title: _filter == AppointmentStatus.requested
                                    ? 'No pending requests'
                                    : 'Nothing here yet',
                                subtitle: _filter ==
                                        AppointmentStatus.requested
                                    ? 'New appointment requests from patients '
                                        'will appear in this list.'
                                    : 'Appointments will show up here as they '
                                        'move through their lifecycle.',
                              );
                            }

                            return ListView.separated(
                              physics: const BouncingScrollPhysics(),
                              padding: const EdgeInsets.only(bottom: 12),
                              itemCount: filtered.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 12),
                              itemBuilder: (context, index) => _AppointmentRow(
                                appointment: filtered[index],
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, String value) {
    return AdminFilterChip(
      label: label,
      selected: _filter == value,
      onTap: () => setState(() => _filter = value),
    );
  }
}

class _AppointmentRow extends ConsumerWidget {
  final AppointmentModel appointment;

  const _AppointmentRow({required this.appointment});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final image = appointment.patientImage;
    final name = appointment.patientName.isEmpty
        ? 'Patient'
        : appointment.patientName;
    final actionable = appointment.isRequested && !appointment.hasSchedule;
    final phase = appointmentDisplayPhase(appointment);
    final joinable =
        showAppointmentJoinAction(appointment, asDoctor: true);
    final canComplete = appointment.isConfirmed &&
        appointment.hasPatientJoined &&
        appointment.hasDoctorJoined;
    final canCancel =
        showAppointmentCancelAction(appointment, asDoctor: true);

    return OpdCard(
      padding: const EdgeInsets.all(16),
      // A slot still to be scheduled opens the scheduling screen; everything
      // else opens the shared detail screen, where the timeline and the
      // lifecycle actions live.
      onTap: actionable
          ? () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      ConfirmAppointmentScreen(appointment: appointment),
                ),
              )
          : () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => AppointmentDetailScreen(
                    appointmentId: appointment.id,
                  ),
                ),
              ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: const Color(0xFFF0F4FA),
                backgroundImage:
                    image.isNotEmpty ? CachedNetworkImageProvider(image) : null,
                child: image.isEmpty
                    ? Text(
                        name[0].toUpperCase(),
                        style: TextStyle(
                          fontSize: context.fs(15),
                          fontWeight: FontWeight.bold,
                          color: const Color(0xFF062B72),
                        ),
                      )
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: context.fs(14),
                        fontWeight: FontWeight.w600,
                        color: AdminPalette.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      appointment.subject.isEmpty
                          ? 'Appointment request'
                          : appointment.subject,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: AdminPalette.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              AppointmentStatusPill(status: appointment.appointmentStatus),
            ],
          ),
          if (phase.isNotEmpty) ...[
            const SizedBox(height: 10),
            AppointmentPhasePill(phase: phase),
          ],
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AdminPalette.infoBg,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AdminPalette.infoBorder),
            ),
            child: appointment.hasSchedule
                ? Column(
                    children: [
                      OpdDetailRow(
                        icon: Icons.event_available_rounded,
                        label: 'Scheduled',
                        value:
                            '${appointmentFormatDisplayDate(appointment.scheduledDate)} • '
                            '${appointment.scheduledStartTime} - '
                            '${appointment.scheduledEndTime}',
                      ),
                    ],
                  )
                : Row(
                    children: [
                      const Icon(
                        Icons.schedule_rounded,
                        size: 18,
                        color: Color(0xFFE9A400),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Waiting for you to pick a date and time',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w500,
                            color: AdminPalette.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
          if (actionable) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                const Icon(
                  Icons.touch_app_rounded,
                  size: 14,
                  color: Color(0xFF062B72),
                ),
                const SizedBox(width: 6),
                Text(
                  'Tap to schedule',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF062B72),
                  ),
                ),
              ],
            ),
          ],
          if (joinable || canComplete || canCancel) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (joinable)
                  FilledButton.icon(
                    onPressed: () => _join(context, ref),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF0E7C86),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 9,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: const Icon(Icons.video_call_rounded, size: 16),
                    label: Text(
                      'Join',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                if (canComplete)
                  OutlinedButton.icon(
                    onPressed: () => _complete(context, ref),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF1E8E5A),
                      side: const BorderSide(color: Color(0xFF9BD3B8)),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 9,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: const Icon(Icons.check_circle_outline_rounded,
                        size: 16),
                    label: Text(
                      'Complete',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                if (canCancel)
                  OutlinedButton.icon(
                    onPressed: () => _cancel(context, ref),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFD64545),
                      side: const BorderSide(color: Color(0xFFF0B4B4)),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 9,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: const Icon(Icons.event_busy_rounded, size: 16),
                    label: Text(
                      'Cancel',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _join(BuildContext context, WidgetRef ref) async {
    final user = ref.read(userProvider);
    if (user == null) return;

    final error =
        await ref.read(appointmentControllerProvider).markAppointmentJoined(
              appointment: appointment,
              actorId: user.id,
              asDoctor: true,
            );
    if (error != null) {
      ToastService.instance.showError(error);
      return;
    }
    ToastService.instance.showSuccess('You have joined the appointment.');
    if (!context.mounted) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          otherUserId: appointment.patientId,
          otherUserName: appointment.patientName.isEmpty
              ? 'Patient'
              : appointment.patientName,
          otherUserImage: appointment.patientImage,
          currentUserRole: UserRoles.doctor,
          otherUserType: UserRoles.patient,
          otherUserRole: UserRoles.patient,
        ),
      ),
    );
  }

  Future<void> _complete(BuildContext context, WidgetRef ref) async {
    final user = ref.read(userProvider);
    if (user == null) return;
    final error =
        await ref.read(appointmentControllerProvider).completeAppointment(
              appointment: appointment,
              actorId: user.id,
              actorRole: AppointmentActors.doctor,
            );
    if (error != null) {
      ToastService.instance.showError(error);
      return;
    }
    ToastService.instance.showSuccess('Appointment completed.');
  }

  Future<void> _cancel(BuildContext context, WidgetRef ref) async {
    final user = ref.read(userProvider);
    if (user == null) return;

    final controller = ref.read(appointmentControllerProvider);
    final config = await controller.config();
    final policy = await controller.userPolicyState(
      collection: FirestoreCollections.doctors,
      userId: user.id,
    );
    if (!context.mounted) return;

    final result = await showAppointmentCancelDialog(
      context,
      config: config,
      warningCount: policy.warnings,
    );
    if (!result.confirmed) return;

    final error = await controller.cancelAppointment(
      appointment: appointment,
      actorId: user.id,
      actorRole: AppointmentActors.doctor,
      reason: result.reason,
    );
    if (error != null) {
      ToastService.instance.showError(error);
      return;
    }
    ToastService.instance.showSuccess('Appointment cancelled.');
  }
}
