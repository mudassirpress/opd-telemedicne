// lib/features/calling/screens/outgoing_call_screen.dart

import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/core/services/auth_routing_service.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/features/calling/controllers/call_controller.dart';
import 'package:telemedicine/features/calling/domain/call_status.dart';
import 'package:telemedicine/features/calling/screens/active_call_screen.dart';
import 'package:telemedicine/features/calling/widgets/call_avatar.dart';
import 'package:telemedicine/features/calling/widgets/call_controls.dart';
import 'package:telemedicine/shared/widgets/auth_layout.dart';

class OutgoingCallScreen extends StatefulWidget {
  final String callId;
  final String receiverId;
  final String receiverName;
  final String receiverRole;
  final String? receiverImage;
  final String currentUserId;
  final String currentUserName;

  const OutgoingCallScreen({
    super.key,
    required this.callId,
    required this.receiverId,
    required this.receiverName,
    required this.receiverRole,
    this.receiverImage,
    required this.currentUserId,
    required this.currentUserName,
  });

  @override
  State<OutgoingCallScreen> createState() => _OutgoingCallScreenState();
}

class _OutgoingCallScreenState extends State<OutgoingCallScreen> {
  final CallController _callController = CallController.instance;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _callSub;

  String _statusText = 'Calling...';
  String? _errorMessage;
  bool _hasError = false;
  bool _isRinging = false;
  bool _isCancelling = false;
  bool _isClosed = false;
  bool _isNavigatingToActive = false;

  // Navy-blue theme gradients
  static const List<Color> _backgroundGradient = [
    Color(0xFF062B72),
    Color(0xFF0F367A),
    Color(0xFF09204A),
    Color(0xFF05132D),
  ];

  @override
  void initState() {
    super.initState();
    _listenToCallUpdates();
  }

  void _listenToCallUpdates() {
    final trimmedCallId = widget.callId.trim();

    // Guard against empty call ID
    if (trimmedCallId.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _handleError('Invalid call session ID.');
      });
      return;
    }

    // Authoritative real-time listener on the Firestore call document
    _callSub = FirebaseFirestore.instance
        .collection(FirestoreCollections.calls)
        .doc(trimmedCallId)
        .snapshots()
        .listen(
      (snapshot) {
        if (!mounted || _isClosed || _isNavigatingToActive) return;

        if (!snapshot.exists || snapshot.data() == null) {
          _handleError('Call session not found.');
          return;
        }

        final data = snapshot.data()!;
        final status = (data['callStatus'] ?? data['status'])
            ?.toString()
            .toLowerCase()
            .trim();
        final roomId = (data['roomId'] ??
                data['channelId'] ??
                'room_call_${widget.callId}')
            .toString();
        final endReason = data['endReason']?.toString();
        final docError = data['error']?.toString();

        if (status == CallingStatus.ringing) {
          setState(() {
            _statusText = 'Ringing...';
            _isRinging = true;
            _hasError = false;
            _errorMessage = null;
          });
        } else if (status == CallingStatus.accepted ||
            status == CallingStatus.connected) {
          _isNavigatingToActive = true;
          _callSub?.cancel();
          _callController.startCallDurationTimer(reset: true);
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (_) => ActiveCallScreen(
                callId: widget.callId,
                roomId: roomId,
                otherUserId: widget.receiverId,
                otherUserName: widget.receiverName,
                otherUserRole: widget.receiverRole,
                otherUserImage: widget.receiverImage,
                currentUserId: widget.currentUserId,
                currentUserName: widget.currentUserName,
                isCaller: true,
              ),
            ),
          );
        } else if (status == CallingStatus.rejected) {
          _setCallTerminationState(
            status: 'Call Declined',
            message: '${widget.receiverName} declined the call.',
            isError: false,
          );
        } else if (status == CallingStatus.busy) {
          _setCallTerminationState(
            status: 'User Busy',
            message: '${widget.receiverName} is currently on another call.',
            isError: false,
          );
        } else if (status == CallingStatus.missed) {
          _setCallTerminationState(
            status: 'No Answer',
            message: 'No answer from ${widget.receiverName}.',
            isError: false,
          );
        } else if (status == CallingStatus.failed) {
          _setCallTerminationState(
            status: 'Call Failed',
            message: docError ?? endReason ?? 'Could not establish connection.',
            isError: true,
          );
        } else if (status == CallingStatus.cancelled ||
            status == CallingStatus.ended) {
          _setCallTerminationState(
            status: 'Call Ended',
            message: endReason != null ? 'Call ended ($endReason)' : null,
            isError: false,
          );
        }
      },
      onError: (error) {
        debugPrint('⚠️ [OutgoingCallScreen] Firestore stream error: $error');
        _handleError('Connection error: $error');
      },
    );
  }

  void _handleError(String message) {
    if (!mounted || _isClosed || _isNavigatingToActive) return;
    _callSub?.cancel();
    setState(() {
      _hasError = true;
      _statusText = 'Error';
      _errorMessage = message;
      _isRinging = false;
    });
    ToastService.instance.showError(message);
    Future.delayed(const Duration(milliseconds: 1800), () {
      _closeScreen();
    });
  }

  void _setCallTerminationState({
    required String status,
    String? message,
    required bool isError,
  }) {
    if (!mounted || _isClosed || _isNavigatingToActive) return;
    _callSub?.cancel();
    setState(() {
      _statusText = status;
      _errorMessage = message;
      _hasError = isError;
      _isRinging = false;
    });

    if (message != null) {
      if (isError) {
        ToastService.instance.showError(message);
      } else {
        ToastService.instance.showInfo(message);
      }
    }

    Future.delayed(const Duration(milliseconds: 1600), () {
      _closeScreen();
    });
  }

  void _closeScreen() {
    if (!mounted || _isClosed || _isNavigatingToActive) return;
    _isClosed = true;
    _callSub?.cancel();
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    } else {
      AuthRoutingService.routeToAppropriatePortal(context);
    }
  }

  Future<void> _cancelCall() async {
    if (_isCancelling || _isClosed || _isNavigatingToActive) return;
    setState(() {
      _isCancelling = true;
      _statusText = 'Cancelling...';
      _isRinging = false;
    });

    try {
      if (widget.callId.trim().isNotEmpty) {
        await _callController.cancelCall(widget.callId.trim());
      }
    } catch (e) {
      debugPrint('⚠️ [OutgoingCallScreen] Cancel call error: $e');
    } finally {
      _closeScreen();
    }
  }

  @override
  void dispose() {
    _callSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final roleLabel = widget.receiverRole.toLowerCase() == 'doctor'
        ? 'Doctor'
        : 'Patient';

    return PopScope(
      canPop: !_isCancelling,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _cancelCall();
        }
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
                    vertical: 20,
                  ),
                  child: Column(
                    children: [
                      const SizedBox(height: 36),
                      // OPD Secure Calling Badge
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.lock_outline_rounded,
                              size: 14,
                              color: Color(0xFF37D2C2),
                            ),
                            SizedBox(width: 6),
                            Text(
                              'End-to-End Encrypted Voice Consultation',
                              style: TextStyle(
                                fontSize: 11.5,
                                color: Color(0xFFD6E4F5),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Spacer(),

                      // Profile Avatar with Pulse Ripple
                      CallAvatar(
                        imageUrl: widget.receiverImage,
                        name: widget.receiverName,
                        radius: 64,
                        isRinging: _isRinging && !_hasError && !_isCancelling,
                      ),
                      const SizedBox(height: 24),

                      // User Name
                      Text(
                        widget.receiverName,
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
                      const SizedBox(height: 8),

                      // Role Pill
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF11B7A8).withValues(alpha: 0.25),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: const Color(0xFF11B7A8).withValues(alpha: 0.5),
                          ),
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
                      const SizedBox(height: 16),

                      // Ringing / Calling / Error Status Row
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (!_hasError &&
                              !_isCancelling &&
                              _errorMessage == null)
                            const SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  Color(0xFF37D2C2),
                                ),
                              ),
                            )
                          else
                            Icon(
                              _hasError
                                  ? Icons.error_outline_rounded
                                  : Icons.info_outline_rounded,
                              size: 16,
                              color: _hasError
                                  ? const Color(0xFFFF5252)
                                  : const Color(0xFFE2E8F0),
                            ),
                          const SizedBox(width: 10),
                          Text(
                            _statusText,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                              color: _hasError
                                  ? const Color(0xFFFF5252)
                                  : Colors.white.withValues(alpha: 0.85),
                            ),
                          ),
                        ],
                      ),

                      // Detailed error or status message
                      if (_errorMessage != null &&
                          _errorMessage != _statusText) ...[
                        const SizedBox(height: 8),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: Text(
                            _errorMessage!,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 13,
                              color: _hasError
                                  ? const Color(0xFFFF8A80)
                                  : Colors.white.withValues(alpha: 0.7),
                            ),
                          ),
                        ),
                      ],

                      const Spacer(),

                      // Cancel Call Action Button
                      Opacity(
                        opacity: _isCancelling ? 0.6 : 1.0,
                        child: EndCallButton(
                          onPressed: _isCancelling ? () {} : _cancelCall,
                          size: 68,
                        ),
                      ),
                      const SizedBox(height: 32),
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
}
