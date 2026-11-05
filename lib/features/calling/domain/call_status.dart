// lib/features/calling/domain/call_status.dart

/// Centralized call lifecycle statuses and validation transitions for Voice Calling.
abstract class CallingStatus {
  CallingStatus._();

  static const String initiating = 'initiating';
  static const String calling = 'calling';
  static const String ringing = 'ringing';
  static const String accepted = 'accepted';
  static const String connecting = 'connecting';
  static const String connected = 'connected';
  static const String rejected = 'rejected';
  static const String cancelled = 'cancelled';
  static const String missed = 'missed';
  static const String ended = 'ended';
  static const String failed = 'failed';
  static const String busy = 'busy';

  /// Terminal statuses where call media and ringing have ceased.
  static const Set<String> terminal = {
    rejected,
    cancelled,
    missed,
    ended,
    failed,
    busy,
  };

  /// Active ringing/waiting states.
  static const Set<String> ringingStates = {
    initiating,
    calling,
    ringing,
  };

  /// Active live session states.
  static const Set<String> liveStates = {
    accepted,
    connecting,
    connected,
  };

  static bool isTerminal(String? status) =>
      status != null && terminal.contains(status.toLowerCase().trim());

  static bool isRinging(String? status) =>
      status != null && ringingStates.contains(status.toLowerCase().trim());

  static bool isConnected(String? status) =>
      status != null && status.toLowerCase().trim() == connected;

  static bool isLive(String? status) =>
      status != null && liveStates.contains(status.toLowerCase().trim());

  /// Whether a call can transition from [current] to [next].
  static bool canTransition(String? current, String next) {
    if (current == null) return next == initiating || next == calling;
    final from = current.toLowerCase().trim();
    final to = next.toLowerCase().trim();

    if (from == to) return true;
    if (isTerminal(from)) return false; // Terminal states are immutable

    switch (from) {
      case initiating:
        return to == calling || to == cancelled || to == failed || to == busy;
      case calling:
        return to == ringing ||
            to == accepted ||
            to == rejected ||
            to == cancelled ||
            to == missed ||
            to == failed ||
            to == busy;
      case ringing:
        return to == accepted ||
            to == rejected ||
            to == cancelled ||
            to == missed ||
            to == failed;
      case accepted:
        return to == connecting || to == connected || to == ended || to == failed;
      case connecting:
        return to == connected || to == ended || to == failed;
      case connected:
        return to == ended || to == failed;
      default:
        return !isTerminal(from);
    }
  }

  static bool canAccept(String? status) {
    if (status == null) return false;
    final s = status.toLowerCase().trim();
    return s == calling || s == ringing || s == initiating;
  }

  static bool canDecline(String? status) {
    if (status == null) return false;
    final s = status.toLowerCase().trim();
    return s == calling || s == ringing || s == initiating;
  }
}

