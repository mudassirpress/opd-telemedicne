// call_screen.dart - Redesigned with the Sign In screen design language
// (navy-blue OPD Telemedicine theme). Call logic/state handling unchanged.
import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/shared/widgets/auth_layout.dart';
import 'package:telemedicine/home_widget/chat_call/call/call_controller/call_controller.dart';

class CallScreen extends StatefulWidget {
  final String channelId;
  final String callId;
  final String callType;
  final String otherUserName;
  final String otherUserImage;
  final bool isCaller;
  final String currentUserId;
  final String otherUserId;
  final String otherUserType;
  const CallScreen({
    super.key,
    required this.channelId,
    required this.callId,
    required this.callType,
    required this.otherUserName,
    required this.otherUserImage,
    required this.currentUserId,
    required this.otherUserId,
    required this.otherUserType,
    this.isCaller = true,
  });
  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen>
    with SingleTickerProviderStateMixin {
  final CallController _callController = CallController();
  final Connectivity _connectivity = Connectivity();
  bool _isMuted = false;
  bool _isSpeakerOn = true;
  bool _cameraEnabled = false;
  int _callDuration = 0;
  Timer? _timer;
  Timer? _connectionTimer;
  Timer? _ringingTimer;
  bool _isCallActive = true;
  bool _isConnected = false;
  String? _connectionStatus;
  /// True while [_connectionStatus] shows the transient "Call reconnected."
  /// success message — rendered with the green pill instead of the red one.
  bool _isStatusSuccess = false;
  /// Weak-network warning from Zego's quality callback. Shown only while the
  /// call is otherwise healthy ([_connectionStatus] == null), so a reconnect
  /// message always takes precedence.
  String? _qualityStatus;
  StreamSubscription? _callStatusSub;
  StreamSubscription? _remoteStreamSub;
  StreamSubscription? _connectionStateSub;
  StreamSubscription? _networkQualitySub;
  StreamSubscription? _connectivitySub;
  Timer? _reconnectWatchdog;
  Timer? _transientStatusTimer;
  /// Manual re-join attempts made since the connection first dropped. Zego
  /// retries internally first; the watchdog only intervenes when the SDK has
  /// given up (room state parked in Disconnected) for a long time.
  int _reconnectAttempts = 0;
  /// When the call first lost its connection, used by the watchdog.
  DateTime? _disconnectedSince;
  /// Last known connectivity interface — used to tell a real disconnect
  /// (wifi → none) apart from a Wi-Fi ⇄ mobile-data handover (wifi → mobile).
  ConnectivityResult? _lastConnectivity;
  bool _recordingStarted = false;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  bool _isRinging = false;
  String _ringingStatus = '';

  // Sign In screen tokens
  static const List<Color> _gradient = [
    Color(0xFF284F85),
    Color(0xFF15386A),
    Color(0xFF0D264E),
    Color(0xFF081938),
  ];

  @override
  void initState() {
    super.initState();
    _cameraEnabled = widget.callType == 'video';
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1300),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.07).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _initializeAndJoinCall();
    _listenForCallStatus();
    _listenForRemoteStream();
    _listenForConnectionState();
    _listenForNetworkQuality();
    _listenForConnectivity();
  }

  Future<void> _initializeAndJoinCall() async {
    try {
      setState(() {
        if (widget.isCaller) {
          _connectionStatus = 'Calling...';
          _ringingStatus = 'Ringing...';
        } else {
          _connectionStatus = 'Incoming call...';
          _ringingStatus = 'Answering...';
        }
      });
      final initialized = await _callController.initializeZego(
        enableVideo: widget.callType == 'video',
      );
      if (!initialized && mounted) {
        _showErrorAndExit('Failed to initialize call engine');
        return;
      }
      setState(() {
        _connectionStatus = widget.isCaller ? 'Calling...' : 'Connecting...';
      });
      final joined = await _callController.joinRoom(
        roomId: widget.channelId,
        uid: widget.currentUserId,
        userName: widget.isCaller ? 'Caller' : widget.otherUserName,
        isVideo: widget.callType == 'video',
      );
      if (!joined && mounted) {
        _showErrorAndExit('Failed to join call');
        return;
      }
      // The receiver may accept (Firestore 'accepted') while this join is
      // still in flight. If 'accepted' already transitioned us to Connected,
      // do NOT downgrade the UI back to "Ringing…" or re-arm the timeout.
      if (!_isConnected) {
        if (widget.isCaller) {
          _startRingingSimulation();
        }
        setState(() {
          _connectionStatus = widget.isCaller
              ? 'Ringing...'
              : 'Connecting...';
        });
        // Safety net: ends the call only when it is genuinely unanswered /
        // unable to connect. It is cancelled as soon as 'accepted' arrives or
        // media starts flowing.
        _connectionTimer = Timer(const Duration(seconds: 45), () {
          if (mounted && !_isConnected && _isCallActive) {
            _showErrorAndExit(widget.isCaller
                ? 'No answer from ${widget.otherUserName}'
                : 'Failed to connect to call');
          }
        });
      }
    } catch (e) {
      debugPrint('Error initializing call: $e');
      _showErrorAndExit('Failed to initialize call');
    }
  }

  void _startRingingSimulation() {
    _isRinging = true;
    _ringingTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      if (mounted && _isRinging && !_isConnected) {
        setState(() {
          _ringingStatus = _ringingStatus == 'Ringing...'
              ? 'Calling...'
              : 'Ringing...';
        });
      } else {
        timer.cancel();
      }
    });
  }

  void _stopRingingSimulation() {
    _isRinging = false;
    _ringingTimer?.cancel();
    _ringingTimer = null;
  }

  void _listenForRemoteStream() {
    _remoteStreamSub = _callController.onRemoteStreamAdded.listen((streamId) {
      debugPrint('✅ Remote stream received!');
      if (mounted && !_isConnected) {
        _stopRingingSimulation();
        setState(() {
          _isConnected = true;
          _connectionStatus = null;
          _ringingStatus = '';
        });
        _connectionTimer?.cancel();
        _startTimer();
        _startCallRecording();
        ToastService.instance.showSuccess(
          'Connected to ${widget.otherUserName}',
        );
      }
    });
  }

  void _listenForConnectionState() {
    _connectionStateSub = _callController.onConnectionState.listen((connected) {
      debugPrint('Connection state changed: $connected');
      if (!mounted) return;
      if (connected && !_isConnected) {
        Future.delayed(const Duration(milliseconds: 500), () {
          if (_callController.hasRemoteStream && mounted && !_isConnected) {
            _stopRingingSimulation();
            setState(() {
              _isConnected = true;
              _connectionStatus = null;
              _ringingStatus = '';
            });
            _connectionTimer?.cancel();
            _startTimer();
            _startCallRecording();
          }
        });
      } else if (connected && _isConnected && _connectionStatus != null) {
        // Back to normal after a reconnect. Show a brief success message so
        // the user knows the call recovered on its own instead of the pill
        // silently vanishing.
        _reconnectWatchdog?.cancel();
        _reconnectWatchdog = null;
        _disconnectedSince = null;
        _reconnectAttempts = 0;
        setState(() {
          _connectionStatus = 'Call reconnected.';
          _isStatusSuccess = true;
        });
        _transientStatusTimer?.cancel();
        _transientStatusTimer = Timer(const Duration(seconds: 3), () {
          if (mounted && _connectionStatus == 'Call reconnected.') {
            setState(() {
              _connectionStatus = null;
              _isStatusSuccess = false;
            });
          }
        });
      } else if (!connected && _isConnected) {
        // Active call lost connection — show inline reconnect status.
        _disconnectedSince ??= DateTime.now();
        _transientStatusTimer?.cancel();
        setState(() {
          _connectionStatus = 'Reconnecting to call…';
          _isStatusSuccess = false;
        });
        _startReconnectWatchdog();
      }
    });
  }

  /// Zego network-quality callback (the stream the controller emits but
  /// nothing used to consume).
  ///
  /// `upload` / `download` are `ZegoStreamQualityLevel` enum indexes:
  /// 0 Excellent, 1 Good, 2 Normal, 3 Bad, 4 Failed. At "Bad" or worse the
  /// user can hear/see the call degrade, so a lightweight warning pill is
  /// shown. It clears itself the moment quality recovers, and it never
  /// overrides a reconnecting status.
  void _listenForNetworkQuality() {
    _networkQualitySub = _callController.networkQuality.listen((quality) {
      if (!mounted || !_isCallActive || !_isConnected) return;

      final upload = (quality['upload'] as num?)?.toInt() ?? 0;
      final download = (quality['download'] as num?)?.toInt() ?? 0;
      final weak = upload >= 3 || download >= 3;
      final status = weak ? 'Your internet connection is weak.' : null;

      // Avoid a rebuild for every quality tick (Zego fires these ~once per
      // second) when nothing visible changed.
      if (status == _qualityStatus) return;
      setState(() => _qualityStatus = status);
    });
  }

  /// Device-level connectivity during the call.
  ///
  /// Distinguishes three situations:
  ///  * real disconnect (interface → none): show "Network disconnected…"
  ///    and start the recovery watchdog;
  ///  * interface restored (none → wifi/mobile): show "Reconnecting to
  ///    call…" — Zego re-joins internally and the room-state listener
  ///    finishes with "Call reconnected.";
  ///  * Wi-Fi ⇄ mobile-data handover (wifi ⇄ mobile, never `none`): do
  ///    nothing — Zego survives this on its own and flashing a warning would
  ///    be noise.
  void _listenForConnectivity() {
    _connectivitySub = _connectivity.onConnectivityChanged.listen((
      result,
    ) {
      if (!mounted || !_isCallActive) return;

      final previous = _lastConnectivity;
      _lastConnectivity = result;

      if (result == ConnectivityResult.none) {
        if (previous == ConnectivityResult.none) return;
        _disconnectedSince ??= DateTime.now();
        if (_isConnected || _connectionStatus != null) {
          _transientStatusTimer?.cancel();
          setState(() {
            _connectionStatus = 'Network disconnected. Trying to reconnect…';
            _isStatusSuccess = false;
          });
          _startReconnectWatchdog();
        }
        return;
      }

      // Back online after a real disconnect.
      if (previous == ConnectivityResult.none && _disconnectedSince != null) {
        setState(() {
          if (_connectionStatus != null) {
            _connectionStatus = 'Reconnecting to call…';
            _isStatusSuccess = false;
          }
        });
        // The room-state listener completes the recovery ("Call
        // reconnected."). Give Zego's own internal rejoin a few seconds to
        // act on the restored network first; only force a manual re-join if
        // the SDK is still not back in the room.
        if (!_callController.isJoined) {
          unawaited(
            Future.delayed(const Duration(seconds: 3), () {
              if (mounted && _isCallActive && !_callController.isJoined) {
                unawaited(_attemptCallRejoin());
              }
            }),
          );
        }
      }
      // wifi ⇄ mobile handover: no message, no action.
    }, onError: (Object e) {
      debugPrint('Connectivity listener error during call: $e');
    });
  }

  /// Safety net for a connection that stays dead.
  ///
  /// Zego retries a dropped room internally, but when the network is gone
  /// long enough the SDK parks the room in `Disconnected` and stops. Without
  /// this watchdog the UI showed "Reconnecting…" forever with the mic and
  /// camera still live. After a generous grace period the call is re-joined
  /// manually (twice at most); if that fails the call ends cleanly so both
  /// sides' Firestore state is updated and the devices are released.
  void _startReconnectWatchdog() {
    if (_reconnectWatchdog != null) return;
    _reconnectWatchdog = Timer(const Duration(seconds: 45), () {
      _reconnectWatchdog = null;
      if (!mounted || !_isCallActive || !_isConnected) return;
      if (_callController.isJoined) {
        // Zego recovered on its own during the grace period.
        return;
      }
      unawaited(_attemptCallRejoin());
    });
  }

  Future<void> _attemptCallRejoin() async {
    if (!mounted || !_isCallActive) return;

    if (_reconnectAttempts >= 2) {
      debugPrint('⚠️ Call reconnection failed after $_reconnectAttempts attempts');
      if (mounted) {
        ToastService.instance.showError(
          'Unable to reconnect. Please check your internet.',
        );
      }
      await _giveUpAndEndCall();
      return;
    }

    _reconnectAttempts++;
    debugPrint(
      '🔁 Attempting call rejoin ($_reconnectAttempts/2) '
      'room=${widget.channelId}',
    );
    setState(() {
      _connectionStatus = 'Reconnecting to call…';
      _isStatusSuccess = false;
    });

    try {
      // `joinRoom` soft-resets a stale session first, logs back into the room
      // and re-publishes. On success the remote stream listener and the
      // room-state listener re-arm the normal "connected" path.
      final rejoined = await _callController.joinRoom(
        roomId: widget.channelId,
        uid: widget.currentUserId,
        userName: widget.isCaller ? 'Caller' : widget.otherUserName,
        isVideo: widget.callType == 'video',
      );
      if (rejoined && mounted) {
        debugPrint('✅ Call rejoin succeeded');
        // Give the remote stream a moment to arrive; the normal listeners
        // will clear the status. If it does not, the next watchdog round
        // (or the failure path) handles it.
        _startReconnectWatchdog();
      } else if (mounted) {
        _startReconnectWatchdog();
      }
    } catch (e) {
      debugPrint('Call rejoin error: $e');
      if (mounted) _startReconnectWatchdog();
    }
  }

  /// Ends the call cleanly after reconnection has failed: updates the
  /// Firestore status for BOTH users, releases the engine and pops the
  /// screen — no stuck call screen, no live microphone/camera.
  Future<void> _giveUpAndEndCall() async {
    if (!_isCallActive) return;
    _isCallActive = false;
    _stopRingingSimulation();
    _timer?.cancel();
    _connectionTimer?.cancel();
    _reconnectWatchdog?.cancel();
    _transientStatusTimer?.cancel();
    _callStatusSub?.cancel();
    _remoteStreamSub?.cancel();
    _connectionStateSub?.cancel();
    _networkQualitySub?.cancel();
    _connectivitySub?.cancel();
    try {
      await _callController.endCall(widget.callId);
    } catch (e) {
      debugPrint('Error ending call after failed reconnect: $e');
    }
    if (mounted) {
      Navigator.pop(context);
    }
  }

  void _listenForCallStatus() {
    _callStatusSub = _callController.watchCall(widget.callId).listen((call) {
      if (call == null || !mounted) return;
      debugPrint('📞 Call status: ${call.callStatus}');

      // The receiver accepted. Sync the local CallController (so the caller's
      // 45s ring timeout is disarmed) and transition the UI:
      //  - Caller: Ringing → Connected immediately.
      //  - Receiver: "Waiting for answer…" → "Connecting…" (Connected once real
      //    Zego media is flowing — onRemoteStreamAdded / onConnectionState).
      if (call.callStatus == 'accepted') {
        // Always sync (disarms the caller's 45s ring timeout and keeps the
        // CallController state machine truthful), even if media already
        // connected before this snapshot arrived.
        _callController.markCallAcceptedForRemote(widget.callId);
        if (!_isConnected) {
          _stopRingingSimulation();
          if (widget.isCaller) {
            _connectionTimer?.cancel();
            setState(() {
              _isConnected = true;
              _connectionStatus = null;
              _ringingStatus = '';
            });
            _startTimer();
            _startCallRecording();
            ToastService.instance.showSuccess(
              'Connected to ${widget.otherUserName}',
            );
          } else {
            setState(() {
              _connectionStatus = 'Connecting...';
              _ringingStatus = '';
            });
          }
        }
        return;
      }

      if (call.callStatus == 'cancelled') {
        ToastService.instance.showInfo('Call cancelled');
        _cleanUpAndPop();
        return;
      }

      if (call.callStatus == 'ended' ||
          call.callStatus == 'rejected' ||
          call.callStatus == 'missed') {
        if (call.callStatus == 'rejected') {
          ToastService.instance.showInfo(
            'Call rejected by ${widget.otherUserName}',
          );
        } else if (call.callStatus == 'missed') {
          ToastService.instance.showInfo('Call missed');
        }
        _cleanUpAndPop();
      }
    });
  }

  Future<void> _startCallRecording() async {
    try {
      await Future.delayed(const Duration(milliseconds: 500));
      final started = await _callController.startCallRecording();
      if (started && mounted) {
        setState(() => _recordingStarted = true);
      }
    } catch (e) {
      debugPrint('Error starting recording: $e');
    }
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _isCallActive) {
        setState(() => _callDuration++);
      }
    });
  }

  void _toggleMute() async {
    setState(() => _isMuted = !_isMuted);
    await _callController.muteMicrophone(_isMuted);
    if (!_isConnected) {
      ToastService.instance.showInfo(
        _isMuted ? 'Microphone muted' : 'Microphone unmuted',
      );
    }
  }

  void _toggleSpeaker() async {
    setState(() => _isSpeakerOn = !_isSpeakerOn);
    await _callController.enableSpeaker(_isSpeakerOn);
    if (!_isConnected) {
      ToastService.instance.showInfo(
        _isSpeakerOn ? 'Speaker mode on' : 'Earpiece mode on',
      );
    }
  }

  void _toggleCamera() async {
    setState(() => _cameraEnabled = !_cameraEnabled);
    await _callController.enableLocalVideo(_cameraEnabled);
  }

  void _switchCamera() async {
    await _callController.toggleCameraDirection();
  }

  Future<void> _endCall() async {
    if (!_isCallActive) return;
    _isCallActive = false;
    _stopRingingSimulation();
    _timer?.cancel();
    _connectionTimer?.cancel();
    _reconnectWatchdog?.cancel();
    _transientStatusTimer?.cancel();
    _callStatusSub?.cancel();
    _remoteStreamSub?.cancel();
    _connectionStateSub?.cancel();
    _networkQualitySub?.cancel();
    _connectivitySub?.cancel();
    if (_recordingStarted) {
      ToastService.instance.showInfo('Saving recording...');
      await _callController.stopRecordingAndUpload(
        callId: widget.callId,
        callerId: widget.currentUserId,
        receiverId: widget.otherUserId,
      );
    }
    await _callController.endCall(widget.callId);
    if (mounted) {
      ToastService.instance.showInfo('Call ended');
      Navigator.pop(context);
    }
  }

  void _showErrorAndExit(String message) {
    if (!mounted) return;
    _stopRingingSimulation();
    ToastService.instance.showError(message);
    _callController.endCall(widget.callId);
    Navigator.pop(context);
  }

  void _cleanUpAndPop() {
    if (!_isCallActive) return;
    _isCallActive = false;
    _stopRingingSimulation();
    _timer?.cancel();
    _connectionTimer?.cancel();
    _reconnectWatchdog?.cancel();
    _transientStatusTimer?.cancel();
    _callStatusSub?.cancel();
    _remoteStreamSub?.cancel();
    _connectionStateSub?.cancel();
    _networkQualitySub?.cancel();
    _connectivitySub?.cancel();
    _callController.leaveRoom();
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    _stopRingingSimulation();
    _timer?.cancel();
    _connectionTimer?.cancel();
    _reconnectWatchdog?.cancel();
    _transientStatusTimer?.cancel();
    _callStatusSub?.cancel();
    _remoteStreamSub?.cancel();
    _connectionStateSub?.cancel();
    _networkQualitySub?.cancel();
    _connectivitySub?.cancel();
    _pulseController.dispose();
    if (_recordingStarted && _isCallActive) {
      _callController.stopRecordingAndUpload(
        callId: widget.callId,
        callerId: widget.currentUserId,
        receiverId: widget.otherUserId,
      );
    }
    if (_isCallActive) {
      _callController.endCall(widget.callId);
    }
    _callController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _endCall();
      },
      child: Scaffold(backgroundColor: Colors.black, body: _buildBody()),
    );
  }

  Widget _buildBody() {
    if (!_isConnected) {
      return _buildRingingUI();
    }
    return _buildActiveCallUI();
  }

  Widget _buildGradientBackground({Widget? child}) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: _gradient,
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            bottom: -40,
            right: -20,
            child: Opacity(
              opacity: 0.05,
              child: Transform.rotate(
                angle: 1.2,
                child: CustomPaint(
                  size: Size(280, 200),
                  painter: ECGWatermarkPainter(),
                ),
              ),
            ),
          ),
          if (child != null) child,
        ],
      ),
    );
  }

  // ==================== RINGING / CONNECTING UI ====================
  Widget _buildRingingUI() {
    return _buildGradientBackground(
      child: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 16),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: context.rsp(16)),
              child: Row(
                children: [
                  _buildCallTypePill(),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: _buildStatusPill(),
                    ),
                  ),
                ],
              ),
            ),
            const Spacer(),
            _buildAvatar(connected: false),
            SizedBox(height: context.rsp(24)),
            _buildContactInfo(),
            const SizedBox(height: 14),
            _buildRingingStatusLine(),
            const Spacer(),
            _buildRingingControls(),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildContactInfo() {
    return Column(
      children: [
        Text(
          widget.otherUserName,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: context.fs(26),
            fontWeight: FontWeight.w600,
            color: Colors.white,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 8),
        if (_resolveRole(widget.otherUserType) != null)
          _buildRoleChip(_resolveRole(widget.otherUserType)!),
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
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isDoctor ? Icons.medical_services_rounded : Icons.person_rounded,
            size: 14,
            color: Colors.white70,
          ),
          const SizedBox(width: 6),
          Text(
            role,
            style: TextStyle(
              fontSize: context.fs(12),
              fontWeight: FontWeight.w600,
              color: Colors.white70,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRingingStatusLine() {
    final status = widget.isCaller
        ? (_ringingStatus.isNotEmpty
            ? _ringingStatus
            : _connectionStatus ?? 'Calling...')
        : (_connectionStatus ?? 'Incoming call...');
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Pulsing dot indicator (lightweight inline status).
        Container(
          width: 8,
          height: 8,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: Color(0xFF4AD6C8),
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            status,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: context.fs(14),
              fontWeight: FontWeight.w500,
              color: Colors.white70,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRingingControls() {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: context.contentMaxWidth),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: context.rsp(24),
            vertical: 8,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _ControlButton(
                icon: _isMuted ? Icons.mic_off : Icons.mic,
                label: _isMuted ? 'Unmute' : 'Mute',
                isActive: _isMuted,
                activeColor: const Color(0xFFE53935),
                onTap: _toggleMute,
              ),
              _EndButton(onTap: _endCall),
              _ControlButton(
                icon: _isSpeakerOn ? Icons.volume_up : Icons.volume_off,
                label: _isSpeakerOn ? 'Speaker' : 'Earpiece',
                isActive: _isSpeakerOn,
                activeColor: const Color(0xFF4AD6C8),
                onTap: _toggleSpeaker,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ==================== ACTIVE CALL UI ====================
  Widget _buildActiveCallUI() {
    final isVideo = widget.callType == 'video';
    return _buildGradientBackground(
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: context.rsp(16),
                vertical: 12,
              ),
              child: Row(
                children: [
                  _buildCallTypePill(),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: _buildConnectedPill(),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: EdgeInsets.symmetric(horizontal: context.rsp(20)),
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: context.contentMaxWidth,
                    ),
                    child: Column(
                      children: [
                        const SizedBox(height: 12),
                        if (isVideo)
                          _buildVideoSurface()
                        else ...[
                          _buildAvatar(connected: true),
                          const SizedBox(height: 24),
                        ],
                        _buildContactInfo(),
                        const SizedBox(height: 10),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              _formatDuration(_callDuration),
                              style: TextStyle(
                                fontSize: context.fs(24),
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                                letterSpacing: 1,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        if (_recordingStarted && !isVideo) _buildRecordingPill(),
                        const SizedBox(height: 6),
                        if (_connectionStatus != null) _buildReconnectStatus(),
                        // Weak-network warning only while the call is
                        // otherwise healthy — a reconnecting status always
                        // takes precedence so the pills never stack.
                        if (_connectionStatus == null &&
                            _qualityStatus != null)
                          _buildWeakNetworkPill(),
                        const SizedBox(height: 24),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            _buildActiveControls(),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  /// Video surface (avatar stands in place of the camera feed, matching the
  /// existing app behaviour). The surface uses the app's bevel/card language.
  Widget _buildVideoSurface() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 20),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(30),
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF0D264E), Color(0xFF081938)],
        ),
        border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF081938).withValues(alpha: 0.45),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: AspectRatio(
        aspectRatio: 3 / 4,
        child: Stack(
          alignment: Alignment.center,
          children: [
            _buildAvatar(connected: true),
            // Live indicator.
            Positioned(
              top: 14,
              right: 14,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.2),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: Color(0xFF4CAF50),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Live',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Recording indicator.
            if (_recordingStarted)
              Positioned(
                bottom: 14,
                left: 14,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: const Color(0xFFE53935).withValues(alpha: 0.5),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: Color(0xFFE53935),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Recording',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildReconnectStatus() {
    final success = _isStatusSuccess;
    final accent = success ? const Color(0xFF4AD6C8) : const Color(0xFFFF8A80);
    final background = success
        ? const Color(0xFF1B5E20).withValues(alpha: 0.35)
        : const Color(0xFFB71C1C).withValues(alpha: 0.25);
    final border = success
        ? const Color(0xFF4AD6C8).withValues(alpha: 0.4)
        : const Color(0xFFE53935).withValues(alpha: 0.4);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!success)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Color(0xFFFF8A80),
              ),
            )
          else
            Icon(Icons.check_circle_outline, size: 14, color: accent),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              _connectionStatus ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: context.fs(13),
                fontWeight: FontWeight.w600,
                color: accent,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Lightweight, unobtrusive warning while the call is connected but the
  /// measured link quality is bad. Amber pill in the same design language as
  /// the reconnect pill; it never blocks the UI and clears itself when the
  /// network recovers.
  Widget _buildWeakNetworkPill() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF9A825).withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: const Color(0xFFF9A825).withValues(alpha: 0.4),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.signal_wifi_statusbar_connected_no_internet_4,
            size: 14,
            color: Color(0xFFFFD54F),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              _qualityStatus ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: context.fs(13),
                fontWeight: FontWeight.w600,
                color: const Color(0xFFFFD54F),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActiveControls() {
    final isVideo = widget.callType == 'video';
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: context.contentMaxWidth),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: context.rsp(24)),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _ControlButton(
                    icon: _isMuted ? Icons.mic_off : Icons.mic,
                    label: _isMuted ? 'Unmute' : 'Mute',
                    isActive: _isMuted,
                    activeColor: const Color(0xFFE53935),
                    onTap: _toggleMute,
                  ),
                  _EndButton(onTap: _endCall),
                  _ControlButton(
                    icon: _isSpeakerOn ? Icons.volume_up : Icons.volume_off,
                    label: _isSpeakerOn ? 'Speaker' : 'Earpiece',
                    isActive: _isSpeakerOn,
                    activeColor: const Color(0xFF4AD6C8),
                    onTap: _toggleSpeaker,
                  ),
                ],
              ),
              if (isVideo) ...[
                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _ControlButton(
                      icon: _cameraEnabled ? Icons.videocam : Icons.videocam_off,
                      label: _cameraEnabled ? 'Camera' : 'Camera off',
                      isActive: !_cameraEnabled,
                      activeColor: const Color(0xFFE53935),
                      onTap: _toggleCamera,
                    ),
                    _ControlButton(
                      icon: Icons.cameraswitch,
                      label: 'Flip',
                      isActive: false,
                      activeColor: const Color(0xFF4AD6C8),
                      onTap: _cameraEnabled ? _switchCamera : null,
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ==================== SHARED WIDGETS ====================
  Widget _buildCallTypePill() {
    final isVideo = widget.callType == 'video';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isVideo ? Icons.videocam_rounded : Icons.call_rounded,
            size: 14,
            color: Colors.white70,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              isVideo ? 'Video Call' : 'Audio Call',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white70,
                fontSize: context.fs(13),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusPill() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Color(0xFF4AD6C8),
            ),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              widget.isCaller
                  ? (_ringingStatus.isNotEmpty ? _ringingStatus : _connectionStatus ?? 'Calling...')
                  : (_connectionStatus ?? 'Incoming call...'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white70,
                fontSize: context.fs(12),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConnectedPill() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF1B5E20).withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(
          color: const Color(0xFF4CAF50).withValues(alpha: 0.45),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Color(0xFF4CAF50),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            'Connected',
            style: TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecordingPill() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFFB71C1C).withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: const Color(0xFFE53935).withValues(alpha: 0.4),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Color(0xFFE53935),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            'Recording',
            style: TextStyle(
              color: Color(0xFFFF8A80),
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAvatar({required bool connected}) {
    final hasImage = widget.otherUserImage.isNotEmpty;
    final initial = widget.otherUserName.isNotEmpty
        ? widget.otherUserName[0].toUpperCase()
        : '?';
    final ringColor = connected
        ? const Color(0xFF4CAF50)
        : Colors.white;
    final avatarSize = (132 * (context.sw / 360)).clamp(104.0, 132.0);
    return AnimatedBuilder(
      animation: _pulseAnimation,
      builder: (context, child) {
        return Transform.scale(
          scale: connected ? 1.0 : _pulseAnimation.value,
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
              border: Border.all(
                color: connected
                    ? ringColor.withValues(alpha: 0.6)
                    : const Color(0xFF8AA0BE),
                width: 3,
              ),
              boxShadow: [
                BoxShadow(
                  color: connected
                      ? const Color(0xFF4CAF50).withValues(alpha: 0.25)
                      : const Color(0xFF081938).withValues(alpha: 0.5),
                  blurRadius: 30,
                  spreadRadius: 6,
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
                        widget.otherUserImage,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => _avatarFallback(initial),
                      )
                    : _avatarFallback(initial),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _avatarFallback(String initial) {
    return Center(
      child: Text(
        initial,
        style: TextStyle(
          fontSize: context.fs(30),
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
    );
  }

  String _formatDuration(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}

// ==================== REUSABLE CONTROL WIDGETS ====================
class _ControlButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final Color activeColor;
  final VoidCallback? onTap;

  const _ControlButton({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.activeColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    final inactiveColor = Colors.white;
    return GestureDetector(
      onTap: disabled ? null : onTap,
      child: Column(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              gradient: isActive
                  ? LinearGradient(
                      colors: [
                        activeColor.withValues(alpha: 0.85),
                        activeColor.withValues(alpha: 0.65),
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    )
                  : const LinearGradient(
                      colors: [
                        Color(0xFF3E5F8F),
                        Color(0xFF1B3A66),
                        Color(0xFF0F244E),
                      ],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    ),
              shape: BoxShape.circle,
              border: Border.all(
                color: isActive
                    ? activeColor
                    : Colors.white.withValues(alpha: 0.2),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: (isActive ? activeColor : const Color(0xFF062B72))
                      .withValues(alpha: 0.35),
                  blurRadius: 12,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: Icon(
              icon,
              color: disabled
                  ? Colors.white38
                  : inactiveColor,
              size: 24,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: disabled
                  ? Colors.white38
                  : isActive
                      ? activeColor
                      : Colors.white70,
              fontSize: context.fs(11),
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _EndButton extends StatelessWidget {
  final VoidCallback onTap;

  const _EndButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            width: 68,
            height: 68,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFFF64E4E), Color(0xFFD32F2F)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              shape: BoxShape.circle,
              border: Border.all(
                color: const Color(0xFFB71C1C),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFD32F2F).withValues(alpha: 0.45),
                  blurRadius: 18,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: const Icon(
              Icons.call_end_rounded,
              color: Colors.white,
              size: 30,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'End',
            style: TextStyle(
              color: const Color(0xFFFF8A80),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}