import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/auth/auth_provider/user_provider.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/data/models/appointment_model.dart';
import 'package:telemedicine/data/models/user_model.dart';
import 'package:telemedicine/features/appointment/appointment_controller.dart';
import 'package:telemedicine/features/appointment/appointment_ui.dart';
import 'package:telemedicine/home_widget/chat_call/chat/chat_screen.dart';
import 'package:telemedicine/shared/widgets/opd_design.dart';

/// One appointment, watched live: the phase banner, who has joined so far,
/// the action row (Join / Open chat / Cancel / Complete) and the append-only
/// audit timeline.
///
/// Shared by the patient tab, the doctor queue and the admin review â€” the
/// actions are gated on the signed-in role, so an admin reading someone's
/// record sees exactly the same history without the buttons.
class AppointmentDetailScreen extends ConsumerWidget {
  const AppointmentDetailScreen({super.key, required this.appointmentId});

  final String appointmentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appointmentAsync = ref.watch(appointmentProvider(appointmentId));
    final user = ref.watch(userProvider);

    return appointmentAsync.when(
      loading: () => OpdScreenShell(
        title: 'Appointment',
        subtitle: 'Loading the latest status...',
        child: const OpdInlineLoader(label: 'Loading appointment...'),
      ),
      error: (_, __) => OpdScreenShell(
        title: 'Appointment',
        child: const OpdEmptyState(
          icon: Icons.wifi_off_rounded,
          title: 'Could not load this appointment',
          subtitle: 'Check your connection and try again.',
        ),
      ),
      data: (appointment) {
        if (appointment == null) {
          return OpdScreenShell(
            title: 'Appointment',
            child: const OpdEmptyState(
              icon: Icons.event_busy_rounded,
              title: 'Appointment not found',
              subtitle: 'It may have been removed.',
            ),
          );
        }

        final isDoctor =
            user != null && user.role == UserRoles.doctor &&
                user.id == appointment.doctorId;
        final isAdmin = user != null && user.role == UserRoles.admin;
        final canAct = user != null && !isAdmin &&
            (isDoctor
                ? user.id == appointment.doctorId
                : user.id == appointment.patientId);

        return OpdScreenShell(
          title: 'Appointment',
          subtitle: appointment.subject.isEmpty
              ? 'Consultation with ${isDoctor ? appointment.patientName : 'Dr. ${appointment.doctorName}'}'
              : appointment.subject,
          bottom: canAct
              ? _buildActions(context, ref, appointment,
                  asDoctor: isDoctor, user: user)
              : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildPartyCard(context, appointment, asDoctor: isDoctor),
              if (canAct &&
                  showAppointmentCancelAction(appointment, asDoctor: isDoctor)) ...[
                const SizedBox(height: 12),
                _buildCancelTile(context, ref, appointment,
                    asDoctor: isDoctor, user: user),
              ],
              const SizedBox(height: 18),
              const OpdSectionLabel('Audit timeline'),
              AppointmentTimeline(appointmentId: appointment.id),
            ],
          ),
        );
      },
    );
  }

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  // PARTY + STATUS CARD
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Widget _buildPartyCard(
    BuildContext context,
    AppointmentModel appointment, {
    required bool asDoctor,
  }) {
    final counterpartName = asDoctor
        ? appointment.patientName
        : 'Dr. ${appointment.doctorName}';
    final counterpartImage =
        asDoctor ? appointment.patientImage : appointment.doctorImage;
    final phase = appointmentDisplayPhase(appointment);

    return OpdCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: const Color(0xFFF0F4FA),
                backgroundImage: counterpartImage.isNotEmpty
                    ? CachedNetworkImageProvider(counterpartImage)
                    : null,
                child: counterpartImage.isEmpty
                    ? Text(
                        counterpartName.isNotEmpty
                            ? counterpartName[0].toUpperCase()
                            : '?',
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
                      counterpartName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: context.fs(14),
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFF1F2F44),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      asDoctor ? 'Patient' : 'Doctor',
                      style: TextStyle(
                        fontSize: 12,
                        color: const Color(0xFF657991),
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
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                AppointmentPhasePill(phase: phase),
                if (appointmentPhaseHint(phase).isNotEmpty)
                  Expanded(
                    child: Text(
                      appointmentPhaseHint(phase),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: appointmentPhaseColor(phase),
                        height: 1.35,
                      ),
                    ),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFF0F4FA),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFDCE6F2)),
            ),
            child: Column(
              children: [
                if (appointment.hasSchedule)
                  OpdDetailRow(
                    icon: Icons.event_available_rounded,
                    label: 'Scheduled',
                    value:
                        '${appointmentFormatDisplayDate(appointment.scheduledDate)} â€¢ '
                        '${appointment.scheduledStartTime} - '
                        '${appointment.scheduledEndTime}',
                  )
                else
                  OpdDetailRow(
                    icon: Icons.schedule_rounded,
                    label: 'Schedule',
                    value: 'Not set yet',
                  ),
                OpdDetailRow(
                  icon: Icons.payments_rounded,
                  label: 'Paid',
                  value: appointmentAmount(appointment.payableAmount),
                ),
                OpdDetailRow(
                  icon: Icons.login_rounded,
                  label: 'Patient joined',
                  value: _joinLabel(appointment.patientJoinedAt),
                ),
                OpdDetailRow(
                  icon: Icons.medical_services_rounded,
                  label: 'Doctor joined',
                  value: _joinLabel(appointment.doctorJoinedAt),
                ),
                if (appointment.isCancelled &&
                    appointment.cancelReason.isNotEmpty)
                  OpdDetailRow(
                    icon: Icons.cancel_rounded,
                    label: 'Reason',
                    value: appointment.cancelReason,
                  ),
                if (appointment.isNoShow)
                  OpdDetailRow(
                    icon: Icons.person_off_rounded,
                    label: 'No-show',
                    value: appointment.noShowBy.isEmpty
                        ? 'Not assigned'
                        : appointment.noShowBy == AppointmentNoShowBy.doctor
                            ? 'Dr. ${appointment.doctorName} did not join'
                            : '${appointment.patientName} did not join',
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _joinLabel(DateTime? joinedAt) {
    if (joinedAt == null) return 'Not yet';
    final local = joinedAt.toLocal();
    final hour12 = local.hour % 12 == 0 ? 12 : local.hour % 12;
    return 'Joined $hour12:${local.minute.toString().padLeft(2, '0')} '
        '${local.hour < 12 ? 'AM' : 'PM'}';
  }

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  // ACTIONS
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  /// Join + Open chat in the fixed action bar. The Join button only appears
  /// while the slot is actually running and this side has not arrived yet â€”
  /// everything else is a quieter secondary action.
  Widget _buildActions(
    BuildContext context,
    WidgetRef ref,
    AppointmentModel appointment, {
    required bool asDoctor,
    required UserModel user,
  }) {
    final joinable = showAppointmentJoinAction(appointment, asDoctor: asDoctor);
    final chatPartnerName = asDoctor
        ? appointment.patientName
        : 'Dr. ${appointment.doctorName}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (joinable) ...[
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => _join(context, ref, appointment,
                      asDoctor: asDoctor, user: user),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF0E7C86),
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  icon: const Icon(Icons.video_call_rounded, size: 18),
                  label: Text(
                    'Join appointment',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
            ],
            OutlinedButton.icon(
              onPressed: () => _openChat(
                context,
                appointment,
                asDoctor: asDoctor,
                name: chatPartnerName,
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF062B72),
                side: const BorderSide(color: Color(0xFFB9C9DE)),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 13,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              icon: const Icon(Icons.chat_bubble_outline_rounded, size: 17),
              label: Text(
                'Chat',
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildCancelTile(
    BuildContext context,
    WidgetRef ref,
    AppointmentModel appointment, {
    required bool asDoctor,
    required UserModel user,
  }) {
    return OpdCard(
      padding: const EdgeInsets.all(14),
      onTap: () => _cancel(context, ref, appointment,
          asDoctor: asDoctor, user: user),
      child: Row(
        children: [
          const Icon(Icons.event_busy_rounded, color: Color(0xFFD64545)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Cancel this appointment',
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: const Color(0xFFD64545),
              ),
            ),
          ),
          const Icon(
            Icons.arrow_forward_ios_rounded,
            size: 14,
            color: Color(0xFFD64545),
          ),
        ],
      ),
    );
  }

  Future<void> _join(
    BuildContext context,
    WidgetRef ref,
    AppointmentModel appointment, {
    required bool asDoctor,
    required UserModel user,
  }) async {
    final controller = ref.read(appointmentControllerProvider);
    final error = await controller.markAppointmentJoined(
      appointment: appointment,
      actorId: user.id,
      asDoctor: asDoctor,
    );
    if (error != null) {
      ToastService.instance.showError(error);
      return;
    }
    ToastService.instance.showSuccess('You have joined the appointment.');
    if (!context.mounted) return;
    _openChat(
      context,
      appointment,
      asDoctor: asDoctor,
      name: asDoctor
          ? appointment.patientName
          : 'Dr. ${appointment.doctorName}',
    );
  }

  Future<void> _cancel(
    BuildContext context,
    WidgetRef ref,
    AppointmentModel appointment, {
    required bool asDoctor,
    required UserModel user,
  }) async {
    final controller = ref.read(appointmentControllerProvider);
    final config = await controller.config();
    final policy = await controller.userPolicyState(
      collection: asDoctor
          ? FirestoreCollections.doctors
          : FirestoreCollections.patients,
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
      actorRole: asDoctor ? AppointmentActors.doctor : AppointmentActors.patient,
      reason: result.reason,
    );
    if (error != null) {
      ToastService.instance.showError(error);
      return;
    }
    ToastService.instance.showSuccess('Appointment cancelled.');
  }

  void _openChat(
    BuildContext context,
    AppointmentModel appointment, {
    required bool asDoctor,
    required String name,
  }) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          otherUserId: asDoctor ? appointment.patientId : appointment.doctorId,
          otherUserName: name,
          otherUserImage:
              asDoctor ? appointment.patientImage : appointment.doctorImage,
          currentUserRole: asDoctor ? UserRoles.doctor : UserRoles.patient,
          otherUserType: asDoctor ? UserRoles.patient : UserRoles.doctor,
          otherUserRole: asDoctor ? UserRoles.patient : UserRoles.doctor,
        ),
      ),
    );
  }

}
