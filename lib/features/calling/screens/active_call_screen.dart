// lib/features/calling/screens/active_call_screen.dart

import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/core/services/auth_routing_service.dart';
import 'package:telemedicine/core/services/call_session_manager.dart';
import 'package:telemedicine/core/services/incoming_call_coordinator.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/features/calling/controllers/call_controller.dart';
import 'package:telemedicine/features/calling/domain/call_status.dart';
import 'package:telemedicine/features/calling/services/call_audio_service.dart';
import 'package:telemedicine/features/calling/services/zego_call_service.dart';
import 'package:telemedicine/features/calling/widgets/call_avatar.dart';
import 'package:telemedicine/features/calling/widgets/call_controls.dart';
import 'package:telemedicine/features/calling/widgets/call_timer.dart';
import 'package:telemedicine/shared/widgets/auth_layout.dart';

class ActiveCallScreen extends StatefulWidget {
  final String callId;
  final String roomId;
  final String otherUserId;
  final String otherUserName;
  final String otherUserRole;
  final String? otherUserImage;
  final String currentUserId;
  final String currentUserName;
  final bool isCaller;

  const ActiveCallScreen({
    super.key,
    required this.callId,
    required this.roomId,
    required this.otherUserId,
    required this.otherUserName,
    required this.otherUserRole,
    this.otherUserImage,
    required this.currentUserId,
    required this.currentUserName,
    required this.isCaller,
  });

  @override
  State<ActiveCallScreen> createState() => _ActiveCallScreenState();
}

class _ActiveCallScreenState extends State<ActiveCallScreen> {
  final CallController _callController = CallController.instance;
  final ZegoCallService _zegoService = ZegoCallService.instance;
  final CallAudioService _audioService = CallAudioService.instance;

  bool _isMuted = false;
  bool _isSpeakerOn = false;
  bool _isBluetoothOn = false;
  bool _isTogglingMute = false;
  bool _isTogglingSpeaker = false;
  bool _isEnding = false;
  bool _hasEnded = false;
  bool _hasError = false;
  String? _errorMessage;
  String? _statusText;
  int _duration = 0;
  String _connectionStatusText = 'Connected';
  Color _connectionStatusColor = const Color(0xFF1E8E5A);
  Timer? _reconnectWatchdogTimer;
  bool _showReconnectAction = false;

  // 15-minute (900 seconds) duration limit enforcement
  static const int maxCallDurationSeconds = 900;
  Timer? _countdownTimer;
  int _remainingSeconds = maxCallDurationSeconds;
  bool _hasShownWarning = false;

  StreamSubscription<int>? _durationSub;
  StreamSubscription<ZegoCallConnectionStatus>? _connectionSub;
  StreamSubscription<Map<String, dynamic>>? _qualitySub;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _firestoreCallSub;

  static const List<Color> _backgroundGradient = [
    Color(0xFF062B72),
    Color(0xFF0C2959),
    Color(0xFF091C3E),
    Color(0xFF040E21),
  ];

  @override
  void initState() {
    super.initState();

    final trimmedId = widget.callId.trim();
    if (trimmedId.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _handleError('Invalid active call session.');
      });
      return;
    }

    _startSessionTracking();

    _callController.cancelRingTimeout();
    _callController.markCallConnected(widget.callId);

    // Ensure call duration timer is active upon entering active call
    _duration = _callController.callDuration;
    if (!_callController.isDurationTimerRunning) {
      _callController.startCallDurationTimer();
    }

    _startCallCountdownTimer();

    _subscribeToStreams();
  }

  void _startSessionTracking() {
    CallSessionManager.instance.startSession(
      callId: widget.callId,
      channelId: widget.roomId,
      callType: 'audio',
      otherUserName: widget.otherUserName,
      otherUserImage: widget.otherUserImage ?? '',
      currentUserId: widget.currentUserId,
      otherUserId: widget.otherUserId,
      otherUserType: widget.otherUserRole,
      isCaller: widget.isCaller,
    );
    CallSessionManager.instance.markMediaConnected();
  }

  void _subscribeToStreams() {
    // Duration stream updates every second
    _durationSub = _callController.durationStream.listen((d) {
      if (!mounted || _hasEnded) return;
      setState(() => _duration = d);
    });

    // Zego connection status with watchdog timeout
    _connectionSub = _zegoService.connectionStatusStream.listen((status) {
      if (!mounted || _hasEnded) return;
      setState(() {
        switch (status) {
          case ZegoCallConnectionStatus.connected:
            _cancelReconnectWatchdog();
            _showReconnectAction = false;
            _connectionStatusText = 'Connected';
            _connectionStatusColor = const Color(0xFF1E8E5A);
            if (_countdownTimer == null || !_countdownTimer!.isActive) {
              _startCallCountdownTimer();
            }
            break;
          case ZegoCallConnectionStatus.reconnecting:
            _startReconnectWatchdog();
            _connectionStatusText = 'Reconnecting...';
            _connectionStatusColor = const Color(0xFFFFA000);
            break;
          case ZegoCallConnectionStatus.connecting:
            _startReconnectWatchdog();
            _connectionStatusText = 'Connecting...';
            _connectionStatusColor = const Color(0xFF2196F3);
            break;
          case ZegoCallConnectionStatus.disconnected:
            _cancelReconnectWatchdog();
            _connectionStatusText = 'Disconnected';
            _connectionStatusColor = const Color(0xFFE53935);
            break;
          case ZegoCallConnectionStatus.failed:
            _cancelReconnectWatchdog();
            _showReconnectAction = true;
            _connectionStatusText = 'Call Failed';
            _connectionStatusColor = const Color(0xFFE53935);
            _hasError = true;
            _errorMessage = 'Audio service connection failed.';
            break;
        }
      });
    });

    // Network quality
    _qualitySub = _zegoService.networkQualityStream.listen((data) {
      if (!mounted || _hasEnded) return;
      final upstream = data['upstream'] as int? ?? 0;
      final downstream = data['downstream'] as int? ?? 0;
      if (upstream >= 3 || downstream >= 3) {
        setState(() {
          _connectionStatusText = 'Weak Connection';
          _connectionStatusColor = const Color(0xFFFFA000);
        });
      }
    });

    // Firestore call doc watcher: ends call if peer hangs up or call fails
    final trimmedId = widget.callId.trim();
    if (trimmedId.isNotEmpty) {
      _firestoreCallSub = FirebaseFirestore.instance
          .collection(FirestoreCollections.calls)
          .doc(trimmedId)
          .snapshots()
          .listen(
            (doc) {
              if (!mounted || _hasEnded) return;
              if (!doc.exists || doc.data() == null) {
                _setCallTerminationState(
                  status: 'Call Ended',
                  message: 'This call session is no longer active.',
                  isError: false,
                );
                return;
              }

              final data = doc.data()!;
              final status = (data['callStatus'] ?? data['status'])
                  ?.toString()
                  .toLowerCase()
                  .trim();
              final endReason = data['endReason']?.toString();
              final docError = data['error']?.toString();

              if (status == CallingStatus.failed) {
                _setCallTerminationState(
                  status: 'Call Failed',
                  message: 'Call failed. Please try again.',
                  isError: true,
                );
              } else if (status == CallingStatus.ended) {
                _setCallTerminationState(
                  status: 'Call Ended',
                  message: 'Call ended.',
                  isError: false,
                );
              } else if (status == CallingStatus.cancelled) {
                _setCallTerminationState(
                  status: 'Call Cancelled',
                  message: 'The call was cancelled.',
                  isError: false,
                );
              } else if (status == CallingStatus.rejected) {
                _setCallTerminationState(
                  status: 'Call Declined',
                  message: 'Call declined.',
                  isError: false,
                );
              } else if (status == CallingStatus.missed) {
                // Safeguard: If the call has already connected or audio is flowing,
                // ignore any stale/errant 'missed' status and prevent premature disconnection.
                if (_duration > 0 ||
                    _callController.isDurationTimerRunning ||
                    _zegoService.isInRoom) {
                  debugPrint(
                    '🛡️ [ActiveCallScreen] Stale "missed" status received while call is actively connected ($_duration s). Ignoring.',
                  );
                  // Re-assert connected status in Firestore so both parties remain in sync
                  FirebaseFirestore.instance
                      .collection(FirestoreCollections.calls)
                      .doc(trimmedId)
                      .set({
                    'status': CallingStatus.connected,
                    'callStatus': CallingStatus.connected,
                  }, SetOptions(merge: true));
                  return;
                }
                _setCallTerminationState(
                  status: 'Missed Call',
                  message: 'Call timed out.',
                  isError: false,
                );
              }
            },
            onError: (e) {
              debugPrint('⚠️ [ActiveCallScreen] Firestore stream error: $e');
              _handleError('Network connection error. Please try again.');
            },
          );
    }
  }

  void _handleError(String message) {
    if (!mounted || _hasEnded) return;
    setState(() {
      _hasError = true;
      _statusText = 'Call Error';
      _errorMessage = message;
      _connectionStatusText = 'Error';
      _connectionStatusColor = const Color(0xFFE53935);
    });

    ToastService.instance.showError(message);

    Future.delayed(const Duration(milliseconds: 1800), () {
      _handleCallEnded();
    });
  }

  void _setCallTerminationState({
    required String status,
    String? message,
    required bool isError,
  }) {
    if (!mounted || _hasEnded) return;
    setState(() {
      _statusText = status;
      _errorMessage = message;
      _hasError = isError;
      _connectionStatusText = status;
      _connectionStatusColor = isError
          ? const Color(0xFFE53935)
          : const Color(0xFFFFA000);
    });

    if (message != null) {
      if (isError) {
        ToastService.instance.showError(message);
      } else {
        ToastService.instance.showInfo(message);
      }
    }

    Future.delayed(const Duration(milliseconds: 1600), () {
      _handleCallEnded();
    });
  }

  Future<void> _toggleMute() async {
    if (_isTogglingMute || _hasEnded) return;
    _isTogglingMute = true;
    final nextMute = !_isMuted;
    setState(() => _isMuted = nextMute);

    try {
      final muted = await _callController.toggleMute();
      if (mounted && !_hasEnded) {
        setState(() => _isMuted = muted);
      }
    } catch (e) {
      debugPrint('⚠️ [ActiveCallScreen] toggleMute error: $e');
    } finally {
      _isTogglingMute = false;
    }
  }

  Future<void> _toggleSpeaker() async {
    if (_isTogglingSpeaker || _hasEnded) return;
    _isTogglingSpeaker = true;
    final nextSpeaker = !_isSpeakerOn;
    setState(() => _isSpeakerOn = nextSpeaker);

    try {
      final speaker = await _callController.toggleSpeaker();
      if (mounted && !_hasEnded) {
        setState(() => _isSpeakerOn = speaker);
      }
    } catch (e) {
      debugPrint('⚠️ [ActiveCallScreen] toggleSpeaker error: $e');
    } finally {
      _isTogglingSpeaker = false;
    }
  }

  void _startReconnectWatchdog() {
    _reconnectWatchdogTimer?.cancel();
    _reconnectWatchdogTimer = Timer(const Duration(seconds: 12), () {
      if (!mounted || _hasEnded) return;
      setState(() {
        _showReconnectAction = true;
      });
      debugPrint('⚠️ [ActiveCallScreen] Reconnection watchdog fired (12s). Surfacing retry UI.');
    });
  }

  void _cancelReconnectWatchdog() {
    _reconnectWatchdogTimer?.cancel();
    _reconnectWatchdogTimer = null;
  }

  Future<void> _manualReconnect() async {
    if (_isEnding || _hasEnded) return;
    _cancelReconnectWatchdog();
    setState(() {
      _showReconnectAction = false;
      _connectionStatusText = 'Reconnecting...';
      _connectionStatusColor = const Color(0xFFFFA000);
    });
    ToastService.instance.showInfo('Attempting to re-establish call connection...');

    try {
      await _zegoService.leaveCallRoom();
      final success = await _zegoService.joinCallRoom(
        roomId: widget.roomId,
        userId: widget.currentUserId,
        userName: widget.currentUserName,
      );
      if (success) {
        await _audioService.onCallConnected();
        if (mounted) {
          setState(() {
            _showReconnectAction = false;
            _connectionStatusText = 'Connected';
            _connectionStatusColor = const Color(0xFF1E8E5A);
          });
        }
        ToastService.instance.showSuccess('Call reconnected successfully.');
      } else {
        if (mounted) {
          setState(() => _showReconnectAction = true);
        }
        ToastService.instance.showError('Reconnection failed. Please check internet connection.');
      }
    } catch (e) {
      debugPrint('⚠️ [ActiveCallScreen] Manual reconnect failed: $e');
      if (mounted) {
        setState(() => _showReconnectAction = true);
      }
    }
  }

  void _toggleBluetooth() {
    setState(() => _isBluetoothOn = !_isBluetoothOn);
    ToastService.instance.showInfo(
      _isBluetoothOn ? 'Bluetooth audio routed' : 'Using standard audio route',
    );
  }

  // ─────────────────────────────────────────────────────────────
  // 15-MINUTE DURATION LIMIT & COUNTDOWN CONTROLS
  // ─────────────────────────────────────────────────────────────

  void _startCallCountdownTimer() {
    _countdownTimer?.cancel();
    final elapsed = _callController.callDuration;
    _remainingSeconds =
        (maxCallDurationSeconds - elapsed).clamp(0, maxCallDurationSeconds);
    _hasShownWarning = _remainingSeconds <= 30;

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _hasEnded || _isEnding) {
        timer.cancel();
        return;
      }

      if (_remainingSeconds > 0) {
        setState(() {
          _remainingSeconds--;
        });

        // 2. Warning Alert: When 30 seconds are remaining (at 00:30)
        if (_remainingSeconds == 30 && !_hasShownWarning) {
          _hasShownWarning = true;
          _showDurationWarning();
        }
      } else {
        // 3. Automatic Disconnection: When timer reaches 00:00
        timer.cancel();
        _onCallDurationLimitReached();
      }
    });
  }

  void _showDurationWarning() {
    ToastService.instance.showWarning(
      'Warning: Call will end in 30 seconds (15-minute limit).',
    );
  }

  Future<void> _onCallDurationLimitReached() async {
    if (_hasEnded || _isEnding) return;
    debugPrint(
      '⏱️ [ActiveCallScreen] 15-minute call duration limit reached (00:00). Disconnecting call...',
    );
    ToastService.instance.showInfo('Call duration limit reached (15 minutes).');
    await _endCall();
  }

  void _cancelCountdownTimer() {
    _countdownTimer?.cancel();
    _countdownTimer = null;
  }

  Future<void> _endCall() async {
    if (_isEnding || _hasEnded) return;
    _isEnding = true;
    _cancelCountdownTimer();

    // Immediately handle UI teardown so buttons/screen never freeze
    _handleCallEnded();

    try {
      await _callController.endCall(widget.callId);
    } catch (e) {
      debugPrint('⚠️ [ActiveCallScreen] endCall background error: $e');
    }
  }

  void _handleCallEnded() {
    if (_hasEnded) return;
    _hasEnded = true;

    _cancelCountdownTimer();
    _cancelReconnectWatchdog();
    IncomingCallCoordinator.instance.markScreenClosed(widget.callId);

    _durationSub?.cancel();
    _connectionSub?.cancel();
    _qualitySub?.cancel();
    _firestoreCallSub?.cancel();

    if (mounted) {
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      } else {
        AuthRoutingService.routeToAppropriatePortal(context);
      }
    }
  }

  void _minimizeCall() {
    CallSessionManager.instance.showOverlay();
    if (mounted) {
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      } else {
        AuthRoutingService.routeToAppropriatePortal(context);
      }
    }
  }

  Future<void> _onBackPressed() async {
    if (_hasEnded || _hasError || _isEnding) {
      _handleCallEnded();
      return;
    }

    final result = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF15386A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Call in Progress',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Do you want to minimize the call or end it?',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 22),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Colors.white30),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        onPressed: () => Navigator.of(ctx).pop('minimize'),
                        icon: const Icon(Icons.picture_in_picture_alt, color: Colors.white, size: 20),
                        label: const Text('Minimize', style: TextStyle(color: Colors.white)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFE53935),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        onPressed: () => Navigator.of(ctx).pop('end'),
                        icon: const Icon(Icons.call_end, color: Colors.white, size: 20),
                        label: const Text('End Call', style: TextStyle(color: Colors.white)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );

    if (!mounted) return;
    if (result == 'minimize') {
      _minimizeCall();
    } else if (result == 'end') {
      _endCall();
    }
  }

  @override
  void dispose() {
    _cancelCountdownTimer();
    _cancelReconnectWatchdog();
    IncomingCallCoordinator.instance.markScreenClosed(widget.callId);
    _durationSub?.cancel();
    _connectionSub?.cancel();
    _qualitySub?.cancel();
    _firestoreCallSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final roleLabel = widget.otherUserRole.toLowerCase() == 'doctor'
        ? 'Doctor'
        : 'Patient';

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _onBackPressed();
      },
      child: Scaffold(
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: _backgroundGradient,
            ),
          ),
          child: Stack(
            children: [
              Positioned(
                top: 20,
                right: 0,
                child: Opacity(
                  opacity: 0.12,
                  child: CustomPaint(
                    size: const Size(260, 200),
                    painter: ECGWatermarkPainter(),
                  ),
                ),
              ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 16,
                  ),
                  child: Column(
                    children: [
                      // Top Row: Minimize Button + Encryption Badge
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          IconButton(
                            icon: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.white.withValues(alpha: 0.12),
                              ),
                              child: const Icon(
                                Icons.keyboard_arrow_down_rounded,
                                color: Colors.white,
                                size: 22,
                              ),
                            ),
                            onPressed: _minimizeCall,
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              color: _connectionStatusColor.withValues(
                                alpha: 0.18,
                              ),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: _connectionStatusColor.withValues(
                                  alpha: 0.4,
                                ),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (_hasError)
                                  const Icon(
                                    Icons.error_outline_rounded,
                                    size: 14,
                                    color: Color(0xFFE53935),
                                  )
                                else
                                  Container(
                                    width: 8,
                                    height: 8,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: _connectionStatusColor,
                                    ),
                                  ),
                                const SizedBox(width: 6),
                                Text(
                                  _statusText ?? _connectionStatusText,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: _connectionStatusColor,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 44), // Alignment balance
                        ],
                      ),

                      const SizedBox(height: 14),

                      // Floating Countdown Badge (Top of Call Screen)
                      _buildCountdownBadge(),

                      const Spacer(),

                      // Active User Avatar
                      CallAvatar(
                        imageUrl: widget.otherUserImage,
                        name: widget.otherUserName,
                        radius: 68,
                        isRinging: false,
                      ),
                      const SizedBox(height: 20),

                      // User Name
                      Text(
                        widget.otherUserName,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                          letterSpacing: -0.3,
                        ),
                      ),
                      const SizedBox(height: 6),

                      // Role Pill
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(
                            0xFF11B7A8,
                          ).withValues(alpha: 0.22),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          roleLabel,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF4AD6C8),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),

                      if (_statusText != null || _errorMessage != null) ...[
                        Text(
                          _statusText ?? 'Call Error',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: _hasError
                                ? const Color(0xFFEF5350)
                                : const Color(0xFFFFA000),
                          ),
                        ),
                        if (_errorMessage != null &&
                            _errorMessage != _statusText) ...[
                          const SizedBox(height: 4),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 24),
                            child: Text(
                              _errorMessage!,
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: _hasError
                                    ? const Color(0xFFFF8A80)
                                    : Colors.white70,
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: 12),
                      ],

                      // Call Duration Ticker
                      CallTimerWidget(durationSeconds: _duration),

                      // Reconnect / High-Latency Fallback Action Card
                      if (_showReconnectAction && !_hasEnded && !_hasError) ...[
                        const SizedBox(height: 16),
                        Container(
                          margin: const EdgeInsets.symmetric(horizontal: 24),
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0F2B5C).withValues(alpha: 0.95),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: const Color(0xFFFFA000).withValues(alpha: 0.8),
                              width: 1.2,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.25),
                                blurRadius: 10,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Row(
                                children: [
                                  Icon(
                                    Icons.wifi_off_rounded,
                                    color: Color(0xFFFFA000),
                                    size: 20,
                                  ),
                                  SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      'Connection taking longer than expected.',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              Row(
                                children: [
                                  Expanded(
                                    child: ElevatedButton.icon(
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(0xFF11B7A8),
                                        foregroundColor: Colors.white,
                                        padding: const EdgeInsets.symmetric(vertical: 10),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(10),
                                        ),
                                      ),
                                      onPressed: _manualReconnect,
                                      icon: const Icon(Icons.refresh_rounded, size: 18),
                                      label: const Text(
                                        'Reconnect',
                                        style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      style: OutlinedButton.styleFrom(
                                        side: const BorderSide(color: Color(0xFFE53935)),
                                        foregroundColor: const Color(0xFFEF5350),
                                        padding: const EdgeInsets.symmetric(vertical: 10),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(10),
                                        ),
                                      ),
                                      onPressed: _endCall,
                                      icon: const Icon(Icons.call_end, size: 18),
                                      label: const Text(
                                        'End Call',
                                        style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],

                      const Spacer(),

                      if (_hasError || _hasEnded || _statusText != null) ...[
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: SizedBox(
                            width: double.infinity,
                            height: 52,
                            child: ElevatedButton.icon(
                              onPressed: _handleCallEnded,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: _hasError
                                    ? const Color(0xFFE53935)
                                    : const Color(0xFF15386A),
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(28),
                                ),
                                elevation: 4,
                              ),
                              icon: const Icon(Icons.close_rounded, size: 20),
                              label: const Text(
                                'Dismiss',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),
                      ] else ...[
                        // In-Call Action Controls
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              // Mute button
                              CallActionButton(
                                icon: _isMuted
                                    ? Icons.mic_off_rounded
                                    : Icons.mic_rounded,
                                label: _isMuted ? 'Unmute' : 'Mute',
                                isActive: _isMuted,
                                onPressed: _toggleMute,
                              ),

                              // Speakerphone button
                              CallActionButton(
                                icon: _isSpeakerOn
                                    ? Icons.volume_up_rounded
                                    : Icons.volume_down_rounded,
                                label: _isSpeakerOn ? 'Speaker On' : 'Earpiece',
                                isActive: _isSpeakerOn,
                                onPressed: _toggleSpeaker,
                              ),

                              // Bluetooth button
                              CallActionButton(
                                icon: _isBluetoothOn
                                    ? Icons.bluetooth_connected_rounded
                                    : Icons.bluetooth_rounded,
                                label: 'Bluetooth',
                                isActive: _isBluetoothOn,
                                onPressed: _toggleBluetooth,
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 36),

                         // End Call Button
                        EndCallButton(onPressed: _endCall, size: 72),
                        const SizedBox(height: 24),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Floating countdown badge displayed at the top of the call screen.
  /// Shows remaining time in "Remaining: mm:ss" format.
  /// Automatically transitions to high-visibility alert red when <= 30 seconds remain.
  Widget _buildCountdownBadge() {
    final minutes = (_remainingSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (_remainingSeconds % 60).toString().padLeft(2, '0');
    final bool isUrgent = _remainingSeconds <= 30;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
      decoration: BoxDecoration(
        color: isUrgent
            ? const Color(0xFFE53935).withValues(alpha: 0.28)
            : Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: isUrgent
              ? const Color(0xFFEF5350)
              : Colors.white.withValues(alpha: 0.25),
          width: isUrgent ? 1.5 : 1.0,
        ),
        boxShadow: isUrgent
            ? [
                BoxShadow(
                  color: const Color(0xFFE53935).withValues(alpha: 0.45),
                  blurRadius: 10,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isUrgent ? Icons.timer_outlined : Icons.hourglass_top_rounded,
            size: 15,
            color: isUrgent ? const Color(0xFFFF5252) : const Color(0xFF4AD6C8),
          ),
          const SizedBox(width: 7),
          Text(
            'Remaining: $minutes:$seconds',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: isUrgent ? const Color(0xFFFF8A80) : Colors.white,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}
