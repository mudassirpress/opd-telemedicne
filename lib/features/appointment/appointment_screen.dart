import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/admin_portal/admin_ui.dart';
import 'package:telemedicine/auth/auth_provider/user_provider.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/data/models/appointment_model.dart';
import 'package:telemedicine/features/appointment/appointment_controller.dart';
import 'package:telemedicine/features/appointment/appointment_detail_screen.dart';
import 'package:telemedicine/features/appointment/appointment_payment_screen.dart';
import 'package:telemedicine/features/appointment/appointment_ui.dart';
import 'package:telemedicine/doctor_portal/ratings/doctor_rating_controller.dart';
import 'package:telemedicine/features/appointment/doctor_details_screen.dart';
import 'package:telemedicine/home_widget/chat_call/chat/chat_screen.dart';
import 'package:telemedicine/shared/widgets/opd_design.dart';

/// Which of the two halves of the Appointments tab is showing.
enum _AppointmentView { findDoctor, myAppointments }

/// Root tab of the patient bottom navigation: pick a doctor, or look at the
/// requests already sent.
///
/// Rendered inside `PatientPortalWrapper`'s `IndexedStack`, so it has no back
/// button of its own — it is a destination, not a pushed route.
class AppointmentScreen extends ConsumerStatefulWidget {
  const AppointmentScreen({super.key});

  @override
  ConsumerState<AppointmentScreen> createState() => _AppointmentScreenState();
}

class _AppointmentScreenState extends ConsumerState<AppointmentScreen> {
  _AppointmentView _view = _AppointmentView.findDoctor;
  String _query = '';

  /// `null` = auto: show the running slot if there is one, otherwise the
  /// upcoming ones. Once the patient taps a chip, the choice sticks.
  String? _listFilter;

  @override
  void initState() {
    super.initState();
    // Close appointments whose scheduled end elapsed. Idempotent and silent,
    // so it is safe to run every time the tab is created.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final user = ref.read(userProvider);
      if (user != null && user.role != UserRoles.doctor) {
        ref.read(appointmentControllerProvider).finalizeExpiredAppointments(
              userId: user.id,
              isDoctor: false,
            );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEDF2F8),
      body: Stack(
        children: [
          Positioned(
            top: 20,
            right: 0,
            child: Opacity(
              opacity: 0.15,
              child: CustomPaint(
                size: const Size(240, 180),
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
                              color: const Color(0xFF1F2F44),
                              letterSpacing: -0.5,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Choose a doctor, watch the intro video and book '
                            'your consultation.',
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w500,
                              color: const Color(0xFF657991),
                              height: 1.4,
                            ),
                          ),
                          const SizedBox(height: 18),
                          OpdSegmentedSelector<_AppointmentView>(
                            options: [
                              (
                                value: _AppointmentView.findDoctor,
                                label: 'Find a Doctor',
                                icon: Icons.search_rounded,
                              ),
                              (
                                value: _AppointmentView.myAppointments,
                                label: 'My Appointments',
                                icon: Icons.event_note_rounded,
                              ),
                            ],
                            selected: _view,
                            onChanged: (v) => setState(() => _view = v),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: context.rsp(20)),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 440),
                        child: _view == _AppointmentView.findDoctor
                            ? _buildDoctorList()
                            : _buildMyAppointments(),
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

  // ─────────────────────────────────────────────────────────────
  // FIND A DOCTOR
  // ─────────────────────────────────────────────────────────────

  Widget _buildDoctorList() {
    final doctorsAsync = ref.watch(doctorsForBookingProvider);

    return Column(
      children: [
        MetallicInput(
          hintText: 'Search by doctor name or specialization',
          icon: Icons.search_rounded,
          onChanged: (value) => setState(() => _query = value.trim()),
        ),
        const SizedBox(height: 14),
        Expanded(
          child: doctorsAsync.when(
            loading: () => const OpdInlineLoader(label: 'Loading doctors...'),
            error: (_, __) => const OpdEmptyState(
              icon: Icons.wifi_off_rounded,
              title: 'Could not load doctors',
              subtitle: 'Check your connection and pull to try again.',
            ),
            data: (doctors) {
              final filtered = doctors.where((d) {
                if (_query.isEmpty) return true;
                final haystack =
                    '${d['fullname'] ?? ''} ${d['specialization'] ?? ''} '
                        '${d['highestDegree'] ?? ''}'
                    .toLowerCase();
                return haystack.contains(_query.toLowerCase());
              }).toList();

              if (filtered.isEmpty) {
                return const OpdEmptyState(
                  icon: Icons.person_search_rounded,
                  title: 'No doctors found',
                  subtitle: 'Try a different name or specialisation.',
                );
              }

              return ListView.separated(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.only(bottom: 8),
                itemCount: filtered.length,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (context, index) =>
                    _DoctorCard(doctor: filtered[index]),
              );
            },
          ),
        ),
      ],
    );
  }

  // ─────────────────────────────────────────────────────────────
  // MY APPOINTMENTS
  // ─────────────────────────────────────────────────────────────

  /// A running slot: either the status flipped to `active`, or the stored
  /// phase says somebody is inside. Shown first in every filter so a patient
  /// who opens the tab mid-consultation lands on the appointment itself.
  static bool _isLive(AppointmentModel appointment) {
    if (appointment.appointmentStatus == AppointmentStatus.active) return true;
    if (!appointment.isConfirmed || !appointment.hasSchedule) return false;
    return AppointmentPhase.isLive(appointmentDisplayPhase(appointment));
  }

  bool _matchesFilter(AppointmentModel appointment, String filter) {
    switch (filter) {
      case 'live':
        return AppointmentStatus.isOpen(appointment.appointmentStatus) &&
            _isLive(appointment);
      case 'upcoming':
        return AppointmentStatus.isOpen(appointment.appointmentStatus) &&
            !_isLive(appointment);
      case 'history':
        return AppointmentStatus.isTerminal(appointment.appointmentStatus);
      default:
        return true;
    }
  }

  Widget _buildMyAppointments() {
    final user = ref.watch(userProvider);
    final appointmentsAsync = ref.watch(myAppointmentsProvider);

    if (user == null || user.isGuest) {
      return const OpdEmptyState(
        icon: Icons.lock_rounded,
        title: 'Sign in to continue',
        subtitle: 'Your appointments appear here once you are signed in.',
      );
    }

    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _listChip('Live', 'live'),
              _listChip('Upcoming', 'upcoming'),
              _listChip('History', 'history'),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Expanded(
          child: appointmentsAsync.when(
            loading: () =>
                const OpdInlineLoader(label: 'Loading your appointments...'),
            error: (_, __) => const OpdEmptyState(
              icon: Icons.wifi_off_rounded,
              title: 'Could not load appointments',
              subtitle: 'Check your connection and try again.',
            ),
            data: (appointments) {
              if (appointments.isEmpty) {
                return const OpdEmptyState(
                  icon: Icons.event_busy_rounded,
                  title: 'No appointments yet',
                  subtitle:
                      'Pick a doctor, watch the intro video and send your '
                      'first appointment request.',
                );
              }

              // Auto until a chip is tapped: a running slot wins, otherwise
              // the upcoming ones.
              final hasLive = appointments.any(_isLive);
              final filter = _listFilter ?? (hasLive ? 'live' : 'upcoming');
              final filtered =
                  appointments.where((a) => _matchesFilter(a, filter)).toList()
                    ..sort((a, b) {
                      final aLive = _isLive(a);
                      final bLive = _isLive(b);
                      if (aLive != bLive) return aLive ? -1 : 1;
                      final aTime = a.startAt ??
                          a.confirmedAt ??
                          a.createdAt;
                      final bTime = b.startAt ??
                          b.confirmedAt ??
                          b.createdAt;
                      if (aTime == null && bTime == null) return 0;
                      if (aTime == null) return 1;
                      if (bTime == null) return -1;
                      return bTime.compareTo(aTime);
                    });

              if (filtered.isEmpty) {
                return OpdEmptyState(
                  icon: Icons.event_busy_rounded,
                  title: filter == 'history'
                      ? 'No past appointments'
                      : filter == 'live'
                          ? 'Nothing running right now'
                          : 'No upcoming appointments',
                  subtitle: filter == 'history'
                      ? 'Completed, expired and cancelled appointments are '
                          'kept here.'
                      : 'Booked consultations show up here as soon as a '
                          'doctor confirms them.',
                );
              }

              return ListView.separated(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.only(bottom: 8),
                itemCount: filtered.length,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (context, index) =>
                    _AppointmentCard(appointment: filtered[index]),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _listChip(String label, String value) {
    // The active filter: the tapped chip, or the one the auto rule picked.
    final hasLive =
        ref.watch(myAppointmentsProvider).valueOrNull?.any(_isLive) ?? false;
    final selected = _listFilter ?? (hasLive ? 'live' : 'upcoming');
    return AdminFilterChip(
      label: label,
      selected: selected == value,
      onTap: () => setState(() => _listFilter = value),
    );
  }
}

class _DoctorCard extends ConsumerWidget {
  final Map<String, dynamic> doctor;

  const _DoctorCard({required this.doctor});

  String get _name {
    final value = (doctor['fullname'] ?? '').toString().trim();
    return value.isEmpty ? 'Doctor' : value;
  }

  String get _specialization {
    final value = (doctor['specialization'] ?? '').toString().trim();
    if (value.isNotEmpty) return value;
    return (doctor['highestDegree'] ?? '').toString().trim();
  }

  /// The doctor's own price from their document — never a hardcoded amount.
  /// A document predating the `price` field falls back to `consultationFee`
  /// and finally to `0`, which renders as an unset price.
  double get _fee => AppointmentController.priceOf(doctor);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final image = (doctor['imageUrl'] ?? '').toString();
    final doctorId = (doctor['id'] ?? '').toString();

    // Real-time rating from the single source of truth (`doctor_ratings`),
    // matching the patient Doctor List and Doctor Grid. The doctor document's
    // legacy `rating` field is written once at profile creation and never
    // updated, so it could only ever show 0 / "no ratings"; the refreshed
    // projection fields (`averageRating` / `totalRatings`) are the fallback
    // while the live stream is still loading.
    final ratingAsync = ref.watch(doctorRatingSummaryProvider(doctorId));
    final rating =
        ratingAsync.valueOrNull?.average ?? (doctor['averageRating'] ?? 0.0).toDouble();
    final totalRatings =
        ratingAsync.valueOrNull?.total ?? (doctor['totalRatings'] ?? 0).toInt();
    final hasRating = totalRatings > 0;

    return OpdCard(
      padding: const EdgeInsets.all(14),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => DoctorDetailsScreen(doctorId: (doctor['id'] ?? '').toString()),
        ),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 26,
            backgroundColor: const Color(0xFFF0F4FA),
            backgroundImage:
                image.isNotEmpty ? CachedNetworkImageProvider(image) : null,
            child: image.isEmpty
                ? Text(
                    _name.isNotEmpty ? _name[0].toUpperCase() : '?',
                    style: TextStyle(
                      fontSize: context.fs(16),
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
                  'Dr. $_name',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: context.fs(14),
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF1F2F44),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _specialization.isEmpty
                      ? 'General Physician'
                      : _specialization,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: const Color(0xFF657991),
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (hasRating)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.star_rounded,
                            size: 15,
                            color: Color(0xFFE9A400),
                          ),
                          const SizedBox(width: 3),
                          Text(
                            '${rating.toStringAsFixed(1)} '
                            '($totalRatings)',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w500,
                              color: const Color(0xFF657991),
                            ),
                          ),
                        ],
                      ),
                    Text(
                      _fee > 0 ? appointmentAmount(_fee) : 'Price not set',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: const Color(0xFF062B72),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          const Icon(
            Icons.arrow_forward_ios_rounded,
            size: 15,
            color: Color(0xFF7E90A6),
          ),
        ],
      ),
    );
  }
}

class _AppointmentCard extends ConsumerWidget {
  final AppointmentModel appointment;

  const _AppointmentCard({required this.appointment});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final phase = appointmentDisplayPhase(appointment);
    final joinable =
        showAppointmentJoinAction(appointment, asDoctor: false);
    final showPaymentFlow =
        appointment.isApproved && appointment.isRequested;
    final isScheduled = appointment.isConfirmed &&
        appointment.hasSchedule &&
        !appointment.isCompleted;

    return OpdCard(
      padding: const EdgeInsets.all(16),
      onTap: showPaymentFlow
          ? () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => AppointmentPaymentScreen(
                    doctorId: appointment.doctorId,
                  ),
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
              Expanded(
                child: Text(
                  'Dr. ${appointment.doctorName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: context.fs(14),
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF1F2F44),
                  ),
                ),
              ),
              AppointmentStatusPill(status: appointment.appointmentStatus),
            ],
          ),
          if (phase.isNotEmpty) ...[
            const SizedBox(height: 8),
            AppointmentPhasePill(phase: phase),
          ],
          const SizedBox(height: 6),
          Text(
            appointment.subject.isEmpty
                ? 'Appointment request'
                : appointment.subject,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: const Color(0xFF657991),
            ),
          ),
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
                if (isScheduled) ...[
                  OpdDetailRow(
                    icon: Icons.event_available_rounded,
                    label: 'Scheduled',
                    value:
                        '${appointmentFormatDisplayDate(appointment.scheduledDate)} • '
                        '${appointment.scheduledStartTime} - '
                        '${appointment.scheduledEndTime}',
                  ),
                ] else if (appointment.isCompleted &&
                    appointment.hasSchedule) ...[
                  OpdDetailRow(
                    icon: Icons.history_rounded,
                    label: 'Completed',
                    value:
                        '${appointmentFormatDisplayDate(appointment.scheduledDate)} • '
                        '${appointment.scheduledStartTime} - '
                        '${appointment.scheduledEndTime}',
                  ),
                ] else if (appointment.isExpired &&
                    appointment.hasSchedule) ...[
                  OpdDetailRow(
                    icon: Icons.event_busy_rounded,
                    label: 'Expired',
                    value:
                        '${appointmentFormatDisplayDate(appointment.scheduledDate)} • '
                        '${appointment.scheduledStartTime} - '
                        '${appointment.scheduledEndTime}',
                  ),
                ] else if (appointment.isNoShow &&
                    appointment.hasSchedule) ...[
                  OpdDetailRow(
                    icon: Icons.person_off_rounded,
                    label: 'No-show',
                    value:
                        '${appointmentFormatDisplayDate(appointment.scheduledDate)} • '
                        '${appointment.scheduledStartTime} - '
                        '${appointment.scheduledEndTime}',
                  ),
                ] else ...[
                  OpdDetailRow(
                    icon: Icons.hourglass_top_rounded,
                    label: 'Status',
                    value: appointment.isRequested
                        ? 'Waiting for the doctor to pick a date and time'
                        : appointmentStatusLabel(
                            appointment.appointmentStatus,
                          ),
                  ),
                ],
                OpdDetailRow(
                  icon: Icons.payments_rounded,
                  label: 'Paid',
                  value: appointmentAmount(appointment.payableAmount),
                ),
              ],
            ),
          ),
          if (joinable) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => _join(context, ref),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF0E7C86),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                icon: const Icon(Icons.video_call_rounded, size: 18),
                label: Text(
                  'Join appointment',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
          if (showPaymentFlow) ...[
            const SizedBox(height: 10),
            Text(
              'Payment approved — tap to send your appointment request.',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
                color: const Color(0xFF1E8E5A),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _join(BuildContext context, WidgetRef ref) async {
    final user = ref.read(userProvider);
    if (user == null) return;

    final error = await ref.read(appointmentControllerProvider).markAppointmentJoined(
          appointment: appointment,
          actorId: user.id,
          asDoctor: false,
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
          otherUserId: appointment.doctorId,
          otherUserName: 'Dr. ${appointment.doctorName}',
          otherUserImage: appointment.doctorImage,
          currentUserRole: UserRoles.patient,
          otherUserType: UserRoles.doctor,
          otherUserRole: UserRoles.doctor,
        ),
      ),
    );
  }
}
