import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:telemedicine/admin_portal/admin_bottom_nav/admin_appointments_screen.dart';
import 'package:telemedicine/admin_portal/admin_chat_management_screen.dart';
import 'package:telemedicine/admin_portal/admin_reports_screen.dart';
import 'package:telemedicine/admin_portal/admin_ui.dart';
import 'package:telemedicine/admin_portal/create_doctor_id_by_admin/create_doctor_id.dart';
import 'package:telemedicine/admin_portal/doctor_videos/admin_doctor_videos_screen.dart';
import 'package:telemedicine/admin_portal/notification/admin_reactivation_screen.dart';
import 'package:telemedicine/admin_portal/notification/payment_approve_noti.dart';
import 'package:telemedicine/admin_portal/notifications/admin_notifications_screen.dart';
import 'package:telemedicine/admin_portal/patient_id_management/patient_id_management_screen.dart';
import 'package:telemedicine/features/complaint/payment_complaint_service.dart';
import 'package:telemedicine/auth/auth_provider/user_provider.dart';
import 'package:telemedicine/auth/auth_screen/sign_in_screen.dart';
import 'package:telemedicine/auth/user_controller/doctor_controller.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/core/services/doctor_presence_service.dart';
import 'package:telemedicine/core/services/soft_delete_service.dart';
import 'package:telemedicine/core/utils/firestore_time.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/data/models/appointment_model.dart';
import 'package:telemedicine/data/models/user_model.dart';
import 'package:telemedicine/features/appointment/appointment_controller.dart';
import 'package:telemedicine/features/appointment/appointment_ui.dart';
import 'package:telemedicine/features/doctor_video/doctor_video_controller.dart';
import 'package:telemedicine/core/providers/badge_providers.dart';
import 'package:telemedicine/shared/widgets/badge_indicator.dart';

class AdminPortalScreen extends ConsumerStatefulWidget {
  const AdminPortalScreen({super.key});

  @override
  ConsumerState<AdminPortalScreen> createState() => _AdminPortalScreenState();
}

class _AdminPortalScreenState extends ConsumerState<AdminPortalScreen> {
  static final DateTime _epoch = DateTime.fromMillisecondsSinceEpoch(0);

  List<Map<String, dynamic>> _doctors = const [];
  List<Map<String, dynamic>> _patients = const [];
  List<Map<String, dynamic>> _reactivations = const [];
  List<UserModel> _pendingAccountPayments = const [];
  List<DoctorVideoModel> _videos = const [];

  bool _doctorsLoaded = false;
  bool _patientsLoaded = false;
  String? _fatalError;

  StreamSubscription<List<Map<String, dynamic>>>? _doctorsSub;
  StreamSubscription<List<Map<String, dynamic>>>? _patientsSub;
  StreamSubscription<List<Map<String, dynamic>>>? _reactivationsSub;
  StreamSubscription<List<UserModel>>? _accountPaymentsSub;
  StreamSubscription<List<DoctorVideoModel>>? _videosSub;

  @override
  void initState() {
    super.initState();
    // Defer subscription until after first frame so providers are ready.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _subscribe();
    });
  }

  @override
  void dispose() {
    _doctorsSub?.cancel();
    _patientsSub?.cancel();
    _reactivationsSub?.cancel();
    _accountPaymentsSub?.cancel();
    _videosSub?.cancel();
    super.dispose();
  }

  void _subscribe() {
    _doctorsSub?.cancel();
    _patientsSub?.cancel();
    _reactivationsSub?.cancel();
    _accountPaymentsSub?.cancel();
    _videosSub?.cancel();

    // --- Doctors stream ---
    try {
      _doctorsSub = ref
          .read(doctorControllerProvider)
          .streamAllDoctorsWithStatus()
          .listen(
            (doctors) {
              if (!mounted) return;
              setState(() {
                _doctors = doctors;
                _doctorsLoaded = true;
                _fatalError = null;
              });
            },
            onError: (Object e) {
              debugPrint('AdminPortal doctors stream error: $e');
              if (!mounted) return;
              setState(() {
                _doctorsLoaded = true; // mark loaded so UI does not hang
                _fatalError ??= 'Unable to load doctors data';
              });
            },
          );
    } catch (e) {
      debugPrint('AdminPortal doctors stream threw: $e');
      _doctorsLoaded = true;
      _fatalError ??= 'Unable to start doctors stream';
    }

    // --- Patients stream ---
    try {
      _patientsSub = ref
          .read(patientControllerProvider)
          .streamAllPatientsWithStatus()
          .listen(
            (patients) {
              if (!mounted) return;
              setState(() {
                _patients = patients;
                _patientsLoaded = true;
                _fatalError = null;
              });
            },
            onError: (Object e) {
              debugPrint('AdminPortal patients stream error: $e');
              if (!mounted) return;
              setState(() {
                _patientsLoaded = true; // mark loaded so UI does not hang
                _fatalError ??= 'Unable to load patients data';
              });
            },
          );
    } catch (e) {
      debugPrint('AdminPortal patients stream threw: $e');
      _patientsLoaded = true;
      _fatalError ??= 'Unable to start patients stream';
    }

    // --- Reactivations stream (non-blocking) ---
    try {
      _reactivationsSub = ref
          .read(patientControllerProvider)
          .getReactivationRequests()
          .listen(
            (requests) {
              if (!mounted) return;
              setState(() => _reactivations = requests);
            },
            onError: (Object e) {
              debugPrint('AdminPortal reactivations stream error: $e');
            },
          );
    } catch (e) {
      debugPrint('AdminPortal reactivations stream threw: $e');
    }

    // --- Account payments stream (non-blocking) ---
    try {
      _accountPaymentsSub = ref
          .read(patientControllerProvider)
          .getFilteredPaymentRequests(PaymentStatus.pending)
          .listen(
            (payments) {
              if (!mounted) return;
              setState(() => _pendingAccountPayments = payments);
            },
            onError: (Object e) {
              debugPrint('AdminPortal account payments stream error: $e');
            },
          );
    } catch (e) {
      debugPrint('AdminPortal account payments stream threw: $e');
    }

    // --- Videos stream (non-blocking) ---
    try {
      _videosSub = ref
          .read(doctorVideoControllerProvider)
          .watchAllVideos()
          .listen(
            (videos) {
              if (!mounted) return;
              setState(() => _videos = videos);
            },
            onError: (Object e) {
              debugPrint('AdminPortal videos stream error: $e');
            },
          );
    } catch (e) {
      debugPrint('AdminPortal videos stream threw: $e');
    }

    // Safety fallback: if nothing emits within 8 seconds, force show UI.
    Future.delayed(const Duration(seconds: 8), () {
      if (!mounted) return;
      if (!_doctorsLoaded || !_patientsLoaded) {
        setState(() {
          _doctorsLoaded = true;
          _patientsLoaded = true;
          _fatalError ??= 'Dashboard is taking too long to load.';
        });
      }
    });
  }

  void _retry() {
    setState(() {
      _fatalError = null;
      _doctorsLoaded = false;
      _patientsLoaded = false;
    });
    _subscribe();
  }

  bool _isSuspendedDoctor(Map<String, dynamic> doctor) {
    final status = (doctor['accountStatus'] ?? 'Active').toString();
    return status != 'Active' || SoftDeleteService.isDeleted(doctor);
  }

  String _timeAgo(DateTime? time) {
    if (time == null) return 'Recently';
    final diff = DateTime.now().difference(time);
    if (diff.isNegative) return 'Just now';
    if (diff.inDays >= 7) return DateFormat('MMM d, y').format(time);
    if (diff.inDays > 0) return '${diff.inDays}d ago';
    if (diff.inHours > 0) return '${diff.inHours}h ago';
    if (diff.inMinutes > 0) return '${diff.inMinutes}m ago';
    return 'Just now';
  }

  String _doctorLabel(String doctorId) {
    for (final doctor in _doctors) {
      if ((doctor['id'] ?? '').toString() == doctorId) {
        return 'Dr. ${(doctor['fullname'] ?? 'Doctor').toString()}';
      }
    }
    return 'Doctor video';
  }

  void _push(Widget screen, String message) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
    ToastService.instance.showInfo(message);
  }

  void _openPayments() =>
      _push(const AdminPaymentScreen(), 'Opening payment requests');

  void _openNotifications() =>
      _push(const AdminNotificationsScreen(), 'Opening notifications & complaints');

  Future<void> _logout() async {
    final shouldLogout = await showAdminConfirmDialog(
      context: context,
      title: 'Logout',
      content: 'Are you sure you want to logout?',
      confirmLabel: 'Logout',
      confirmColor: AdminPalette.error,
    );

    if (shouldLogout != true) return;
    if (!mounted) return;

    ToastService.instance.showInfo('Logging out...');
    final controller = ref.read(patientControllerProvider);
    await controller.signOut();

    if (!mounted) return;
    ToastService.instance.showSuccess('Logged out successfully');
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (context) => SignInScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final appointments =
        ref.watch(allAppointmentsProvider).valueOrNull ??
        const <AppointmentModel>[];
    final appointmentPayments =
        ref.watch(appointmentPaymentsProvider).valueOrNull ??
        const <AppointmentPaymentModel>[];

    final isLoading = !_doctorsLoaded || !_patientsLoaded;
    final livePendingPayments = ref.watch(adminPendingPaymentsCountProvider);
    final unreadNotifications =
        ref.watch(adminUnreadNotificationsCountProvider).valueOrNull ?? 0;

    return AdminScreen(
      title: 'Admin Dashboard',
      subtitle: 'System Overview & Management',
      actions: [
        AdminHeaderAction(
          icon: Icons.notifications_rounded,
          tooltip: 'Notifications & Complaints',
          badgeCount: unreadNotifications,
          onPressed: _openNotifications,
        ),
        const SizedBox(width: 6),
        AdminHeaderAction(
          icon: Icons.payment_rounded,
          tooltip: 'Check Payments',
          badgeCount: livePendingPayments,
          onPressed: _openPayments,
        ),
        const SizedBox(width: 6),
        AdminHeaderAction(
          icon: Icons.logout_rounded,
          tooltip: 'Logout',
          onPressed: _logout,
        ),
      ],
      body: isLoading
          ? const AdminLoading(label: 'Loading dashboard...')
          : _buildBody(context, appointments, appointmentPayments),
    );
  }

  Widget _buildBody(
    BuildContext context,
    List<AppointmentModel> appointments,
    List<AppointmentPaymentModel> appointmentPayments,
  ) {
    final now = DateTime.now();
    final today = DateFormat('yyyy-MM-dd').format(now);

    final pendingAppointmentPayments = appointmentPayments
        .where((p) => p.isPending)
        .toList();
    final pendingPaymentCount =
        pendingAppointmentPayments.length + _pendingAccountPayments.length;

    final activeAppointments = appointments
        .where((a) => AppointmentStatus.isOpen(a.appointmentStatus))
        .length;
    final todaysAppointments = appointments
        .where((a) => a.scheduledDate == today)
        .length;
    final pendingReactivations = _reactivations
        .where((r) => (r['status'] ?? '').toString() == 'pending')
        .length;
    final activeVideos = _videos.where((v) => v.isActive).length;

    final presenceMap = ref.watch(doctorPresenceProvider);
    final totalDoctors = _doctors.length;
    final suspendedDoctors = _doctors.where(_isSuspendedDoctor).length;
    final onlineDoctors = _doctors
        .where((d) {
          final id = (d['id'] ?? '').toString();
          final isOnline = presenceMap[id]?.isOnline ?? (d['isOnline'] == true);
          return isOnline && !_isSuspendedDoctor(d);
        })
        .length;
    final rawOffline = totalDoctors - onlineDoctors - suspendedDoctors;
    final offlineDoctors = rawOffline < 0 ? 0 : rawOffline;

    final sortedAppointments = [...appointments]..sort(
        (a, b) => (b.createdAt ?? _epoch).compareTo(a.createdAt ?? _epoch),
      );
    final recentAppointments = sortedAppointments.take(4).toList();
    final pendingRows = _buildPendingRows(pendingAppointmentPayments);
    final activity = _buildActivity(
      appointments,
      appointmentPayments,
    ).take(6).toList();

    final activeDoctors = _doctors
        .where((d) => !_isSuspendedDoctor(d))
        .toList();
    final chatDoctors = sortDoctorsByPresence<Map<String, dynamic>>(
      activeDoctors,
      presenceForDoctorList(_doctors, ref.watch(doctorPresenceProvider)),
      (d) => (d['id'] ?? '').toString(),
    ).take(4).toList();

    return ListView(
      physics: const BouncingScrollPhysics(),
      padding: EdgeInsets.fromLTRB(context.rsp(16), 18, context.rsp(16), 28),
      children: [
        if (_fatalError != null) ...[
          AdminCard(
            child: Row(
              children: [
                const Icon(Icons.warning_amber_rounded,
                    color: AdminPalette.warning),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _fatalError!,
                    style: AdminTextStyles.body(size: context.fs(12)),
                  ),
                ),
                TextButton(
                  onPressed: _retry,
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        _sectionHeader(context, Icons.insights_rounded, 'Dashboard Overview'),
        const SizedBox(height: 12),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _statTile(
                  icon: Icons.medical_services_outlined,
                  color: AdminPalette.brand,
                  label: 'Total Doctors',
                  value: '$totalDoctors',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _statTile(
                  icon: Icons.people_outline_rounded,
                  color: AdminPalette.brand,
                  label: 'Total Patients',
                  value: '${_patients.length}',
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _statTile(
                  icon: Icons.event_available_rounded,
                  color: AdminPalette.brand,
                  label: 'Active Appointments',
                  value: '$activeAppointments',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _statTile(
                  icon: Icons.pending_actions_rounded,
                  color: AdminPalette.warning,
                  label: 'Pending Payments',
                  value: '$pendingPaymentCount',
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _statTile(
                  icon: Icons.wifi_rounded,
                  color: AdminPalette.success,
                  label: 'Online Doctors',
                  value: '$onlineDoctors',
                  caption: 'Connected now',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _statTile(
                  icon: Icons.replay_circle_filled_rounded,
                  color: AdminPalette.warning,
                  label: 'Pending Reactivations',
                  value: '$pendingReactivations',
                  caption: 'Awaiting review',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _statTile(
                  icon: Icons.today_rounded,
                  color: AdminPalette.brand,
                  label: "Today's Appointments",
                  value: '$todaysAppointments',
                  caption: DateFormat('MMM d').format(now),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 18),
        _sectionHeader(context, Icons.bolt_rounded, 'Quick Actions'),
        const SizedBox(height: 12),
        _buildActionGrid(
          context,
          pendingPayments: pendingPaymentCount,
          pendingAppointments: activeAppointments,
          pendingReactivations: pendingReactivations,
        ),

        const SizedBox(height: 18),
        _sectionHeader(
          context,
          Icons.event_note_rounded,
          'Recent Appointments',
          onAction: () =>
              _push(const AdminAppointmentsScreen(), 'Opening appointments'),
        ),
        const SizedBox(height: 12),
        if (recentAppointments.isEmpty)
          _emptyCard(context, 'No appointments yet.')
        else
          ..._spaced(
            recentAppointments.map((a) => _appointmentTile(context, a)).toList(),
            10,
          ),

        const SizedBox(height: 18),
        _sectionHeader(
          context,
          Icons.payments_rounded,
          'Pending Payments',
          onAction: _openPayments,
        ),
        const SizedBox(height: 12),
        if (pendingRows.isEmpty)
          _emptyCard(context, 'No pending payments. Everything is reviewed.')
        else
          ..._spaced(
            pendingRows.map((r) => _pendingPaymentTile(context, r)).toList(),
            10,
          ),

        const SizedBox(height: 18),
        _sectionHeader(context, Icons.medical_services_outlined, 'Doctor Status'),
        const SizedBox(height: 12),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _statTile(
                  icon: Icons.circle,
                  color: AdminPalette.success,
                  label: 'Online',
                  value: '$onlineDoctors',
                  caption: 'Available now',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _statTile(
                  icon: Icons.circle_outlined,
                  color: AdminPalette.textMuted,
                  label: 'Offline',
                  value: '$offlineDoctors',
                  caption: 'Not connected',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _statTile(
                  icon: Icons.block_rounded,
                  color: AdminPalette.warning,
                  label: 'Suspended',
                  value: '$suspendedDoctors',
                  caption: 'Blocked or deleted',
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerRight,
          child: Text(
            '$activeVideos video${activeVideos == 1 ? '' : 's'} assigned',
            style: AdminTextStyles.small(size: context.fs(11)),
          ),
        ),

        const SizedBox(height: 18),
        _sectionHeader(context, Icons.timeline_rounded, 'Recent Activity'),
        const SizedBox(height: 12),
        if (activity.isEmpty)
          _emptyCard(context, 'No recent activity yet.')
        else
          ..._spaced(activity.map((i) => _activityTile(context, i)).toList(), 10),

        const SizedBox(height: 18),
        _sectionHeader(
          context,
          Icons.chat_bubble_outline_rounded,
          'Recent Chats',
          onAction: () => _push(
            const AdminChatManagementScreen(),
            'Opening doctor chats',
          ),
        ),
        const SizedBox(height: 12),
        if (chatDoctors.isEmpty)
          _emptyCard(
            context,
            'No doctors yet. Create a doctor ID to get started.',
          )
        else
          ..._spaced(
            chatDoctors.map((d) => _chatDoctorTile(context, d)).toList(),
            10,
          ),
      ],
    );
  }

  List<_PendingPaymentRow> _buildPendingRows(
    List<AppointmentPaymentModel> appointmentPending,
  ) {
    final rows = <_PendingPaymentRow>[
      ...appointmentPending.map(
        (p) => _PendingPaymentRow(
          name: p.patientName,
          detail: 'Appointment • Dr. ${p.doctorName}',
          amount: appointmentAmount(p.payableAmount),
          time: p.submittedAt ?? p.updatedAt,
        ),
      ),
      ..._pendingAccountPayments.map(
        (u) => _PendingPaymentRow(
          name: u.fullname,
          detail: 'Account payment',
          amount: appointmentAmount(u.totalPayment),
          time: u.paymentSubmittedAt,
        ),
      ),
    ];
    rows.sort((a, b) => (b.time ?? _epoch).compareTo(a.time ?? _epoch));
    return rows.take(3).toList();
  }

  List<_ActivityItem> _buildActivity(
    List<AppointmentModel> appointments,
    List<AppointmentPaymentModel> payments,
  ) {
    final items = <_ActivityItem>[];

    for (final a in appointments) {
      if (a.createdAt == null) continue;
      items.add(
        _ActivityItem(
          icon: Icons.event_note_rounded,
          color: AdminPalette.brand,
          title: 'New appointment',
          detail: '${a.patientName} with Dr. ${a.doctorName}',
          time: a.createdAt,
        ),
      );
    }

    for (final p in payments) {
      if (p.isPending || p.reviewedAt == null) continue;
      items.add(
        _ActivityItem(
          icon: p.isApproved
              ? Icons.check_circle_outline_rounded
              : Icons.cancel_outlined,
          color: p.isApproved ? AdminPalette.success : AdminPalette.error,
          title: p.isApproved ? 'Payment approved' : 'Payment rejected',
          detail: '${p.patientName} • ${appointmentAmount(p.payableAmount)}',
          time: p.reviewedAt,
        ),
      );
    }

    for (final r in _reactivations) {
      final status = (r['status'] ?? '').toString();
      if (status != 'approved' && status != 'rejected') continue;
      final reviewedAt = parseFirestoreTimestamp(r['reviewedAt']);
      if (reviewedAt == null) continue;
      items.add(
        _ActivityItem(
          icon: status == 'approved'
              ? Icons.replay_circle_filled_rounded
              : Icons.cancel_outlined,
          color: status == 'approved'
              ? AdminPalette.success
              : AdminPalette.error,
          title: status == 'approved'
              ? 'Reactivation approved'
              : 'Reactivation rejected',
          detail: (r['patientName'] ?? 'Patient').toString(),
          time: reviewedAt,
        ),
      );
    }

    for (final d in _doctors) {
      final createdAt = parseFirestoreTimestamp(d['createdAt']);
      if (createdAt == null) continue;
      final name = (d['fullname'] ?? 'Doctor').toString();
      final idNumber = (d['doctorId'] ?? '').toString();
      items.add(
        _ActivityItem(
          icon: Icons.person_add_alt_1_rounded,
          color: AdminPalette.brand,
          title: 'New doctor created',
          detail: idNumber.isEmpty ? 'Dr. $name' : 'Dr. $name • ID $idNumber',
          time: createdAt,
        ),
      );
    }

    for (final v in _videos) {
      if (!v.isActive) continue;
      final at = v.updatedAt ?? v.createdAt;
      if (at == null) continue;
      items.add(
        _ActivityItem(
          icon: Icons.video_library_rounded,
          color: AdminPalette.brand,
          title: 'Doctor video assigned',
          detail: _doctorLabel(v.doctorId),
          time: at,
        ),
      );
    }

    items.sort((a, b) => (b.time ?? _epoch).compareTo(a.time ?? _epoch));
    return items;
  }

  List<Widget> _spaced(List<Widget> children, double gap) {
    final out = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) out.add(SizedBox(height: gap));
      out.add(children[i]);
    }
    return out;
  }

  Widget _sectionHeader(
    BuildContext context,
    IconData icon,
    String title, {
    VoidCallback? onAction,
  }) {
    return Row(
      children: [
        Icon(icon, color: AdminPalette.brand, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AdminTextStyles.title(size: context.fs(15.5)),
          ),
        ),
        if (onAction != null) ...[
          const SizedBox(width: 8),
          GestureDetector(
            onTap: onAction,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
              child: Text(
                'View All',
                style: AdminTextStyles.heading(
                  size: context.fs(12.5),
                  color: AdminPalette.brand,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _statTile({
    required IconData icon,
    required Color color,
    required String label,
    required String value,
    String? caption,
  }) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.rsp(14),
        vertical: context.rsp(14),
      ),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(icon, color: color, size: 18),
          ),
          const SizedBox(height: 10),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AdminTextStyles.title(
              size: context.fs(20),
              color: AdminPalette.textPrimary,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AdminTextStyles.body(size: context.fs(11.5)),
          ),
          if (caption != null) ...[
            const SizedBox(height: 2),
            Text(
              caption,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AdminTextStyles.small(size: context.fs(10.5), color: color),
            ),
          ],
        ],
      ),
    );
  }

  BoxDecoration _cardDecoration() {
    return BoxDecoration(
      gradient: AdminPalette.cardGradient,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: AdminPalette.cardBorder),
      boxShadow: [
        BoxShadow(
          color: AdminPalette.cardShadow.withValues(alpha: 0.10),
          blurRadius: 16,
          offset: const Offset(0, 6),
        ),
      ],
    );
  }

  Widget _emptyCard(BuildContext context, String message) {
    return AdminCard(
      child: Text(
        message,
        textAlign: TextAlign.center,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: AdminTextStyles.body(size: context.fs(12.5)),
      ),
    );
  }

  Widget _buildActionGrid(
    BuildContext context, {
    int pendingPayments = 0,
    int pendingAppointments = 0,
    int pendingReactivations = 0,
  }) {
    final actions = <(String, IconData, VoidCallback, int)>[
      (
        'Doctors',
        Icons.medical_services_outlined,
        () => _push(
          const AdminChatManagementScreen(),
          'Opening doctor chats',
        ),
        0,
      ),
      (
        'Create Doctor ID',
        Icons.person_add_alt_1_rounded,
        () => _push(CreateDcotorId(), 'Opening doctor creation form'),
        0,
      ),
      (
        'Patient IDs',
        Icons.badge_rounded,
        () => _push(
          const PatientIdManagementScreen(),
          'Opening Patient ID management',
        ),
        0,
      ),
      (
        'Appointments',
        Icons.event_note_rounded,
        () => _push(
          const AdminAppointmentsScreen(),
          'Opening appointments',
        ),
        pendingAppointments,
      ),
      (
        'Payments',
        Icons.payment_rounded,
        () => _push(const AdminPaymentScreen(), 'Opening payment requests'),
        pendingPayments,
      ),
      (
        'Doctor Videos',
        Icons.video_library_rounded,
        () => _push(
          const AdminDoctorVideosScreen(),
          'Opening doctor videos',
        ),
        0,
      ),
      (
        'Reactivation',
        Icons.replay_circle_filled_rounded,
        () => _push(
          const AdminReactivationScreen(),
          'Opening reactivation requests',
        ),
        pendingReactivations,
      ),
      (
        'Reports',
        Icons.assessment_rounded,
        () => _push(const AdminReportsScreen(), 'Opening reports'),
        0,
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final itemWidth = (constraints.maxWidth - 12) / 2;
        final rows = <Widget>[];
        for (var i = 0; i < actions.length; i += 2) {
          if (rows.isNotEmpty) rows.add(const SizedBox(height: 12));
          rows.add(
            Row(
              children: [
                _buildActionTile(actions[i], itemWidth),
                const SizedBox(width: 12),
                if (i + 1 < actions.length)
                  _buildActionTile(actions[i + 1], itemWidth),
              ],
            ),
          );
        }
        return Column(children: rows);
      },
    );
  }

  Widget _buildActionTile(
    (String, IconData, VoidCallback, int) action,
    double width,
  ) {
    return GestureDetector(
      onTap: action.$3,
      child: Container(
        width: width,
        padding: EdgeInsets.symmetric(
          horizontal: context.rsp(14),
          vertical: context.rsp(14),
        ),
        decoration: _cardDecoration(),
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
                count: action.$4,
                offset: const Offset(-2, -2),
                child: Icon(action.$2, color: AdminPalette.brand, size: 20),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                action.$1,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AdminTextStyles.heading(size: context.fs(12.5)),
              ),
            ),
            if (action.$4 > 0) ...[
              const SizedBox(width: 4),
              BadgeIndicator(count: action.$4),
            ],
          ],
        ),
      ),
    );
  }

  Widget _appointmentTile(BuildContext context, AppointmentModel a) {
    final schedule = a.scheduledDate.isEmpty
        ? 'Not scheduled'
        : a.scheduledStartTime.isEmpty
        ? a.scheduledDate
        : '${a.scheduledDate} • ${a.scheduledStartTime}';

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
                  style: AdminTextStyles.heading(size: context.fs(13.5)),
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
            label: 'Schedule',
            value: schedule,
          ),
          AdminInfoRow(
            icon: Icons.payments_rounded,
            label: 'Amount',
            value: appointmentAmount(a.payableAmount),
          ),
        ],
      ),
    );
  }

  Widget _pendingPaymentTile(BuildContext context, _PendingPaymentRow row) {
    return AdminCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: AdminPalette.warning.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.pending_actions_rounded,
              color: AdminPalette.warning,
              size: 18,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AdminTextStyles.heading(size: context.fs(13)),
                ),
                const SizedBox(height: 2),
                Text(
                  row.detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AdminTextStyles.small(size: context.fs(11)),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                row.amount,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AdminTextStyles.heading(
                  size: context.fs(12.5),
                  color: AdminPalette.brand,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                _timeAgo(row.time),
                style: AdminTextStyles.small(size: context.fs(10.5)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _activityTile(BuildContext context, _ActivityItem item) {
    return AdminCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: item.color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(item.icon, color: item.color, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AdminTextStyles.heading(size: context.fs(12.5)),
                ),
                const SizedBox(height: 2),
                Text(
                  '${item.detail} • ${_timeAgo(item.time)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AdminTextStyles.small(size: context.fs(11)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _chatDoctorTile(BuildContext context, Map<String, dynamic> doctor) {
    final docId = (doctor['id'] ?? '').toString();
    final name = (doctor['fullname'] ?? 'Doctor').toString();
    final degree = (doctor['highestDegree'] ?? 'General Physician').toString();
    final idNumber = (doctor['doctorId'] ?? 'N/A').toString();
    final imageUrl = (doctor['imageUrl'] ?? '').toString();
    final isOnline = ref.watch(doctorOnlineProvider(docId));

    return GestureDetector(
      onTap: () => _push(
        AdminChatManagementScreen(initialDoctorId: docId),
        'Viewing $name\'s patient chats',
      ),
      child: AdminCard(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: AdminPalette.brand.withValues(alpha: 0.1),
              backgroundImage: imageUrl.isNotEmpty
                  ? NetworkImage(imageUrl)
                  : null,
              child: imageUrl.isEmpty
                  ? const Icon(
                      Icons.person,
                      color: AdminPalette.brand,
                      size: 18,
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
                    style: AdminTextStyles.heading(size: context.fs(13)),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'ID: $idNumber • $degree',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AdminTextStyles.small(size: context.fs(11)),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _onlineChip(context, isOnline),
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

  Widget _onlineChip(BuildContext context, bool isOnline) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: isOnline
            ? AdminPalette.success.withValues(alpha: 0.12)
            : AdminPalette.unselectedText.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isOnline
              ? AdminPalette.success.withValues(alpha: 0.3)
              : AdminPalette.segmentBorder,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isOnline ? AdminPalette.success : AdminPalette.textMuted,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            isOnline ? 'Online' : 'Offline',
            style: AdminTextStyles.heading(
              size: 10,
              color: isOnline ? AdminPalette.success : AdminPalette.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}

class _ActivityItem {
  const _ActivityItem({
    required this.icon,
    required this.color,
    required this.title,
    required this.detail,
    required this.time,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String detail;
  final DateTime? time;
}

class _PendingPaymentRow {
  const _PendingPaymentRow({
    required this.name,
    required this.detail,
    required this.amount,
    required this.time,
  });

  final String name;
  final String detail;
  final String amount;
  final DateTime? time;
}