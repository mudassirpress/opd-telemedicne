import 'package:hive/hive.dart';

part 'offline_chat_message.g.dart';

/// Delivery status of a chat message used by the offline store.
enum OfflineDeliveryStatus {
  /// Message is queued locally but has not been sent to the server yet.
  pending,

  /// Message has been delivered to the server.
  sent,

  /// Message has been delivered to the receiver.
  delivered,
}

/// Read status of a chat message used by the offline store.
enum OfflineReadStatus {
  /// Message has not been seen by the receiver.
  unread,

  /// Message has been seen by the receiver.
  read,
}

@HiveType(typeId: 1)
class OfflineChatMessage {
  @HiveField(0)
  final String messageId;

  @HiveField(1)
  final String senderId;

  @HiveField(2)
  final String receiverId;

  @HiveField(3)
  final String message;

  @HiveField(4)
  final DateTime timestamp;

  @HiveField(5)
  final String messageType; // text, image, audio, video, document, call_recording

  @HiveField(6)
  final String deliveryStatus; // pending, sent, delivered

  @HiveField(7)
  final String readStatus; // unread, read

  @HiveField(8)
  final String? mediaUrl;

  @HiveField(9)
  final int? duration;

  @HiveField(10)
  final Map<String, dynamic>? callData;

  @HiveField(11)
  final bool isDeleted;

  @HiveField(12)
  final bool isEdited;

  @HiveField(13)
  final DateTime? editedAt;

  @HiveField(14)
  final String? deletedBy;

  @HiveField(15)
  final String? fileName;

  @HiveField(16)
  final bool isAdminMessage;

  @HiveField(17)
  final String? adminName;

  @HiveField(18)
  final String? adminId;

  @HiveField(19)
  final String? originalSenderId;

  @HiveField(20)
  final String? replyTo;

  /// The chat id this message belongs to (sorted participant pair).
  @HiveField(21)
  final String chatId;

  /// Set when [messageType] == 'prescription'. Links the locally cached
  /// prescription card to its `prescriptions/{prescriptionId}` document.
  @HiveField(22)
  final String? prescriptionId;

  /// Short note preview rendered inside the prescription card, kept locally so
  /// the card looks right even with no connection.
  @HiveField(23)
  final String? prescriptionNotePreview;

  /// Set when this message was produced by forwarding another chat's message.
  @HiveField(24)
  final bool isForwarded;

  /// When [isDeleted] is true, the moment "Delete for Everyone" was applied.
  @HiveField(25)
  final DateTime? deletedAt;

  /// When [messageType] == 'audio' or 'voice', whether the receiver listened to the message.
  @HiveField(26)
  final bool isListened;

  OfflineChatMessage({
    required this.messageId,
    required this.senderId,
    required this.receiverId,
    required this.message,
    required this.timestamp,
    required this.messageType,
    required this.deliveryStatus,
    required this.readStatus,
    this.mediaUrl,
    this.duration,
    this.callData,
    this.isDeleted = false,
    this.isEdited = false,
    this.editedAt,
    this.deletedBy,
    this.fileName,
    this.isAdminMessage = false,
    this.adminName,
    this.adminId,
    this.originalSenderId,
    this.replyTo,
    required this.chatId,
    this.prescriptionId,
    this.prescriptionNotePreview,
    this.isForwarded = false,
    this.deletedAt,
    this.isListened = false,
  });

  OfflineChatMessage copyWith({
    String? deliveryStatus,
    String? readStatus,
    bool? isDeleted,
    bool? isEdited,
    DateTime? editedAt,
    String? deletedBy,
    String? message,
    bool? isForwarded,
    DateTime? deletedAt,
    bool? isListened,
  }) {
    return OfflineChatMessage(
      messageId: messageId,
      senderId: senderId,
      receiverId: receiverId,
      message: message ?? this.message,
      timestamp: timestamp,
      messageType: messageType,
      deliveryStatus: deliveryStatus ?? this.deliveryStatus,
      readStatus: readStatus ?? this.readStatus,
      mediaUrl: mediaUrl,
      duration: duration,
      callData: callData,
      isDeleted: isDeleted ?? this.isDeleted,
      isEdited: isEdited ?? this.isEdited,
      editedAt: editedAt ?? this.editedAt,
      deletedBy: deletedBy ?? this.deletedBy,
      fileName: fileName,
      isAdminMessage: isAdminMessage,
      adminName: adminName,
      adminId: adminId,
      originalSenderId: originalSenderId,
      replyTo: replyTo,
      chatId: chatId,
      prescriptionId: prescriptionId,
      prescriptionNotePreview: prescriptionNotePreview,
      isForwarded: isForwarded ?? this.isForwarded,
      deletedAt: deletedAt ?? this.deletedAt,
      isListened: isListened ?? this.isListened,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'messageId': messageId,
      'senderId': senderId,
      'receiverId': receiverId,
      'message': message,
      'timestamp': timestamp.toIso8601String(),
      'messageType': messageType,
      'deliveryStatus': deliveryStatus,
      'readStatus': readStatus,
      if (mediaUrl != null) 'mediaUrl': mediaUrl,
      if (duration != null) 'duration': duration,
      if (callData != null) 'callData': callData,
      'isDeleted': isDeleted,
      'isEdited': isEdited,
      if (editedAt != null) 'editedAt': editedAt!.toIso8601String(),
      if (deletedBy != null) 'deletedBy': deletedBy,
      if (deletedAt != null) 'deletedAt': deletedAt!.toIso8601String(),
      if (fileName != null) 'fileName': fileName,
      'isAdminMessage': isAdminMessage,
      if (adminName != null) 'adminName': adminName,
      if (adminId != null) 'adminId': adminId,
      if (originalSenderId != null) 'originalSenderId': originalSenderId,
      if (replyTo != null) 'replyTo': replyTo,
      'chatId': chatId,
      if (prescriptionId != null) 'prescriptionId': prescriptionId,
      if (prescriptionNotePreview != null)
        'prescriptionNotePreview': prescriptionNotePreview,
      if (isListened) 'isListened': true,
    };
  }
}
