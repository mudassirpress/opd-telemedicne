import 'dart:async';
import 'package:flutter/material.dart';
import 'package:telemedicine/core/services/call_session_manager.dart';
import 'package:telemedicine/features/calls/presentation/controllers/call_controller.dart';

/// A draggable, compact floating overlay for an ongoing minimized call.
/// Displays call duration, remote party info, mute toggle, and hang-up button.
/// Tapping the card returns the user to [CallScreen].
class CallFloatingOverlay extends StatefulWidget {
  const CallFloatingOverlay({super.key});

  @override
  State<CallFloatingOverlay> createState() => _CallFloatingOverlayState();
}

class _CallFloatingOverlayState extends State<CallFloatingOverlay> {
  final CallController _callController = CallController();
  final CallSessionManager _sessionManager = CallSessionManager.instance;

  double _xOffset = 16.0;
  double _yOffset = 80.0;
  bool _isMuted = false;
  StreamSubscription<int>? _durationSub;
  int _duration = 0;

  @override
  void initState() {
    super.initState();
    _duration = _sessionManager.callDuration;
    _durationSub = _sessionManager.durationStream.listen((sec) {
      if (mounted) setState(() => _duration = sec);
    });
  }

  @override
  void dispose() {
    _durationSub?.cancel();
    super.dispose();
  }

  void _toggleMute() async {
    setState(() => _isMuted = !_isMuted);
    await _callController.muteMicrophone(_isMuted);
  }

  Future<void> _hangUp() async {
    await _sessionManager.endCall();
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final otherName = _sessionManager.otherUserName ?? 'In Call';
    final otherImage = _sessionManager.otherUserImage;
    final isVideo = _sessionManager.callType == 'video';

    return Positioned(
      left: _xOffset,
      top: _yOffset,
      child: GestureDetector(
        onPanUpdate: (details) {
          setState(() {
            _xOffset = (_xOffset + details.delta.dx)
                .clamp(8.0, screenSize.width - 240.0);
            _yOffset = (_yOffset + details.delta.dy)
                .clamp(32.0, screenSize.height - 100.0);
          });
        },
        onTap: () => _sessionManager.restoreCall(),
        child: Material(
          elevation: 12,
          borderRadius: BorderRadius.circular(20),
          color: Colors.transparent,
          child: Container(
            width: 230,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [
                  Color(0xFF1E3A8A),
                  Color(0xFF0F172A),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.2),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.5),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Avatar with pulse indicator
                Stack(
                  alignment: Alignment.center,
                  children: [
                    CircleAvatar(
                      radius: 18,
                      backgroundColor: Colors.white24,
                      backgroundImage: otherImage != null && otherImage.isNotEmpty
                          ? NetworkImage(otherImage)
                          : null,
                      child: otherImage == null || otherImage.isEmpty
                          ? Icon(
                              isVideo ? Icons.videocam : Icons.person,
                              color: Colors.white,
                              size: 18,
                            )
                          : null,
                    ),
                    Positioned(
                      bottom: 0,
                      right: 0,
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: Color(0xFF22C55E),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 8),
                // Name and duration
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        otherName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        CallSessionManager.formatDuration(_duration),
                        style: const TextStyle(
                          color: Color(0xFF94A3B8),
                          fontSize: 11,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                ),
                // Mute button
                GestureDetector(
                  onTap: _toggleMute,
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: _isMuted
                          ? const Color(0xFFEF4444).withValues(alpha: 0.8)
                          : Colors.white.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      _isMuted ? Icons.mic_off : Icons.mic,
                      color: Colors.white,
                      size: 14,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                // End call button
                GestureDetector(
                  onTap: _hangUp,
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: const BoxDecoration(
                      color: Color(0xFFEF4444),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.call_end,
                      color: Colors.white,
                      size: 14,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

