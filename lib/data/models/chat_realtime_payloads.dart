import 'chat_model.dart';

/// Wire-level event names used by the chat realtime channel.
///
/// The current backend is Firestore, so these payloads are also the contract
/// for the document patches the app writes. Keeping them explicit (rather than
/// sprinkling string maps through the controller) makes a future WebSocket
/// transport a drop-in replacement: encode with `toJson`, decode with
/// `fromJson`, and apply the same state transitions.
enum ChatRealtimeEvent {
  messageNew,
  deliveryReceipt,
  readMarker,
  typing,
  callStatus,
  voiceListened;

  static ChatRealtimeEvent parse(Object? raw) {
    for (final event in ChatRealtimeEvent.values) {
      if (event.name == raw) return event;
    }
    return ChatRealtimeEvent.messageNew;
  }
}

/// A sender's receipt transition acknowledged by the receiver's device.
///
/// `state` is always `sent`, `delivered` or `read`; `pending` is local-only and
/// must never be transmitted.
class DeliveryReceiptPayload {
  final String chatId;
  final String messageId;
  final String senderId;
  final String receiverId;
  final MessageDeliveryState state;
  final DateTime occurredAt;

  const DeliveryReceiptPayload({
    required this.chatId,
    required this.messageId,
    required this.senderId,
    required this.receiverId,
    required this.state,
    required this.occurredAt,
  });

  factory DeliveryReceiptPayload.fromJson(Map<String, dynamic> json) {
    return DeliveryReceiptPayload(
      chatId: _string(json['chatId']),
      messageId: _string(json['messageId']),
      senderId: _string(json['senderId']),
      receiverId: _string(json['receiverId']),
      state: MessageDeliveryState.parse(
        json['state'] ?? json['deliveryStatus'],
      ),
      occurredAt: _date(json['occurredAt']) ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
    'type': ChatRealtimeEvent.deliveryReceipt.name,
    'chatId': chatId,
    'messageId': messageId,
    'senderId': senderId,
    'receiverId': receiverId,
    'state': state.name,
    'occurredAt': occurredAt.toUtc().toIso8601String(),
  };

  /// The fields the receiver writes to the message document.
  Map<String, dynamic> toMessagePatch() => {
    'deliveryStatus': state.name,
    'isDelivered': state.index >= MessageDeliveryState.delivered.index,
    'isRead': state == MessageDeliveryState.read,
    if (state == MessageDeliveryState.delivered)
      'deliveredAt': occurredAt.toUtc().toIso8601String(),
    if (state == MessageDeliveryState.read)
      'readAt': occurredAt.toUtc().toIso8601String(),
  };

  bool get isValid => chatId.isNotEmpty && messageId.isNotEmpty;
}

/// Read marker for one or more messages in a conversation.
///
/// Batching is intentional: a viewport can expose several messages in one
/// frame, and one write per frame is cheaper than one write per bubble.
class ReadMarkerPayload {
  final String chatId;
  final String readerId;
  final List<String> messageIds;
  final DateTime readAt;

  const ReadMarkerPayload({
    required this.chatId,
    required this.readerId,
    required this.messageIds,
    required this.readAt,
  });

  factory ReadMarkerPayload.fromJson(Map<String, dynamic> json) {
    final rawIds = json['messageIds'];
    return ReadMarkerPayload(
      chatId: _string(json['chatId']),
      readerId: _string(json['readerId']),
      messageIds: rawIds is List
          ? rawIds.map((e) => e.toString()).toList(growable: false)
          : const [],
      readAt: _date(json['readAt']) ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
    'type': ChatRealtimeEvent.readMarker.name,
    'chatId': chatId,
    'readerId': readerId,
    'messageIds': messageIds,
    'readAt': readAt.toUtc().toIso8601String(),
  };

  Map<String, dynamic> toMessagePatch() => {
    'isRead': true,
    'is_read': true,
    'isDelivered': true,
    'deliveryStatus': MessageDeliveryState.read.name,
    'readAt': readAt.toUtc().toIso8601String(),
  };

  bool get isValid =>
      chatId.isNotEmpty && readerId.isNotEmpty && messageIds.isNotEmpty;
}

/// Ephemeral typing event. A receiver must ALSO enforce [ttlMs] locally so a
/// missed "stopped typing" event can never leave a permanent indicator.
class TypingPayload {
  final String chatId;
  final String userId;
  final bool isTyping;
  final DateTime sentAt;
  final int ttlMs;

  const TypingPayload({
    required this.chatId,
    required this.userId,
    required this.isTyping,
    required this.sentAt,
    this.ttlMs = 3000,
  });

  factory TypingPayload.fromJson(Map<String, dynamic> json) {
    return TypingPayload(
      chatId: _string(json['chatId']),
      userId: _string(json['userId']),
      isTyping: json['isTyping'] == true,
      sentAt: _date(json['sentAt']) ?? DateTime.now(),
      ttlMs: _int(json['ttlMs']) ?? 3000,
    );
  }

  Map<String, dynamic> toJson() => {
    'type': ChatRealtimeEvent.typing.name,
    'chatId': chatId,
    'userId': userId,
    'isTyping': isTyping,
    'sentAt': sentAt.toUtc().toIso8601String(),
    'ttlMs': ttlMs,
  };

  /// Firestore field names used by `ChatController.updateTypingStatus`.
  Map<String, dynamic> toChatPatch() => {
    'typing_$userId': isTyping,
    'lastTypingUpdate': sentAt.toUtc().toIso8601String(),
  };

  bool get isValid => chatId.isNotEmpty && userId.isNotEmpty;
  bool get isExpired =>
      DateTime.now().difference(sentAt).inMilliseconds > ttlMs;
}

/// Call-state synchronization event.
///
/// This is the event that lets the chat banner transform from
/// "In Progress" to "Call Ended / Duration" without waiting for a chat message
/// to be re-written.
class CallStatusPayload {
  final String callId;
  final String chatId;
  final String callType;
  final String status;
  final int? durationSeconds;
  final DateTime? startedAt;
  final DateTime? endedAt;
  final DateTime updatedAt;

  const CallStatusPayload({
    required this.callId,
    required this.chatId,
    required this.callType,
    required this.status,
    required this.updatedAt,
    this.durationSeconds,
    this.startedAt,
    this.endedAt,
  });

  factory CallStatusPayload.fromJson(Map<String, dynamic> json) {
    return CallStatusPayload(
      callId: _string(json['callId']),
      chatId: _string(json['chatId']),
      callType: _string(json['callType']).isEmpty
          ? 'audio'
          : _string(json['callType']),
      status: _string(json['status'] ?? json['callStatus']),
      durationSeconds: _int(json['duration'] ?? json['durationSeconds']),
      startedAt: _date(json['startedAt'] ?? json['startTime']),
      endedAt: _date(json['endedAt']),
      updatedAt: _date(json['updatedAt']) ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
    'type': ChatRealtimeEvent.callStatus.name,
    'callId': callId,
    'chatId': chatId,
    'callType': callType,
    'status': status,
    if (durationSeconds != null) 'duration': durationSeconds,
    if (startedAt != null) 'startedAt': startedAt!.toUtc().toIso8601String(),
    if (endedAt != null) 'endedAt': endedAt!.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  Map<String, dynamic> toCallPatch() => {
    'callStatus': status,
    'status': status,
    if (durationSeconds != null) 'duration': durationSeconds,
    if (startedAt != null) 'startTime': startedAt!.toUtc().toIso8601String(),
    if (endedAt != null) 'endedAt': endedAt!.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  bool get isValid => callId.isNotEmpty && status.isNotEmpty;
}

/// Optional versioned envelope for transports that multiplex event types.
class ChatRealtimeEnvelope {
  final int version;
  final ChatRealtimeEvent event;
  final Map<String, dynamic> payload;

  const ChatRealtimeEnvelope({
    required this.event,
    required this.payload,
    this.version = 1,
  });

  factory ChatRealtimeEnvelope.fromJson(Map<String, dynamic> json) {
    return ChatRealtimeEnvelope(
      version: _int(json['version']) ?? 1,
      event: ChatRealtimeEvent.parse(json['event'] ?? json['type']),
      payload:
          (json['payload'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{},
    );
  }

  Map<String, dynamic> toJson() => {
    'version': version,
    'event': event.name,
    'type': event.name,
    'payload': payload,
  };
}

String _string(Object? value) => value?.toString().trim() ?? '';

int? _int(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

DateTime? _date(Object? value) {
  if (value is DateTime) return value;
  if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
  if (value is String) return DateTime.tryParse(value);
  return null;
}
