import 'package:telemedicine/data/models/chat_model.dart';

/// Which actions the current multi-select toolbar should offer.
///
/// Everything is derived from [MessageActionRules.resolveForSelection], which
/// is a pure function so the eligibility matrix can be unit-tested without a
/// widget, a Firebase project or a Hive box.
class ChatToolbarActions {
  const ChatToolbarActions({
    this.canReply = false,
    this.canEdit = false,
    this.canDownload = false,
    this.canForward = false,
    this.canDeleteForMe = false,
    this.canDeleteForEveryone = false,
  });

  final bool canReply;
  final bool canEdit;
  final bool canDownload;
  final bool canForward;
  final bool canDeleteForMe;
  final bool canDeleteForEveryone;

  static const ChatToolbarActions none = ChatToolbarActions();

  bool get isEmpty => !canReply &&
      !canEdit &&
      !canDownload &&
      !canForward &&
      !canDeleteForMe &&
      !canDeleteForEveryone;
}

/// Pure eligibility rules for the WhatsApp-style chat actions: long-press
/// selection, the dynamic selection toolbar, forwarding, editing and the
/// three delete variants.
///
/// Keep this file free of Flutter/Firebase imports so it stays unit-testable.
class MessageActionRules {
  MessageActionRules._();

  /// Message types a user may select, reply to, forward and delete.
  ///
  /// Rich cards (prescription, appointment) keep their own dedicated flows and
  /// are deliberately excluded: selecting a whole card and forwarding it would
  /// forward a prescription the recipient's own record never authorised, and an
  /// appointment message carries a live `appointmentId`.
  static const Set<String> selectableTypes = {
    'text',
    'image',
    'video',
    'audio',
    'document',
    'call_recording',
    'forwarded_report',
  };

  /// True when this message may take part in selection/forward/reply/delete.
  static bool isSelectable(ChatMessageModel message, String currentUserId) {
    if (message.isDeleted) return false;
    if (message.isAppointmentMessage) return false;
    if (message.isPrescription) return false;
    return selectableTypes.contains(message.messageType);
  }

  /// Single source of truth for "did I send this message?".
  ///
  /// Message ownership is decided *only* by comparing the authenticated
  /// user's id with the `senderId` stored on the message — never by bubble
  /// colour, list position or a patient/doctor assumption, so it holds for
  /// patient-to-doctor and doctor-to-patient chats alike. Firestore documents
  /// and the offline Hive cache both decode into the same
  /// [ChatMessageModel.senderId], so a message renders on the same side after
  /// reopening the chat as it did on the live stream.
  static bool isOwnMessage(ChatMessageModel message, String currentUserId) {
    if (currentUserId.trim().isEmpty || message.senderId.trim().isEmpty) {
      return false;
    }
    return message.senderId.trim() == currentUserId.trim();
  }

  /// One message may be replied to only when it is selectable.
  static bool canReply(ChatMessageModel message, String currentUserId) =>
      isSelectable(message, currentUserId);

  /// Editing is limited to your own plain text, and only while it is not
  /// deleted.
  static bool canEdit(ChatMessageModel message, String currentUserId) =>
      !message.isDeleted &&
      message.messageType == 'text' &&
      isOwnMessage(message, currentUserId);

  /// "Delete for Me" applies to any single non-deleted message — the sender's
  /// and the other participant's alike.
  static bool canDeleteForMe(ChatMessageModel message) => !message.isDeleted;

  /// "Delete for Everyone" keeps the existing authorization rule: your own
  /// messages only, and only while they are not already deleted.
  static bool canDeleteForEveryone(
    ChatMessageModel message,
    String currentUserId,
  ) =>
      !message.isDeleted && isOwnMessage(message, currentUserId);

  /// Forwarding works for every selectable message.
  static bool canForward(ChatMessageModel message) => isSelectable(message, '');

  /// Download is a single-image action (exactly one message selected, an
  /// image with a remote URL).
  static bool canDownload(ChatMessageModel message) =>
      !message.isDeleted &&
      message.messageType == 'image' &&
      (message.mediaUrl?.isNotEmpty ?? false);

  /// Resolves the toolbar for the current selection.
  ///
  /// Reply/Edit act on a single message; Download on exactly one image;
  /// Forward requires *every* selected message to be forwardable; Delete
  /// appears when at least one message can be deleted for me, while
  /// "Delete for Everyone" requires the whole selection to be yours.
  static ChatToolbarActions resolveForSelection(
    List<ChatMessageModel> selected,
    String currentUserId,
  ) {
    if (selected.isEmpty) return ChatToolbarActions.none;
    final single = selected.length == 1;

    final allForwardable = selected.every(canForward);
    final anyDeletableForMe = selected.any(canDeleteForMe);
    final allYours = selected.isNotEmpty &&
        selected.every((m) => canDeleteForEveryone(m, currentUserId));

    return ChatToolbarActions(
      canReply: single && canReply(selected.first, currentUserId),
      canEdit: single && canEdit(selected.first, currentUserId),
      canDownload: single && canDownload(selected.first),
      canForward: allForwardable,
      canDeleteForMe: anyDeletableForMe,
      canDeleteForEveryone: allYours,
    );
  }

  /// Recipients must not be the sender themselves.
  static bool isValidForwardTarget({
    required String senderId,
    required String recipientId,
  }) =>
      senderId.isNotEmpty && recipientId.isNotEmpty && senderId != recipientId;
}
