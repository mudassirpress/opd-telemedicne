// chat_model.dart - Updated with reply functionality

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:telemedicine/data/models/chat_call_event.dart';

class ReplyData {
  final String messageId;
  final String message;
  final String senderName;
  final String messageType;
  final String? mediaUrl;

  ReplyData({
    required this.messageId,
    required this.message,
    required this.senderName,
    required this.messageType,
    this.mediaUrl,
  });

  Map<String, dynamic> toMap() {
    return {
      'messageId': messageId,
      'message': message,
      'senderName': senderName,
      'messageType': messageType,
      if (mediaUrl != null) 'mediaUrl': mediaUrl,
    };
  }

  factory ReplyData.fromMap(Map<String, dynamic> map) {
    return ReplyData(
      messageId: map['messageId'] ?? '',
      message: map['message'] ?? '',
      senderName: map['senderName'] ?? '',
      messageType: map['messageType'] ?? 'text',
      mediaUrl: map['mediaUrl'],
    );
  }
}

/// Lifecycle of a chat message, mirroring WhatsApp's four-stage receipt.
///
/// ```
/// pending   ->  sent  ->  delivered  ->  read
///   clock        one     two grey      two blue
/// ```
///
/// [MessageDeliveryState.pending] is a **local-only** state: a queued message
/// that has not reached Firestore yet. It is never written to the server,
/// because a document that exists in Firestore has, by definition, been
/// uploaded. Every other state is synchronised through the server.
enum MessageDeliveryState {
  /// Queued locally, not yet uploaded. Rendered as a clock.
  pending,

  /// Uploaded to Firestore; the receiver has not acknowledged it. Single tick.
  sent,

  /// Uploaded and acknowledged by the receiver's device. Double grey tick.
  delivered,

  /// Seen by the receiver. Double blue tick.
  read;

  static MessageDeliveryState parse(Object? raw) {
    for (final value in MessageDeliveryState.values) {
      if (value.name == raw) return value;
    }
    return MessageDeliveryState.sent;
  }
}

/// Maps a legacy document (written before `deliveryStatus` existed) onto a
/// state, using only the booleans it carries.
///
/// Such a document exists in Firestore, so it was certainly uploaded — it is
/// never [MessageDeliveryState.pending]. It can be `read` or `delivered`, and
/// otherwise plain `sent`.
///
/// Static and pure so the migration rule is unit-testable.
MessageDeliveryState deriveLegacyDeliveryState({
  required bool isRead,
  required bool isDelivered,
}) {
  if (isRead) return MessageDeliveryState.read;
  if (isDelivered) return MessageDeliveryState.delivered;
  return MessageDeliveryState.sent;
}

/// Reconciles a locally stored `deliveryStatus` string with the booleans on the
/// same Hive row.
///
/// The local status is authoritative for queueing: a row is only `pending`
/// while nothing has been uploaded, and the `isDelivered` / `isRead` values on
/// that row are *derived from* the status rather than independent evidence, so
/// they cannot promote a queued message to `sent`. An earlier "most advanced
/// wins" version of this rule did exactly that and turned every clock into a
/// single tick the moment it was read back.
///
/// `read` is the one exception and always wins, because a message cannot be
/// un-read.
///
/// This is deliberately *not* where a stale local row gets corrected — that
/// happens in the merge, where the server copy is also present and is compared
/// by `ChatController.preferNewerDeliveryStatus`.
///
/// Static and pure so the rule is unit-testable.
MessageDeliveryState deriveDeliveryState({
  required String localStatus,
  required bool isRead,
  required bool isDelivered,
}) {
  final local = MessageDeliveryState.parse(localStatus);

  if (isRead || local == MessageDeliveryState.read) {
    return MessageDeliveryState.read;
  }
  if (local == MessageDeliveryState.pending) {
    return MessageDeliveryState.pending;
  }
  if (local == MessageDeliveryState.delivered) {
    return MessageDeliveryState.delivered;
  }
  return isDelivered
      ? MessageDeliveryState.delivered
      : MessageDeliveryState.sent;
}

/// Reads a date field written by either side: Firestore `Timestamp`, a Dart
/// [DateTime] (Hive rows, tests) or epoch milliseconds. Returns null otherwise.
DateTime? readDateTime(Object? value) {
  if (value == null) return null;
  if (value is Timestamp) return value.toDate();
  if (value is DateTime) return value;
  if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
  if (value is String) return DateTime.tryParse(value);
  return null;
}

class ChatMessageModel {
  final String id;
  final String senderId;
  final String receiverId;
  final String message;
  final String
  messageType; // 'text', 'image', 'audio', 'video', 'document', 'call_recording', 'prescription', 'appointment'
  final DateTime timestamp;
  final bool isRead;
  final bool isDelivered;
  final DateTime? deliveredAt;
  final DateTime? readAt;
  final String? mediaUrl;
  final int? duration;
  final Map<String, dynamic>? callData;

  // Admin messaging fields
  final bool isAdminMessage;
  final String? adminName;
  final String? adminId;
  final String? originalSenderId;

  // New fields for message management
  final bool isDeleted;
  final bool isEdited;
  final DateTime? editedAt;
  final ReplyData? replyTo;
  final String? deletedBy;
  final String? fileName;

  /// Set when this message was produced by forwarding another chat's message.
  /// Renders the "Forwarded" label above the bubble.
  final bool isForwarded;

  /// When [isDeleted] is true, the moment "Delete for Everyone" was applied.
  final DateTime? deletedAt;

  /// Set when [messageType] == 'prescription'. Links this chat message to the
  /// `prescriptions/{prescriptionId}` document, which is what the card in the
  /// bubble and the Prescription Detail page read.
  final String? prescriptionId;

  /// A short, single-line preview of the prescription note, stored on the
  /// message itself so the card renders instantly (and offline) without
  /// fetching the prescription document.
  final String? prescriptionNotePreview;

  /// Original PDF download URL for prescription documents.
  final String? pdfUrl;

  /// Rendered preview image URL (PNG) of the prescription page.
  final String? previewImageUrl;

  /// Creation date of the prescription.
  final DateTime? prescriptionDate;

  /// Doctor's name for prescription cards.
  final String? doctorName;

  /// True for the system message written when a doctor confirms an
  /// appointment. Pinned messages are rendered as a banner at the top of the
  /// conversation until the appointment ends.
  final bool isPinned;

  /// Set alongside [isPinned]; links back to `appointments/{appointmentId}`
  /// so the banner and the appointment record can be reconciled.
  final String? appointmentId;

  /// Authoritative delivery state.
  ///
  /// Present on the wire for messages written after this field was introduced.
  /// Documents written before it carry only the legacy `isRead` / `isDelivered`
  /// booleans and are mapped onto a state by [fromMap] — see [_legacyState].
  ///
  /// Note that `isDelivered` alone cannot express this: `false` means both
  /// "queued, never uploaded" and "uploaded, receiver offline", and those need
  /// a clock and a single tick respectively.
  final MessageDeliveryState deliveryStatus;

  /// True when a voice message has been listened to by the receiver.
  final bool isListened;

  /// The timestamp when the voice message was marked as listened.
  final DateTime? listenedAt;

  /// The user ID of the receiver who listened to the voice message.
  final String? listenedBy;

  ChatMessageModel({
    required this.id,
    required this.senderId,
    required this.receiverId,
    required this.message,
    required this.messageType,
    required this.timestamp,
    this.isRead = false,
    this.isDelivered = false,
    this.deliveredAt,
    this.readAt,
    this.mediaUrl,
    this.duration,
    this.callData,
    this.isAdminMessage = false,
    this.adminName,
    this.adminId,
    this.originalSenderId,
    this.isDeleted = false,
    this.isEdited = false,
    this.editedAt,
    this.replyTo,
    this.deletedBy,
    this.fileName,
    this.isForwarded = false,
    this.deletedAt,
    this.prescriptionId,
    this.prescriptionNotePreview,
    this.pdfUrl,
    this.previewImageUrl,
    this.prescriptionDate,
    this.doctorName,
    this.isPinned = false,
    this.appointmentId,
    this.deliveryStatus = MessageDeliveryState.sent,
    this.isListened = false,
    this.listenedAt,
    this.listenedBy,
  });

  factory ChatMessageModel.fromMap(Map<String, dynamic> map) {
    final isRead = map['isRead'] == true || map['is_read'] == true;
    final isDelivered = map['isDelivered'] ?? false;
    final rawStatus = map['deliveryStatus'];
    final rawDeleted =
        map['isDeleted'] == true || map['isDeletedForEveryone'] == true;

    return ChatMessageModel(
      id: map['id'] ?? '',
      senderId: map['senderId'] ?? map['sender_id'] ?? '',
      receiverId:
          map['receiverId'] ?? map['recipient_id'] ?? map['receiver_id'] ?? '',
      message: map['message'] ?? '',
      messageType: map['messageType'] ?? 'text',
      timestamp:
          readDateTime(
            map['serverTimestamp'] ?? map['timestamp'] ?? map['createdAt'],
          ) ??
          DateTime.now(),
      isRead: isRead,
      isDelivered: isDelivered,
      deliveryStatus: rawStatus != null
          ? MessageDeliveryState.parse(rawStatus)
          : deriveLegacyDeliveryState(isRead: isRead, isDelivered: isDelivered),
      deliveredAt: (map['deliveredAt'] as Timestamp?)?.toDate(),
      readAt: (map['readAt'] as Timestamp?)?.toDate(),
      mediaUrl: map['mediaUrl'],
      duration: map['duration'],
      callData: map['callData'],
      isAdminMessage: map['isAdminMessage'] ?? false,
      adminName: map['adminName'],
      adminId: map['adminId'],
      originalSenderId: map['originalSenderId'],
      isDeleted: rawDeleted,
      isEdited: map['isEdited'] ?? false,
      editedAt: readDateTime(map['editedAt']),
      replyTo: map['replyTo'] != null
          ? ReplyData.fromMap(map['replyTo'])
          : null,
      deletedBy: map['deletedBy'],
      isForwarded: map['isForwarded'] ?? false,
      deletedAt: readDateTime(map['deletedAt']),
      fileName: map['fileName'],
      prescriptionId: map['prescriptionId'],
      prescriptionNotePreview: map['prescriptionNotePreview'],
      pdfUrl: map['pdfUrl']?.toString(),
      previewImageUrl: (map['previewImageUrl'] ?? map['previewUrl'])?.toString(),
      prescriptionDate: readDateTime(map['prescriptionDate']),
      doctorName: map['doctorName']?.toString(),
      isPinned: map['isPinned'] ?? false,
      appointmentId: map['appointmentId'],
      isListened: map['isListened'] == true || map['is_listened'] == true,
      listenedAt: readDateTime(map['listenedAt']),
      listenedBy: map['listenedBy']?.toString(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'senderId': senderId,
      'receiverId': receiverId,
      'message': message,
      'messageType': messageType,
      'timestamp': Timestamp.fromDate(timestamp),
      'serverTimestamp': FieldValue.serverTimestamp(),
      'isRead': isRead,
      'isDelivered': isDelivered,
      // Never writes `pending`: a document in Firestore has been uploaded, and
      // the receiver derives their state from the booleans above. A caller that
      // somehow holds a pending model should persist it as `sent`.
      'deliveryStatus': deliveryStatus == MessageDeliveryState.pending
          ? MessageDeliveryState.sent.name
          : deliveryStatus.name,
      if (deliveredAt != null) 'deliveredAt': Timestamp.fromDate(deliveredAt!),
      if (readAt != null) 'readAt': Timestamp.fromDate(readAt!),
      'isAdminMessage': isAdminMessage,
      'isDeleted': isDeleted,
      'isEdited': isEdited,
      if (editedAt != null) 'editedAt': Timestamp.fromDate(editedAt!),
      if (replyTo != null) 'replyTo': replyTo!.toMap(),
      if (deletedBy != null) 'deletedBy': deletedBy,
      if (deletedAt != null) 'deletedAt': Timestamp.fromDate(deletedAt!),
      // Mirrored so older devices that only know `isDeleted` and newer code
      // that reads either flag agree on the same state.
      if (isDeleted) 'isDeletedForEveryone': true,
      if (isForwarded) 'isForwarded': true,
      if (mediaUrl != null) 'mediaUrl': mediaUrl,
      if (duration != null) 'duration': duration,
      if (callData != null) 'callData': callData,
      if (adminName != null) 'adminName': adminName,
      if (adminId != null) 'adminId': adminId,
      if (originalSenderId != null) 'originalSenderId': originalSenderId,
      'fileName': fileName,
      if (prescriptionId != null) 'prescriptionId': prescriptionId,
      if (prescriptionNotePreview != null)
        'prescriptionNotePreview': prescriptionNotePreview,
      if (pdfUrl != null) 'pdfUrl': pdfUrl,
      if (previewImageUrl != null) 'previewImageUrl': previewImageUrl,
      if (prescriptionDate != null)
        'prescriptionDate': Timestamp.fromDate(prescriptionDate!),
      if (doctorName != null) 'doctorName': doctorName,
      'isPinned': isPinned,
      if (appointmentId != null) 'appointmentId': appointmentId,
      'isListened': isListened,
      if (listenedAt != null) 'listenedAt': Timestamp.fromDate(listenedAt!),
      if (listenedBy != null) 'listenedBy': listenedBy,
    };
  }

  /// True when this message carries a prescription card rather than plain text.
  bool get isPrescription => messageType == 'prescription';

  /// True when this row is a call timeline event (audio/video call, recording).
  bool get isCallEvent =>
      messageType == 'audio' ||
      messageType == 'video' ||
      messageType == 'call_recording';

  /// Normalized call event for the timeline/call card, or null for non-call
  /// rows. The raw `callData` map remains available for forward compatibility.
  ChatCallEvent? get callEvent {
    if (!isCallEvent) return null;
    return ChatCallEvent.fromMessageData(
      messageType: messageType,
      message: message,
      callData: callData,
      duration: duration,
      timestamp: timestamp,
    );
  }

  /// The call document id when the writer persisted one. Legacy rows may not
  /// have it; the UI then relies on the live CallController instead.
  String? get callId {
    final value = callData?['callId'] ?? callData?['id'];
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? null : text;
  }

  /// True when this is the system message created for a confirmed appointment.
  bool get isAppointmentMessage => messageType == 'appointment';

  /// True when the message is still queued on this device and has not been
  /// uploaded. The UI renders a clock for these.
  bool get isPending => deliveryStatus == MessageDeliveryState.pending;

  /// Returns a copy advanced to [status], keeping the legacy booleans
  /// consistent so older readers and any code still keyed on `isDelivered`
  /// cannot regress.
  ///
  /// The state machine only ever moves forward; an attempt to go backwards is
  /// ignored, because Firestore snapshots can arrive out of order and a late
  /// `sent` must not downgrade a message the receiver has already read.
  ChatMessageModel withDeliveryStatus(MessageDeliveryState status) {
    if (status.index <= deliveryStatus.index) return this;
    return ChatMessageModel(
      id: id,
      senderId: senderId,
      receiverId: receiverId,
      message: message,
      messageType: messageType,
      timestamp: timestamp,
      isRead: status == MessageDeliveryState.read,
      isDelivered: status.index >= MessageDeliveryState.delivered.index,
      deliveredAt: deliveredAt,
      readAt: readAt,
      mediaUrl: mediaUrl,
      duration: duration,
      callData: callData,
      isAdminMessage: isAdminMessage,
      adminName: adminName,
      adminId: adminId,
      originalSenderId: originalSenderId,
      isDeleted: isDeleted,
      isEdited: isEdited,
      editedAt: editedAt,
      replyTo: replyTo,
      deletedBy: deletedBy,
      fileName: fileName,
      isForwarded: isForwarded,
      deletedAt: deletedAt,
      prescriptionId: prescriptionId,
      prescriptionNotePreview: prescriptionNotePreview,
      isPinned: isPinned,
      appointmentId: appointmentId,
      deliveryStatus: status,
      isListened: isListened,
      listenedAt: listenedAt,
      listenedBy: listenedBy,
    );
  }

  /// Copy with any subset of fields replaced. `null` keeps the current value
  /// (pass the sentinel explicitly via a fresh constructor if you must clear).
  ChatMessageModel copyWith({
    String? id,
    String? senderId,
    String? receiverId,
    String? message,
    String? messageType,
    DateTime? timestamp,
    bool? isRead,
    bool? isDelivered,
    DateTime? deliveredAt,
    DateTime? readAt,
    String? mediaUrl,
    int? duration,
    Map<String, dynamic>? callData,
    bool? isAdminMessage,
    String? adminName,
    String? adminId,
    String? originalSenderId,
    bool? isDeleted,
    bool? isEdited,
    DateTime? editedAt,
    ReplyData? replyTo,
    String? deletedBy,
    String? fileName,
    bool? isForwarded,
    DateTime? deletedAt,
    String? prescriptionId,
    String? prescriptionNotePreview,
    bool? isPinned,
    String? appointmentId,
    MessageDeliveryState? deliveryStatus,
    bool? isListened,
    DateTime? listenedAt,
    String? listenedBy,
  }) {
    return ChatMessageModel(
      id: id ?? this.id,
      senderId: senderId ?? this.senderId,
      receiverId: receiverId ?? this.receiverId,
      message: message ?? this.message,
      messageType: messageType ?? this.messageType,
      timestamp: timestamp ?? this.timestamp,
      isRead: isRead ?? this.isRead,
      isDelivered: isDelivered ?? this.isDelivered,
      deliveredAt: deliveredAt ?? this.deliveredAt,
      readAt: readAt ?? this.readAt,
      mediaUrl: mediaUrl ?? this.mediaUrl,
      duration: duration ?? this.duration,
      callData: callData ?? this.callData,
      isAdminMessage: isAdminMessage ?? this.isAdminMessage,
      adminName: adminName ?? this.adminName,
      adminId: adminId ?? this.adminId,
      originalSenderId: originalSenderId ?? this.originalSenderId,
      isDeleted: isDeleted ?? this.isDeleted,
      isEdited: isEdited ?? this.isEdited,
      editedAt: editedAt ?? this.editedAt,
      replyTo: replyTo ?? this.replyTo,
      deletedBy: deletedBy ?? this.deletedBy,
      fileName: fileName ?? this.fileName,
      isForwarded: isForwarded ?? this.isForwarded,
      deletedAt: deletedAt ?? this.deletedAt,
      prescriptionId: prescriptionId ?? this.prescriptionId,
      prescriptionNotePreview:
          prescriptionNotePreview ?? this.prescriptionNotePreview,
      isPinned: isPinned ?? this.isPinned,
      appointmentId: appointmentId ?? this.appointmentId,
      deliveryStatus: deliveryStatus ?? this.deliveryStatus,
      isListened: isListened ?? this.isListened,
      listenedAt: listenedAt ?? this.listenedAt,
      listenedBy: listenedBy ?? this.listenedBy,
    );
  }

  /// True once the message has been deleted for every participant.
  ///
  /// `isDeletedForEveryone` is only ever written as a mirror of [isDeleted],
  /// so either flag alone means the same thing on any code version.
  bool get isDeletedForEveryone => isDeleted;

  // Helper method to get display message
  String getDisplayMessage() {
    if (isDeleted) {
      return 'This message was deleted';
    }
    if (messageType == 'image') return '📷 Photo';
    if (messageType == 'audio') return '🎤 Voice message';
    if (messageType == 'video') return '🎥 Video';
    if (messageType == 'prescription') {
      return '📋 Prescription available — Tap to view';
    }
    return message;
  }
}
