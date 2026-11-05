import 'dart:async';
import 'package:flutter/material.dart';
import 'package:telemedicine/core/services/notification_service.dart';
import 'package:telemedicine/features/calls/presentation/call_screen.dart';
import 'package:telemedicine/features/calls/presentation/controllers/call_controller.dart';
import 'package:telemedicine/features/calls/presentation/widgets/call_floating_overlay.dart';

/// Manages global persistence of an ongoing call session.
///
/// When the user leaves [CallScreen] via the back button or minimize gesture,
/// the underlying Zego media stream is kept alive and a compact floating
/// overlay is rendered over the app. Tapping the overlay restores the full
/// [CallScreen] without reconnecting or interrupting the media.
class CallSessionManager {
  CallSessionManager._internal();
  static final CallSessionManager instance = CallSessionManager._internal();

  final CallController _callController = CallController();

  // Active call metadata
  String? _callId;
  String? _channelId;
  String? _callType;
  String? _otherUserName;
  String? _otherUserImage;
  String? _currentUserId;
  String? _otherUserId;
  String? _otherUserType;
  bool _isCaller = true;

  // Session state
  bool _isCallActive = false;
  bool _isMinimized = false;
  bool _isMediaConnected = false;
  int _callDuration = 0;
  Timer? _durationTimer;
  OverlayEntry? _overlayEntry;

  // Streams for UI components to listen to
  final StreamController<int> _durationController =
      StreamController<int>.broadcast();
  final StreamController<bool> _minimizedStateController =
      StreamController<bool>.broadcast();

  // Getters
  bool get isCallActive => _isCallActive;
  bool get isMinimized => _isMinimized;
  bool get isMediaConnected => _isMediaConnected;
  int get callDuration => _callDuration;
  String? get currentCallId => _callId;
  String? get channelId => _channelId;
  String? get callType => _callType;
  String? get otherUserName => _otherUserName;
  String? get otherUserImage => _otherUserImage;
  String? get currentUserId => _currentUserId;
  String? get otherUserId => _otherUserId;
  String? get otherUserType => _otherUserType;
  bool get isCaller => _isCaller;

  Stream<int> get durationStream => _durationController.stream;
  Stream<bool> get minimizedStateStream => _minimizedStateController.stream;

  /// True when [callId] is the session currently owning the media engine.
  bool isCurrentSession(String callId) =>
      _isCallActive && _callId != null && _callId == callId;

  /// Called once media is actually flowing, so a restored [CallScreen] can
  /// skip re-joining and go straight to the connected UI.
  void markMediaConnected() {
    if (!_isCallActive) return;
    _isMediaConnected = true;
  }

  /// A restored screen must not call `startSession` again for the same call:
  /// doing so used to reset the duration to 00:00 and restart the timer.
  void resumeSession({required String callId}) {
    if (!isCurrentSession(callId)) return;
    _isMinimized = false;
    hideOverlay();
    _minimizedStateController.add(false);
  }

  /// Starts tracking a call session. Called when [CallScreen] mounts.
  void startSession({
    required String callId,
    required String channelId,
    required String callType,
    required String otherUserName,
    required String otherUserImage,
    required String currentUserId,
    required String otherUserId,
    required String otherUserType,
    required bool isCaller,
  }) {
    if (isCurrentSession(callId)) {
      resumeSession(callId: callId);
      return;
    }
    _callId = callId;
    _channelId = channelId;
    _callType = callType;
    _otherUserName = otherUserName;
    _otherUserImage = otherUserImage;
    _currentUserId = currentUserId;
    _otherUserId = otherUserId;
    _otherUserType = otherUserType;
    _isCaller = isCaller;
    _isCallActive = true;
    _isMinimized = false;
    _isMediaConnected = false;
    _callDuration = 0;

    _durationTimer?.cancel();
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_isCallActive) {
        _callDuration++;
        _durationController.add(_callDuration);
      }
    });

    hideOverlay();
  }

  /// Minimizes the current call to a floating overlay and pops the [CallScreen].
  void minimize(BuildContext context) {
    if (!_isCallActive || _isMinimized) return;
    _isMinimized = true;
    _minimizedStateController.add(true);

    _showOverlay();
    Navigator.of(context).pop();
  }

  /// Restores the minimized call back to the full-screen [CallScreen].
  ///
  /// Returns false when the navigator is not ready, so callers can retry
  /// instead of silently dropping the user's tap.
  bool restoreCall() {
    if (!_isCallActive || !_isMinimized) return false;
    final context = NotificationService.navigatorKey.currentContext;
    if (context == null) return false;

    hideOverlay();
    _isMinimized = false;
    _minimizedStateController.add(false);

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CallScreen(
          channelId: _channelId ?? '',
          callId: _callId ?? '',
          callType: _callType ?? 'audio',
          otherUserName: _otherUserName ?? '',
          otherUserImage: _otherUserImage ?? '',
          currentUserId: _currentUserId ?? '',
          otherUserId: _otherUserId ?? '',
          otherUserType: _otherUserType ?? 'patient',
          isCaller: _isCaller,
        ),
      ),
    );
    return true;
  }

  /// Displays the persistent floating call overlay.
  void showOverlay() => _showOverlay();
  void endSession() => forceClearSession();

  void _showOverlay() {
    hideOverlay();
    final overlayState = NotificationService.navigatorKey.currentState?.overlay;
    if (overlayState == null) return;

    _overlayEntry = OverlayEntry(
      builder: (context) => const CallFloatingOverlay(),
    );
    overlayState.insert(_overlayEntry!);
  }

  /// Removes the floating overlay from the screen.
  void hideOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  /// Completely resets all session metadata and dismisses floating overlays.
  void forceClearSession() {
    _isCallActive = false;
    _isMinimized = false;
    _isMediaConnected = false;
    _callId = null;
    _channelId = null;
    _durationTimer?.cancel();
    _durationTimer = null;
    _callDuration = 0;
    hideOverlay();
    _minimizedStateController.add(false);
  }

  /// Completely ends the active call session and cleans up media resources.
  Future<void> endCall() async {
    final idToEnd = _callId;
    forceClearSession();
    if (idToEnd != null && idToEnd.isNotEmpty) {
      await _callController.terminateAndCleanupCall(
        callId: idToEnd,
        reason: 'session_manager_end',
      );
    }
  }

  /// Formats seconds into mm:ss or hh:mm:ss
  static String formatDuration(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}
