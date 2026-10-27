import 'package:telemedicine/data/models/call_model.dart';
import 'package:telemedicine/data/models/chat_model.dart';

import 'models/offline_call_record.dart';
import 'models/offline_chat_message.dart';

/// Converters between the existing domain models (server/UI facing) and the
/// Hive-first offline models (local cache-facing).
class OfflineConverters {
  OfflineConverters._();

  // ─────────────────────────── CHAT MESSAGES ───────────────────────────

  /// The local `deliveryStatus` string for a domain message.
  ///
  /// A message read back from the server is by definition not
  /// [MessageDeliveryState.pending], so the state round-trips verbatim and
  /// never collapses `sent` into `delivered`.
  static String _toOfflineDeliveryStatus(ChatMessageModel message) {
    switch (message.deliveryStatus) {
      case MessageDeliveryState.pending:
        return OfflineDeliveryStatus.pending.name;
      case MessageDeliveryState.sent:
        return OfflineDeliveryStatus.sent.name;
      case MessageDeliveryState.delivered:
      case MessageDeliveryState.read:
        return OfflineDeliveryStatus.delivered.name;
    }
  }

  static OfflineChatMessage toOffline(ChatMessageModel message, String chatId) {
    return OfflineChatMessage(
      messageId: message.id,
      senderId: message.senderId,
      receiverId: message.receiverId,
      message: message.message,
      timestamp: message.timestamp,
      messageType: message.messageType,
      deliveryStatus: _toOfflineDeliveryStatus(message),
      readStatus: message.isRead
          ? OfflineReadStatus.read.name
          : OfflineReadStatus.unread.name,
      mediaUrl: message.mediaUrl,
      duration: message.duration,
      callData: message.callData,
      isDeleted: message.isDeleted,
      isEdited: message.isEdited,
      editedAt: message.editedAt,
      deletedBy: message.deletedBy,
      fileName: message.fileName,
      isAdminMessage: message.isAdminMessage,
      adminName: message.adminName,
      adminId: message.adminId,
      originalSenderId: message.originalSenderId,
      replyTo: message.replyTo != null
          ? _replyDataToJson(message.replyTo!)
          : null,
      chatId: chatId,
      prescriptionId: message.prescriptionId,
      prescriptionNotePreview: message.prescriptionNotePreview,
      isForwarded: message.isForwarded,
      deletedAt: message.deletedAt,
      isListened: message.isListened,
    );
  }

  static ChatMessageModel toDomain(OfflineChatMessage m) {
    final isRead = m.readStatus == OfflineReadStatus.read.name;
    final isDelivered =
        m.deliveryStatus == OfflineDeliveryStatus.delivered.name;

    return ChatMessageModel(
      id: m.messageId,
      senderId: m.senderId,
      receiverId: m.receiverId,
      message: m.message,
      messageType: m.messageType,
      timestamp: m.timestamp,
      isRead: isRead,
      isDelivered: isDelivered,
      // The local row is the authority for a queued message: a `pending` row
      // has never reached Firestore and must not be reported as delivered just
      // because the local store flushes it as `sent`.
      deliveryStatus: deriveDeliveryState(
        localStatus: m.deliveryStatus,
        isRead: isRead,
        isDelivered: isDelivered,
      ),
      mediaUrl: m.mediaUrl,
      duration: m.duration,
      callData: m.callData,
      isDeleted: m.isDeleted,
      isEdited: m.isEdited,
      editedAt: m.editedAt,
      replyTo: m.replyTo != null ? _replyDataFromJson(m.replyTo!) : null,
      deletedBy: m.deletedBy,
      fileName: m.fileName,
      isAdminMessage: m.isAdminMessage,
      adminName: m.adminName,
      adminId: m.adminId,
      originalSenderId: m.originalSenderId,
      prescriptionId: m.prescriptionId,
      prescriptionNotePreview: m.prescriptionNotePreview,
      isForwarded: m.isForwarded,
      deletedAt: m.deletedAt,
      isListened: m.isListened,
    );
  }

  static String _replyDataToJson(ReplyData reply) => reply.toMap().toString();

  static ReplyData _replyDataFromJson(String raw) {
    // The string is the toString() of ReplyData.toMap(), e.g.
    // "{messageId: x, message: y, senderName: z, messageType: text}".
    final Map<String, String> values = {};
    var content = raw.trim();
    if (content.startsWith('{')) content = content.substring(1);
    if (content.endsWith('}'))
      content = content.substring(0, content.length - 1);
    for (final part in content.split(',')) {
      final idx = part.indexOf(':');
      if (idx < 0) continue;
      final key = part.substring(0, idx).trim();
      var value = part.substring(idx + 1).trim();
      if (value.startsWith('[') && value.endsWith(']')) {
        // Nested value; keep only the simple keys we care about.
        continue;
      }
      values[key] = value;
    }
    return ReplyData(
      messageId: values['messageId'] ?? '',
      message: values['message'] ?? raw,
      senderName: values['senderName'] ?? '',
      messageType: values['messageType'] ?? 'text',
      mediaUrl: values['mediaUrl'],
    );
  }

  // ─────────────────────────── CALL RECORDS ───────────────────────────

  static OfflineCallRecord toOfflineCall(CallModel call) {
    return OfflineCallRecord(
      callId: call.id,
      callerId: call.callerId,
      receiverId: call.receiverId,
      callType: call.callType,
      startTime: call.startTime,
      endTime: call.endedAt,
      duration: call.duration,
      callStatus: call.callStatus,
      callerName: call.callerName,
      receiverName: call.receiverName,
      callerImage: call.callerImage,
      receiverImage: call.receiverImage,
      channelId: call.channelId,
      synced: true,
    );
  }

  static CallModel toDomainCall(OfflineCallRecord c) {
    return CallModel(
      id: c.callId,
      callerId: c.callerId,
      receiverId: c.receiverId,
      callerName: c.callerName ?? '',
      receiverName: c.receiverName ?? '',
      callerImage: c.callerImage,
      receiverImage: c.receiverImage,
      channelId: c.channelId,
      callType: c.callType,
      callStatus: c.callStatus,
      startTime: c.startTime,
      endedAt: c.endTime,
      duration: c.duration,
    );
  }
}
