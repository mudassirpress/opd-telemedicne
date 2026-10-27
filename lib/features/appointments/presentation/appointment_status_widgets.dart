import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/data/models/appointment_model.dart';
import 'package:telemedicine/features/appointments/presentation/appointment_controller.dart';
import 'package:telemedicine/features/appointments/presentation/appointment_lifecycle_logic.dart';
import 'package:telemedicine/shared/widgets/custom_text_field.dart';
import 'package:telemedicine/shared/widgets/opd_design_system.dart';

/// Shared presentation helpers for the appointment feature: status labels,
/// phase labels, timeline labels, status colours and money formatting are
/// defined once so the patient tab, the doctor queue and the admin review can
/// never drift apart.

String appointmentStatusLabel(String status) {
  switch (status) {
    case AppointmentStatus.requested:
      return 'Requested';
    case AppointmentStatus.confirmed:
      return 'Confirmed';
    case AppointmentStatus.active:
      return 'In Progress';
    case AppointmentStatus.completed:
      return 'Completed';
    case AppointmentStatus.expired:
      return 'Expired';
    case AppointmentStatus.rejected:
      return 'Rejected';
    case AppointmentStatus.cancelled:
      return 'Cancelled';
    case AppointmentStatus.noShow:
      return 'No-Show';
    default:
      return status.isEmpty ? 'Unknown' : status;
  }
}

Color appointmentStatusColor(String status) {
  switch (status) {
    case AppointmentStatus.requested:
      return const Color(0xFFE9A400);
    case AppointmentStatus.confirmed:
      return const Color(0xFF1E8E5A);
    // Live now: a cooler green so it reads as "the same thing, in progress"
    // without being mistaken for a merely confirmed booking.
    case AppointmentStatus.active:
      return const Color(0xFF0E7C86);
    case AppointmentStatus.completed:
      return const Color(0xFF062B72);
    // History, not an error: slate rather than the red used for
    // rejected/cancelled, so a patient never reads an expired slot as a
    // failure.
    case AppointmentStatus.expired:
      return const Color(0xFF6B7A90);
    // Somebody's time was actually wasted — warmer than the slate of an
    // expired slot but not the red of a rejection, so the two never read as
    // the same thing.
    case AppointmentStatus.noShow:
      return const Color(0xFFB45309);
    case AppointmentStatus.rejected:
    case AppointmentStatus.cancelled:
      return const Color(0xFFD64545);
    default:
      return const Color(0xFF7E90A6);
  }
}

IconData appointmentStatusIcon(String status) {
  switch (status) {
    case AppointmentStatus.requested:
      return Icons.schedule_rounded;
    case AppointmentStatus.confirmed:
      return Icons.event_available_rounded;
    case AppointmentStatus.active:
      return Icons.video_call_rounded;
    case AppointmentStatus.completed:
      return Icons.check_circle_rounded;
    case AppointmentStatus.expired:
      return Icons.event_busy_rounded;
    case AppointmentStatus.noShow:
      return Icons.person_off_rounded;
    case AppointmentStatus.rejected:
    case AppointmentStatus.cancelled:
      return Icons.cancel_rounded;
    default:
      return Icons.event_rounded;
  }
}

// ─────────────────────────────────────────────────────────────
// PHASE (the fine-grained, time-and-attendance state)
// ─────────────────────────────────────────────────────────────

/// The phase worth *showing* for [appointment], or `''` when the status pill
/// already says everything (unscheduled, waiting-only or terminal records).
///
/// The stored `appointmentPhase` is authoritative — the foreground clock and
/// the scheduled Cloud Function keep it fresh every few seconds. Only a legacy
/// document that predates the field falls back to deriving it here, with the
/// business defaults.
String appointmentDisplayPhase(AppointmentModel appointment, {DateTime? now}) {
  if (!AppointmentStatus.isOpen(appointment.appointmentStatus)) return '';
  if (!appointment.isConfirmed || !appointment.hasSchedule) return '';

  final stored = appointment.appointmentPhase;
  if (stored.isNotEmpty &&
      stored != AppointmentPhase.waiting &&
      stored != AppointmentPhase.closed) {
    return stored;
  }
  return resolveAppointmentPhase(
    status: appointment.appointmentStatus,
    startAt: appointment.startAt,
    endAt: appointment.endAt,
    patientJoinedAt: appointment.patientJoinedAt,
    doctorJoinedAt: appointment.doctorJoinedAt,
    now: now ?? DateTime.now(),
    config: AppointmentConfig.defaults(),
  );
}

String appointmentPhaseLabel(String phase) {
  switch (phase) {
    case AppointmentPhase.waiting:
      return 'Awaiting Schedule';
    case AppointmentPhase.scheduled:
      return 'Scheduled';
    case AppointmentPhase.startingSoon:
      return 'Starting Soon';
    case AppointmentPhase.waitingForDoctor:
      return 'Waiting for Doctor';
    case AppointmentPhase.waitingForPatient:
      return 'Waiting for Patient';
    case AppointmentPhase.doctorLate:
      return 'Doctor Late';
    case AppointmentPhase.patientLate:
      return 'Patient Late';
    case AppointmentPhase.graceEnding:
      return 'Ending Soon';
    case AppointmentPhase.inProgress:
      return 'In Session';
    case AppointmentPhase.closed:
      return 'Closed';
    default:
      return phase.isEmpty ? '' : phase;
  }
}

Color appointmentPhaseColor(String phase) {
  switch (phase) {
    case AppointmentPhase.waiting:
      return const Color(0xFF6B7A90);
    case AppointmentPhase.scheduled:
      return const Color(0xFF1E8E5A);
    case AppointmentPhase.startingSoon:
      return const Color(0xFFE9A400);
    case AppointmentPhase.waitingForDoctor:
    case AppointmentPhase.waitingForPatient:
      return const Color(0xFF3D6DB5);
    // Somebody is missing and the clock is running — the two late phases
    // escalate with who is at fault: the doctor keeping a patient waiting is
    // the more urgent of the two.
    case AppointmentPhase.doctorLate:
      return const Color(0xFFD64545);
    case AppointmentPhase.patientLate:
      return const Color(0xFFC2410C);
    case AppointmentPhase.graceEnding:
      return const Color(0xFFE9A400);
    case AppointmentPhase.inProgress:
      return const Color(0xFF0E7C86);
    default:
      return const Color(0xFF7E90A6);
  }
}

IconData appointmentPhaseIcon(String phase) {
  switch (phase) {
    case AppointmentPhase.waiting:
      return Icons.hourglass_top_rounded;
    case AppointmentPhase.scheduled:
      return Icons.event_available_rounded;
    case AppointmentPhase.startingSoon:
      return Icons.alarm_rounded;
    case AppointmentPhase.waitingForDoctor:
    case AppointmentPhase.waitingForPatient:
      return Icons.schedule_rounded;
    case AppointmentPhase.doctorLate:
    case AppointmentPhase.patientLate:
      return Icons.timer_off_rounded;
    case AppointmentPhase.graceEnding:
      return Icons.hourglass_bottom_rounded;
    case AppointmentPhase.inProgress:
      return Icons.video_call_rounded;
    default:
      return Icons.event_rounded;
  }
}

/// One neutral sentence about what a phase means — third person, because the
/// same line is shown to the patient, the doctor and the admin.
String appointmentPhaseHint(String phase) {
  switch (phase) {
    case AppointmentPhase.startingSoon:
      return 'The slot opens shortly. Join when it starts.';
    case AppointmentPhase.waitingForDoctor:
      return 'The slot is running — waiting for the doctor to join.';
    case AppointmentPhase.waitingForPatient:
      return 'The doctor is in — waiting for the patient to join.';
    case AppointmentPhase.doctorLate:
      return 'The doctor has not joined yet. The slot keeps running.';
    case AppointmentPhase.patientLate:
      return 'The patient has not joined yet.';
    case AppointmentPhase.graceEnding:
      return 'The slot is about to close. Join now or it will end.';
    case AppointmentPhase.inProgress:
      return 'Both sides are in — the consultation is under way.';
    default:
      return '';
  }
}

/// `1500` → `PKR 1,500`. Matches `AppointmentPricing.format` but works without
/// a pricing instance, which the list cards need.
String appointmentAmount(num value) {
  final rounded = value.round();
  final formatted = rounded.toString();
  final buffer = StringBuffer();
  for (int i = 0; i < formatted.length; i++) {
    final fromEnd = formatted.length - i;
    buffer.write(formatted[i]);
    if (fromEnd > 1 && fromEnd % 3 == 1) buffer.write(',');
  }
  return '${AppointmentDefaults.currency} $buffer';
}

/// Pulls the 11-character video id out of the common YouTube URL shapes so the
/// details screen can show a real thumbnail. Returns `''` for anything it does
/// not recognise — the caller then falls back to a play-icon placeholder.
String appointmentYoutubeVideoId(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null) return '';
  final host = uri.host.toLowerCase();
  if (host == 'youtu.be') {
    return uri.pathSegments.isEmpty ? '' : uri.pathSegments.first;
  }
  if (host == 'youtube.com' ||
      host.endsWith('.youtube.com') ||
      host == 'youtube-nocookie.com' ||
      host.endsWith('.youtube-nocookie.com')) {
    final fromQuery = uri.queryParameters['v'];
    if (fromQuery != null && fromQuery.isNotEmpty) return fromQuery;
    final segments = uri.pathSegments;
    if (segments.length >= 2) {
      final penultimate = segments[segments.length - 2];
      if (penultimate == 'embed' || penultimate == 'shorts') {
        return segments.last;
      }
    }
  }
  return '';
}

/// Compact status badge used on every appointment card.
class AppointmentStatusPill extends StatelessWidget {
  final String status;
  final double fontSize;

  const AppointmentStatusPill({
    super.key,
    required this.status,
    this.fontSize = 11.5,
  });

  @override
  Widget build(BuildContext context) {
    final color = appointmentStatusColor(status);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: context.rsp(10), vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(appointmentStatusIcon(status), size: 13, color: color),
          const SizedBox(width: 5),
          Text(
            appointmentStatusLabel(status).toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w600,
              color: color,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact badge for the *phase* — sits next to [AppointmentStatusPill] while
/// an appointment is open, and carries the time-and-attendance half of the
/// story ("waiting for the doctor") that the coarse status cannot.
class AppointmentPhasePill extends StatelessWidget {
  final String phase;
  final double fontSize;

  const AppointmentPhasePill({
    super.key,
    required this.phase,
    this.fontSize = 11.5,
  });

  @override
  Widget build(BuildContext context) {
    if (phase.isEmpty) return const SizedBox.shrink();
    final color = appointmentPhaseColor(phase);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: context.rsp(10), vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(appointmentPhaseIcon(phase), size: 13, color: color),
          const SizedBox(width: 5),
          Text(
            appointmentPhaseLabel(phase).toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w600,
              color: color,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// AUDIT TIMELINE — `appointments/{id}/events`
// ─────────────────────────────────────────────────────────────

String appointmentEventLabel(String type) {
  switch (type) {
    case AppointmentEventTypes.created:
      return 'Request created';
    case AppointmentEventTypes.confirmed:
      return 'Confirmed by doctor';
    case AppointmentEventTypes.rescheduled:
      return 'Date and time set';
    case AppointmentEventTypes.activated:
      return 'Slot started';
    case AppointmentEventTypes.patientJoined:
      return 'Patient joined';
    case AppointmentEventTypes.doctorJoined:
      return 'Doctor joined';
    case AppointmentEventTypes.reminderSent:
      return 'Reminder sent';
    case AppointmentEventTypes.doctorLate:
      return 'Doctor late';
    case AppointmentEventTypes.patientLate:
      return 'Patient late';
    case AppointmentEventTypes.graceEnding:
      return 'Slot ending soon';
    case AppointmentEventTypes.cancelled:
      return 'Cancelled';
    case AppointmentEventTypes.warningIssued:
      return 'Cancellation warning issued';
    case AppointmentEventTypes.freezeApplied:
      return 'Bookings paused';
    case AppointmentEventTypes.freezeLifted:
      return 'Bookings restored';
    case AppointmentEventTypes.expired:
      return 'Expired';
    case AppointmentEventTypes.completed:
      return 'Completed';
    case AppointmentEventTypes.noShow:
      return 'Marked as a no-show';
    case AppointmentEventTypes.adminAction:
      return 'Admin action';
    default:
      return type.isEmpty ? 'Updated' : type;
  }
}

IconData appointmentEventIcon(String type) {
  switch (type) {
    case AppointmentEventTypes.created:
      return Icons.add_circle_outline_rounded;
    case AppointmentEventTypes.confirmed:
      return Icons.event_available_rounded;
    case AppointmentEventTypes.rescheduled:
      return Icons.update_rounded;
    case AppointmentEventTypes.activated:
      return Icons.play_circle_outline_rounded;
    case AppointmentEventTypes.patientJoined:
      return Icons.person_rounded;
    case AppointmentEventTypes.doctorJoined:
      return Icons.medical_services_rounded;
    case AppointmentEventTypes.reminderSent:
      return Icons.notifications_active_rounded;
    case AppointmentEventTypes.doctorLate:
    case AppointmentEventTypes.patientLate:
      return Icons.timer_off_rounded;
    case AppointmentEventTypes.graceEnding:
      return Icons.hourglass_bottom_rounded;
    case AppointmentEventTypes.cancelled:
      return Icons.cancel_rounded;
    case AppointmentEventTypes.warningIssued:
      return Icons.warning_amber_rounded;
    case AppointmentEventTypes.freezeApplied:
      return Icons.block_rounded;
    case AppointmentEventTypes.freezeLifted:
      return Icons.lock_open_rounded;
    case AppointmentEventTypes.expired:
      return Icons.event_busy_rounded;
    case AppointmentEventTypes.completed:
      return Icons.check_circle_rounded;
    case AppointmentEventTypes.noShow:
      return Icons.person_off_rounded;
    case AppointmentEventTypes.adminAction:
      return Icons.admin_panel_settings_rounded;
    default:
      return Icons.circle_rounded;
  }
}

Color appointmentEventColor(String type) {
  switch (type) {
    case AppointmentEventTypes.cancelled:
      return const Color(0xFFD64545);
    case AppointmentEventTypes.warningIssued:
    case AppointmentEventTypes.freezeApplied:
      return const Color(0xFFE9A400);
    case AppointmentEventTypes.freezeLifted:
      return const Color(0xFF1E8E5A);
    case AppointmentEventTypes.doctorLate:
      return const Color(0xFFD64545);
    case AppointmentEventTypes.patientLate:
      return const Color(0xFFC2410C);
    case AppointmentEventTypes.graceEnding:
      return const Color(0xFFE9A400);
    case AppointmentEventTypes.noShow:
      return const Color(0xFFB45309);
    case AppointmentEventTypes.completed:
      return const Color(0xFF062B72);
    case AppointmentEventTypes.expired:
      return const Color(0xFF6B7A90);
    default:
      return const Color(0xFF3D6DB5);
  }
}

/// Human time for a timeline entry: "10:42 AM" today, "12 Oct, 10:42 AM"
/// otherwise — compact enough for a row, precise enough for an audit.
String appointmentEventTime(DateTime? at) {
  if (at == null) return 'Just now';
  final now = DateTime.now();
  final local = at.toLocal();
  final time =
      '${local.hour % 12 == 0 ? 12 : local.hour % 12}:'
      '${local.minute.toString().padLeft(2, '0')} '
      '${local.hour < 12 ? 'AM' : 'PM'}';
  if (local.year == now.year &&
      local.month == now.month &&
      local.day == now.day) {
    return time;
  }
  const months = <String>[
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${local.day} ${months[local.month - 1]}, $time';
}

/// One row of the audit timeline: coloured icon, label, optional detail and
/// the wall-clock time of the entry.
class AppointmentTimelineRow extends StatelessWidget {
  const AppointmentTimelineRow({super.key, required this.event});

  final AppointmentEvent event;

  @override
  Widget build(BuildContext context) {
    final color = appointmentEventColor(event.type);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.10),
              shape: BoxShape.circle,
            ),
            child: Icon(
              appointmentEventIcon(event.type),
              size: 16,
              color: color,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  appointmentEventLabel(event.type),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF1F2F44),
                  ),
                ),
                if (event.detail.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    event.detail,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: const Color(0xFF657991),
                      height: 1.35,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            appointmentEventTime(event.at),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: const Color(0xFF7E90A6),
            ),
          ),
        ],
      ),
    );
  }
}

/// The whole audit timeline of one appointment — newest first, with the
/// loading / empty / error states baked in so the patient detail screen and
/// the admin review cannot drift.
class AppointmentTimeline extends ConsumerWidget {
  const AppointmentTimeline({super.key, required this.appointmentId});

  final String appointmentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final eventsAsync = ref.watch(appointmentEventsProvider(appointmentId));

    return eventsAsync.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 18),
        child: OpdInlineLoader(label: 'Loading history...'),
      ),
      error: (_, __) => const OpdEmptyState(
        icon: Icons.wifi_off_rounded,
        title: 'Could not load the history',
        subtitle: 'Check your connection and try again.',
      ),
      data: (events) {
        if (events.isEmpty) {
          return const OpdEmptyState(
            icon: Icons.history_rounded,
            title: 'No history yet',
            subtitle: 'Every change to this appointment is recorded here.',
          );
        }
        return OpdCard(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Column(
            children: [
              for (var i = 0; i < events.length; i++) ...[
                if (i > 0) const Divider(height: 1, color: Color(0xFFEDF2F8)),
                AppointmentTimelineRow(event: events[i]),
              ],
            ],
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────
// ACTION VISIBILITY — one rule per button, shared by the patient card, the
// doctor row, the detail screen and the chat banner so they can never offer
// a Join in one place and hide it in another.
// ─────────────────────────────────────────────────────────────

/// Whether the Join button should be offered to this side right now.
///
/// True only inside (or after) the scheduled slot while the appointment is
/// running and this side has not arrived yet — a slot still hours away has
/// nothing to join, and a side that already joined has no reason to see it.
bool showAppointmentJoinAction(
  AppointmentModel appointment, {
  required bool asDoctor,
}) {
  if (!appointment.isConfirmed) return false;
  if (!appointment.hasSchedule) return false;

  final start = appointment.startAt;
  if (start == null || start.isAfter(DateTime.now())) return false;

  final end = appointment.endAt;
  if (end != null && !end.isAfter(DateTime.now())) return false;

  return asDoctor
      ? !appointment.hasDoctorJoined
      : !appointment.hasPatientJoined;
}

/// Whether this side may cancel right now. Mirrors the policy half of
/// `evaluateCancellation`: an open appointment, except a doctor declining an
/// unscheduled request (that is a Reject, not a cancellation).
bool showAppointmentCancelAction(
  AppointmentModel appointment, {
  required bool asDoctor,
}) {
  if (!AppointmentStatus.isOpen(appointment.appointmentStatus)) return false;
  if (asDoctor &&
      appointment.appointmentStatus == AppointmentStatus.requested) {
    return false;
  }
  return true;
}

// ─────────────────────────────────────────────────────────────
// CANCELLATION DIALOG — policy text the patient/doctor reads *before* they
// confirm, plus an optional reason that lands in the audit trail.
// ─────────────────────────────────────────────────────────────

/// Asks the user to confirm a cancellation, showing the refund policy and the
/// warning limit up front. Returns the confirmed flag and the typed reason.
Future<({bool confirmed, String reason})> showAppointmentCancelDialog(
  BuildContext context, {
  required AppointmentConfig config,
  required int warningCount,
}) async {
  final reasonController = TextEditingController();
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: Text(
        'Cancel appointment?',
        style: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.bold,
          color: const Color(0xFF1F2F44),
        ),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              config.refundPolicyLabel,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: const Color(0xFF657991),
                height: 1.45,
              ),
            ),
            if (config.cancellationWarningLimit > 0 &&
                warningCount < config.cancellationWarningLimit) ...[
              const SizedBox(height: 10),
              Text(
                'You have cancelled $warningCount of '
                '${config.cancellationWarningLimit} appointments. '
                'After that limit, new bookings are paused until an admin '
                'lifts the pause.',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: const Color(0xFFB45309),
                  height: 1.45,
                ),
              ),
            ],
            const SizedBox(height: 14),
            CustomTextField(
              controller: reasonController,
              prefixIcon: Icons.chat_bubble_outline_rounded,
              hintText: 'Reason (optional)',
              fontSize: 13,
            ),
          ],
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text(
            'Keep it',
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: const Color(0xFF657991),
            ),
          ),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFFD64545),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: Text(
            'Cancel appointment',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
  final reason = reasonController.text.trim();
  reasonController.dispose();
  return (confirmed: confirmed ?? false, reason: reason);
}
