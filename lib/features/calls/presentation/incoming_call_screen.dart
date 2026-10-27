// lib/home_widget/chat_call/call/incoming_call.dart
// Redesigned with the Sign In screen design language (navy-blue OPD Telemedicine theme).
// Keeps the existing call state handling (Zego/FCM/CallKit wiring intact).
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/features/auth/presentation/providers/user_provider.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/core/services/incoming_call_coordinator.dart';
import 'package:telemedicine/features/calls/presentation/controllers/call_controller.dart';
import 'package:telemedicine/features/calls/presentation/call_screen.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/services/audio_service.dart';
import 'package:telemedicine/shared/widgets/auth_layout.dart';

class IncomingCallScreen extends ConsumerStatefulWidget {
  final String callId;
  final String callerName;
  final String callerImage;
  final String channelId;
  final String callType;
  final String callerId;
  final String callerType;

  /// When true the screen will automatically trigger accept flow
  /// (used when tapping "Accept" on the OS notification action button).
  final bool autoAccept;

  static bool isIncomingCallScreenOpen = false;

  const IncomingCallScreen({
    super.key,
    required this.callId,
    required this.callerName,
    required this.callerImage,
    required this.channelId,
    required this.callerId,
    this.callType = 'audio',
    this.callerType = 'doctor',
    this.autoAccept = false,
  });
  @override
  ConsumerState<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends ConsumerState<IncomingCallScreen>
    with TickerProviderStateMixin {
  final CallController _callController = CallController();

  // ── Animations (lightweight, disposed on screen close) ──────────
  late final AnimationController _avatarPulseController;
  late final Animation<double> _avatarPulse;
  late final AnimationController _ringController;
  late final Animation<double> _ringAnim;

  Timer? _autoMissTimer;
  StreamSubscription? _callStatusSub;
  bool _isProcessing = false;
  bool _isConnecting = false;
  bool _canPop = false;

  /// Latches once this screen has handed over to the Call screen. Every
  /// accept signal — the in-app button, the notification's Accept action and
  /// the Firestore `accepted` snapshot — routes through the same latch, so a
  /// call can never produce two live-call screens.
  bool _navigatedToCall = false;

  // Sign In screen color tokens
  static const Color _bg = Color(0xFFEDF2F8);
  static const Color _ink = Color(0xFF1F2F44);
  static const Color _muted = Color(0xFF657991);
  static const Color _navy = Color(0xFF062B72);
  static const Color _red = Color(0xFFE53935);

  @override
  void initState() {
    super.initState();
    IncomingCallScreen.isIncomingCallScreenOpen = true;
    IncomingCallCoordinator.instance.markScreenOpened(widget.callId);

    // Avatar breathing pulse (loops while screen is open).
    _avatarPulseController = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    )..repeat(reverse: true);
    _avatarPulse = Tween<double>(begin: 1.0, end: 1.06).animate(
      CurvedAnimation(parent: _avatarPulseController, curve: Curves.easeInOut),
    );

    // Expanding ripple ring around the avatar.
    _ringController = AnimationController(
      duration: const Duration(milliseconds: 2000),
      vsync: this,
    )..repeat();
    _ringAnim = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _ringController, curve: Curves.easeOut));

    // Auto-miss after 45 seconds
    _autoMissTimer = Timer(const Duration(seconds: 45), () {
      if (mounted && !_isProcessing && !_isConnecting) {
        ToastService.instance.showInfo('Call missed');
        _missCall();
      }
    });
    _listenForCallCancel();
    // Start ringtone after short delay
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) _startRinging();
    });
    // If autoAccept → start accepting immediately
    if (widget.autoAccept) {
      Future.delayed(const Duration(milliseconds: 600), () {
        if (mounted && !_isProcessing) _acceptCall();
      });
    }
  }

  // ── Animation helpers ──────────────────────────────────────────
  void _stopAnimations() {
    _avatarPulseController
      ..stop()
      ..reset();
    _ringController
      ..stop()
      ..reset();
  }

  // ── Ringtone ──────────────────────────────────────────────────
  Future<void> _startRinging() async {
    // Idempotent: the notification presenter starts the ringtone the moment
    // the call notification is posted, so this may already be ringing.
    await SystemRingtonePlayer.playDefaultRingtone();
  }

  Future<void> _stopRinging() async {
    // Always forwarded, never gated on local state: the presenter may have
    // started the ringtone before this screen existed, and dispose must
    // never leave it looping.
    await SystemRingtonePlayer.stopDefaultRingtone();
  }

  // ── Call Status Listener ───────────────────────────────────────
  //
  // Two jobs:
  //  1. Close the screen when the call reaches a terminal state (caller
  //     cancelled, ring timeout elapsed, declined on another surface).
  //  2. Hand over to the live Call screen when the call becomes `accepted`
  //     *without* this screen having done it — i.e. the Accept button on the
  //     notification, or the background isolate applying the transition. Both
  //     go through the same coordinator accept, so this is the same handover
  //     as the in-app Accept button and cannot fire twice.
  void _listenForCallCancel() {
    _callStatusSub = _callController.watchCall(widget.callId).listen((call) {
      if (call == null || !mounted) return;
      debugPrint('📞 Call status from Firestore: ${call.callStatus}');

      if (call.callStatus == CallStatus.accepted) {
        if (!_isProcessing && !_navigatedToCall) {
          _handoverToCallScreen('remote accept');
        }
        return;
      }

      if (CallStatus.isTerminal(call.callStatus)) {
        _stopAnimations();
        _stopRinging();
        // One dismissal path for every terminal state, whether it was caused by
        // the caller hanging up, the ring timeout or this device answering
        // elsewhere.
        IncomingCallCoordinator.instance.dismissNotification(widget.callId);
        if (mounted && !_isProcessing && !_isConnecting) {
          setState(() {
            _canPop = true;
          });
          Navigator.of(context).pop();
        }
      }
    });
  }

  /// Replaces this screen with the live Call screen. Guarded by
  /// [_navigatedToCall] so the handover happens exactly once no matter how many
  /// signals say "accepted".
  Future<void> _handoverToCallScreen(String reason) async {
    if (_navigatedToCall) return;
    _navigatedToCall = true;

    debugPrint(
      '📞 IncomingCallScreen → CallScreen (${reason}) callId=${widget.callId}',
    );
    _stopAnimations();
    await _stopRinging();
    _autoMissTimer?.cancel();
    _callStatusSub?.cancel();
    IncomingCallCoordinator.instance.dismissNotification(widget.callId);

    final currentUserId = await _resolveCurrentUserId();
    if (!mounted) return;
    if (currentUserId.isEmpty) {
      setState(() {
        _isProcessing = false;
        _isConnecting = false;
      });
      ToastService.instance.showError('User not logged in');
      return;
    }

    _canPop = true;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        settings: const RouteSettings(name: '/call_screen'),
        builder: (_) => CallScreen(
          channelId: widget.channelId,
          callId: widget.callId,
          callType: widget.callType,
          otherUserName: widget.callerName,
          otherUserImage: widget.callerImage,
          currentUserId: currentUserId,
          otherUserId: widget.callerId,
          otherUserType: widget.callerType,
          isCaller: false,
        ),
      ),
    );
  }

  // ── Accept ────────────────────────────────────────────────────
  //
  // Resolves the signed-in user, then hands the transition to
  // [IncomingCallCoordinator] — the *same* entry point the notification's
  // Accept button uses. The screen does not talk to Firestore or Zego
  // directly, which is what makes a double press, a stale Firestore snapshot
  // and a notification action impossible to apply twice.
  Future<void> _acceptCall() async {
    if (_isProcessing || _isConnecting) return;
    debugPrint(
      '📞 Accept pressed on IncomingCallScreen callId=${widget.callId} '
      'caller=${widget.callerName}',
    );
    setState(() {
      _isProcessing = true;
      _isConnecting = true;
    });
    _stopAnimations();
    await _stopRinging();
    _autoMissTimer?.cancel();
    _callStatusSub?.cancel();

    final currentUserId = await _resolveCurrentUserId();
    if (currentUserId.isEmpty) {
      ToastService.instance.showError('User not logged in');
      if (mounted) {
        setState(() {
          _canPop = true;
          _isProcessing = false;
          _isConnecting = false;
        });
        Navigator.of(context).pop();
      }
      return;
    }

    // The notification is dismissed by the coordinator as part of accepting, so
    // the tray and the screen can never disagree.
    final outcome = await IncomingCallCoordinator.instance.accept(
      widget.callId,
    );

    if (!outcome.handled) {
      debugPrint('⚠️ Accept ignored for ${widget.callId}: ${outcome.reason}');
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _isConnecting = false;
        });
        ToastService.instance.showError('This call is no longer available.');
      }
      return;
    }

    if (!mounted) return;
    await _handoverToCallScreen('in-app accept');
  }

  // ── Reject ────────────────────────────────────────────────────
  Future<void> _rejectCall() async {
    if (_isProcessing || _isConnecting) return;
    debugPrint('📞 Decline pressed on IncomingCallScreen callId=${widget.callId}');
    setState(() => _isProcessing = true);
    _stopAnimations();
    await _stopRinging();
    _autoMissTimer?.cancel();
    _callStatusSub?.cancel();

    final outcome = await IncomingCallCoordinator.instance.decline(
      widget.callId,
    );
    debugPrint(
      outcome.handled
          ? '📞 Call declined: ${widget.callId}'
          : '⚠️ Decline ignored for ${widget.callId}: ${outcome.reason}',
    );

    if (mounted) {
      setState(() => _canPop = true);
      Navigator.of(context).pop();
    }
  }

  // ── Miss ──────────────────────────────────────────────────────
  Future<void> _missCall() async {
    if (_isProcessing || _isConnecting) return;
    _isProcessing = true;
    _stopAnimations();
    await _stopRinging();
    _callStatusSub?.cancel();
    // A timed-out ring is a terminal state: clear the claim so the *next* call
    // from this caller is not mistaken for a replay of this one.
    await IncomingCallCoordinator.instance.clearCallRecord(widget.callId);
    IncomingCallCoordinator.instance.dismissNotification(widget.callId);
    try {
      await _callController.missCall(widget.callId);
    } catch (e) {
      debugPrint('Error marking call as missed: $e');
    }
    if (mounted) {
      setState(() => _canPop = true);
      Navigator.of(context).pop();
    }
  }

  /// Resolves the signed-in id from the Riverpod session, falling back to the
  /// persisted patient/doctor session blobs.
  Future<String> _resolveCurrentUserId() async {
    final fromProvider = ref.read(userProvider)?.id;
    if (fromProvider != null && fromProvider.isNotEmpty) return fromProvider;
    return IncomingCallCoordinator.instance.resolveCurrentUserId();
  }

  @override
  void dispose() {
    IncomingCallScreen.isIncomingCallScreenOpen = false;
    IncomingCallCoordinator.instance.markScreenClosed(widget.callId);
    _stopRinging();
    _autoMissTimer?.cancel();
    _callStatusSub?.cancel();
    _avatarPulseController.dispose();
    _ringController.dispose();
    super.dispose();
  }

  // ── UI ────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _canPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_isProcessing && !_isConnecting) {
          _rejectCall();
        }
      },
      child: Scaffold(
        backgroundColor: _bg,
        body: SizedBox.expand(
          child: Stack(
            children: [
              // ECG Waveform Watermark (Top Right) — Sign In screen treatment.
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
              Positioned.fill(
                child: SafeArea(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final maxHeight = constraints.maxHeight;
                      return SingleChildScrollView(
                        physics: const BouncingScrollPhysics(),
                        child: Center(
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              minHeight: maxHeight,
                              maxWidth: context.contentMaxWidth,
                            ),
                            child: Column(
                              mainAxisAlignment:
                                  MainAxisAlignment.spaceBetween,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.only(top: 12),
                                  child: Column(
                                    children: const [
                                      // OPD Telemedicine branding.
                                      LogoCard(),
                                      SizedBox(height: 14),
                                    ],
                                  ),
                                ),
                                _buildCallTypeLabel(),
                                _buildAvatarWithRing(),
                                _buildCallerInfo(),
                                Padding(
                                  padding: EdgeInsets.only(
                                    bottom: context.rsp(24),
                                  ),
                                  child: _buildActionButtons(),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCallTypeLabel() {
    final isVideo = widget.callType == 'video';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Colors.white, Color(0xFFF5F8FC)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: const Color(0xFFDCE6F2)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF12263F).withValues(alpha: 0.10),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isVideo ? Icons.videocam_rounded : Icons.call_rounded,
            color: _navy,
            size: 18,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              isVideo ? 'Incoming Video Call' : 'Incoming Audio Call',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: const Color(0xFF163B6E),
                fontSize: context.fs(14),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAvatarWithRing() {
    final hasImage = widget.callerImage.isNotEmpty;
    final initial = widget.callerName.isNotEmpty
        ? widget.callerName[0].toUpperCase()
        : '?';
    final boxSize = (210 * (context.sw / 360)).clamp(168.0, 210.0);
    final avatarSize = boxSize * 132 / 210;
    return SizedBox(
      width: boxSize,
      height: boxSize,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Expanding ripple ring.
          AnimatedBuilder(
            animation: _ringAnim,
            builder: (_, __) {
              final ringSize =
                  avatarSize + ((boxSize - avatarSize - 6) * _ringAnim.value);
              return Container(
                width: ringSize,
                height: ringSize,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: _navy.withValues(
                      alpha: (1 - _ringAnim.value) * 0.35,
                    ),
                    width: 2,
                  ),
                ),
              );
            },
          ),
          // Breathing avatar with navy ring (same bevel language as inputs).
          AnimatedBuilder(
            animation: _avatarPulse,
            builder: (_, child) => Transform.scale(
              scale: _avatarPulse.value,
              child: Container(
                width: avatarSize,
                height: avatarSize,
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [
                      Color(0xFFE3EAF2),
                      Color(0xFFF5F8FC),
                      Color(0xFFE2E9F2),
                    ],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ),
                  borderRadius: BorderRadius.circular(avatarSize / 2),
                  border: Border.all(color: const Color(0xFFB9C6D8), width: 2),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF0F233C).withValues(alpha: 0.16),
                      blurRadius: 24,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(
                      colors: [
                        Color(0xFF284F85),
                        Color(0xFF15386A),
                        Color(0xFF0D264E),
                      ],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    ),
                    border: Border.all(
                      color: const Color(0xFF132D56),
                      width: 2,
                    ),
                  ),
                  child: ClipOval(
                    child: hasImage
                        ? Image.network(
                            widget.callerImage,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) =>
                                _buildAvatarFallback(initial),
                          )
                        : _buildAvatarFallback(initial),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAvatarFallback(String initial) {
    return Center(
      child: Text(
        initial,
        style: TextStyle(
          fontSize: context.fs(32),
          fontWeight: FontWeight.bold,
          color: Colors.white,
        ),
      ),
    );
  }

  Widget _buildCallerInfo() {
    final role = _resolveRole(widget.callerType);
    return Column(
      children: [
        Text(
          widget.callerName,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: context.fs(22),
            fontWeight: FontWeight.bold,
            color: _ink,
            letterSpacing: -0.5,
          ),
        ),
        if (role != null) ...[const SizedBox(height: 8), _buildRoleChip(role)],
        const SizedBox(height: 12),
        Text(
          _isConnecting ? 'Connecting...' : 'is calling you...',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: context.fs(14),
            fontWeight: FontWeight.w500,
            color: _muted,
          ),
        ),
      ],
    );
  }

  String? _resolveRole(String type) {
    if (type == 'doctor') return 'Doctor';
    if (type == 'patient') return 'Patient';
    return null;
  }

  Widget _buildRoleChip(String role) {
    final isDoctor = role == 'Doctor';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFFF0F4FA),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFDCE6F2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isDoctor ? Icons.medical_services_rounded : Icons.person_rounded,
            size: 15,
            color: _navy,
          ),
          const SizedBox(width: 6),
          Text(
            role,
            style: TextStyle(
              fontSize: context.fs(12),
              fontWeight: FontWeight.w600,
              color: const Color(0xFF163B6E),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButtons() {
    final disabled = _isProcessing || _isConnecting;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: context.rsp(24)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _SlideActionButton(
            icon: widget.callType == 'video'
                ? Icons.videocam_rounded
                : Icons.call_rounded,
            label: _isConnecting ? 'Connecting...' : 'Slide to Answer',
            baseColor: const Color(0xFF284F85),
            gradient: const [
              Color(0xFF284F85),
              Color(0xFF15386A),
              Color(0xFF0D264E),
              Color(0xFF081938),
            ],
            isLoading: _isConnecting,
            onComplete: disabled ? null : _acceptCall,
          ),
          const SizedBox(height: 20),
          _SlideActionButton(
            icon: Icons.call_end_rounded,
            label: 'Slide to Decline',
            baseColor: _red,
            gradient: const [Color(0xFFF64E4E), Color(0xFFD32F2F)],
            onComplete: disabled ? null : _rejectCall,
          ),
        ],
      ),
    );
  }
}

class _SlideActionButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final Color baseColor;
  final List<Color> gradient;
  final VoidCallback? onComplete;
  final bool isLoading;

  const _SlideActionButton({
    required this.icon,
    required this.label,
    required this.baseColor,
    required this.gradient,
    required this.onComplete,
    this.isLoading = false,
  });

  @override
  _SlideActionButtonState createState() => _SlideActionButtonState();
}

class _SlideActionButtonState extends State<_SlideActionButton>
    with TickerProviderStateMixin {
  static const double _buttonSize = 64.0;
  static const double _armThreshold = 0.75;
  static const double _disarmThreshold = 0.5;

  late final AnimationController _snapController;
  late final AnimationController _fxController;

  double _drag = 0.0;
  double _maxDrag = 0.0;
  double _fxStart = 0.0;
  bool _completed = false;
  bool _armed = false;
  bool _pressed = false;

  bool get _interactive =>
      !_completed && !widget.isLoading && widget.onComplete != null;

  @override
  void initState() {
    super.initState();
    _snapController =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 320),
        )..addListener(() {
          // Snap-back drag follows the animation tick 1:1.
          if (!mounted) return;
          setState(() {
            _drag = _snapController.value * _maxDrag;
          });
        });
    _fxController =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 420),
        )..addListener(() {
          // Completion slam: glide thumb to the end + ripple/thumb pop.
          if (!mounted) return;
          setState(() {
            final t = _fxController.value;
            if (t >= 1.0) {
              _drag = _maxDrag;
            } else {
              _drag =
                  _fxStart +
                  (_maxDrag - _fxStart) * Curves.easeOutCubic.transform(t);
            }
          });
        });
  }

  @override
  void dispose() {
    _snapController.dispose();
    _fxController.dispose();
    super.dispose();
  }

  void _onPanStart(DragStartDetails details, double maxDrag) {
    if (!_interactive) return;
    // Captured here, in the gesture phase, never during build/layout.
    _maxDrag = maxDrag;
    setState(() => _pressed = true);
  }

  void _onPanUpdate(DragUpdateDetails details, double maxDrag) {
    if (!_interactive) return;
    final next = (_drag + details.delta.dx).clamp(0.0, maxDrag);
    final progress = maxDrag <= 0 ? 0.0 : next / maxDrag;
    setState(() {
      _drag = next;
      // Soft haptic tick the moment the control becomes "armed".
      if (progress >= _armThreshold && !_armed) {
        _armed = true;
        HapticFeedback.selectionClick();
      } else if (progress < _disarmThreshold && _armed) {
        _armed = false;
      }
    });
  }

  void _onPanEnd(DragEndDetails details, double maxDrag) {
    if (!_interactive) return;
    setState(() => _pressed = false);
    if (maxDrag <= 0) return;
    if (_drag >= maxDrag * _armThreshold) {
      _complete(maxDrag);
    } else {
      _armed = false;
      _snapController
        ..stop()
        ..value = (_drag / maxDrag).clamp(0.0, 1.0);
      _snapController.animateTo(0.0, curve: Curves.easeOutCubic);
    }
  }

  void _onPanCancel() {
    if (!_interactive) return;
    setState(() {
      _pressed = false;
      _armed = false;
    });
    if (_maxDrag > 0) {
      _snapController
        ..stop()
        ..value = (_drag / _maxDrag).clamp(0.0, 1.0);
      _snapController.animateTo(0.0, curve: Curves.easeOutCubic);
    }
  }

  void _complete(double maxDrag) {
    _fxStart = _drag;
    setState(() {
      // Lock the control immediately so the action can never fire twice.
      _completed = true;
      _pressed = false;
      _armed = false;
    });
    HapticFeedback.heavyImpact();
    _fxController.forward(from: 0);
    widget.onComplete?.call();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        final maxDrag = maxWidth - _buttonSize;
        final progress = maxDrag <= 0 ? 0.0 : (_drag / maxDrag).clamp(0.0, 1.0);
        final disabled = !_interactive;
        final labelOpacity = (1.0 - progress * 1.6).clamp(0.0, 1.0);
        final labelColor = disabled
            ? const Color(0xFF7E90A6)
            : widget.baseColor;

        var thumbScale = _pressed ? 0.94 : (_armed ? 1.06 : 1.0);
        final fx = _fxController.value;
        if (_completed) {
          thumbScale *= 1 + 0.28 * math.sin(math.pi * fx);
        }
        final fillGradient = disabled
            ? const [Color(0xFF93A6BD), Color(0xFF6C7D92)]
            : widget.gradient;

        return IgnorePointer(
          ignoring: disabled,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (details) => _onPanStart(details, maxDrag),
            onPanUpdate: (details) => _onPanUpdate(details, maxDrag),
            onPanEnd: (details) => _onPanEnd(details, maxDrag),
            onPanCancel: _onPanCancel,
            child: Container(
              height: _buttonSize,
              decoration: BoxDecoration(
                color: widget.baseColor.withValues(
                  alpha: disabled ? 0.06 : 0.10,
                ),
                borderRadius: BorderRadius.circular(_buttonSize / 2),
                border: Border.all(
                  color: widget.baseColor.withValues(
                    alpha: disabled ? 0.16 : 0.28,
                  ),
                ),
              ),
              child: Stack(
                children: [
                  // Filled progress track following the thumb.
                  if (_drag > 0.5)
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      width: _buttonSize + _drag,
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(_buttonSize / 2),
                          gradient: LinearGradient(
                            colors: disabled
                                ? [
                                    const Color(
                                      0xFF93A6BD,
                                    ).withValues(alpha: 0.20),
                                    const Color(
                                      0xFF93A6BD,
                                    ).withValues(alpha: 0.34),
                                  ]
                                : [
                                    widget.baseColor.withValues(alpha: 0.16),
                                    widget.baseColor.withValues(alpha: 0.34),
                                  ],
                          ),
                        ),
                      ),
                    ),
                  // Armed pulse ring behind the thumb.
                  if (_armed)
                    Positioned(
                      left: _drag - 6,
                      top: -6,
                      child: Container(
                        width: _buttonSize + 12,
                        height: _buttonSize + 12,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: widget.baseColor.withValues(alpha: 0.35),
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                  // Direction hint chevron at the end of the track.
                  Positioned(
                    right: 22,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: Icon(
                        Icons.chevron_right_rounded,
                        color: disabled
                            ? const Color(0xFF7E90A6)
                            : widget.baseColor.withValues(alpha: 0.45),
                        size: 28,
                      ),
                    ),
                  ),
                  // Centered label (fades + shifts as the finger approaches the end).
                  Center(
                    child: Opacity(
                      opacity: labelOpacity,
                      child: Transform.translate(
                        offset: Offset(-(progress * 36), 0),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                widget.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: labelColor,
                                  fontSize: context.fs(14),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            if (!disabled && !widget.isLoading)
                              Icon(
                                Icons.chevron_right_rounded,
                                color: labelColor,
                                size: 18,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // Completion ripple expanding from the thumb.
                  if (_completed)
                    Positioned(
                      left: _drag + _buttonSize / 2 - (rippleSize(fx) / 2),
                      top: _buttonSize / 2 - (rippleSize(fx) / 2),
                      child: IgnorePointer(
                        child: Container(
                          width: rippleSize(fx),
                          height: rippleSize(fx),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.white.withValues(
                                alpha: (1 - fx) * 0.6,
                              ),
                              width: 2,
                            ),
                          ),
                        ),
                      ),
                    ),
                  // Draggable thumb.
                  Positioned(
                    left: _drag,
                    top: 0,
                    child: Transform.scale(
                      scale: thumbScale,
                      child: Container(
                        width: _buttonSize,
                        height: _buttonSize,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            colors: fillGradient,
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          border: Border.all(
                            color: disabled
                                ? const Color(0xFFB9C6D8)
                                : Colors.white.withValues(alpha: 0.25),
                            width: 1.5,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: disabled
                                  ? Colors.black12
                                  : widget.baseColor.withValues(
                                      alpha: 0.45 + (progress * 0.35),
                                    ),
                              blurRadius: 8 + (progress * 18),
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Center(
                          child: widget.isLoading && _completed
                              ? const SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(
                                    color: Colors.white,
                                    strokeWidth: 2,
                                  ),
                                )
                              : Icon(
                                  widget.icon,
                                  color: Colors.white,
                                  size: 28,
                                ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  double rippleSize(double fx) =>
      (_buttonSize + fx * 72).clamp(0.0, double.infinity);
}
