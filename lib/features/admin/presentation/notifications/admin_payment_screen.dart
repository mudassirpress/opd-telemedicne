import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:telemedicine/data/models/user_model.dart';
import 'package:telemedicine/features/auth/presentation/providers/user_provider.dart';
import 'package:telemedicine/features/admin/presentation/admin_design_system.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/data/models/appointment_model.dart';
import 'package:telemedicine/features/appointments/presentation/appointment_controller.dart';
import 'package:telemedicine/features/appointments/presentation/appointment_status_widgets.dart';

/// Which payment stream the admin review screen is showing.
///
/// `account` is the original subscription payment kept on the patient
/// document; `appointment` is the per-doctor fee in `appointment_payments`.
enum AdminPaymentSegment { account, appointment }

class AdminPaymentScreen extends ConsumerStatefulWidget {
  const AdminPaymentScreen({
    super.key,
    this.focusPatientId,
    this.focusPaymentId,
    this.initialSegment = AdminPaymentSegment.account,
  });

  /// Set when the screen is opened from a `payment_submitted` notification.
  /// The matching record is selected, scrolled to and highlighted so the admin
  /// lands directly on the proof to review.
  final String? focusPatientId;

  /// The payment submission the notification referred to. Used only for
  /// logging/traceability — the patient document is the record of truth.
  final String? focusPaymentId;

  /// Which list to open on. An `appointment_payment_submitted` notification
  /// opens the appointment segment.
  final AdminPaymentSegment initialSegment;

  /// Navigation guard. `NotificationService` checks this before pushing so the
  /// same notification cannot stack two copies of this screen, and this screen
  /// also raises it when opened from the admin portal so a later notification
  /// tap does not duplicate the route.
  static bool isAdminPaymentScreenOpen = false;

  @override
  ConsumerState<AdminPaymentScreen> createState() => _AdminPaymentScreenState();
}

class _AdminPaymentScreenState extends ConsumerState<AdminPaymentScreen> {
  String selectedFilter = 'pending';
  late AdminPaymentSegment _segment;

  final ScrollController _scrollController = ScrollController();
  final Map<String, GlobalKey> _cardKeys = {};
  bool _didAutoScroll = false;
  bool _isProcessing = false;

  // Memoised on the filter value: rebuilding (e.g. _isProcessing toggling)
  // must not open a new Firestore listener, while changing the filter chip
  // must. The previous code called getFilteredPaymentRequests(selectedFilter)
  // directly in build(), resubscribing per rebuild.
  Stream<List<UserModel>>? _accountPaymentsStream;
  String? _accountPaymentsFilter;

  @override
  void initState() {
    super.initState();
    _segment = widget.initialSegment;
    AdminPaymentScreen.isAdminPaymentScreenOpen = true;
    if ((widget.focusPatientId ?? '').isNotEmpty) {
      if (_segment == AdminPaymentSegment.account) {
        _focusPaymentRecordFromFirestore();
      } else {
        _focusAppointmentPayment();
      }
    }
  }

  /// Reads the appointment payment document directly so the screen opens on
  /// the filter that actually contains it, instead of guessing from the
  /// patient's subscription status.
  Future<void> _focusAppointmentPayment() async {
    final patientId = widget.focusPatientId!;
    try {
      final snap = await FirebaseFirestore.instance
          .collection(FirestoreCollections.appointmentPayments)
          .where('patientId', isEqualTo: patientId)
          .limit(1)
          .get();
      if (!mounted || snap.docs.isEmpty) return;
      final status =
          (snap.docs.first.data()['paymentStatus'] as String?) ?? 'pending';
      if (!mounted) return;
      setState(() => selectedFilter = status);
    } catch (_) {
      if (!mounted) return;
      setState(() => selectedFilter = 'all');
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    AdminPaymentScreen.isAdminPaymentScreenOpen = false;
    super.dispose();
  }

  /// Reads the patient's record straight from Firestore so the screen opens on
  /// the filter that actually contains the payment the notification refers to,
  /// and so the displayed proof is never a cached one. The list itself is
  /// driven by a live snapshot stream, which keeps it fresh afterwards.
  Future<void> _focusPaymentRecordFromFirestore() async {
    final patientId = widget.focusPatientId!;
    try {
      final doc = await FirebaseFirestore.instance
          .collection(FirestoreCollections.patients)
          .doc(patientId)
          .get();

      if (!mounted) return;

      if (!doc.exists) {
        ToastService.instance.showError('Payment record not found');
        return;
      }

      final status = (doc.data()?['paymentStatus'] as String?) ?? '';
      debugPrint(
        '💳 Admin payment focus: patient=$patientId '
        'paymentId=${widget.focusPaymentId} status=$status',
      );

      final filter =
          <String>[
            PaymentStatus.pending,
            PaymentStatus.approved,
            PaymentStatus.rejected,
          ].contains(status)
          ? status
          : 'all';

      if (filter != selectedFilter) {
        setState(() => selectedFilter = filter);
      }
      if (mounted) {
        ToastService.instance.showInfo(
          'Showing payment for '
          '${(doc.data()?['fullname'] as String?) ?? 'patient'}',
        );
      }
    } catch (e) {
      debugPrint('Error focusing payment record: $e');
      if (mounted) {
        setState(() => selectedFilter = 'all');
      }
    }
  }

  /// Brings the focused record into view once it exists in the list. Runs
  /// after the first frame that actually contains the card.
  void _maybeScrollToFocused(List<UserModel> requests) {
    final patientId = widget.focusPatientId;
    if (_didAutoScroll || patientId == null || patientId.isEmpty) return;
    if (!requests.any((r) => r.id == patientId)) return;

    _didAutoScroll = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final targetContext = _cardKeys[patientId]?.currentContext;
      if (targetContext == null) return;
      Scrollable.ensureVisible(
        targetContext,
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeOutCubic,
        alignment: 0.05,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final patientController = ref.read(patientControllerProvider);
    final isAppointment = _segment == AdminPaymentSegment.appointment;

    return AdminScreen(
      showBack: true,
      title: isAppointment ? 'Appointment Payments' : 'Payment Requests',
      subtitle: isAppointment
          ? 'Review consultation fee proofs'
          : 'Review and approve patient payments',
      body: Column(
        children: [
          // Account / Appointment switch.
          Padding(
            padding: EdgeInsets.fromLTRB(
              context.rsp(16),
              14,
              context.rsp(16),
              0,
            ),
            child: AdminSegmentedControl<AdminPaymentSegment>(
              options: const [
                AdminSegmentOption(
                  AdminPaymentSegment.account,
                  'Account',
                  Icons.account_balance_wallet_rounded,
                ),
                AdminSegmentOption(
                  AdminPaymentSegment.appointment,
                  'Appointment',
                  Icons.calendar_month_rounded,
                ),
              ],
              value: _segment,
              onChanged: (value) => setState(() => _segment = value),
            ),
          ),

          // Filter chips
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: context.rsp(16),
              vertical: 14,
            ),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _buildFilterChip('Pending', 'pending'),
                _buildFilterChip('Approved', 'approved'),
                _buildFilterChip('Rejected', 'rejected'),
                _buildFilterChip('All', 'all'),
              ],
            ),
          ),
          Expanded(
            child: isAppointment
                ? _buildAppointmentPayments()
                : _buildAccountPayments(patientController),
          ),
        ],
      ),
    );
  }

  Widget _buildAccountPayments(dynamic patientController) {
    if (_accountPaymentsFilter != selectedFilter ||
        _accountPaymentsStream == null) {
      _accountPaymentsFilter = selectedFilter;
      _accountPaymentsStream = patientController.getFilteredPaymentRequests(
        selectedFilter,
      );
    }
    return StreamBuilder<List<UserModel>>(
      stream: _accountPaymentsStream,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          // Retry re-creates the stream: a bare setState(() {}) re-subscribed
          // to the same errored stream instance, so the admin could never
          // recover. The toast also used to live here, inside build(), so it
          // re-fired on every unrelated rebuild of this screen.
          return AdminErrorState(
            message: 'Error loading payment requests',
            onRetry: () => setState(() {
              _accountPaymentsStream = patientController
                  .getFilteredPaymentRequests(selectedFilter);
            }),
          );
        }

        if (snapshot.connectionState == ConnectionState.waiting) {
          return const AdminLoading(label: 'Loading payments...');
        }

        final requests = snapshot.data ?? [];

        if (requests.isEmpty) {
          return const AdminEmptyState(
            icon: Icons.payment,
            title: 'No payment requests found',
          );
        }

        _maybeScrollToFocused(requests);

        return ListView.builder(
          controller: _scrollController,
          padding: EdgeInsets.fromLTRB(context.rsp(16), 4, context.rsp(16), 16),
          itemCount: requests.length,
          itemBuilder: (context, index) {
            final request = requests[index];
            final key = _cardKeys.putIfAbsent(request.id, GlobalKey.new);
            return KeyedSubtree(
              key: key,
              child: _buildPaymentCard(
                request,
                isFocused: request.id == widget.focusPatientId,
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildAppointmentPayments() {
    final paymentsAsync = ref.watch(appointmentPaymentsProvider);

    return paymentsAsync.when(
      loading: () =>
          const AdminLoading(label: 'Loading appointment payments...'),
      error: (_, __) => AdminErrorState(
        message: 'Error loading appointment payments',
        // Invalidate the provider to actually re-subscribe; setState alone
        // re-watched the same errored provider value.
        onRetry: () => ref.invalidate(appointmentPaymentsProvider),
      ),
      data: (all) {
        final payments = all
            .where(
              (p) =>
                  selectedFilter == 'all' || p.paymentStatus == selectedFilter,
            )
            .toList();

        if (payments.isEmpty) {
          return const AdminEmptyState(
            icon: Icons.calendar_month,
            title: 'No appointment payments found',
          );
        }

        return ListView.builder(
          controller: _scrollController,
          padding: EdgeInsets.fromLTRB(context.rsp(16), 4, context.rsp(16), 16),
          itemCount: payments.length,
          itemBuilder: (context, index) =>
              _buildAppointmentPaymentCard(payments[index]),
        );
      },
    );
  }

  Widget _buildAppointmentPaymentCard(AppointmentPaymentModel payment) {
    final statusColor = _getStatusColor(payment.paymentStatus);
    final isFocused =
        payment.patientId == widget.focusPatientId &&
        _segment == AdminPaymentSegment.appointment;

    return AdminCard(
      margin: const EdgeInsets.only(bottom: 16),
      radius: 18,
      padding: EdgeInsets.zero,
      borderColor: isFocused ? AdminPalette.brand : null,
      shadowStrength: isFocused ? 0.22 : 0.10,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isFocused)
            Container(
              width: double.infinity,
              decoration: const BoxDecoration(
                color: AdminPalette.brand,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(18),
                  topRight: Radius.circular(18),
                ),
              ),
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
              child: Text(
                'From appointment payment notification',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ),
          Container(
            padding: EdgeInsets.all(context.rsp(16)),
            decoration: BoxDecoration(
              color: AdminPalette.infoBg,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(18),
                topRight: Radius.circular(18),
              ),
              border: Border(
                bottom: BorderSide(
                  color: AdminPalette.cardBorder.withValues(alpha: 0.6),
                ),
              ),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: statusColor.withValues(alpha: 0.1),
                  child: Icon(
                    _getStatusIcon(payment.paymentStatus),
                    color: statusColor,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        payment.patientName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AdminTextStyles.heading(size: context.fs(14.5)),
                      ),
                      Text(
                        'Dr. ${payment.doctorName} • ${payment.doctorSpecialization}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AdminTextStyles.small(size: context.fs(12.5)),
                      ),
                      Text(
                        payment.patientPhone,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AdminTextStyles.small(size: context.fs(12.5)),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: AdminPill(
                    text: payment.paymentStatus.toUpperCase(),
                    color: statusColor,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.all(context.rsp(16)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: AdminPalette.brand.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: AdminPalette.brand.withValues(alpha: 0.2),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.calendar_today_rounded,
                        size: 14,
                        color: AdminPalette.brand,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Purpose: Appointment Booking',
                        style: TextStyle(
                          fontSize: context.fs(12),
                          fontWeight: FontWeight.w600,
                          color: AdminPalette.brand,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AdminPalette.infoBg,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AdminPalette.infoBorder),
                  ),
                  child: Column(
                    children: [
                      if (payment.appointmentId.isNotEmpty) ...[
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: AdminInfoRow(
                            icon: Icons.event_rounded,
                            label: 'Appointment ID',
                            value: payment.appointmentId,
                          ),
                        ),
                      ],
                      _amountRow('Original fee', payment.consultationFee),
                      if (payment.discountPercentage > 0) ...[
                        const SizedBox(height: 6),
                        _amountRow(
                          'Video discount (${payment.discountPercentage.toStringAsFixed(0)}%)',
                          -payment.discountAmount,
                          color: AdminPalette.success,
                        ),
                        const SizedBox(height: 6),
                        _amountRow(
                          'Discount amount',
                          payment.discountAmount,
                          color: AdminPalette.success,
                        ),
                        const SizedBox(height: 6),
                        _amountRow(
                          'You save',
                          payment.discountAmount,
                          color: AdminPalette.success,
                        ),
                      ],
                      const Divider(height: 14),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Flexible(
                            child: Text(
                              'Final amount',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AdminTextStyles.body(size: context.fs(13)),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            appointmentAmount(payment.payableAmount),
                            style: TextStyle(
                              fontSize: context.fs(14.5),
                              fontWeight: FontWeight.bold,
                              color: AdminPalette.brand,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Flexible(
                            child: Text(
                              'Submitted amount',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AdminTextStyles.body(size: context.fs(13)),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            appointmentAmount(payment.payableAmount),
                            style: TextStyle(
                              fontSize: context.fs(13),
                              fontWeight: FontWeight.w600,
                              color: AdminPalette.textPrimary,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (payment.videoWatched) ...[
                  const SizedBox(height: 10),
                  AdminPill(text: 'VIDEO WATCHED', color: AdminPalette.success),
                ],
                const SizedBox(height: 16),
                Text(
                  'Payment Proof:',
                  style: AdminTextStyles.heading(size: context.fs(13)),
                ),
                const SizedBox(height: 8),
                if ((payment.paymentImage ?? '').isNotEmpty)
                  GestureDetector(
                    onTap: () => _showFullScreenImage(payment.paymentImage!),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: CachedNetworkImage(
                        imageUrl: payment.paymentImage!,
                        height: 200,
                        width: double.infinity,
                        fit: BoxFit.cover,
                      ),
                    ),
                  )
                else
                  Text(
                    'No proof attached',
                    style: AdminTextStyles.small(size: context.fs(12.5)),
                  ),
                const SizedBox(height: 12),
                if (payment.submittedAt != null)
                  Text(
                    'Submitted: ${_formatDate(payment.submittedAt!)}',
                    style: AdminTextStyles.small(size: context.fs(12.5)),
                  ),
                if (payment.rejectionReason != null &&
                    payment.rejectionReason!.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AdminPalette.error.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: AdminPalette.error.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.error_outline,
                          color: AdminPalette.error,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Rejection Reason: ${payment.rejectionReason}',
                            style: TextStyle(
                              fontSize: context.fs(12),
                              color: AdminPalette.error,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                if (payment.isPending) ...[
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          minWidth: context.rsp(116) * context.textScale,
                          maxWidth: 260,
                        ),
                        child: AdminOutlineButton(
                          label: 'Reject',
                          icon: Icons.close,
                          color: AdminPalette.error,
                          onPressed: () =>
                              _showRejectAppointmentDialog(payment),
                        ),
                      ),
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          minWidth: context.rsp(116) * context.textScale,
                          maxWidth: 260,
                        ),
                        child: AdminSolidButton(
                          label: 'Approve',
                          icon: Icons.check_circle,
                          color: AdminPalette.success,
                          onPressed: () => _approveAppointmentPayment(payment),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _amountRow(String label, double value, {Color? color}) {
    final negative = value < 0;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AdminTextStyles.body(size: context.fs(13)),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          negative
              ? '- ${appointmentAmount(value.abs())}'
              : appointmentAmount(value),
          style: TextStyle(
            fontSize: context.fs(13),
            fontWeight: FontWeight.w600,
            color: color ?? AdminPalette.textPrimary,
          ),
        ),
      ],
    );
  }

  Future<void> _approveAppointmentPayment(
    AppointmentPaymentModel payment,
  ) async {
    final confirmed = await showAdminConfirmDialog(
      context: context,
      title: 'Approve Appointment Payment',
      content:
          "Approve ${payment.patientName}'s payment for Dr. ${payment.doctorName}?",
      confirmLabel: 'Approve',
      confirmColor: AdminPalette.success,
    );
    if (confirmed != true) return;

    ToastService.instance.showInfo('Processing approval...');
    final error = await ref
        .read(appointmentControllerProvider)
        .approveAppointmentPayment(payment);
    if (!mounted) return;
    if (error != null) {
      ToastService.instance.showError(error);
    } else {
      ToastService.instance.showSuccess('Appointment payment approved');
    }
  }

  void _showRejectAppointmentDialog(AppointmentPaymentModel payment) {
    showAdminReasonDialog(
      context: context,
      title: 'Reject Appointment Payment',
      prompt: 'Reject ${payment.patientName}' + "'s payment?",
      confirmLabel: 'Reject',
      confirmColor: AdminPalette.error,
      onConfirm: (reason) async {
        ToastService.instance.showInfo('Rejecting payment...');
        final error = await ref
            .read(appointmentControllerProvider)
            .rejectAppointmentPayment(payment, reason: reason);
        if (!mounted) return;
        if (error != null) {
          ToastService.instance.showError(error);
        } else {
          ToastService.instance.showSuccess('Appointment payment rejected');
        }
      },
    );
  }

  Widget _buildFilterChip(String label, String filter) {
    return AdminFilterChip(
      label: label,
      selected: selectedFilter == filter,
      onTap: () {
        if (selectedFilter != filter) {
          setState(() => selectedFilter = filter);
          ToastService.instance.showInfo(
            'Showing ${label.toLowerCase()} payments',
          );
        }
      },
    );
  }

  Widget _buildPaymentCard(UserModel request, {bool isFocused = false}) {
    final isPending = request.paymentStatus == 'pending';
    final statusColor = _getStatusColor(request.paymentStatus ?? 'pending');

    return AdminCard(
      margin: const EdgeInsets.only(bottom: 16),
      radius: 18,
      padding: EdgeInsets.zero,
      // Ring the record the admin was deep-linked to so it is obvious which
      // submission the notification was about.
      borderColor: isFocused ? AdminPalette.brand : null,
      shadowStrength: isFocused ? 0.22 : 0.10,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isFocused)
            Container(
              width: double.infinity,
              decoration: const BoxDecoration(
                color: AdminPalette.brand,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(18),
                  topRight: Radius.circular(18),
                ),
              ),
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
              child: Text(
                'From payment notification',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ),
          // Header
          Container(
            padding: EdgeInsets.all(context.rsp(16)),
            decoration: BoxDecoration(
              color: AdminPalette.infoBg,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(18),
                topRight: Radius.circular(18),
              ),
              border: Border(
                bottom: BorderSide(
                  color: AdminPalette.cardBorder.withValues(alpha: 0.6),
                ),
              ),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: statusColor.withValues(alpha: 0.1),
                  child: Icon(
                    _getStatusIcon(request.paymentStatus ?? 'pending'),
                    color: statusColor,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        request.fullname,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AdminTextStyles.heading(size: context.fs(14.5)),
                      ),
                      Text(
                        'ID: ${request.id.substring(0, 8)}...',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AdminTextStyles.small(size: context.fs(12.5)),
                      ),
                      Text(
                        request.phoneNumber,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AdminTextStyles.small(size: context.fs(12.5)),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: AdminPill(
                    text: (request.paymentStatus ?? 'pending').toUpperCase(),
                    color: statusColor,
                  ),
                ),
              ],
            ),
          ),

          // Content
          Padding(
            padding: EdgeInsets.all(context.rsp(16)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: AdminPalette.brand.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: AdminPalette.brand.withValues(alpha: 0.2),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.verified_user_outlined,
                        size: 14,
                        color: AdminPalette.brand,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Purpose: ${request.ispayment ? "Account Reactivation" : "Account Activation"}',
                        style: TextStyle(
                          fontSize: context.fs(12),
                          fontWeight: FontWeight.w600,
                          color: AdminPalette.brand,
                        ),
                      ),
                    ],
                  ),
                ),
                // Amount
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AdminPalette.infoBg,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AdminPalette.infoBorder),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Flexible(
                        child: Text(
                          'Amount:',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AdminTextStyles.body(size: context.fs(13)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Rs. ${request.totalPayment.toStringAsFixed(2)}',
                        style: TextStyle(
                          fontSize: context.fs(15),
                          fontWeight: FontWeight.bold,
                          color: AdminPalette.brand,
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 16),

                // Payment Image with tap to view full screen
                if (request.paymentImage != null) ...[
                  Text(
                    'Payment Proof:',
                    style: AdminTextStyles.heading(size: context.fs(13)),
                  ),
                  const SizedBox(height: 8),
                  GestureDetector(
                    onTap: () => _showFullScreenImage(request.paymentImage!),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: CachedNetworkImage(
                        imageUrl: request.paymentImage!,
                        height: 200,
                        width: double.infinity,
                        fit: BoxFit.cover,
                        placeholder: (context, url) => Container(
                          height: 200,
                          color: AdminPalette.background,
                          child: const Center(
                            child: CircularProgressIndicator(
                              color: AdminPalette.brand,
                            ),
                          ),
                        ),
                        errorWidget: (context, url, error) => Container(
                          height: 200,
                          color: AdminPalette.background,
                          child: const Center(
                            child: Icon(
                              Icons.error_outline,
                              color: AdminPalette.error,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],

                const SizedBox(height: 16),

                // Timestamps
                if (request.paymentSubmittedAt != null)
                  Text(
                    'Submitted: ${_formatDate(request.paymentSubmittedAt!)}',
                    style: AdminTextStyles.small(size: context.fs(12.5)),
                  ),

                if (request.rejectionReason != null) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AdminPalette.error.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: AdminPalette.error.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.error_outline,
                          color: AdminPalette.error,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Rejection Reason: ${request.rejectionReason}',
                            style: TextStyle(
                              fontSize: context.fs(12),
                              color: AdminPalette.error,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                // Action Buttons (only for pending requests)
                if (isPending) ...[
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          minWidth: context.rsp(116) * context.textScale,
                          maxWidth: 260,
                        ),
                        child: AdminOutlineButton(
                          label: 'Reject',
                          icon: Icons.close,
                          color: AdminPalette.error,
                          onPressed: _isProcessing
                              ? null
                              : () => _showRejectDialog(request),
                        ),
                      ),
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          minWidth: context.rsp(116) * context.textScale,
                          maxWidth: 260,
                        ),
                        child: AdminSolidButton(
                          label: 'Approve',
                          icon: Icons.check_circle,
                          color: AdminPalette.success,
                          onPressed: _isProcessing
                              ? null
                              : () => _approvePayment(request),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showFullScreenImage(String imageUrl) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => FullScreenImageViewer(imageUrl: imageUrl),
      ),
    );
  }

  Future<void> _approvePayment(UserModel request) async {
    if (_isProcessing) return;
    setState(() => _isProcessing = true);
    try {
      final confirmed = await showAdminConfirmDialog(
        context: context,
        title: 'Approve Payment',
        content:
            "Are you sure you want to approve ${request.fullname}'s payment?",
        confirmLabel: 'Approve',
        confirmColor: AdminPalette.success,
      );

      if (confirmed == true) {
        ToastService.instance.showInfo('Processing approval...');

        final patientController = ref.read(patientControllerProvider);
        final success = await patientController.approvePayment(request.id);

        if (success) {
          ToastService.instance.showSuccess(
            'Payment approved for ${request.fullname}',
          );
        } else {
          ToastService.instance.showError(
            'Failed to approve payment: ${patientController.errorMessage}',
          );
        }
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  void _showRejectDialog(UserModel request) {
    if (_isProcessing) return;
    showAdminReasonDialog(
      context: context,
      title: 'Reject Payment',
      prompt: 'Reject payment for ${request.fullname}?',
      confirmLabel: 'Reject',
      confirmColor: AdminPalette.error,
      onConfirm: (reason) async {
        setState(() => _isProcessing = true);
        try {
          ToastService.instance.showInfo('Rejecting payment...');

          final patientController = ref.read(patientControllerProvider);
          final success = await patientController.rejectPayment(
            request.id,
            reason,
          );

          if (success) {
            ToastService.instance.showSuccess(
              'Payment rejected for ${request.fullname}',
            );
          } else {
            ToastService.instance.showError(
              'Failed to reject payment: ${patientController.errorMessage}',
            );
          }
        } finally {
          if (mounted) setState(() => _isProcessing = false);
        }
      },
    );
  }

  Color _getStatusColor(String status) {
    switch (status.toLowerCase()) {
      case 'pending':
        return AdminPalette.frozen;
      case 'approved':
        return AdminPalette.success;
      case 'rejected':
        return AdminPalette.error;
      default:
        return AdminPalette.textMuted;
    }
  }

  IconData _getStatusIcon(String status) {
    switch (status.toLowerCase()) {
      case 'pending':
        return Icons.pending;
      case 'approved':
        return Icons.check_circle;
      case 'rejected':
        return Icons.cancel;
      default:
        return Icons.payment;
    }
  }

  String _formatDate(DateTime date) {
    return '${date.day}/${date.month}/${date.year} ${date.hour}:${date.minute.toString().padLeft(2, '0')}';
  }
}

class FullScreenImageViewer extends StatelessWidget {
  final String imageUrl;

  const FullScreenImageViewer({super.key, required this.imageUrl});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black.withOpacity(0.8),
        elevation: 0,
        leading: IconButton(
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.close, color: Colors.white, size: 28),
        ),
        title: Text(
          'Payment Proof',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
        ),
        centerTitle: true,
      ),
      body: GestureDetector(
        onTap: () => Navigator.pop(context),
        child: Center(
          child: InteractiveViewer(
            minScale: 0.5,
            maxScale: 4.0,
            child: CachedNetworkImage(
              imageUrl: imageUrl,
              placeholder: (context, url) => Container(
                color: Colors.black,
                child: const Center(
                  child: CircularProgressIndicator(color: Colors.white),
                ),
              ),
              errorWidget: (context, url, error) => Container(
                color: Colors.black,
                child: const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.error_outline, color: Colors.white, size: 64),
                      SizedBox(height: 16),
                      Text(
                        'Failed to load image',
                        style: TextStyle(color: Colors.white),
                      ),
                    ],
                  ),
                ),
              ),
              fit: BoxFit.contain,
            ),
          ),
        ),
      ),
    );
  }
}
