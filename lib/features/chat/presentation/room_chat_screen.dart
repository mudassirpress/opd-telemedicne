import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/data/models/user_model.dart';
import 'package:telemedicine/features/auth/presentation/providers/user_provider.dart';
import 'package:telemedicine/features/auth/presentation/screens/expired_patient_screen.dart';
import 'package:telemedicine/features/auth/presentation/screens/sign_in_screen.dart';
import 'package:telemedicine/features/patients/presentation/screens/patient_profile_screen.dart';
import 'package:telemedicine/features/payments/presentation/screens/payment_screen.dart';
import 'package:telemedicine/features/chat/presentation/chat_list_widget.dart';
import 'package:telemedicine/features/doctors/presentation/doctor_list_widget.dart';
import 'package:telemedicine/features/calls/presentation/controllers/call_controller.dart';
import 'package:telemedicine/features/calls/presentation/call_history_screen.dart';
import 'package:telemedicine/features/reports/presentation/report_history/report_history_screen.dart';
import 'package:telemedicine/features/reports/presentation/upload_report_screen/upload_report_screen.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/core/services/account_expiry_service.dart';
import 'package:telemedicine/core/services/incoming_call_coordinator.dart';
import 'package:telemedicine/core/services/notification_service.dart';
import 'package:telemedicine/app/theme/app_theme.dart';
import 'package:telemedicine/core/utils/guest_guard.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/core/providers/badge_providers.dart';
import 'package:telemedicine/features/complaints/presentation/submit_complaint_screen.dart';
import 'package:telemedicine/core/services/payment_complaint_visibility_service.dart';
import 'package:telemedicine/shared/widgets/auth_layout.dart';
import 'package:telemedicine/shared/widgets/badge_indicator.dart';

class ChatRoomScreen extends ConsumerStatefulWidget {
  const ChatRoomScreen({super.key});

  /// Navigation guard used by `NotificationService`: an approval/rejection tap
  /// refreshes the already-open Room Chat in place instead of pushing a second
  /// copy of it.
  static bool isChatRoomScreenOpen = false;

  @override
  ConsumerState<ChatRoomScreen> createState() => _ChatRoomScreenState();
}

class _ChatRoomScreenState extends ConsumerState<ChatRoomScreen>
    with WidgetsBindingObserver {
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  final GlobalKey<RefreshIndicatorState> _refreshIndicatorKey =
      GlobalKey<RefreshIndicatorState>();
  Timer? _paymentStatusTimer;
  Timer? _expiryCheckTimer;
  bool _isFabOpen = false;
  bool _initialized = false;
  bool _isRefreshingStatus = false;

  /// Latest account-validity snapshot for the expiry warning.
  ///
  /// Null means "no time-based validity" (a normal, non Patient-ID patient) or
  /// "not evaluated yet"; either way no warning is shown.
  PatientExpiryStatus? _expiryStatus;

  /// Fingerprint of the last evaluated status, used to skip no-op rebuilds on
  /// the 60s expiry tick. See [_expirySignatureOf].
  String? _expirySignature;

  /// Everything the banner actually renders. Comparing this instead of the
  /// whole status means the countdown only triggers a rebuild when the visible
  /// text would change — a day boundary, not every minute.
  String _expirySignatureOf(PatientExpiryStatus status) {
    if (!status.hasExpiry) return 'none';
    return '${status.expiryDate!.toIso8601String()}|'
        '${status.isExpiringSoon}|'
        '${status.isExpired}|'
        '${AccountExpiryService.describeRemaining(status)}';
  }

  /// Whether the dismissible warning banner should currently be visible.
  bool get _showExpiryWarning {
    final status = _expiryStatus;
    if (status == null) return false;
    if (!status.isExpiringSoon) return false;

    final userId = ref.read(userProvider)?.id;
    if (userId == null || userId.isEmpty) return false;

    return !AccountExpiryService.isBannerDismissed(status, userId);
  }

  final CallController _callController = CallController();
  StreamSubscription? _incomingCallSub;
  bool _isSearching = false;

  @override
  void initState() {
    super.initState();
    ChatRoomScreen.isChatRoomScreenOpen = true;
    WidgetsBinding.instance.addObserver(this);
    _searchController.addListener(() {
      setState(() {
        _searchQuery = _searchController.text.trim().toLowerCase();
      });
    });
    // A tapped `payment_approved` / `payment_rejected` notification is
    // handled here rather than by pushing a new screen, so the app unlocks (or
    // stays locked) in place with no restart.
    NotificationService.onPaymentStatusRefreshRequested = (_) {
      _checkPaymentStatus();
    };
    if (!_initialized) {
      _initialized = true;
      _initializeScreen();
    }
  }

  @override
  void dispose() {
    ChatRoomScreen.isChatRoomScreenOpen = false;
    if (NotificationService.onPaymentStatusRefreshRequested != null) {
      NotificationService.onPaymentStatusRefreshRequested = null;
    }
    WidgetsBinding.instance.removeObserver(this);
    _searchController.dispose();
    _incomingCallSub?.cancel();
    // NOT dispose(): the CallController is an app-wide singleton; closing the
    // Room Chat must not tear down live call timers/state.
    _callController.resetForScreen();
    _paymentStatusTimer?.cancel();
    _expiryCheckTimer?.cancel();
    super.dispose();
  }

  /// Re-check the live payment status whenever the Room Chat screen comes back
  /// to the foreground, so an admin approval is picked up without the patient
  /// having to pull-to-refresh or relaunch the app.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (!mounted) return;
    if (_isLocked) {
      _checkPaymentStatus();
    } else {
      _startPaymentStatusChecker();
    }
    // Re-evaluate the warning on resume so a patient returning to the app
    // inside the window still sees it, and one whose period was renewed while
    // backgrounded stops seeing it.
    _refreshExpiryWarning();
  }

  /// Whether the current user is a normal (non Patient Card) patient whose
  /// payment has not been approved — either still awaiting the admin or
  /// rejected. While locked, the Room Chat screen must expose zero active
  /// functionality: no chat, no calls and no "+" menu.
  bool get _isLocked {
    final user = ref.read(userProvider);
    if (user == null) return false;
    if (user.role == 'doctor') return false;
    if (user.isPatientIdUser) return false;
    return user.paymentStatus != 'approved' && user.paymentStatus != 'completed';
  }

  bool get _blocksBackNavigation {
    return false;
  }

  void _toggleFab() {
    if (_isLocked) return;
    setState(() {
      _isFabOpen = !_isFabOpen;
    });
  }

  Future<void> _initializeScreen() async {
    try {
      await ref.read(patientControllerProvider).loadSavedUser(forceRefresh: true);

      final currentUser = ref.read(userProvider);
      if (currentUser?.isGuest == true) {
        if (mounted) setState(() {});
        return;
      }
      if (currentUser != null &&
          currentUser.role == 'patient' &&
          currentUser.isExpired) {
        if (mounted) {
          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute(builder: (_) => const ExpiredPatientScreen()),
            (route) => false,
          );
        }
        return;
      }

      _startIncomingCallListener();
      _startPaymentStatusChecker();
      _startExpiryChecker();

      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      debugPrint('Error initializing room chat: $e');
    }
  }

  void _startPaymentStatusChecker() {
    _paymentStatusTimer?.cancel();

    final currentUser = ref.read(userProvider);
    if (currentUser?.isPatientIdUser == true) {
      _paymentStatusTimer = null;
      return;
    }

    _paymentStatusTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      if (!mounted) return;
      final status = ref.read(userProvider)?.paymentStatus;

      // Keep polling while the patient is locked, including after a
      // rejection: the admin may approve a resubmitted payment at any time
      // and the unlock must happen without an app restart.
      if (status == 'pending' || status == 'rejected') {
        _checkPaymentStatus();
        return;
      }

      if (status == 'approved' || status == 'completed') {
        timer.cancel();
        _paymentStatusTimer = null;
      }
    });
  }

  void _startExpiryChecker() {
    _expiryCheckTimer?.cancel();

    final currentUser = ref.read(userProvider);
    if (currentUser == null || currentUser.role != 'patient') return;

    // Evaluate immediately so the banner is correct on first paint, then
    // re-evaluate on the existing 60s cadence.
    _refreshExpiryWarning();

    _expiryCheckTimer = Timer.periodic(const Duration(seconds: 60), (
      timer,
    ) async {
      if (!mounted) return;
      final controller = ref.read(patientControllerProvider);
      final expired = await controller.isCurrentPatientExpired();
      if (expired && mounted) {
        timer.cancel();
        await controller.expirePatientSession();
        if (mounted) {
          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute(builder: (_) => const ExpiredPatientScreen()),
            (route) => false,
          );
        }
        return;
      }

      // Still valid — this is where the warning window is re-checked, so a
      // patient who crosses the 5-month mark while the app is open is warned
      // without a restart. Kept strictly after the expiry branch above, which
      // owns the automatic-logout contract and is left byte-identical.
      await _refreshExpiryWarning();
    });
  }

  /// Re-reads the authoritative expiry date and refreshes both warning layers.
  ///
  /// Runs on mount, on every 60s expiry tick, and after a resume. The
  /// once-per-period heads-up toast is claimed here, so repeated evaluations
  /// (every screen the patient visits, every tick) cannot re-fire it.
  Future<void> _refreshExpiryWarning() async {
    try {
      final controller = ref.read(patientControllerProvider);
      final status = await controller.getCurrentPatientExpiryStatus();
      if (!mounted) return;

      // Rebuild only when the banner would actually look different. The 60s
      // tick runs for the whole session, and rebuilding the main content (which
      // hosts the doctor list and chat list) on every tick for a countdown that
      // has not changed is pure waste.
      final signature = _expirySignatureOf(status);
      if (signature == _expirySignature) return;
      _expirySignature = signature;

      // A patient with no time-based validity must never show a banner.
      if (!status.hasExpiry) {
        if (_expiryStatus != null) {
          setState(() => _expiryStatus = null);
        }
        return;
      }

      setState(() => _expiryStatus = status);

      if (!status.isExpiringSoon) return;

      // Claim the single heads-up for this warning period. A pending
      // reactivation already covers the action, so it suppresses the toast too.
      final userId = ref.read(userProvider)?.id;
      if (userId == null || userId.isEmpty) return;

      final hasPending = await controller.hasPendingReactivationRequest();
      if (!mounted) return;

      final shouldWarn = await AccountExpiryService.shouldWarn(
        status: status,
        userId: userId,
        hasPendingReactivation: hasPending,
      );
      if (!shouldWarn) return;

      // Mark before showing: if the toast call itself throws, the period is
      // still consumed and the next tick will not retry in a loop.
      await controller.markUpcomingExpiryWarningShown();
      if (!mounted) return;

      ToastService.instance.showWarning(AccountExpiry.warningMessage);
    } catch (e) {
      // The warning is advisory; never let it disturb the screen or the
      // expiry check that shares this timer.
      debugPrint('Expiry warning check failed: $e');
    }
  }

  /// The dismissible warning banner with the reactivation action.
  Widget _buildExpiryWarningBanner() {
    final status = _expiryStatus;
    if (status == null) return const SizedBox.shrink();

    final userId = ref.read(userProvider)?.id ?? '';
    final remaining = AccountExpiryService.describeRemaining(status);

    return Container(
      width: double.infinity,
      margin: EdgeInsets.fromLTRB(context.rsp(16), 10, context.rsp(16), 0),
      padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.45)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, size: 20, color: AppColors.warning),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  remaining.isEmpty
                      ? 'Account Expiring Soon'
                      : 'Account expires $remaining',
                  style: TextStyle(
                    fontSize: context.fs(13.5),
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF1F2F44),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  AccountExpiry.warningMessage,
                  style: TextStyle(
                    fontSize: context.fs(12),
                    color: const Color(0xFF657991),
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 8),
                // The action routes into the existing reactivation /
                // payment-proof flow. `isExpiringSoon: true` keeps the session
                // intact and pops back to the app on submit.
                TextButton.icon(
                  onPressed: _openReactivationFlow,
                  icon: const Icon(Icons.verified_user_outlined, size: 16),
                  label: const Text('Reactivate Account'),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.primaryRed,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    textStyle: TextStyle(
                      fontSize: context.fs(12.5),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () {
              AccountExpiryService.dismissBanner(status, userId);
              setState(() {});
            },
            icon: const Icon(Icons.close, size: 16),
            color: const Color(0xFF657991),
            visualDensity: VisualDensity.compact,
            tooltip: 'Dismiss',
          ),
        ],
      ),
    );
  }

  /// Opens the existing payment-proof / reactivation flow.
  ///
  /// Pushed (not `pushReplacement`) so the patient returns to a fully working
  /// app afterwards — they are still inside their validity period.
  Future<void> _openReactivationFlow() async {
    final submitted = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => const ExpiredPatientScreen(isExpiringSoon: true),
      ),
    );

    if (!mounted) return;

    if (submitted == true) {
      // A proof is now awaiting review: the warning has been acted upon, so
      // stop surfacing it for the rest of this period.
      final userId = ref.read(userProvider)?.id ?? '';
      if (_expiryStatus != null && userId.isNotEmpty) {
        AccountExpiryService.dismissBanner(_expiryStatus!, userId);
      }
      ToastService.instance.showInfo(
        'Your reactivation request is pending admin approval.',
      );
      setState(() {});
    }
  }

  /// Re-reads the payment status from Firestore — never from the cached
  /// session — and applies any change. This is the single place the Room Chat
  /// unlocks or re-locks, whether the trigger is the 3s poller, a resume, a
  /// pull-to-refresh, or a tapped `payment_approved` / `payment_rejected`
  /// notification.
  Future<void> _checkPaymentStatus() async {
    try {
      final controller = ref.read(patientControllerProvider);
      final currentUser = controller.currentUser;

      if (currentUser == null || currentUser.id.isEmpty) return;

      final freshUser = await controller.getUserById(currentUser.id);
      if (freshUser == null || !mounted) return;

      final oldStatus = currentUser.paymentStatus;
      final newStatus = freshUser.paymentStatus;

      if (oldStatus == newStatus) return;

      if (newStatus == 'approved' || newStatus == 'completed') {
        _paymentStatusTimer?.cancel();
        _paymentStatusTimer = null;
      }

      // Force-refresh so the freshly read Firestore document (including
      // `rejectionReason`) replaces the locally cached session.
      await controller.loadSavedUser(forceRefresh: true);
      if (!mounted) return;

      await Future.delayed(const Duration(milliseconds: 300));
      if (!mounted) return;

      final wasLocked = oldStatus == 'pending' || oldStatus == 'rejected';

      if (newStatus == 'approved' || newStatus == 'completed') {
        // Unlocking re-enables the "+" menu and the full chat UI.
        if (_isFabOpen) _isFabOpen = false;
        if (wasLocked) {
          ToastService.instance.showSuccess(
            'Payment approved! You now have full access to all features.',
          );
        }
        setState(() {});
      } else if (newStatus == 'rejected') {
        if (wasLocked) {
          ToastService.instance.showError(
            'Payment rejected. Reason: '
            '${freshUser.rejectionReason ?? 'Please resubmit'}',
          );
        }
        if (_isFabOpen) _isFabOpen = false;
        setState(() {});
      } else {
        // Back to pending (e.g. a resubmission) — re-arm the poller.
        _startPaymentStatusChecker();
        if (_isFabOpen) _isFabOpen = false;
        setState(() {});
      }
    } catch (e) {
      print('Error checking payment status: $e');
    }
  }

  void _startIncomingCallListener() {
    final user = ref.read(patientControllerProvider).currentUser;
    if (user == null || user.isGuest) return;

    // Lost-push safety net. This listener used to push its own
    // `IncomingCallScreen` directly, with a private `_isShowingIncomingCall`
    // guard that knew nothing about the FCM handler's guard — so one call
    // could stack two Incoming Call screens. It now goes through the
    // coordinator, whose `callId` claim is shared with the push path: whichever
    // of the two fires first renders, the other is dropped.
    _incomingCallSub = _callController.incomingCallStream(user.id).listen((
      call,
    ) {
      if (call == null || !mounted) return;
      // A patient locked on a pending or rejected payment must not be able to
      // enter an active call through the incoming-call route.
      if (_isLocked) {
        debugPrint(
          '🚫 Incoming call blocked – payment not approved for ${user.id}',
        );
        return;
      }

      debugPrint(
        '📞 Lost-push watcher saw ringing call ${call.id} '
        'caller=${call.callerName} type=${call.callType}',
      );

      IncomingCallCoordinator.instance.registerIncomingCall(<String, dynamic>{
        ...call.toMap(),
        'id': call.id,
        'callId': call.id,
      }, origin: IncomingCallOrigin.firestoreWatcher);
    });
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() {
      _searchQuery = '';
    });
    ToastService.instance.showInfo('Search cleared');
  }

  Future<void> _refreshData() async {
    try {
      final patientController = ref.read(patientControllerProvider);
      // Always read the latest payment status straight from Firestore.
      await patientController.loadSavedUser(forceRefresh: true);
      await patientController.verifyCurrentSession();

      if (_searchQuery.isNotEmpty) {
        _clearSearch();
      }

      if (_isLocked) {
        _startPaymentStatusChecker();
      }

      if (mounted) {
        setState(() {});
        ToastService.instance.showSuccess('Data refreshed successfully');
      }
    } catch (e) {
      ToastService.instance.showError('Failed to refresh: ${e.toString()}');
    }
  }

  /// The single action a pending patient is allowed to trigger. Uses
  /// button-level loading (never a full-screen indicator) and re-reads the
  /// payment status from Firestore.
  Future<void> _refreshPaymentStatus() async {
    if (_isRefreshingStatus) return;
    setState(() {
      _isRefreshingStatus = true;
    });
    try {
      await _checkPaymentStatus();
      // Still pending (or the transition was already handled above).
      if (mounted) {
        final status = ref.read(userProvider)?.paymentStatus;
        if (status == 'pending') {
          ToastService.instance.showInfo(
            'Still pending approval. We will keep checking for you.',
          );
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _isRefreshingStatus = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentUser = ref.watch(userProvider);

    if (currentUser == null) {
      return _buildNotLoggedInScreen();
    }

    final showDoctorList = currentUser.role != 'doctor';
    final paymentStatus = currentUser.paymentStatus;
    final isPatientIdUser = currentUser.isPatientIdUser;
    final isPaymentApproved =
        isPatientIdUser ||
        paymentStatus == 'approved' ||
        paymentStatus == 'completed';
    final isPaymentPending = paymentStatus == 'pending';
    final isPaymentRejected = paymentStatus == 'rejected';
    final hasNoPayment =
        !isPatientIdUser && (paymentStatus == null || paymentStatus.isEmpty);

    // A patient whose payment is pending or rejected is fully locked out.
    // Doctors and Patient Card users are never locked, so their UI is
    // unchanged.
    final isLocked = _isLocked;

    final body = Scaffold(
      backgroundColor: const Color(0xFFEDF2F8),
      body: SafeArea(
        child: RefreshIndicator(
          key: _refreshIndicatorKey,
          onRefresh: _refreshData,
          color: AppColors.primaryRed,
          backgroundColor: Colors.white,
          strokeWidth: 2.5,
          displacement: 40,
          child: _buildBodyBasedOnPaymentStatus(
            currentUser,
            paymentStatus,
            isPaymentPending,
            isPaymentApproved,
            isPaymentRejected,
            hasNoPayment,
            showDoctorList,
          ),
        ),
      ),
      // The FAB is the entry point to Upload Reports / Report History. It must
      // not exist at all while the payment is pending or rejected, or for guests.
      floatingActionButton: (isLocked || currentUser.isGuest) ? null : _buildFab(),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
    );

    if (!_blocksBackNavigation) return body;

    // Block back navigation so the pending screen cannot be dismissed into
    // another navigation path.
    return PopScope(canPop: false, child: body);
  }

  Widget _buildFab() {
    final unreadReports = ref.watch(unreadReportsCountProvider).value ?? 0;

    return Padding(
      padding: const EdgeInsets.only(bottom: 5, right: 4.5),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (_isFabOpen) ...[
            _FABMenuItem(
              icon: Icons.upload_file,
              label: 'Upload Reports',
              onTap: () {
                _toggleFab();
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const UploadReportScreen()),
                );
              },
            ),
            _FABMenuItem(
              icon: Icons.history_rounded,
              label: 'Report History',
              badgeCount: unreadReports,
              onTap: () {
                _toggleFab();
                markReportsAsViewed(ref);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const ReportHistoryScreen(),
                  ),
                );
              },
            ),
          ],
          BadgeIndicator(
            count: _isFabOpen ? 0 : unreadReports,
            child: FloatingActionButton(
              onPressed: _toggleFab,
              backgroundColor: _isFabOpen
                  ? const Color(0xFFE8EDF3)
                  : AppColors.primaryRed,
              elevation: 4,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                transitionBuilder: (Widget child, Animation<double> animation) {
                  return RotationTransition(
                    turns: Tween<double>(begin: 0, end: 1).animate(
                      CurvedAnimation(parent: animation, curve: Curves.easeInOut),
                    ),
                    child: FadeTransition(opacity: animation, child: child),
                  );
                },
                child: _isFabOpen
                    ? const Icon(
                        Icons.close,
                        key: ValueKey('close'),
                        color: Color(0xFF1F2F44),
                      )
                    : const Icon(
                        Icons.add,
                        key: ValueKey('add'),
                        color: Colors.white,
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --- Not Logged In Screen ---
  Widget _buildNotLoggedInScreen() {
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
          CenteredContent(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const LogoCard(),
                  const SizedBox(height: 28),
                  Icon(
                    Icons.account_circle,
                    size: 60,
                    color: const Color(0xFF7E90A6),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Not Logged In',
                    style: TextStyle(
                      fontSize: context.fs(19),
                      fontWeight: FontWeight.bold,
                      color: const Color(0xFF1F2F44),
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Please log in to continue',
                    style: TextStyle(
                      fontSize: context.fs(14),
                      color: const Color(0xFF657991),
                    ),
                  ),
                  const SizedBox(height: 28),
                  GradientButton(
                    text: 'Sign In',
                    onPressed: () async {
                      final result = await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const SignInScreen(),
                        ),
                      );
                      if (result == true && mounted) {
                        await _refreshData();
                      }
                    },
                    icon: Icons.arrow_forward_rounded,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --- Payment Required Widget ---
  Widget _buildPaymentRequiredWidget() {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: CenteredContent(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const LogoCard(),
                    const SizedBox(height: 28),
                    Icon(
                      Icons.payment_rounded,
                      size: 56,
                      color: AppColors.primaryRed,
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'Payment Required',
                      style: TextStyle(
                        fontSize: context.fs(20),
                        fontWeight: FontWeight.bold,
                        color: const Color(0xFF1F2F44),
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        'Please make a payment to access chat and call features.',
                        style: TextStyle(
                          color: const Color(0xFF657991),
                          fontSize: context.fs(14),
                          height: 1.5,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(height: 28),
                    GradientButton(
                      text: 'Make Payment',
                      onPressed: () async {
                        ToastService.instance.showInfo(
                          'Opening payment screen',
                        );
                        final result = await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const PaymentScreen(),
                          ),
                        );
                        if (result == true) {
                          await _refreshData();
                        }
                      },
                      icon: Icons.arrow_forward_rounded,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // --- Payment Rejected Widget ---
  Widget _buildPaymentRejectedWidget(UserModel currentUser) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: CenteredContent(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const LogoCard(),
                    const SizedBox(height: 28),
                    Icon(
                      Icons.cancel_rounded,
                      size: 56,
                      color: Colors.red[400],
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'Payment Rejected',
                      style: TextStyle(
                        fontSize: context.fs(20),
                        fontWeight: FontWeight.bold,
                        color: const Color(0xFF1F2F44),
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (currentUser.rejectionReason != null)
                      Container(
                        margin: const EdgeInsets.symmetric(horizontal: 16),
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF0F4FA),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: const Color(0xFFDCE6F2)),
                        ),
                        child: Column(
                          children: [
                            Text(
                              'Reason for rejection:',
                              style: TextStyle(
                                fontSize: context.fs(13),
                                fontWeight: FontWeight.w600,
                                color: const Color(0xFF1F2F44),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              currentUser.rejectionReason!,
                              style: TextStyle(
                                fontSize: context.fs(13),
                                color: const Color(0xFF657991),
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 12),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        'Your payment proof was rejected. Please submit a new valid payment proof.',
                        style: TextStyle(
                          color: const Color(0xFF657991),
                          fontSize: context.fs(14),
                          height: 1.5,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(height: 28),
                    GradientButton(
                      text: 'Submit New Payment',
                      onPressed: () async {
                        ToastService.instance.showInfo(
                          'Opening payment screen',
                        );
                        final result = await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const PaymentScreen(),
                          ),
                        );
                        if (result == true) {
                          await _refreshData();
                        }
                      },
                      icon: Icons.arrow_forward_rounded,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // --- Payment Pending Widget ---
  Widget _buildPaymentPendingWidget({
    required String message,
    required bool showSubmitButton,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: CenteredContent(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const LogoCard(),
                    const SizedBox(height: 28),
                    Icon(
                      Icons.pending_actions_rounded,
                      size: 56,
                      color: Colors.orange[400],
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'Pending Approval',
                      style: TextStyle(
                        fontSize: context.fs(20),
                        fontWeight: FontWeight.bold,
                        color: const Color(0xFF1F2F44),
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        message,
                        style: TextStyle(
                          color: const Color(0xFF657991),
                          fontSize: context.fs(14),
                          height: 1.5,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF0F4FA),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: const Color(0xFFDCE6F2)),
                      ),
                      child: Text(
                        'Status: PENDING',
                        style: TextStyle(
                          fontSize: context.fs(13),
                          fontWeight: FontWeight.w600,
                          color: AppColors.primaryRed,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Tap the button below to check your approval status. '
                      'All other features stay locked until an admin approves your payment.',
                      style: TextStyle(
                        fontSize: context.fs(13),
                        color: const Color(0xFF7E90A6),
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 28),
                    GradientButton(
                      text: 'Refresh Status',
                      isLoading: _isRefreshingStatus,
                      onPressed: _refreshPaymentStatus,
                      icon: Icons.refresh_rounded,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // --- Main Content ---
  Widget _buildBodyBasedOnPaymentStatus(
    UserModel currentUser,
    String? paymentStatus,
    bool isPaymentPending,
    bool isPaymentApproved,
    bool isPaymentRejected,
    bool hasNoPayment,
    bool showDoctorList,
  ) {
    if (currentUser.isGuest) {
      return _buildMainContent(showDoctorList, false);
    }

    if (currentUser.role == 'doctor') {
      return _buildMainContent(showDoctorList, true);
    }

    if (currentUser.isPatientIdUser) {
      return _buildMainContent(showDoctorList, true);
    }

    // Both approved and restricted patients (pending, rejected, not_submitted)
    // view the main dashboard (like guests) with restricted privileges.
    return _buildMainContent(showDoctorList, isPaymentApproved);
  }

  Widget _buildMainContent(bool showDoctorList, bool isPaymentApproved) {
    final currentUser = ref.watch(userProvider)!;
    final isPaymentPending = currentUser.paymentStatus == 'pending';
    final isPaymentRejected = currentUser.paymentStatus == 'rejected';
    final showComplaintButton = PaymentComplaintVisibility.shouldShow(currentUser);

    return Column(
      children: [
        // Account-expiry warning.
        //
        // Placed here — at the very top of the main content — because this is
        // the only branch a Patient ID user ever reaches (see the
        // `isPatientIdUser` early return in
        // `_buildBodyBasedOnPaymentStatus`), and a patient with a time-based
        // validity is by definition a Patient ID user. Keeping it out of
        // `build()` also means it never renders on the payment-gated screens.
        if (_showExpiryWarning) _buildExpiryWarningBanner(),
        // Header
        Container(
          padding: EdgeInsets.symmetric(
            horizontal: context.rsp(16),
            vertical: 12,
          ),
          child: Row(
            children: [
              const SizedBox(width: 0),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Telemedicine',
                      style: TextStyle(
                        fontSize: context.fs(17),
                        fontWeight: FontWeight.bold,
                        color: const Color(0xFF1F2F44),
                        letterSpacing: -0.5,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),

                    Text(
                      'Your healthcare dashboard',
                      style: TextStyle(
                        fontSize: context.fs(12),
                        color: const Color(0xFF657991),
                      ),
                    ),
                  ],
                ),
              ),
              if (currentUser.role == 'patient') ...[
                const SizedBox(height: 4),
                _buildLoginMethodBadge(currentUser),
              ],
              const SizedBox(width: 8),
              IconButton(
                icon: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color(0xFFE8EDF3),
                  ),
                  child: Icon(
                    Icons.call_rounded,
                    color: AppColors.primaryRed,
                    size: 20,
                  ),
                ),
                onPressed: () {
                  if (currentUser.isGuest) {
                    GuestGuard.showLoginPrompt(
                      context,
                      message: 'Please log in to access call history.',
                    );
                    return;
                  }
                  ToastService.instance.showInfo('Opening call history');
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const CallHistoryScreen(),
                    ),
                  );
                },
              ),
              if (showComplaintButton)
                IconButton(
                  icon: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Color(0xFFE8EDF3),
                    ),
                    child: Icon(
                      Icons.help_outline_rounded,
                      color: AppColors.primaryRed,
                      size: 20,
                    ),
                  ),
                  tooltip: 'Help / Complaint',
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const SubmitComplaintScreen(),
                      ),
                    );
                  },
                ),
              const SizedBox(width: 4),
              _buildUserAvatar(currentUser),
            ],
          ),
        ),
        Padding(
          padding: EdgeInsets.symmetric(
            horizontal: context.rsp(16),
            vertical: 8,
          ),
          child: MetallicInput(
            hintText: 'Search doctors by name...',
            icon: Icons.search_rounded,
            controller: _searchController,
            validator: null,
          ),
        ),
        // Doctor list (visible for approved patients, read-only guests, and restricted patients)
        if (showDoctorList)
          SizedBox(
            height: 156 + (context.textScale - 1.0) * 64,
            child: DoctorList(searchQuery: _searchQuery),
          ),

        // Chat list
        if (currentUser.isGuest)
          Expanded(
            child: CenteredContent(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.chat_bubble_outline_rounded,
                      size: 48,
                      color: Color(0xFF7E90A6),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Doctor Messaging is Locked',
                      style: TextStyle(
                        fontSize: context.fs(15),
                        color: const Color(0xFF1F2F44),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Guests can browse doctors. Log in to start chatting with doctors and manage consultations.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: context.fs(13),
                        color: const Color(0xFF657991),
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 20),
                    GradientButton(
                      text: 'Sign In to Chat',
                      onPressed: () {
                        Navigator.pushAndRemoveUntil(
                          context,
                          MaterialPageRoute(builder: (_) => const SignInScreen()),
                          (route) => false,
                        );
                      },
                      icon: Icons.login_rounded,
                    ),
                  ],
                ),
              ),
            ),
          )
        else if (isPaymentApproved || currentUser.role == 'doctor')
          Expanded(child: ChatListWidget(searchQuery: _searchQuery))
        else
          Expanded(
            child: CenteredContent(
              child: Padding(
                padding: const EdgeInsets.all(20.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 58,
                      height: 58,
                      decoration: BoxDecoration(
                        color: isPaymentPending
                            ? Colors.orange.withValues(alpha: 0.12)
                            : (isPaymentRejected
                                ? Colors.red.withValues(alpha: 0.12)
                                : const Color(0xFFE8EDF3)),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        isPaymentPending
                            ? Icons.pending_actions_rounded
                            : (isPaymentRejected
                                ? Icons.cancel_rounded
                                : Icons.lock_outline_rounded),
                        size: 32,
                        color: isPaymentPending
                            ? Colors.orange[800]
                            : (isPaymentRejected
                                ? Colors.red[700]
                                : AppColors.primaryRed),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      isPaymentPending
                          ? 'Payment Verification Pending'
                          : (isPaymentRejected
                              ? 'Payment Proof Rejected'
                              : 'Account in Restricted Mode'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: context.fs(16),
                        color: const Color(0xFF1F2F44),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (isPaymentRejected &&
                        currentUser.rejectionReason != null &&
                        currentUser.rejectionReason!.isNotEmpty) ...[
                      Container(
                        padding: const EdgeInsets.all(10),
                        margin: const EdgeInsets.only(bottom: 10),
                        decoration: BoxDecoration(
                          color: Colors.red[50],
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.red[200]!),
                        ),
                        child: Text(
                          'Rejection Reason: ${currentUser.rejectionReason!}',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: context.fs(12),
                            color: Colors.red[900],
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                    Text(
                      isPaymentPending
                          ? 'Your payment proof has been submitted and is currently being reviewed by administrators. You can browse doctors, but doctor chat and calls remain locked until approval.'
                          : (isPaymentRejected
                              ? 'Your submitted payment proof was rejected. Please submit a valid payment proof to restore full access, or tap Help / Complaint if you need assistance.'
                              : 'Payment proof has not been submitted yet. You can browse doctor profiles in restricted mode. Submit payment proof to unlock chatting and consultations.'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: context.fs(13),
                        color: const Color(0xFF657991),
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (isPaymentPending)
                          ElevatedButton.icon(
                            icon: _isRefreshingStatus
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Icon(Icons.refresh_rounded, size: 16),
                            label: const Text('Refresh Status'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.primaryRed,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 10),
                            ),
                            onPressed: _refreshPaymentStatus,
                          )
                        else
                          ElevatedButton.icon(
                            icon: const Icon(Icons.payment_rounded, size: 16),
                            label: Text(isPaymentRejected
                                ? 'Resubmit Payment'
                                : 'Make Payment'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.primaryRed,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 10),
                            ),
                            onPressed: () async {
                              final result = await Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => const PaymentScreen(),
                                ),
                              );
                              if (result == true && mounted) {
                                await _refreshData();
                              }
                            },
                          ),
                        if (showComplaintButton) ...[
                          const SizedBox(width: 10),
                          OutlinedButton.icon(
                            icon: const Icon(Icons.help_outline_rounded, size: 16),
                            label: const Text('Help / Complaint'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFF1F2F44),
                              side: const BorderSide(color: Color(0xFFDCE6F2)),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 10),
                            ),
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => const SubmitComplaintScreen(),
                                ),
                              );
                            },
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  // --- Login Method Badge ---
  Widget _buildLoginMethodBadge(UserModel currentUser) {
    if (currentUser.isGuest) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: const Color(0xFFF1F5F9),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFFCBD5E1)),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.visibility_rounded,
              size: 13,
              color: Color(0xFF475569),
            ),
            SizedBox(width: 5),
            Text(
              'Guest',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Color(0xFF475569),
              ),
            ),
          ],
        ),
      );
    }
    final isPatientCard = currentUser.isPatientIdUser;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFFEAF2FC),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFC9DBEF)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isPatientCard ? Icons.badge_rounded : Icons.phone_rounded,
            size: 13,
            color: const Color(0xFF163B6E),
          ),
          const SizedBox(width: 5),
          Text(
            isPatientCard ? 'Patient Card' : 'Online',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: const Color(0xFF163B6E),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUserAvatar(UserModel currentUser) {
    return GestureDetector(
      onTap: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (context) => const PatientProfileScreen()),
        );
      },
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: const Color(0xFFDCE6F2), width: 2),
        ),
        child: CircleAvatar(
          radius: 20,
          backgroundColor: const Color(0xFFF0F4FA),
          backgroundImage:
              currentUser.image != null && currentUser.image!.isNotEmpty
              ? NetworkImage(currentUser.image!)
              : null,
          child: currentUser.image == null || currentUser.image!.isEmpty
              ? Text(
                  currentUser.fullname.isNotEmpty
                      ? currentUser.fullname[0].toUpperCase()
                      : 'U',
                  style: TextStyle(
                    color: AppColors.primaryRed,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                )
              : null,
        ),
      ),
    );
  }
}

// --- FAB Menu Item Widget ---
class _FABMenuItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final int badgeCount;

  const _FABMenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.badgeCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: context.sw * 0.85),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(30),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(30),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF0F233C).withValues(alpha: 0.12),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  BadgeIndicator(
                    count: badgeCount,
                    child: Icon(icon, color: AppColors.primaryRed, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: const Color(0xFF1F2F44),
                        fontSize: context.fs(13.5),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
