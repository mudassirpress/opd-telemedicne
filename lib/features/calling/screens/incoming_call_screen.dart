// lib/features/calling/screens/incoming_call_screen.dart

import 'dart:async';
import 'dart:math' as math;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/core/services/auth_routing_service.dart';
import 'package:telemedicine/core/services/incoming_call_coordinator.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/features/calling/controllers/call_controller.dart';
import 'package:telemedicine/features/calling/domain/call_status.dart';
import 'package:telemedicine/features/calling/screens/active_call_screen.dart';
import 'package:telemedicine/features/calling/services/call_audio_service.dart';
import 'package:telemedicine/shared/widgets/auth_layout.dart';

class IncomingCallScreen extends StatefulWidget {
  final String callId;
  final String roomId;
  final String callerId;
  final String callerName;
  final String callerRole;
  final String? callerImage;
  final String currentUserId;
  final String currentUserName;

  const IncomingCallScreen({
    super.key,
    required this.callId,
    required this.roomId,
    required this.callerId,
    required this.callerName,
    required this.callerRole,
    this.callerImage,
    required this.currentUserId,
    required this.currentUserName,
  });

  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen>
    with TickerProviderStateMixin {
  final CallController _callController = CallController.instance;
  final CallAudioService _audioService = CallAudioService.instance;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _statusSub;
  bool _isProcessingAction = false;
  bool _isClosed = false;
  bool _hasError = false;
  String? _statusText;
  String? _errorMessage;

  // ── Animations (same as first screen) ──────────────────────────
  late final AnimationController _avatarPulseController;
  late final Animation<double> _avatarPulse;
  late final AnimationController _ringController;
  late final Animation<double> _ringAnim;

  // Sign In screen color tokens (first screen)
  static const Color _bg = Color(0xFFEDF2F8);
  static const Color _ink = Color(0xFF1F2F44);
  static const Color _muted = Color(0xFF657991);
  static const Color _navy = Color(0xFF062B72);
  static const Color _red = Color(0xFFE53935);

  @override
  void initState() {
    super.initState();
    IncomingCallCoordinator.instance.markScreenOpened(widget.callId);

    // Avatar breathing pulse
    _avatarPulseController = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    )..repeat(reverse: true);
    _avatarPulse = Tween<double>(begin: 1.0, end: 1.06).animate(
      CurvedAnimation(parent: _avatarPulseController, curve: Curves.easeInOut),
    );

    // Expanding ripple ring
    _ringController = AnimationController(
      duration: const Duration(milliseconds: 2000),
      vsync: this,
    )..repeat();
    _ringAnim = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _ringController, curve: Curves.easeOut));

    // Start ringtone loop & vibration
    _audioService.startRingtone(
      timeout: const Duration(seconds: 45),
      onTimeout: _handleTimeout,
    );

    // Watch Firestore document for caller cancellation
    _watchCallDocument();
  }

  void _watchCallDocument() {
    final trimmedId = widget.callId.trim();
    if (trimmedId.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _handleError('Invalid incoming call session.');
      });
      return;
    }

    _statusSub = FirebaseFirestore.instance
        .collection(FirestoreCollections.calls)
        .doc(trimmedId)
        .snapshots()
        .listen(
          (snapshot) {
            if (!mounted || _isClosed) return;

            if (!snapshot.exists || snapshot.data() == null) {
              _setTerminationState(
                status: 'Call Ended',
                message: 'This call session is no longer active.',
                isError: false,
              );
              return;
            }

            final data = snapshot.data()!;
            final status = (data['callStatus'] ?? data['status'])
                ?.toString()
                .toLowerCase()
                .trim();
            final endReason = data['endReason']?.toString();
            final docError = data['error']?.toString();

            if (status == CallingStatus.accepted ||
                status == CallingStatus.connected) {
              debugPrint('📞 [IncomingCallScreen] Detected $status in Firestore -> transitioning to active call');
              _acceptCall();
              return;
            }

            if (status == CallingStatus.cancelled) {
              _setTerminationState(
                status: 'Call Cancelled',
                message: 'The caller cancelled the call.',
                isError: false,
              );
            } else if (status == CallingStatus.missed) {
              _setTerminationState(
                status: 'Missed Call',
                message: 'Incoming call timed out.',
                isError: false,
              );
            } else if (status == CallingStatus.ended) {
              _setTerminationState(
                status: 'Call Ended',
                message: endReason != null ? 'Call ended ($endReason)' : 'Call ended.',
                isError: false,
              );
            } else if (status == CallingStatus.rejected) {
              _setTerminationState(
                status: 'Call Declined',
                message: 'Call declined.',
                isError: false,
              );
            } else if (status == CallingStatus.failed) {
              _setTerminationState(
                status: 'Call Failed',
                message: docError ?? endReason ?? 'Call connection failed.',
                isError: true,
              );
            }
          },
          onError: (e) {
            debugPrint('⚠️ [IncomingCallScreen] Firestore stream error: $e');
            _handleError('Connection error: $e');
          },
        );
  }

  void _handleTimeout() {
    if (!mounted || _isClosed) return;
    _setTerminationState(
      status: 'Missed Call',
      message: 'Call timed out with no answer.',
      isError: false,
    );
  }

  void _handleError(String message) {
    if (!mounted || _isClosed) return;
    _isClosed = true;
    _stopAnimations();
    _statusSub?.cancel();
    _audioService.stopRingtone();
    IncomingCallCoordinator.instance.dismissNotification(widget.callId);

    setState(() {
      _hasError = true;
      _statusText = 'Call Error';
      _errorMessage = message;
      _isProcessingAction = false;
    });

    ToastService.instance.showError(message);

    Future.delayed(const Duration(milliseconds: 1800), () {
      _dismissCall();
    });
  }

  void _setTerminationState({
    required String status,
    String? message,
    required bool isError,
  }) {
    if (!mounted || _isClosed) return;
    _isClosed = true;
    _stopAnimations();
    _statusSub?.cancel();
    _audioService.stopRingtone();
    IncomingCallCoordinator.instance.dismissNotification(widget.callId);

    setState(() {
      _hasError = isError;
      _statusText = status;
      _errorMessage = message;
      _isProcessingAction = false;
    });

    if (message != null) {
      if (isError) {
        ToastService.instance.showError(message);
      } else {
        ToastService.instance.showInfo(message);
      }
    }

    Future.delayed(const Duration(milliseconds: 1600), () {
      _dismissCall();
    });
  }

  void _dismissCall() {
    _statusSub?.cancel();
    _audioService.stopRingtone();
    IncomingCallCoordinator.instance.dismissNotification(widget.callId);
    if (mounted) {
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      } else {
        AuthRoutingService.routeToAppropriatePortal(context);
      }
    }
  }

  // ── Animations helpers ─────────────────────────────────────────
  void _stopAnimations() {
    try {
      if (_avatarPulseController.isAnimating) {
        _avatarPulseController.stop();
      }
      if (_ringController.isAnimating) {
        _ringController.stop();
      }
    } catch (_) {}
  }

  // ── Accept (logic same as before, design only changed) ────────
  Future<void> _acceptCall() async {
    if (_isProcessingAction || _isClosed) return;
    setState(() => _isProcessingAction = true);
    _stopAnimations();

    _statusSub?.cancel();
    await _audioService.stopRingtone();
    await IncomingCallCoordinator.instance.dismissNotification(widget.callId);

    try {
      final success = await _callController.acceptCall(
        widget.callId,
        userId: widget.currentUserId,
        userName: widget.currentUserName,
      );

      if (!mounted) return;

      if (success) {
        _isClosed = true;
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => ActiveCallScreen(
              callId: widget.callId,
              roomId: widget.roomId,
              otherUserId: widget.callerId,
              otherUserName: widget.callerName,
              otherUserRole: widget.callerRole,
              otherUserImage: widget.callerImage,
              currentUserId: widget.currentUserId,
              currentUserName: widget.currentUserName,
              isCaller: false,
            ),
          ),
        );
      } else {
        _handleError(
          'Could not connect to call. Please check microphone permissions.',
        );
      }
    } catch (e) {
      debugPrint('⚠️ [IncomingCallScreen] acceptCall error: $e');
      _handleError('Connection failed: $e');
    } finally {
      if (mounted && !_isClosed) {
        setState(() => _isProcessingAction = false);
      }
    }
  }

  // ── Reject (logic same) ────────────────────────────────────────
  Future<void> _rejectCall() async {
    if (_isProcessingAction || _isClosed) return;
    setState(() => _isProcessingAction = true);
    _stopAnimations();

    _statusSub?.cancel();
    await _audioService.stopRingtone();
    await IncomingCallCoordinator.instance.dismissNotification(widget.callId);

    try {
      await _callController.rejectCall(
        widget.callId,
        rejectedBy: widget.currentUserId,
      );
    } catch (e) {
      debugPrint('⚠️ [IncomingCallScreen] rejectCall error: $e');
    } finally {
      _setTerminationState(
        status: 'Call Declined',
        message: 'You declined the call.',
        isError: false,
      );
    }
  }

  @override
  void dispose() {
    IncomingCallCoordinator.instance.markScreenClosed(widget.callId);
    _statusSub?.cancel();
    _audioService.stopRingtone();
    _avatarPulseController.dispose();
    _ringController.dispose();
    super.dispose();
  }

  // ── UI (first screen design language) ──────────────────────────
  @override
  Widget build(BuildContext context) {
    final roleLabel = widget.callerRole.toLowerCase() == 'doctor'
        ? 'Doctor'
        : 'Patient';

    return PopScope(
      canPop: _isClosed,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_isProcessingAction && !_isClosed) {
          _rejectCall();
        }
      },
      child: Scaffold(
        backgroundColor: _bg,
        body: SizedBox.expand(
          child: Stack(
            children: [
              // ECG Waveform Watermark (Top Right) — Sign In treatment
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
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.only(top: 12),
                                  child: Column(
                                    children: const [
                                      // OPD Telemedicine branding
                                      LogoCard(),
                                      SizedBox(height: 14),
                                    ],
                                  ),
                                ),
                                _buildCallTypeLabel(),
                                _buildAvatarWithRing(),
                                _buildCallerInfo(roleLabel),
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
    final isTerminated = _statusText != null;
    final badgeColor = _hasError
        ? const Color(0xFFD32F2F)
        : (isTerminated ? const Color(0xFF15386A) : _navy);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: _hasError
              ? [const Color(0xFFFFEBEE), const Color(0xFFFFCDD2)]
              : (isTerminated
                  ? [const Color(0xFFF0F4FA), const Color(0xFFE2E9F4)]
                  : [Colors.white, const Color(0xFFF5F8FC)]),
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(
          color: _hasError ? const Color(0xFFEF9A9A) : const Color(0xFFDCE6F2),
        ),
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
            _hasError
                ? Icons.error_outline_rounded
                : (isTerminated ? Icons.call_end_rounded : Icons.call_rounded),
            color: badgeColor,
            size: 18,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              _statusText ?? 'Incoming Voice Call',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: badgeColor,
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
    final hasImage =
        widget.callerImage != null && widget.callerImage!.isNotEmpty;
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
          // Expanding ripple ring
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
          // Breathing avatar with navy ring
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
                            widget.callerImage!,
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

  Widget _buildCallerInfo(String role) {
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
        const SizedBox(height: 8),
        _buildRoleChip(role),
        const SizedBox(height: 12),
        if (_statusText != null || _errorMessage != null) ...[
          Text(
            _statusText ?? 'Call Error',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: context.fs(15),
              fontWeight: FontWeight.w600,
              color: _hasError ? _red : const Color(0xFF15386A),
            ),
          ),
          if (_errorMessage != null && _errorMessage != _statusText) ...[
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: context.fs(12.5),
                  fontWeight: FontWeight.w500,
                  color: _hasError ? const Color(0xFFD32F2F) : _muted,
                ),
              ),
            ),
          ],
        ] else
          Text(
            _isProcessingAction ? 'Connecting...' : 'is calling you...',
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
    if (_isClosed || _statusText != null || _hasError) {
      return Padding(
        padding: EdgeInsets.symmetric(horizontal: context.rsp(24)),
        child: SizedBox(
          width: double.infinity,
          height: 52,
          child: ElevatedButton.icon(
            onPressed: _dismissCall,
            style: ElevatedButton.styleFrom(
              backgroundColor: _hasError ? _red : const Color(0xFF15386A),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
              ),
              elevation: 4,
            ),
            icon: const Icon(Icons.close_rounded, size: 20),
            label: const Text(
              'Dismiss',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      );
    }

    final disabled = _isProcessingAction;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: context.rsp(24)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _SlideActionButton(
            icon: Icons.call_rounded,
            label: _isProcessingAction ? 'Connecting...' : 'Slide to Answer',
            baseColor: const Color(0xFF284F85),
            gradient: const [
              Color(0xFF284F85),
              Color(0xFF15386A),
              Color(0xFF0D264E),
              Color(0xFF081938),
            ],
            isLoading: _isProcessingAction,
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

// ─────────────────────────────────────────────────────────────
// Slide action button (copied as-is from first file's design)
// ─────────────────────────────────────────────────────────────
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
    _maxDrag = maxDrag;
    setState(() => _pressed = true);
  }

  void _onPanUpdate(DragUpdateDetails details, double maxDrag) {
    if (!_interactive) return;
    final next = (_drag + details.delta.dx).clamp(0.0, maxDrag);
    final progress = maxDrag <= 0 ? 0.0 : next / maxDrag;
    setState(() {
      _drag = next;
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
