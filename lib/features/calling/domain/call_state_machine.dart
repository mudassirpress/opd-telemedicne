// lib/features/calling/domain/call_state_machine.dart

import 'package:flutter/foundation.dart';
import 'package:telemedicine/features/calling/domain/call_status.dart';

/// Centralized state machine managing voice call state transitions safely.
class CallStateMachine {
  String _currentStatus;
  final String callId;

  CallStateMachine({
    required this.callId,
    String initialStatus = CallingStatus.initiating,
  }) : _currentStatus = initialStatus;

  String get currentStatus => _currentStatus;
  bool get isTerminal => CallingStatus.isTerminal(_currentStatus);
  bool get isRinging => CallingStatus.isRinging(_currentStatus);
  bool get isConnected => CallingStatus.isConnected(_currentStatus);

  /// Attempts to transition to [newStatus].
  /// Returns `true` if transition was legal and performed, `false` otherwise.
  bool transitionTo(String newStatus) {
    if (_currentStatus == newStatus) return true;

    if (!CallingStatus.canTransition(_currentStatus, newStatus)) {
      debugPrint(
        '⚠️ [CallStateMachine] Illegal transition for call $callId: '
        '$_currentStatus -> $newStatus rejected.',
      );
      return false;
    }

    final old = _currentStatus;
    _currentStatus = newStatus;
    debugPrint(
      '🔄 [CallStateMachine] Call $callId transitioned: $old -> $newStatus',
    );
    return true;
  }
}

