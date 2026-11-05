import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/features/auth/presentation/providers/user_provider.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/data/models/appointment_model.dart';
import 'package:telemedicine/features/doctor_portal/presentation/ratings/doctor_rating_controller.dart';
import 'package:telemedicine/core/services/doctor_presence_service.dart';
import 'package:telemedicine/features/appointments/presentation/appointment_controller.dart';
import 'package:telemedicine/features/appointments/presentation/appointment_payment_screen.dart';
import 'package:telemedicine/features/appointments/presentation/appointment_status_widgets.dart';
import 'package:telemedicine/features/calling/controllers/call_controller.dart';
import 'package:telemedicine/features/calling/screens/outgoing_call_screen.dart';
import 'package:telemedicine/shared/widgets/auth_layout.dart';
import 'package:telemedicine/shared/widgets/opd_design_system.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:telemedicine/core/utils/guest_guard.dart';

/// Everything the patient sees before paying: who the doctor is, the required
/// YouTube introduction, and the exact price after the 30 % video discount.
class DoctorDetailsScreen extends ConsumerWidget {
  const DoctorDetailsScreen({super.key, required this.doctorId});

  final String doctorId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final doctorAsync = ref.watch(doctorBookingProvider(doctorId));

    return doctorAsync.when(
      loading: () => OpdScreenShell(
        title: 'Doctor',
        subtitle: 'Loading profile...',
        child: const OpdInlineLoader(label: 'Loading doctor profile...'),
      ),
      error: (_, __) => OpdScreenShell(
        title: 'Doctor',
        subtitle: 'Something went wrong',
        child: const OpdEmptyState(
          icon: Icons.wifi_off_rounded,
          title: 'Could not load this doctor',
          subtitle: 'Go back and pick another doctor, or retry shortly.',
        ),
      ),
      data: (doctor) {
        if (doctor == null) {
          return OpdScreenShell(
            title: 'Doctor',
            subtitle: 'Not available',
            child: const OpdEmptyState(
              icon: Icons.person_off_rounded,
              title: 'Doctor not found',
              subtitle: 'This profile may have been deactivated.',
            ),
          );
        }
        return _DoctorDetails(doctor: doctor);
      },
    );
  }
}

class _DoctorDetails extends ConsumerStatefulWidget {
  const _DoctorDetails({required this.doctor});

  final Map<String, dynamic> doctor;

  @override
  ConsumerState<_DoctorDetails> createState() => _DoctorDetailsState();
}

class _DoctorDetailsState extends ConsumerState<_DoctorDetails> {
  bool _marking = false;
  bool _checking = false;

  Map<String, dynamic> get doctor => widget.doctor;

  String get _name {
    final value = (doctor['fullname'] ?? '').toString().trim();
    return value.isEmpty ? 'Doctor' : value;
  }

  String get _specialization {
    final value = (doctor['specialization'] ?? '').toString().trim();
    if (value.isNotEmpty) return value;
    return (doctor['highestDegree'] ?? '').toString().trim();
  }

  String get _videoUrl => AppointmentController.youtubeUrlOf(doctor);

  bool get _hasVideo => AppointmentController.isUsableYoutubeUrl(_videoUrl);

  Future<void> _markWatched() async {
    final user = ref.read(userProvider);
    if (user == null || user.isGuest) {
      GuestGuard.showLoginPrompt(
        context,
        message: 'Please log in to unlock video discounts.',
      );
      return;
    }
    setState(() => _marking = true);
    final ok = await ref
        .read(appointmentControllerProvider)
        .markVideoWatched(
          patientId: user.id,
          doctorId: (doctor['id'] ?? '').toString(),
          patientName: user.fullname,
          doctorName: _name,
          videoAssignmentId: (doctor['id'] ?? '').toString(),
          youtubeVideoId: appointmentYoutubeVideoId(_videoUrl),
        );
    if (!mounted) return;
    setState(() => _marking = false);
    if (ok) {
      ToastService.instance.showSuccess(
        'Video marked as watched — 30% discount unlocked',
      );
    } else {
      ToastService.instance.showError('Could not save that. Please retry.');
    }
  }

  Future<void> _openVideo() async {
    final uri = Uri.tryParse(_videoUrl);
    if (uri == null) return;
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened) {
      ToastService.instance.showError('Could not open the video.');
    }
  }

  /// Gate on the way into the booking stack.
  ///
  /// The write path re-checks anyway, so this exists only to tell the patient
  /// *why* nothing is happening instead of letting them pay for a booking
  /// that cannot be created.
  Future<void> _bookAppointment() async {
    if (_checking) return;
    final user = ref.read(userProvider);
    if (user == null || user.isGuest) {
      GuestGuard.showLoginPrompt(
        context,
        message: 'Please log in to book appointments.',
      );
      return;
    }

    final isRestrictedPatient =
        user.role == 'patient' &&
        !user.isPatientIdUser &&
        user.paymentStatus != 'approved' &&
        user.paymentStatus != 'completed';

    if (isRestrictedPatient) {
      ToastService.instance.showWarning(
        'Please complete your payment verification before booking appointments.',
      );
      return;
    }

    setState(() => _checking = true);
    final block = await ref
        .read(appointmentControllerProvider)
        .bookingBlockMessageFor(
          patientId: user.id,
          doctorId: (doctor['id'] ?? '').toString(),
        );
    if (!mounted) return;
    setState(() => _checking = false);

    if (block != null) {
      ToastService.instance.showError(block);
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            AppointmentPaymentScreen(doctorId: (doctor['id'] ?? '').toString()),
      ),
    );
  }

  Future<void> _initiateVoiceCall() async {
    final user = ref.read(userProvider);
    if (user == null || user.isGuest) {
      GuestGuard.showLoginPrompt(
        context,
        message: 'Please log in to make voice calls.',
      );
      return;
    }

    if (user.isExpired) {
      ToastService.instance.showError(
        'Your account has expired. Please renew your subscription to make calls.',
      );
      return;
    }

    final isRestrictedPatient =
        user.role == 'patient' &&
        !user.isPatientIdUser &&
        user.paymentStatus != 'approved' &&
        user.paymentStatus != 'completed';

    if (isRestrictedPatient) {
      ToastService.instance.showWarning(
        'Please complete your payment verification before placing calls.',
      );
      return;
    }

    final doctorId = (doctor['id'] ?? '').toString();
    final isOnline = ref.read(doctorOnlineProvider(doctorId));
    if (!isOnline) {
      ToastService.instance.showWarning(
        'Doctor is currently offline and unavailable for calls.',
      );
      return;
    }

    ToastService.instance.showInfo('Checking doctor availability...');

    final result = await CallController.instance.initiateVoiceCall(
      callerId: user.id,
      callerName: user.fullname,
      callerRole: user.role,
      callerImage: user.image,
      receiverId: doctorId,
      receiverName: _name,
      receiverRole: 'doctor',
      receiverImage: (doctor['imageUrl'] ?? '').toString(),
    );

    if (!mounted) return;

    if (result['success'] == true) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => OutgoingCallScreen(
            callId: result['callId'],
            receiverId: doctorId,
            receiverName: _name,
            receiverRole: 'doctor',
            receiverImage: (doctor['imageUrl'] ?? '').toString(),
            currentUserId: user.id,
            currentUserName: user.fullname,
          ),
        ),
      );
    } else {
      ToastService.instance.showError(
        result['error'] ?? 'Could not place call to doctor.',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final watched =
        ref
            .watch(
              appointmentVideoWatchedProvider((doctor['id'] ?? '').toString()),
            )
            .valueOrNull ??
        false;
    final pricing = AppointmentController.pricingFor(
      doctor: doctor,
      videoWatched: watched,
    );
    final image = (doctor['imageUrl'] ?? '').toString();
    // Real-time rating from the single source of truth (`doctor_ratings`),
    // with the projected fields on the doctor document as the loading
    // fallback. The legacy `rating` field is never updated after profile
    // creation, so it cannot be trusted here.
    final ratingAsync = ref.watch(
      doctorRatingSummaryProvider((doctor['id'] ?? '').toString()),
    );
    final doctorDocId = (doctor['id'] ?? '').toString();
    final isOnline = ref.watch(doctorOnlineProvider(doctorDocId));
    final rating =
        ratingAsync.valueOrNull?.average ??
        (doctor['averageRating'] ?? 0.0).toDouble();
    final totalRatings =
        ratingAsync.valueOrNull?.total ?? (doctor['totalRatings'] ?? 0).toInt();
    final hasRating = totalRatings > 0;
    final description = (doctor['description'] ?? '').toString().trim();
    // Missing on older documents — `parse` yields an empty list, which the UI
    // renders as "not declared" rather than crashing.
    final languages = DoctorLanguages.parse(
      doctor[DoctorLanguages.field] ?? doctor[DoctorLanguages.legacyField],
    );
    final videoId = appointmentYoutubeVideoId(_videoUrl);

    return OpdScreenShell(
      title: 'Dr. $_name',
      subtitle: _specialization.isEmpty ? 'General Physician' : _specialization,
      bottom: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _initiateVoiceCall,
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF062B72),
                side: const BorderSide(color: Color(0xFF062B72), width: 1.5),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(26),
                ),
              ),
              icon: const Icon(Icons.phone_in_talk_rounded, size: 18),
              label: const Text(
                'Voice Call',
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: GradientButton(
              text: _checking ? 'Checking...' : 'Appointment',
              icon: Icons.calendar_month_rounded,
              isLoading: _checking,
              onPressed: _checking ? null : _bookAppointment,
            ),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Identity ──
          OpdCard(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                CircleAvatar(
                  radius: 40,
                  backgroundColor: const Color(0xFFF0F4FA),
                  backgroundImage: image.isNotEmpty
                      ? CachedNetworkImageProvider(image)
                      : null,
                  child: image.isEmpty
                      ? Text(
                          _name.isNotEmpty ? _name[0].toUpperCase() : '?',
                          style: TextStyle(
                            fontSize: context.fs(20),
                            fontWeight: FontWeight.bold,
                            color: const Color(0xFF062B72),
                          ),
                        )
                      : null,
                ),
                const SizedBox(height: 12),
                Text(
                  'Dr. $_name',
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: context.fs(16),
                    fontWeight: FontWeight.bold,
                    color: const Color(0xFF1F2F44),
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    OpdPill(
                      icon: isOnline ? Icons.circle : Icons.circle_outlined,
                      label: isOnline ? 'Online • Ready for calls' : 'Offline',
                      color: isOnline
                          ? const Color(0xFF2E7D32)
                          : const Color(0xFF757575),
                    ),
                    OpdPill(
                      icon: Icons.medical_services_rounded,
                      label: _specialization.isEmpty
                          ? 'General Physician'
                          : _specialization,
                    ),
                    if (hasRating)
                      OpdPill(
                        icon: Icons.star_rounded,
                        label:
                            '${rating.toStringAsFixed(1)} • $totalRatings ratings',
                        color: const Color(0xFFB07A00),
                      ),
                    ...languages.map(
                      (language) => OpdPill(
                        icon: Icons.translate_rounded,
                        label: language,
                        color: const Color(0xFF062B72),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // Always rendered: a document written before `description` existed
          // shows an explicit empty state instead of silently hiding the
          // section the patient is meant to read.
          const SizedBox(height: 18),
          const OpdSectionLabel('About this doctor'),
          OpdCard(
            child: Text(
              description.isNotEmpty
                  ? description
                  : 'This doctor has not added a description yet.',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w400,
                fontStyle: description.isNotEmpty
                    ? FontStyle.normal
                    : FontStyle.italic,
                color: description.isNotEmpty
                    ? const Color(0xFF657991)
                    : const Color(0xFF7E90A6),
                height: 1.5,
              ),
            ),
          ),

          // ── Video gate ──
          const SizedBox(height: 18),
          OpdSectionLabel(
            'Doctor Introduction Video',
            trailing: watched
                ? const Icon(
                    Icons.check_circle_rounded,
                    size: 18,
                    color: Color(0xFF1E8E5A),
                  )
                : null,
          ),
          if (!watched) ...[
            const SizedBox(height: 6),
            Text(
              'Watch this video to unlock ${pricingPercentLabel()} OFF your appointment.',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                color: const Color(0xFF657991),
              ),
            ),
          ],
          if (watched) ...[
            const SizedBox(height: 8),
            OpdPill(
              icon: Icons.verified_rounded,
              label: '${pricingPercentLabel()} OFF UNLOCKED',
              color: const Color(0xFF1E8E5A),
            ),
          ],
          const SizedBox(height: 10),
          _buildVideoCard(watched: watched, videoId: videoId),

          // ── Price ──
          const SizedBox(height: 18),
          const OpdSectionLabel('Step 2 — Consultation price'),
          OpdCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Column(
              children: [
                OpdDetailRow(
                  icon: Icons.payments_rounded,
                  label: 'Price',
                  value: pricing.feeLabel,
                ),
                OpdDetailRow(
                  icon: Icons.ondemand_video_rounded,
                  label: pricing.discountTitle,
                  value: pricing.discountApplied
                      ? pricing.discountLabel
                      : 'Watch the video to unlock',
                ),
                const Divider(height: 1, color: Color(0xFFDCE6F2)),
                OpdDetailRow(
                  icon: Icons.account_balance_wallet_rounded,
                  label: 'You pay',
                  value: pricing.payableLabel,
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),
          OpdInfoPanel(
            icon: Icons.info_outline_rounded,
            title: 'How booking works',
            description:
                'Pay the consultation fee, wait for admin approval, then send '
                'your appointment request. The doctor picks the date and time.',
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildVideoCard({required bool watched, required String videoId}) {
    return OpdCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_hasVideo) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  AspectRatio(
                    aspectRatio: 16 / 9,
                    child: videoId.isEmpty
                        ? Container(color: const Color(0xFF0F2445))
                        : CachedNetworkImage(
                            imageUrl:
                                'https://img.youtube.com/vi/$videoId/hqdefault.jpg',
                            fit: BoxFit.cover,
                            placeholder: (context, url) =>
                                Container(color: const Color(0xFFF0F4FA)),
                            errorWidget: (context, url, error) =>
                                Container(color: const Color(0xFF0F2445)),
                          ),
                  ),
                  Container(
                    width: 62,
                    height: 44,
                    decoration: BoxDecoration(
                      color: const Color(0xFFD64545),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 32,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              watched
                  ? 'Video watched — your discount is unlocked.'
                  : 'Watch the full introduction video to unlock a '
                        '${pricingPercentLabel()} discount on this consultation.',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                color: watched
                    ? const Color(0xFF1E8E5A)
                    : const Color(0xFF657991),
                height: 1.4,
              ),
            ),
            const SizedBox(height: 12),
            _videoActions(watched: watched),
          ] else ...[
            OpdInfoPanel(
              icon: Icons.videocam_off_rounded,
              title: 'No introduction video',
              description:
                  'This doctor has not published an introduction video, so no '
                  'video step is required before booking.',
              accent: const Color(0xFF7E90A6),
            ),
          ],
        ],
      ),
    );
  }

  Widget _videoActions({required bool watched}) {
    final primary = GradientButton(
      text: watched ? 'Rewatch video' : 'Watch video',
      icon: Icons.play_circle_rounded,
      onPressed: _openVideo,
    );
    final secondary = watched
        ? GradientButton(
            text: 'Watched',
            icon: Icons.check_rounded,
            onPressed: null,
          )
        : GradientButton(
            text: _marking ? 'Saving...' : 'Finished',
            icon: Icons.check_rounded,
            isLoading: _marking,
            onPressed: _marking ? null : _markWatched,
          );

    final capped = context.sw > 440 ? 440.0 : context.sw;
    final fitsSideBySide = capped - 90 >= 306 * context.textScale;

    if (fitsSideBySide) {
      return Row(
        children: [
          Expanded(child: primary),
          const SizedBox(width: 10),
          Expanded(child: secondary),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [primary, const SizedBox(height: 10), secondary],
    );
  }

  String pricingPercentLabel() {
    final percent = appointmentDiscountPercentFor(doctor['discountPercentage']);
    return '${percent.toStringAsFixed(0)}%';
  }
}
