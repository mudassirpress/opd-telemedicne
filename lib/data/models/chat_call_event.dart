/// Normalized lifecycle of a call as it appears inside a conversation.
///
/// Firestore deliberately stores call timeline entries as ordinary chat
/// messages (`messageType: audio|video|call_recording`) with a free-form
/// `callData` map. That is convenient for the wire, but unsafe for the UI: a
/// message can be rendered long after the call document has moved on, and an
/// old `"in progress"` body must never keep a live-looking card on screen.
///
/// This model is the single place where those wire representations are
/// normalized. It is pure and has no Flutter/plugin dependency so the rules
/// can be unit-tested (and reused by a socket adapter later).
enum ChatCallStatus {
  calling,
  ringing,
  incoming,
  connecting,
  accepted,
  connected,
  ongoing,
  completed,
  missed,
  rejected,
  cancelled,
  busy,
  failed,
  recorded;

  static ChatCallStatus parse(Object? raw) {
    final value = (raw ?? '').toString().trim().toLowerCase();
    switch (value) {
      case 'calling':
      case 'dialing':
        return ChatCallStatus.calling;
      case 'ringing':
        return ChatCallStatus.ringing;
      case 'incoming':
        return ChatCallStatus.incoming;
      case 'connecting':
        return ChatCallStatus.connecting;
      case 'accepted':
      case 'answered':
        return ChatCallStatus.accepted;
      case 'connected':
        return ChatCallStatus.connected;
      case 'ongoing':
      case 'in_progress':
      case 'in-progress':
      case 'in progress':
      case 'active':
      case 'initiated':
        return ChatCallStatus.ongoing;
      case 'completed':
      case 'ended':
        return ChatCallStatus.completed;
      case 'missed':
      case 'no_answer':
      case 'no answer':
        return ChatCallStatus.missed;
      case 'rejected':
      case 'declined':
        return ChatCallStatus.rejected;
      case 'cancelled':
      case 'canceled':
        return ChatCallStatus.cancelled;
      case 'busy':
        return ChatCallStatus.busy;
      case 'recorded':
        return ChatCallStatus.recorded;
      case 'failed':
      case 'error':
        return ChatCallStatus.failed;
      default:
        return ChatCallStatus.completed;
    }
  }

  /// A call that still owns the live media session (or is about to).
  bool get isLive =>
      this == calling ||
      this == ringing ||
      this == incoming ||
      this == connecting ||
      this == accepted ||
      this == connected ||
      this == ongoing;

  /// A call that can no longer be re-joined.
  bool get isTerminal =>
      this == completed ||
      this == missed ||
      this == rejected ||
      this == cancelled ||
      this == busy ||
      this == failed;

  bool get isMissedOrRejected =>
      this == missed || this == rejected || this == cancelled;
}

/// Typed view over a call timeline message.
///
/// The original `callData` is kept for forward compatibility (recordings add
/// `recordingUrl`, for example), but every decision the UI makes uses the
/// normalized fields below.
class ChatCallEvent {
  final String? callId;
  final String callType;
  final ChatCallStatus status;
  final int? durationSeconds;
  final DateTime? startedAt;
  final DateTime? endedAt;
  final String rawMessage;

  /// Optional direct link to the uploaded recording.
  final String? recordingUrl;

  const ChatCallEvent({
    this.callId,
    required this.callType,
    required this.status,
    this.durationSeconds,
    this.startedAt,
    this.endedAt,
    this.rawMessage = '',
    this.recordingUrl,
  });

  bool get isLive => status.isLive;
  bool get isTerminal => status.isTerminal;
  bool get isRecording => status == ChatCallStatus.recorded;

  bool get hasDuration => durationSeconds != null && (durationSeconds ?? 0) > 0;

  /// True when this event must render as a completed call rather than a live
  /// one, even if its legacy body still says "in progress".
  bool get isCompletedLike =>
      status == ChatCallStatus.completed || status == ChatCallStatus.ongoing;

  /// WhatsApp-style card title. The timestamp/duration live beside it.
  String get title {
    final kind = _kindLabel;
    switch (status) {
      case ChatCallStatus.missed:
        return 'Missed ${kind.toLowerCase()} call';
      case ChatCallStatus.rejected:
        return 'Declined ${kind.toLowerCase()} call';
      case ChatCallStatus.cancelled:
        return 'Cancelled ${kind.toLowerCase()} call';
      case ChatCallStatus.busy:
        return 'Call declined - line busy';
      case ChatCallStatus.failed:
        return 'Call failed';
      case ChatCallStatus.recorded:
        return 'Call recording';
      case ChatCallStatus.calling:
      case ChatCallStatus.ringing:
      case ChatCallStatus.incoming:
      case ChatCallStatus.connecting:
      case ChatCallStatus.accepted:
      case ChatCallStatus.connected:
      case ChatCallStatus.ongoing:
        return '$kind call';
      case ChatCallStatus.completed:
        return '$kind call ended';
    }
  }

  String get _kindLabel =>
      callType.toLowerCase() == 'video' ? 'Video' : 'Audio';

  /// Builds an event from the fields that are actually persisted on a chat
  /// message. Falls back to reading the human-readable body for legacy rows
  /// written before `callData` existed.
  factory ChatCallEvent.fromMessageData({
    required String messageType,
    required String message,
    Map<String, dynamic>? callData,
    int? duration,
    DateTime? timestamp,
  }) {
    final data = callData ?? const <String, dynamic>{};
    final rawStatus = data['callStatus'] ?? data['status'];
    final body = message.toLowerCase();

    final ChatCallStatus status;
    if (rawStatus != null) {
      status = ChatCallStatus.parse(rawStatus);
    } else if (body.contains('missed') || body.contains('no answer')) {
      status = ChatCallStatus.missed;
    } else if (body.contains('reject') || body.contains('declined')) {
      status = ChatCallStatus.rejected;
    } else if (body.contains('cancel')) {
      status = ChatCallStatus.cancelled;
    } else if (body.contains('busy')) {
      status = ChatCallStatus.busy;
    } else if (body.contains('recording')) {
      status = ChatCallStatus.recorded;
    } else if (body.contains('ongoing') ||
        body.contains('in progress') ||
        body.contains('in-progress') ||
        body.contains('active call')) {
      status = ChatCallStatus.ongoing;
    } else if (body.contains('ended') || body.contains('completed')) {
      status = ChatCallStatus.completed;
    } else if (body.contains('started') || body.contains('calling')) {
      status = ChatCallStatus.calling;
    } else {
      status = ChatCallStatus.completed;
    }

    final effectiveStatus = messageType == 'call_recording'
        ? ChatCallStatus.recorded
        : status;

    final parsedDuration =
        _readInt(data['duration']) ?? _readFirstDuration(message) ?? duration;

    return ChatCallEvent(
      callId: _readString(data['callId'] ?? data['id']),
      callType:
          _readString(data['callType']) ??
          (messageType == 'video' ? 'video' : 'audio'),
      status: effectiveStatus,
      durationSeconds: parsedDuration,
      startedAt: _readDate(data['startedAt'] ?? data['startTime']) ?? timestamp,
      endedAt: _readDate(data['endedAt'] ?? data['endTime']),
      rawMessage: message,
      recordingUrl: _readString(data['recordingUrl']),
    );
  }

  ChatCallEvent copyWith({
    String? callId,
    String? callType,
    ChatCallStatus? status,
    int? durationSeconds,
    DateTime? startedAt,
    DateTime? endedAt,
    String? recordingUrl,
  }) {
    return ChatCallEvent(
      callId: callId ?? this.callId,
      callType: callType ?? this.callType,
      status: status ?? this.status,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      startedAt: startedAt ?? this.startedAt,
      endedAt: endedAt ?? this.endedAt,
      rawMessage: rawMessage,
      recordingUrl: recordingUrl ?? this.recordingUrl,
    );
  }

  static String? _readString(Object? value) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? null : text;
  }

  static int? _readInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  static DateTime? _readDate(Object? value) {
    if (value is DateTime) return value;
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
    if (value is String) return DateTime.tryParse(value);
    return null;
  }

  static int? _readFirstDuration(String message) {
    final match = RegExp(r'(\d{1,2}):(\d{2})').firstMatch(message);
    if (match == null) return null;
    final minutes = int.tryParse(match.group(1) ?? '') ?? 0;
    final seconds = int.tryParse(match.group(2) ?? '') ?? 0;
    return (minutes * 60) + seconds;
  }
}
