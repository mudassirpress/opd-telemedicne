// chat_controller.dart - Complete with document upload to Cloudinary

import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'package:hive/hive.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:telemedicine/core/services/firebase_storage_service.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/data/models/chat_model.dart';
import 'package:telemedicine/data/local/models/offline_chat_message.dart';
import 'package:telemedicine/data/local/offline_chat_service.dart';
import 'package:telemedicine/data/local/offline_converters.dart';
import 'package:telemedicine/core/services/soft_delete_service.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/features/chat/presentation/chat_action/message_action_rules.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'dart:async';

/// One freshly generated forward copy: the id/timestamp it was queued under
/// plus the original it mirrors.
class _QueuedForward {
  const _QueuedForward({
    required this.messageId,
    required this.timestamp,
    required this.display,
    required this.source,
  });

  final String messageId;
  final DateTime timestamp;
  final String display;
  final ChatMessageModel source;
}

/// Thrown when a new chat/consultation is requested with a counterpart that has
/// been soft-deleted or deactivated.
///
/// The counterpart's record is never removed — this only prevents a *new*
/// conversation from being opened. Existing chats remain fully accessible.
class ChatNotAvailableException implements Exception {
  final String reason;

  const ChatNotAvailableException(this.reason);

  @override
  String toString() => reason;
}

class ChatController {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  final Map<String, Map<String, dynamic>> _userProfileCache = {};

  /// Bootstrap unread counts per `'$userId:$chatId'`, kept on the instance so
  /// re-entering the chat list does not re-read every `user_chats` badge doc
  /// (autoDispose tears the stream down on each screen entry). Entries are
  /// invalidated when the chat's `lastMessageId` changes (a new message
  /// invalidates the old count) and when this device writes the badge locally.
  /// The live overlay in `withLiveUnreadCounts` stays authoritative either way.
  final Map<String, int> _unreadMemo = {};

  /// Drops the cached bootstrap unread value after a local badge write so the
  /// next emission re-reads it instead of serving the pre-write number.
  void invalidateUnreadMemo(String userId, String chatId) {
    _unreadMemo.remove('$userId:$chatId');
  }



  String getChatId(String userId1, String userId2) {
    return userId1.compareTo(userId2) < 0
        ? '${userId1}_$userId2'
        : '${userId2}_$userId1';
  }

  // Check if receiver is online — uses lastHeartbeat for authoritative check
  Future<bool> isReceiverOnline(String receiverId, String receiverRole) async {
    try {
      final col = receiverRole == 'doctor'
          ? FirestoreCollections.doctors
          : FirestoreCollections.patients;
      final doc = await _firestore.collection(col).doc(receiverId).get();
      if (!doc.exists) return false;

      final data = doc.data()!;
      final isOnline = data['isOnline'] ?? false;
      final lastHeartbeat = data['lastHeartbeat'] as Timestamp?;
      final lastSeen = data['lastSeen'] as Timestamp?;

      if (!isOnline) return false;

      final reference = lastHeartbeat ?? lastSeen;
      if (reference == null) return false;

      final diff = DateTime.now().difference(reference.toDate());
      return diff.inSeconds < 45;
    } catch (e) {
      print('Error checking online status: $e');
      return false;
    }
  }

  /// Mark messages as delivered when receiver comes online.
  /// Sets both isDelivered=true and deliveredAt timestamp.
  Future<void> updateMessageDeliveryStatus({
    required String senderId,
    required String receiverId,
  }) async {
    try {
      final chatId = getChatId(senderId, receiverId);

      final undeliveredMessages = await _firestore
          .collection(FirestoreCollections.chats)
          .doc(chatId)
          .collection('messages')
          .where('receiverId', isEqualTo: receiverId)
          .where('isDelivered', isEqualTo: false)
          .get();

      if (undeliveredMessages.docs.isNotEmpty) {
        final batch = _firestore.batch();
        for (final doc in undeliveredMessages.docs) {
          batch.update(doc.reference, {
            'isDelivered': true,
            'deliveredAt': FieldValue.serverTimestamp(),
          });
        }
        await batch.commit();
        print(
          '✅ Updated ${undeliveredMessages.docs.length} messages to delivered',
        );
      }
    } catch (e) {
      print('Error updating delivery status: $e');
    }
  }

  // Save call message in chat

  /// Stream real-time read receipts for messages sent by [senderId] in a chat.
  /// Emits whenever any of the sender's messages are marked as read.
  Stream<List<Map<String, dynamic>>> watchReadReceipts({
    required String chatId,
    required String senderId,
  }) {
    return _firestore
        .collection(FirestoreCollections.chats)
        .doc(chatId)
        .collection('messages')
        .where('senderId', isEqualTo: senderId)
        .where('isRead', isEqualTo: true)
        .snapshots()
        .map((snapshot) {
          return snapshot.docs
              .map((doc) => {'id': doc.id, ...doc.data()})
              .toList();
        });
  }

  // ───────────────────────────────────────────────────────────────────────
  // READ / UNREAD — the single source of truth
  //
  // Firestore owns read state. `messages/{id}.isRead` is authoritative; the
  // `user_chats/{uid}/chats/{chatId}.unreadCount` document is a denormalised
  // counter kept in step with it by [markMessagesRead] on every mutation, and
  // never adjusted by a blind +/- outside that method.
  //
  // Why this is centralised: the previous arrangement had three overlapping
  // entry points that disagreed with each other —
  //
  //   • `markMessageAsSeen`  — flipped `isRead` but left the counter alone, so
  //     a message read *while the chat was open* cleared its double-tick but
  //     left the list badge stuck at 1.
  //   • `markAllMessagesAsSeen` / `markMessagesAsRead` — reset the counter only
  //     `if (unreadMessages.docs.isNotEmpty)`. Once the counter had drifted
  //     above the true number of unread messages, re-opening the chat found
  //     nothing unread and therefore never reset it: a permanently wrong badge.
  //
  // One method fixes both classes of bug, and it always reconciles the counter
  // with the messages it actually changed.
  // ───────────────────────────────────────────────────────────────────────

  /// Marks received messages as read and reconciles the unread counter.
  ///
  /// Pass [messageIds] to mark only those (a message that arrived while the
  /// conversation is open). Omit it to mark every unread message in the
  /// conversation (the "user opened the chat" case).
  ///
  /// Returns the number of messages actually transitioned to read.
  ///
  /// Only messages whose `receiverId == userId` are touched, so a sender's own
  /// outgoing messages — which stay `isRead == false` until the *other* party
  /// opens the conversation — are never falsely marked read. Read receipts for
  /// the other party depend on that.
  Future<int> markMessagesRead({
    required String userId,
    required String otherUserId,
    List<String>? messageIds,
  }) async {
    if (userId.isEmpty || otherUserId.isEmpty) return 0;
    final chatId = getChatId(userId, otherUserId);

    try {
      final unreadByReceiver = await _firestore
          .collection(FirestoreCollections.chats)
          .doc(chatId)
          .collection('messages')
          .where('receiverId', isEqualTo: userId)
          .where('isRead', isEqualTo: false)
          .get();

      // Also support legacy/alternative snake_case schema (recipient_id / is_read)
      final unreadByRecipient = await _firestore
          .collection(FirestoreCollections.chats)
          .doc(chatId)
          .collection('messages')
          .where('recipient_id', isEqualTo: userId)
          .get();

      final candidateMap = <String, DocumentSnapshot<Map<String, dynamic>>>{};
      for (final doc in unreadByReceiver.docs) {
        candidateMap[doc.id] = doc;
      }
      for (final doc in unreadByRecipient.docs) {
        final data = doc.data();
        if (data != null) {
          final isRead = data['isRead'] == true || data['is_read'] == true;
          if (!isRead) {
            candidateMap[doc.id] = doc;
          }
        }
      }

      // CRITICAL: Strictly count and mark ONLY incoming messages where
      // (receiverId == userId || recipient_id == userId) AND is_read == false.
      // NEVER touch or count outgoing messages sent by this user (senderId == userId).
      final incomingUnread = candidateMap.values.where((doc) {
        final data = doc.data();
        if (data == null) return false;
        final sender = (data['senderId'] ?? data['sender_id'] ?? '').toString();
        if (sender == userId)
          return false; // Patient's own outgoing messages must NOT be counted
        final receiver =
            (data['receiverId'] ??
                    data['recipient_id'] ??
                    data['receiver_id'] ??
                    '')
                .toString();
        if (receiver != userId) return false;
        final isRead = data['isRead'] == true || data['is_read'] == true;
        return !isRead;
      }).toList();

      final targets = incomingUnread
          .where((doc) => messageIds == null || messageIds.contains(doc.id))
          .toList();

      if (targets.isEmpty) {
        // A whole-conversation open must unconditionally assert 0 and synchronize
        // both Firestore and local Hive cache. This instantly repairs any drifted
        // counters (such as an unread badge stuck at 7) upon entering the chat.
        if (messageIds == null) {
          await _reconcileUnreadCount(
            userId: userId,
            chatId: chatId,
            remainingUnread: 0,
          );
          await OfflineChatService.instance.markChatAsRead(chatId, userId);
          await OfflineChatService.instance.setCachedChatUnreadCount(
            userId: userId,
            chatId: chatId,
            count: 0,
          );
          invalidateUnreadMemo(userId, chatId);
        }
        return 0;
      }

      // Firestore batches cap at 500 operations. Chunk so a conversation with a
      // long backlog of unread messages cannot fail the whole write.
      const chunkSize = 400;
      for (var i = 0; i < targets.length; i += chunkSize) {
        final chunk = targets.sublist(
          i,
          (i + chunkSize).clamp(0, targets.length),
        );
        final batch = _firestore.batch();
        for (final doc in chunk) {
          batch.update(doc.reference, {
            'isRead': true,
            'is_read': true,
            // A read message is inherently delivered, so this path also
            // completes the receipt in one write rather than leaving the
            // document claiming `isDelivered: false` alongside `isRead: true`.
            'isDelivered': true,
            if (doc.data()?['deliveredAt'] == null)
              'deliveredAt': FieldValue.serverTimestamp(),
            // Explicit state so the sender's client does not have to infer it
            // from the legacy booleans.
            'deliveryStatus': MessageDeliveryState.read.name,
            'readAt': FieldValue.serverTimestamp(),
          });
        }
        await batch.commit();
      }

      // Whole-conversation read ⇒ the badge must be exactly 0, unconditionally.
      // Partial read ⇒ subtract only what we just changed, clamped at 0.
      await _reconcileUnreadCount(
        userId: userId,
        chatId: chatId,
        remainingUnread: messageIds == null ? 0 : null,
        decrementBy: messageIds == null ? null : targets.length,
      );

      // Keep the offline cache consistent so returning to the chat list does
      // not flash a stale badge before the live snapshot arrives.
      await OfflineChatService.instance.markChatAsRead(chatId, userId);
      await OfflineChatService.instance.setCachedChatUnreadCount(
        userId: userId,
        chatId: chatId,
        count: messageIds == null ? 0 : await _readUnreadCount(userId, chatId),
      );
      // The badge just moved; the instance-level bootstrap memo must not
      // replay the pre-read number on the next list emission.
      invalidateUnreadMemo(userId, chatId);

      debugPrint(
        '✅ Marked ${targets.length} message(s) read '
        '(chatId=$chatId, ${messageIds == null ? 'whole conversation' : 'partial'})',
      );
      return targets.length;
    } catch (e) {
      debugPrint('Error marking messages as read: $e');
      return 0;
    }
  }

  /// Resolves the next unread count from the current one.
  ///
  /// Pure so the clamp is unit-testable — it is the part that decides whether
  /// a badge can ever go negative or drift upwards.
  ///
  /// * [absolute] wins when supplied. This is the whole-conversation read case
  ///   and is the only form that *repairs* a previously drifted counter.
  /// * [decrementBy] is the partial-read case: subtract what was just marked
  ///   read, never below zero.
  /// * With neither, the count is left alone.
  static int resolveNextUnreadCount({
    required int current,
    int? absolute,
    int? decrementBy,
  }) {
    final next =
        absolute ?? (decrementBy == null ? current : current - decrementBy);
    return next < 0 ? 0 : next;
  }

  /// Writes the unread counter so it can never disagree with the messages.
  ///
  /// Give either [remainingUnread] (an absolute value) or [decrementBy] (a
  /// relative one). An absolute value is always preferred: it is the only form
  /// that repairs drift rather than propagating it.
  Future<void> _reconcileUnreadCount({
    required String userId,
    required String chatId,
    int? remainingUnread,
    int? decrementBy,
  }) async {
    final ref = _unreadCountRef(userId, chatId);
    try {
      await _firestore.runTransaction((transaction) async {
        final snapshot = await transaction.get(ref);
        final current = _toUnreadInt(snapshot.data()?['unreadCount']);

        transaction.set(ref, {
          'unreadCount': resolveNextUnreadCount(
            current: current,
            absolute: remainingUnread,
            decrementBy: decrementBy,
          ),
          'lastUpdated': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      });
    } catch (e) {
      debugPrint('Error reconciling unread count: $e');
    }
  }

  DocumentReference<Map<String, dynamic>> _unreadCountRef(
    String userId,
    String chatId,
  ) {
    return _firestore
        .collection(FirestoreCollections.userChats)
        .doc(userId)
        .collection(FirestoreCollections.chats)
        .doc(chatId);
  }

  int _toUnreadInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return 0;
  }

  Future<int> _readUnreadCount(String userId, String chatId) async {
    try {
      final doc = await _unreadCountRef(userId, chatId).get();
      return _toUnreadInt(doc.data()?['unreadCount']);
    } catch (_) {
      return 0;
    }
  }

  /// Realtime unread counters for a user, keyed by `chatId`.
  ///
  /// This is what makes the list badge react to a read-state change in its own
  /// right. Previously the badge only refreshed when the `chats` document
  /// changed (i.e. when a new message arrived); clearing it did not emit, so
  /// the count could not update until something else moved.
  Stream<Map<String, int>> streamUnreadCounts(String userId) {
    if (userId.isEmpty) return Stream.value(const {});
    return _firestore
        .collection(FirestoreCollections.userChats)
        .doc(userId)
        .collection(FirestoreCollections.chats)
        .snapshots()
        .map((snapshot) {
          final counts = <String, int>{};
          for (final doc in snapshot.docs) {
            counts[doc.id] = _toUnreadInt(doc.data()?['unreadCount']);
          }
          return counts;
        })
        .handleError((Object error) {
          debugPrint('Error streaming unread counts: $error');
          return <String, int>{};
        });
  }

  /// Overlays realtime unread counters onto a chat/patient list stream.
  ///
  /// Re-emits the list whenever EITHER source changes: a new message (base
  /// stream) or a read-state change (counter stream). Keeps the existing
  /// per-chat read so the count is one document fetch per conversation.
  Stream<List<Map<String, dynamic>>> withLiveUnreadCounts({
    required Stream<List<Map<String, dynamic>>> source,
    required String userId,
  }) {
    if (userId.isEmpty) return source;

    final controller = StreamController<List<Map<String, dynamic>>>();
    var items = const <Map<String, dynamic>>[];
    var counts = const <String, int>{};

    // Until the counter stream has produced its first snapshot, the counts map
    // is empty — and treating "no entry" as 0 would flash every badge to zero
    // on load. Pass the value the source stream already resolved from the same
    // `user_chats` documents until the overlay is actually authoritative.
    var countsLoaded = false;
    var sourceLoaded = false;

    void emit() {
      if (controller.isClosed) return;
      // CRITICAL: Do NOT emit if source has not yet produced its first snapshot!
      // When countsSub emits first, `items` is still empty ([]). Emitting here causes
      // the UI to flash "No conversation yet" and overwrites the Hive local DB with an empty list.
      if (!sourceLoaded) return;
      controller.add([
        for (final item in items)
          {
            ...item,
            'unreadCount': (countsLoaded && counts.containsKey(item['chatId']))
                ? counts[item['chatId']]
                : (item['unreadCount'] ?? 0),
          },
      ]);
    }

    final sourceSub = source.listen((next) {
      items = next;
      sourceLoaded = true;
      emit();
    }, onError: controller.addError);
    final countsSub = streamUnreadCounts(userId).listen(
      (next) {
        counts = next;
        countsLoaded = true;
        if (sourceLoaded) {
          emit();
        }
      },
      onError: (Object _) {
        // A counter failure must not blank the list; keep the last known
        // counts and let the base stream carry on.
      },
    );

    controller.onCancel = () async {
      await sourceSub.cancel();
      await countsSub.cancel();
    };

    return controller.stream;
  }

  /// Stream the chat document to watch for typing status changes.
  Stream<DocumentSnapshot<Map<String, dynamic>>> watchChatMetadata(
    String chatId,
  ) {
    return _firestore
        .collection(FirestoreCollections.chats)
        .doc(chatId)
        .snapshots();
  }

  // Mark all messages as seen when the user opens the conversation.
  //
  // Thin wrapper over the single authoritative implementation. Kept as a named
  // method because "user opened this chat" is a distinct intent from the
  // partial read done when a message arrives mid-conversation.
  Future<void> markAllMessagesAsSeen({
    required String userId,
    required String otherUserId,
  }) {
    return markMessagesRead(userId: userId, otherUserId: otherUserId);
  }

  /// Acknowledges delivery of every message addressed to [userId] that the
  /// server still considers undelivered, turning the sender's single tick into
  /// a double tick.
  ///
  /// This is the transition that was previously missing entirely:
  /// `updateMessageDeliveryStatus` existed but nothing ever called it, so
  /// `isDelivered` was frozen at its send-time value and a message stayed at
  /// one tick forever unless the receiver happened to be online at the exact
  /// moment of sending.
  ///
  /// It is driven by the *receiver's* device rather than the sender's, which is
  /// what makes the receipt trustworthy: the receiver is provably online and
  /// reachable when this runs. The write lands on the same document the sender
  /// is already subscribed to, so the sender's tick updates in realtime with no
  /// polling and no extra listener.
  ///
  /// Safe to call repeatedly and on every chat open — the Firestore query only
  /// matches messages that are still undelivered, so a second call is a cheap
  /// no-op read.
  Future<int> markIncomingMessagesDelivered({
    required String userId,
    required String otherUserId,
  }) async {
    if (userId.isEmpty || otherUserId.isEmpty) return 0;
    final chatId = getChatId(userId, otherUserId);

    try {
      final undelivered = await _firestore
          .collection(FirestoreCollections.chats)
          .doc(chatId)
          .collection('messages')
          .where('receiverId', isEqualTo: userId)
          .where('isDelivered', isEqualTo: false)
          // Two equality filters only, which Firestore serves from its
          // automatic single-field indexes — no composite index to deploy.
          .limit(200)
          .get();

      if (undelivered.docs.isEmpty) return 0;

      // Firestore has no per-document conditional write inside a batch, so each
      // update is built from what the server actually holds: a message already
      // marked read must not be dragged back to `delivered` by this path.
      final batch = _firestore.batch();
      for (final doc in undelivered.docs) {
        final data = doc.data();
        final alreadyRead =
            data?['isRead'] == true || data?['deliveryStatus'] == 'read';
        batch.update(doc.reference, {
          'isDelivered': true,
          'deliveredAt': FieldValue.serverTimestamp(),
          'deliveryStatus': alreadyRead ? 'read' : 'delivered',
        });
      }
      await batch.commit();

      // Mirror locally so the receiver's own copy does not linger as `sent`.
      for (final doc in undelivered.docs) {
        await OfflineChatService.instance.updateDeliveryStatus(
          chatId,
          doc.id,
          OfflineDeliveryStatus.delivered,
        );
      }

      debugPrint(
        'MESSAGES_DELIVERED chatId=$chatId userId=$userId '
        'count=${undelivered.docs.length}',
      );
      return undelivered.docs.length;
    } catch (e) {
      // A failed acknowledgement must never break the chat screen; the
      // next open retries.
      debugPrint('Error marking messages delivered: $e');
      return 0;
    }
  }

  // Save call message in chat
  Future<void> saveCallMessage({
    required String senderId,
    required String receiverId,
    required String callType,
    required String callStatus,
    int? duration,
    String? receiverRole,
  }) async {
    try {
      final chatId = getChatId(senderId, receiverId);
      final messageId = _firestore
          .collection(FirestoreCollections.chats)
          .doc(chatId)
          .collection('messages')
          .doc()
          .id;

      String messageText = '';

      switch (callStatus) {
        case 'missed':
          messageText =
              'Missed ${callType == 'audio' ? 'audio' : 'video'} call';
          break;
        case 'rejected':
          messageText =
              'Rejected ${callType == 'audio' ? 'audio' : 'video'} call';
          break;
        case 'busy':
          messageText = '👤 Doctor is on another call. Please try again later.';
          break;
        case 'ended':
          messageText = '${callType == 'audio' ? 'Audio' : 'Video'} call';
          if (duration != null && duration > 0) {
            messageText += ' (${_formatDuration(duration)})';
          }
          break;
        case 'initiated':
          messageText =
              '${callType == 'audio' ? 'Audio' : 'Video'} call started';
          break;
        case 'accepted':
        case 'ongoing':
          messageText =
              '${callType == 'audio' ? 'Audio' : 'Video'} call in progress';
          break;
        case 'cancelled':
          messageText =
              '${callType == 'audio' ? 'Audio' : 'Video'} call cancelled';
          break;
        default:
          messageText = '${callType == 'audio' ? 'Audio' : 'Video'} call';
      }

      final isOffline = await _isOffline();
      final bool isReceiverOnlineValue;
      if (!isOffline && receiverRole != null) {
        isReceiverOnlineValue = await isReceiverOnline(
          receiverId,
          receiverRole,
        );
      } else {
        isReceiverOnlineValue = false;
      }

      final chatMessage = ChatMessageModel(
        id: messageId,
        senderId: senderId,
        receiverId: receiverId,
        message: messageText,
        messageType: callType,
        timestamp: DateTime.now(),
        isRead: false,
        isDelivered: isReceiverOnlineValue,
        mediaUrl: null,
        duration: duration,
        callData: {
          'callStatus': callStatus,
          'duration': duration,
          'callType': callType,
        },
      );

      await _firestore
          .collection(FirestoreCollections.chats)
          .doc(chatId)
          .collection('messages')
          .doc(messageId)
          .set(chatMessage.toMap());

      await _firestore.collection(FirestoreCollections.chats).doc(chatId).set({
        'participants': [senderId, receiverId],
        'lastMessage': messageText,
        'lastMessageTime': FieldValue.serverTimestamp(),
        'lastMessageType': callType,
        'lastMessageSenderId': senderId,
      }, SetOptions(merge: true));

      await _updateUnreadCount(receiverId, chatId, true);
    } catch (e) {
      print('Error saving call message: $e');
      rethrow;
    }
  }

  String _formatDuration(int seconds) {
    final minutes = seconds ~/ 60;
    final remainingSeconds = seconds % 60;
    if (minutes > 0) {
      return '$minutes:${remainingSeconds.toString().padLeft(2, '0')}';
    }
    return '${seconds}s';
  }

  // Main send message method
  Future<void> sendMessage({
    required String senderId,
    required String receiverId,
    required String message,
    required String messageType,
    String? mediaUrl,
    int? duration,
    String? receiverRole,
    String? fileName,
    Map<String, dynamic>? callData,
    String? prescriptionId,
    String? prescriptionNotePreview,
  }) async {
    final chatId = getChatId(senderId, receiverId);

    // Generate a stable messageId locally so it can be de-duplicated later.
    final messageId = _firestore
        .collection(FirestoreCollections.chats)
        .doc(chatId)
        .collection('messages')
        .doc()
        .id;

    // Format display message based on type
    String displayMessage = message;
    if ((messageType == 'audio' || messageType == 'voice') && duration != null) {
      final minutes = duration ~/ 60;
      final seconds = duration % 60;
      final durationText = minutes > 0
          ? '$minutes:${seconds.toString().padLeft(2, '0')}'
          : '0:$seconds'.padLeft(4, '0');
      displayMessage = '🎤 Voice message ($durationText)';
    } else if (messageType == 'image') {
      displayMessage = '📷 Image';
    } else if (messageType == 'video') {
      displayMessage = '📥 Video';
    } else if (messageType == 'document') {
      displayMessage = '📄 $message';
    } else if (messageType == 'forwarded_report') {
      displayMessage = '📄 Medical Report';
    } else if (messageType == 'prescription') {
      displayMessage = '📋 Prescription available — Tap to view';
    }

    DateTime timestamp = DateTime.now();
    // Guarantee monotonic ordering: ensure outgoing optimistic message timestamp
    // is never earlier than the latest message already recorded in this chat.
    final existingMessages = OfflineChatService.instance.getMessagesForChat(
      chatId,
    );
    if (existingMessages.isNotEmpty) {
      final latestExisting = existingMessages
          .map((m) => m.timestamp)
          .reduce((a, b) => a.isAfter(b) ? a : b);
      if (!timestamp.isAfter(latestExisting)) {
        timestamp = latestExisting.add(const Duration(milliseconds: 1));
      }
    }

    // 1) Persist locally FIRST — before any network round-trip — so the
    //    sender's bubble appears instantly and the message can never be lost.
    //
    //    `pending` is the honest state at this point: nothing has been uploaded
    //    yet. The previous code pre-computed `sent`/`delivered` from a
    //    connectivity probe and wrote that instead, so a device reporting
    //    "mobile data on" but with no actual internet produced a row stuck at
    //    `sent` for a message that had never left the device — and the user saw
    //    a single tick implying it had.
    final offlineMessage = OfflineChatMessage(
      messageId: messageId,
      senderId: senderId,
      receiverId: receiverId,
      message: displayMessage,
      timestamp: timestamp,
      messageType: messageType,
      deliveryStatus: OfflineDeliveryStatus.pending.name,
      readStatus: OfflineReadStatus.unread.name,
      mediaUrl: mediaUrl,
      duration: duration,
      fileName: fileName,
      chatId: chatId,
      prescriptionId: prescriptionId,
      prescriptionNotePreview: prescriptionNotePreview,
    );
    await OfflineChatService.instance.saveMessage(offlineMessage);

    final isOffline = await _isOffline();

    // SOFT DELETE — block only the creation of a NEW conversation.
    //
    // `sendMessage` is also how an existing chat is continued, and a
    // soft-deleted counterpart must not invalidate history the user can still
    // open and read. So the guard runs exclusively on the branch where the
    // chat document does not exist yet — i.e. this send would be the first
    // message of a brand-new conversation, which is exactly the action a
    // deleted doctor must not receive.
    //
    // Skipped while offline: we cannot tell whether the chat already exists,
    // and blocking would silently drop a message the user has already seen
    // appear. The queued row is re-checked by the sync path instead.
    if (!isOffline) {
      final chatExists = await _firestore
          .collection(FirestoreCollections.chats)
          .doc(chatId)
          .get()
          .then((doc) => doc.exists)
          .catchError(
            (_) => true,
          ); // fail open on a read error; never lose a message

      if (!chatExists) {
        final blockedReason = await SoftDeleteService.newBusinessBlockedReason(
          receiverId,
        );
        if (blockedReason != null) {
          debugPrint(
            '🚫 Blocked first message of a new chat with $receiverId: '
            '$blockedReason',
          );
          // Roll back the optimistic row so it can never sync later.
          await OfflineChatService.instance.deleteMessage(chatId, messageId);
          throw ChatNotAvailableException(blockedReason);
        }
      }
    }

    debugPrint(
      'MESSAGE_SEND_STARTED chatId=$chatId messageId=$messageId senderId=$senderId receiverId=$receiverId',
    );

    // 2) If offline, keep it queued locally and return. It will be synced
    //    automatically when connectivity returns.
    if (isOffline) {
      return;
    }

    // Receiver presence is only consulted once we know we can actually upload.
    // It decides whether the message lands as `sent` (single tick) or
    // `delivered` (double tick); it never decides whether to send.
    final bool isReceiverOnlineValue;
    if (receiverRole != null) {
      isReceiverOnlineValue = await isReceiverOnline(receiverId, receiverRole);
    } else {
      isReceiverOnlineValue = false;
    }

    try {
      final chatMessage = ChatMessageModel(
        id: messageId,
        senderId: senderId,
        receiverId: receiverId,
        message: displayMessage,
        messageType: messageType,
        timestamp: timestamp,
        isRead: false,
        isDelivered: isReceiverOnlineValue,
        mediaUrl: mediaUrl,
        duration: duration,
        fileName: fileName,
        callData: callData,
        prescriptionId: prescriptionId,
        prescriptionNotePreview: prescriptionNotePreview,
        deliveryStatus: isReceiverOnlineValue
            ? MessageDeliveryState.delivered
            : MessageDeliveryState.sent,
        isListened: false,
      );

      await _firestore
          .collection(FirestoreCollections.chats)
          .doc(chatId)
          .collection('messages')
          .doc(messageId)
          .set(chatMessage.toMap());

      await _firestore.collection(FirestoreCollections.chats).doc(chatId).set({
        'lastMessage': displayMessage,
        'lastMessageTime': FieldValue.serverTimestamp(),
        'lastMessageSenderId': senderId,
        'lastMessageId': messageId,
        'participants': [senderId, receiverId],
      }, SetOptions(merge: true));

      await _updateUnreadCount(receiverId, chatId, true);

      debugPrint(
        'MESSAGE_SAVED chatId=$chatId messageId=$messageId senderId=$senderId receiverId=$receiverId',
      );

      // 3) Mark locally as sent now that the server accepted it.
      await OfflineChatService.instance.updateDeliveryStatus(
        chatId,
        messageId,
        isReceiverOnlineValue
            ? OfflineDeliveryStatus.delivered
            : OfflineDeliveryStatus.sent,
      );

      // The chat push is sent by the `sendChatNotification` Cloud Function
      // when this message document is created. The client must not send it
      // too: doing so produced two notifications per message and required a
      // service-account key inside the app.
    } catch (e) {
      // The message is already durable in the local outbox, so a failed upload
      // is NOT a failed send and must not surface as one: the bubble stays on
      // screen with a clock and `syncPendingMessages` will retry it. Rethrowing
      // here used to show the user a "Failed to send message" toast for a
      // message that was in fact safely queued.
      //
      // Genuine rejections still throw, and they all happen *before* the local
      // write above — e.g. `ChatNotAvailableException` from the soft-delete
      // guard — so nothing is left stranded in the outbox.
      print('Error uploading message $messageId, queued for retry: $e');
      debugPrint('MESSAGE_QUEUED_FOR_RETRY messageId=$messageId error=$e');
    }
  }

  Future<void> updateTypingStatus({
    required String userId,
    required String otherUserId,
    required bool isTyping,
  }) async {
    final chatId = getChatId(userId, otherUserId);
    await _firestore.collection(FirestoreCollections.chats).doc(chatId).set({
      'typing_$userId': isTyping,
      'lastTypingUpdate': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Stream<Map<String, dynamic>> getChatMetadata(
    String userId,
    String otherUserId,
  ) {
    final chatId = getChatId(userId, otherUserId);
    return _firestore
        .collection(FirestoreCollections.chats)
        .doc(chatId)
        .snapshots()
        .map((doc) {
          return doc.data() ?? <String, dynamic>{};
        });
  }

  // Send document message with Firebase Storage upload
  Future<void> sendDocumentMessage({
    required String senderId,
    required String receiverId,
    required File documentFile,
    required String fileName,
    String? folder,
    String? receiverRole,
  }) async {
    try {
      ToastService.instance.showInfo('Uploading document...');

      final chatId = getChatId(senderId, receiverId);
      final messageId = 'doc_${DateTime.now().millisecondsSinceEpoch}';

      final uploadResult = await FirebaseStorageService.instance.uploadChatAttachment(
        conversationId: chatId,
        messageId: messageId,
        file: documentFile,
        originalFileName: fileName,
      );

      // Send message with document details
      await sendMessage(
        senderId: senderId,
        receiverId: receiverId,
        message: fileName,
        messageType: 'document',
        mediaUrl: uploadResult.downloadUrl,
        fileName: fileName,
        receiverRole: receiverRole,
      );

      ToastService.instance.showSuccess('Document sent successfully');
    } catch (e) {
      debugPrint('Error sending document message: $e');
      ToastService.instance.showError(
        'Failed to send document: ${e.toString()}',
      );
      rethrow;
    }
  }

  Future<void> saveCallRecordingMessage({
    required String senderId,
    required String receiverId,
    required String recordingUrl,
    required String callId,
    required int duration,
    String? receiverRole,
  }) async {
    try {
      final chatId = getChatId(senderId, receiverId);
      final messageId = _firestore
          .collection(FirestoreCollections.chats)
          .doc(chatId)
          .collection('messages')
          .doc()
          .id;

      final durationMinutes = duration ~/ 60;
      final durationSeconds = duration % 60;
      final durationText = durationMinutes > 0
          ? '$durationMinutes:${durationSeconds.toString().padLeft(2, '0')}'
          : '${durationSeconds}s';

      final messageText = '🎙️ Call Recording ($durationText)';

      final isOffline = await _isOffline();
      final bool isReceiverOnlineValue;
      if (!isOffline && receiverRole != null) {
        isReceiverOnlineValue = await isReceiverOnline(
          receiverId,
          receiverRole,
        );
      } else {
        isReceiverOnlineValue = false;
      }

      final chatMessage = ChatMessageModel(
        id: messageId,
        senderId: senderId,
        receiverId: receiverId,
        message: messageText,
        messageType: 'call_recording',
        timestamp: DateTime.now(),
        isRead: false,
        isDelivered: isReceiverOnlineValue,
        mediaUrl: recordingUrl,
        duration: duration,
        callData: {
          'callStatus': 'recorded',
          'duration': duration,
          'callType': 'audio',
          'callId': callId,
          'recordingUrl': recordingUrl,
        },
      );

      await _firestore
          .collection(FirestoreCollections.chats)
          .doc(chatId)
          .collection('messages')
          .doc(messageId)
          .set(chatMessage.toMap());

      await _firestore.collection(FirestoreCollections.chats).doc(chatId).set({
        'participants': [senderId, receiverId],
        'lastMessage': messageText,
        'lastMessageTime': FieldValue.serverTimestamp(),
        'lastMessageType': 'call_recording',
        'lastMessageSenderId': senderId,
      }, SetOptions(merge: true));

      await _updateUnreadCount(receiverId, chatId, true);

      debugPrint('✅ Call recording message saved to chat');
    } catch (e) {
      debugPrint('Error saving call recording message: $e');
      rethrow;
    }
  }

  Future<void> sendImageMessage({
    required String senderId,
    required String receiverId,
    required dynamic imageFile,
    String? folder,
    String? receiverRole,
  }) async {
    try {
      ToastService.instance.showInfo('Uploading image...');
      final chatId = getChatId(senderId, receiverId);
      final messageId = 'img_${DateTime.now().millisecondsSinceEpoch}';

      File localFile;
      if (imageFile is XFile) {
        localFile = File(imageFile.path);
      } else if (imageFile is File) {
        localFile = imageFile;
      } else if (imageFile is String) {
        localFile = File(imageFile);
      } else if (imageFile is Uint8List) {
        final uploadResult = await FirebaseStorageService.instance.uploadData(
          storagePath: 'chat_attachments/$chatId/${messageId}_image.jpg',
          data: imageFile,
          contentType: 'image/jpeg',
        );
        await sendMessage(
          senderId: senderId,
          receiverId: receiverId,
          message: 'Image',
          messageType: 'image',
          mediaUrl: uploadResult.downloadUrl,
          receiverRole: receiverRole,
        );
        return;
      } else {
        throw Exception('Invalid image format');
      }

      final uploadResult = await FirebaseStorageService.instance.uploadChatAttachment(
        conversationId: chatId,
        messageId: messageId,
        file: localFile,
      );

      await sendMessage(
        senderId: senderId,
        receiverId: receiverId,
        message: 'Image',
        messageType: 'image',
        mediaUrl: uploadResult.downloadUrl,
        receiverRole: receiverRole,
      );
    } catch (e) {
      debugPrint('Error sending image message: $e');
      rethrow;
    }
  }

  // Send voice message with Firebase Storage upload
  Future<void> sendAudioMessage({
    required String senderId,
    required String receiverId,
    required String audioPath,
    required int duration,
    String? folder,
    String? receiverRole,
  }) async {
    try {
      // Show uploading indicator
      ToastService.instance.showInfo('Uploading voice message...');
      final chatId = getChatId(senderId, receiverId);
      final messageId = 'voice_${DateTime.now().millisecondsSinceEpoch}';
      final file = File(audioPath);

      final uploadResult = await FirebaseStorageService.instance.uploadChatVoice(
        conversationId: chatId,
        messageId: messageId,
        file: file,
      );

      await sendMessage(
        senderId: senderId,
        receiverId: receiverId,
        message: 'Voice message',
        messageType: 'voice',
        mediaUrl: uploadResult.downloadUrl,
        duration: duration,
        receiverRole: receiverRole,
      );

      // Clean up temporary local recording file
      try {
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {}

      ToastService.instance.showSuccess('Voice message sent');
    } catch (e) {
      debugPrint('Error sending audio message: $e');
      ToastService.instance.showError('Failed to send voice message');
      rethrow;
    }
  }

  /// Marks a received voice message as listened to in Firestore and offline cache.
  /// Only the receiver of the voice message can mark it as listened to.
  Future<void> markVoiceMessageAsListened({
    required String messageId,
    required String senderId,
    required String receiverId,
  }) async {
    try {
      final chatId = getChatId(senderId, receiverId);
      final docRef = _firestore
          .collection(FirestoreCollections.chats)
          .doc(chatId)
          .collection('messages')
          .doc(messageId);

      await docRef.update({
        'isListened': true,
        'is_listened': true,
        'listenedAt': FieldValue.serverTimestamp(),
        'listenedBy': receiverId,
        'isRead': true,
        'is_read': true,
        'readAt': FieldValue.serverTimestamp(),
        'deliveryStatus': MessageDeliveryState.read.name,
      });

      // Synchronize with local Hive cache if message exists locally
      final local = OfflineChatService.instance.getMessage(chatId, messageId);
      if (local != null) {
        await OfflineChatService.instance.saveMessage(
          local.copyWith(
            isListened: true,
            readStatus: OfflineReadStatus.read.name,
            deliveryStatus: OfflineDeliveryStatus.delivered.name,
          ),
        );
      }
      debugPrint(
        'VOICE_MESSAGE_LISTENED chatId=$chatId messageId=$messageId receiverId=$receiverId',
      );
    } catch (e) {
      debugPrint('[ChatController] Error marking voice message as listened: $e');
    }
  }

  Stream<List<ChatMessageModel>> getMessages(
    String userId,
    String otherUserId,
  ) {
    final chatId = getChatId(userId, otherUserId);

    return _firestore
        .collection(FirestoreCollections.chats)
        .doc(chatId)
        .collection('messages')
        .orderBy('timestamp', descending: false)
        .snapshots()
        .map((snapshot) {
          final messages =
              snapshot.docs
                  .map((doc) => ChatMessageModel.fromMap(doc.data()))
                  .toList()
                ..sort((a, b) {
                  final cmp = a.timestamp.compareTo(b.timestamp);
                  if (cmp != 0) return cmp;
                  return a.id.compareTo(b.id);
                });
          return messages;
        });
  }

  /// Increments a user's unread counter for one conversation.
  ///
  /// Uses `FieldValue.increment` so concurrent sends cannot lose an update
  /// through a read-modify-write race, and so the call costs a single write
  /// instead of a transaction.
  ///
  /// Decrementing and resetting deliberately do NOT live here — read-state
  /// changes go through [markMessagesRead] / [_reconcileUnreadCount] so the
  /// counter can only be changed by something that also changed the messages it
  /// is counting.
  Future<void> _updateUnreadCount(
    String userId,
    String chatId,
    bool increment,
  ) async {
    try {
      final ref = _unreadCountRef(userId, chatId);

      if (increment) {
        await ref.set({
          'unreadCount': FieldValue.increment(1),
          'lastUpdated': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        return;
      }

      await ref.set({'unreadCount': 0}, SetOptions(merge: true));
    } catch (e) {
      print('Error updating unread count: $e');
    }
  }

  Stream<int> getUnreadCount(String userId) {
    return _firestore
        .collection(FirestoreCollections.userChats)
        .doc(userId)
        .collection(FirestoreCollections.chats)
        .snapshots()
        .map((snapshot) {
          var totalUnread = 0;
          for (final doc in snapshot.docs) {
            final unreadCount = doc.data()['unreadCount'];
            if (unreadCount is int) {
              totalUnread += unreadCount;
            } else if (unreadCount is num) {
              totalUnread += unreadCount.toInt();
            }
          }
          return totalUnread;
        })
        .handleError((error) {
          print('Error getting unread count: $error');
          return 0;
        });
  }

  Stream<List<Map<String, dynamic>>> getRecentChats(String userId) {
    final Map<String, Map<String, dynamic>> localCache = {};

    // Per-chat enrichment memos.
    //
    // The chat doc changes for reasons that have nothing to do with its last
    // message — typing toggles (`typing_<userId>`), presence-ish writes — and
    // `includeMetadataChanges: true` also fires on local latency-compensated
    // writes. Each of those events used to re-run a last-message query AND an
    // unread-doc read for that chat: a read storm proportional to typing
    // activity. The memo keys the last-message result on `lastMessageId`.
    //
    // Deliberately per-subscription (NOT instance-level): a read receipt by
    // the peer moves the message doc without touching the chat doc, and only
    // a fresh query after re-entering the screen can pick that up — an
    // instance-wide memo would freeze the tile's ticks at their old state.
    final Map<String, Map<String, dynamic>> lastMessageMemo = {};
    // The unread bootstrap memo lives on the instance (see `_unreadMemo`):
    // badge freshness is guarded by the live overlay, so saving the re-read on
    // every screen entry is a straight win.

    // Realtime unread counters are overlaid by [withLiveUnreadCounts] so the
    // badge also reacts to a read-state change, not only to a new message.
    return withLiveUnreadCounts(
      userId: userId,
      source: _firestore
          .collection(FirestoreCollections.chats)
          .where('participants', arrayContains: userId)
          .snapshots(includeMetadataChanges: true)
          .asyncMap((snapshot) async {
            for (final change in snapshot.docChanges) {
              final doc = change.doc;
              if (change.type == DocumentChangeType.removed) {
                localCache.remove(doc.id);
                lastMessageMemo.remove(doc.id);
                _unreadMemo.remove('$userId:${doc.id}');
                continue;
              }

              try {
                final chatData = doc.data() ?? {};
                final participants = List<String>.from(
                  chatData['participants'] ?? [],
                );

                if (participants.length < 2) continue;

                final otherUserId = participants.firstWhere(
                  (id) => id != userId,
                  orElse: () => '',
                );

                if (otherUserId.isEmpty) continue;

                String lastMessageSenderId = '';
                bool isLastMessageRead = false;
                bool isLastMessageDelivered = false;
                // Explicit receipt state for the chat-list tile, so it renders the
                // same four stages as the message bubble (including the pending
                // clock). Null when there is no last message yet.
                MessageDeliveryState? lastMessageStatus;

                // The chat document already carries `lastMessageId`; when it is
                // unchanged, the previous result is still valid — no query.
                // Receipts do not move without a new message either: a read
                // updates the message doc + the badge doc, not this chat doc.
                final currentLastMessageId =
                    chatData['lastMessageId']?.toString() ?? '';
                final memo = currentLastMessageId.isEmpty
                    ? null
                    : lastMessageMemo[doc.id];
                final memoMatches =
                    memo != null &&
                    memo['lastMessageId'] == currentLastMessageId;

                if (memoMatches) {
                  lastMessageSenderId = memo['senderId'] as String;
                  isLastMessageRead = memo['isRead'] as bool;
                  isLastMessageDelivered = memo['isDelivered'] as bool;
                  lastMessageStatus = memo['status'] as MessageDeliveryState?;
                } else {
                  // A changed lastMessageId means a new message landed — the
                  // bootstrap unread value is stale, so drop it and re-read.
                  // (The live listener corrects the badge anyway; this just
                  // keeps the pre-listener frame honest.)
                  _unreadMemo.remove('$userId:${doc.id}');

                  // Query the last message for this specific updated chat
                  final lastMessageQuery = await _firestore
                      .collection(FirestoreCollections.chats)
                      .doc(doc.id)
                      .collection('messages')
                      .orderBy('timestamp', descending: true)
                      .limit(1)
                      .get();

                  if (lastMessageQuery.docs.isNotEmpty) {
                    final lastMessageData = lastMessageQuery.docs.first.data();
                    lastMessageSenderId = lastMessageData['senderId'] ?? '';
                    isLastMessageRead = lastMessageData['isRead'] ?? false;
                    isLastMessageDelivered =
                        lastMessageData['isDelivered'] ?? false;
                    lastMessageStatus =
                        lastMessageData['deliveryStatus'] != null
                        ? MessageDeliveryState.parse(
                            lastMessageData['deliveryStatus'],
                          )
                        : deriveLegacyDeliveryState(
                            isRead: isLastMessageRead,
                            isDelivered: isLastMessageDelivered,
                          );
                  }

                  if (currentLastMessageId.isNotEmpty) {
                    lastMessageMemo[doc.id] = {
                      'lastMessageId': currentLastMessageId,
                      'senderId': lastMessageSenderId,
                      'isRead': isLastMessageRead,
                      'isDelivered': isLastMessageDelivered,
                      'status': lastMessageStatus,
                    };
                  }
                }

                var otherUserData = await _getParticipantProfileFixed(
                  otherUserId,
                );
                otherUserData ??= <String, dynamic>{
                  'id': otherUserId,
                  'fullname': 'User',
                  'name': 'User',
                  'role': 'patient',
                  'imageUrl': '',
                };

                int unreadCount = 0;
                final unreadKey = '$userId:${doc.id}';
                if (_unreadMemo.containsKey(unreadKey)) {
                  unreadCount = _unreadMemo[unreadKey]!;
                } else {
                  try {
                    final unreadDoc = await _firestore
                        .collection(FirestoreCollections.userChats)
                        .doc(userId)
                        .collection(FirestoreCollections.chats)
                        .doc(doc.id)
                        .get();
                    if (unreadDoc.exists) {
                      unreadCount =
                          (unreadDoc.data()?['unreadCount'] ?? 0) as int;
                    }
                  } catch (e) {
                    unreadCount = 0;
                  }
                  _unreadMemo[unreadKey] = unreadCount;
                }

                final role = otherUserData['role'] ?? 'doctor';

                String imageUrl = '';
                if (otherUserData['imageUrl'] != null &&
                    otherUserData['imageUrl'].toString().isNotEmpty) {
                  imageUrl = otherUserData['imageUrl'].toString();
                } else if (otherUserData['image'] != null &&
                    otherUserData['image'].toString().isNotEmpty) {
                  imageUrl = otherUserData['image'].toString();
                } else if (otherUserData['profileImage'] != null &&
                    otherUserData['profileImage'].toString().isNotEmpty) {
                  imageUrl = otherUserData['profileImage'].toString();
                } else if (otherUserData['images'] != null &&
                    otherUserData['images'].toString().isNotEmpty) {
                  imageUrl = otherUserData['images'].toString();
                }

                String specialty = '';
                if (role == 'doctor') {
                  specialty =
                      otherUserData['highestDegree']?.toString() ??
                      otherUserData['specialty']?.toString() ??
                      otherUserData['category']?.toString() ??
                      'Doctor';
                } else {
                  specialty = 'Patient';
                }

                String userName =
                    otherUserData['fullname']?.toString() ??
                    otherUserData['fullName']?.toString() ??
                    otherUserData['name']?.toString() ??
                    'Unknown User';

                DateTime lastMessageTime = _parseChatTime(
                  chatData['lastMessageTime'],
                );

                final isTyping = chatData['typing_$otherUserId'] == true;

                localCache[doc.id] = {
                  'chatId': doc.id,
                  'otherUserId': otherUserId,
                  'otherUserName': userName,
                  'otherUserImage': imageUrl,
                  'doctorSpecialty': specialty,
                  'role': role,
                  'isOnline': otherUserData['isActive'] == true,
                  // Soft-delete state of the OTHER PARTY, surfaced purely so the
                  // tile can label the conversation ("Dr. Ahmed · Deleted").
                  //
                  // It is deliberately NOT used to filter anything out: a chat
                  // list answers "does a relationship already exist?", never "is
                  // the other account currently active?". Filtering here is the
                  // single most destructive mistake available in this file — it
                  // would make a patient's history with a deleted doctor vanish.
                  'isOtherUserDeleted': SoftDeleteService.isDeleted(
                    otherUserData,
                  ),
                  'otherUserDeletedReason':
                      (otherUserData[SoftDeleteFields.deletedReason] ?? '')
                          .toString(),
                  'lastMessage':
                      chatData['lastMessage']?.toString() ?? 'No messages yet',
                  'lastMessageTime': lastMessageTime,
                  'unreadCount': unreadCount,
                  'lastMessageSenderId': lastMessageSenderId,
                  'lastMessageRead': isLastMessageRead,
                  'lastMessageDelivered': isLastMessageDelivered,
                  'lastMessageStatus': lastMessageStatus?.name,
                  'isTyping': isTyping,
                };
              } catch (e) {
                print('Error processing chat document ${doc.id}: $e');
                continue;
              }
            }

            final List<Map<String, dynamic>> chats = localCache.values.toList();
            chats.sort((a, b) {
              final aTime = a['lastMessageTime'] as DateTime;
              final bTime = b['lastMessageTime'] as DateTime;
              return bTime.compareTo(aTime);
            });

            // A server-backed snapshot means the cached list (persisted by the
            // provider wrapping this stream) was just confirmed against the
            // source of truth — latch the sync marker so launch-time recovery
            // sees the cache as complete. Snapshots served from Firestore's own
            // local cache do not count: they only prove some earlier sync.
            if (!snapshot.metadata.isFromCache) {
              OfflineChatService.instance.markSyncCompleted(userId);
            }

            return chats;
          })
          .handleError((error) {
            print('Error in getRecentChats stream: $error');
            return <Map<String, dynamic>>[];
          }),
    );
  }

  DateTime _parseChatTime(dynamic value) {
    if (value == null) {
      return DateTime.now();
    }
    if (value is DateTime) {
      return value;
    }
    if (value is Timestamp) {
      return value.toDate();
    }
    if (value is String) {
      try {
        return DateTime.parse(value);
      } catch (_) {
        return DateTime.now();
      }
    }
    return DateTime.now();
  }

  /// Resolves a chat counterpart's profile.
  ///
  /// SOFT DELETE — this is a point read that MUST NOT filter. Returning `null`
  /// for a soft-deleted user would make the caller `continue`, which silently
  /// removes a historical conversation from the list. A soft-deleted user
  /// returns their full profile (the `...data` spread already carries
  /// `isDeleted`), and the caller decorates rather than filters.
  ///
  /// `null` is reserved for a document that genuinely does not exist.
  Future<Map<String, dynamic>?> _getParticipantProfileFixed(
    String userId,
  ) async {
    final cleanId = userId.trim();
    if (cleanId.isEmpty) return null;

    if (_userProfileCache.containsKey(cleanId)) {
      return _userProfileCache[cleanId];
    }
    try {
      // 1. Check patients collection ('telemedicine_patient') by doc ID
      final patientDoc = await _firestore
          .collection(FirestoreCollections.patients)
          .doc(cleanId)
          .get();

      if (patientDoc.exists) {
        final data = patientDoc.data();
        if (data != null) {
          final profile = {
            ...data,
            'id': patientDoc.id,
            'role': data['role'] ?? 'patient',
          };
          _userProfileCache[cleanId] = profile;
          return profile;
        }
      }

      // 2. Check doctors collection ('telemedicine_doctors') by doc ID
      final doctorDoc = await _firestore
          .collection(FirestoreCollections.doctors)
          .doc(cleanId)
          .get();

      if (doctorDoc.exists) {
        final data = doctorDoc.data();
        if (data != null) {
          final profile = {...data, 'id': doctorDoc.id, 'role': 'doctor'};
          _userProfileCache[cleanId] = profile;
          return profile;
        }
      }

      // 3. Check doctors collection ('telemedicine_doctors') by doctorId field
      final doctorQuery = await _firestore
          .collection(FirestoreCollections.doctors)
          .where('doctorId', isEqualTo: cleanId)
          .limit(1)
          .get();

      if (doctorQuery.docs.isNotEmpty) {
        final doc = doctorQuery.docs.first;
        final data = doc.data();
        final profile = {
          ...data,
          'id': doc.id,
          'role': 'doctor',
        };
        _userProfileCache[cleanId] = profile;
        return profile;
      }

      // 4. Check patients collection by patientId field
      final patientQuery = await _firestore
          .collection(FirestoreCollections.patients)
          .where('patientId', isEqualTo: cleanId)
          .limit(1)
          .get();

      if (patientQuery.docs.isNotEmpty) {
        final doc = patientQuery.docs.first;
        final data = doc.data();
        final profile = {
          ...data,
          'id': doc.id,
          'role': data['role'] ?? 'patient',
        };
        _userProfileCache[cleanId] = profile;
        return profile;
      }

      // 5. Check 'users' collection (legacy/cross-role alias)
      try {
        final userDoc = await _firestore.collection('users').doc(cleanId).get();
        if (userDoc.exists) {
          final data = userDoc.data();
          if (data != null) {
            final profile = {
              ...data,
              'id': userDoc.id,
              'role': data['role'] ?? 'user',
            };
            _userProfileCache[cleanId] = profile;
            return profile;
          }
        }
      } catch (_) {}

      // 6. Check 'doctors' collection (legacy alias)
      try {
        final legacyDoc =
            await _firestore.collection('doctors').doc(cleanId).get();
        if (legacyDoc.exists) {
          final data = legacyDoc.data();
          if (data != null) {
            final profile = {
              ...data,
              'id': legacyDoc.id,
              'role': 'doctor',
            };
            _userProfileCache[cleanId] = profile;
            return profile;
          }
        }
      } catch (_) {}

      // Safe fallback: when document does not exist, return a default placeholder
      // without crashing the UI or spamming the console on every frame/rebuild.
      debugPrint('ℹ️ User profile not found for ID: $cleanId — using default fallback');
      final fallback = <String, dynamic>{
        'id': cleanId,
        'fullname': 'User',
        'name': 'User',
        'role': 'patient',
        'imageUrl': '',
        'image': '',
        'isOnline': false,
        'isFallback': true,
      };
      _userProfileCache[cleanId] = fallback;
      return fallback;
    } catch (e) {
      debugPrint('Warning: Error getting participant profile for $cleanId: $e');
      final fallback = <String, dynamic>{
        'id': cleanId,
        'fullname': 'User',
        'name': 'User',
        'role': 'patient',
        'imageUrl': '',
        'image': '',
        'isOnline': false,
        'isFallback': true,
      };
      _userProfileCache[cleanId] = fallback;
      return fallback;
    }
  }

  Future<void> deleteMessage(String chatId, String messageId) async {
    try {
      await _firestore
          .collection(FirestoreCollections.chats)
          .doc(chatId)
          .collection('messages')
          .doc(messageId)
          .delete();
    } catch (e) {
      print('Error deleting message: $e');
      rethrow;
    }
  }

  /// Ensures a chat document exists for the pair.
  ///
  /// SOFT DELETE — this is the gate for *starting a new conversation*. The
  /// counterpart's live Firestore state is re-read here, so a doctor who was
  /// deactivated after the patient already had their screen open still cannot
  /// receive a new conversation.
  ///
  /// An **existing** chat is never touched, blocked or removed: the guard only
  /// runs on the `!chatDoc.exists` branch. Historical messages, prescriptions,
  /// reports and call history for a soft-deleted counterpart stay fully
  /// readable, exactly as required.
  ///
  /// Returns `true` when a chat is available to use.
  Future<bool> initializeChat(String userId1, String userId2) async {
    final chatId = getChatId(userId1, userId2);
    final chatRef = _firestore
        .collection(FirestoreCollections.chats)
        .doc(chatId);

    final chatDoc = await chatRef.get();

    if (chatDoc.exists) {
      // Historical conversation — always allowed, regardless of whether the
      // other party has since been soft-deleted.
      return true;
    }

    final blockedReason = await SoftDeleteService.newBusinessBlockedReason(
      userId2,
    );
    if (blockedReason != null) {
      debugPrint('🚫 Blocked new chat with $userId2: $blockedReason');
      throw ChatNotAvailableException(blockedReason);
    }

    await chatRef.set({
      'participants': [userId1, userId2],
      'createdAt': FieldValue.serverTimestamp(),
      'lastMessage': '',
      'lastMessageTime': FieldValue.serverTimestamp(),
    });
    return true;
  }

  Future<List<Map<String, dynamic>>> getDoctorPatients(String doctorId) async {
    final stream = watchDoctorPatients(doctorId);
    return await stream.first;
  }

  Stream<List<Map<String, dynamic>>> watchDoctorPatients(String doctorId) {
    // The per-patient `unreadCount` read below is removed and overlaid instead
    // by [withLiveUnreadCounts], so the doctor's badge also reacts to a
    // read-state change rather than only to a new message.
    return withLiveUnreadCounts(
      userId: doctorId,
      source: _firestore
          .collection(FirestoreCollections.chats)
          .where('participants', arrayContains: doctorId)
          .snapshots()
          .asyncMap((chatsSnapshot) async {
            final List<Map<String, dynamic>> patients = [];

            for (var chatDoc in chatsSnapshot.docs) {
              final chatData = chatDoc.data();
              final participants = List<String>.from(
                chatData['participants'] ?? [],
              );

              final patientId = participants.firstWhere(
                (id) => id != doctorId,
                orElse: () => '',
              );

              if (patientId.isEmpty) continue;

              var patientData = await _getParticipantProfileFixed(patientId);
              patientData ??= <String, dynamic>{
                'id': patientId,
                'fullname': 'Patient',
                'name': 'Patient',
                'role': 'patient',
                'imageUrl': '',
              };

              if (patientData != null) {
                patients.add({
                  'patientId': patientId,
                  'patientName':
                      patientData['fullname'] ??
                      patientData['name'] ??
                      'Patient',
                  'patientImage':
                      patientData['imageUrl'] ?? patientData['image'] ?? '',
                  // Decoration only — see the note in `getRecentChats`. A
                  // soft-deleted patient must keep appearing in the doctor's
                  // historical conversation list.
                  'isPatientDeleted': SoftDeleteService.isDeleted(patientData),
                  'lastMessage': chatData['lastMessage'] ?? 'No messages',
                  'lastMessageTime': _parseChatTime(
                    chatData['lastMessageTime'],
                  ),
                  'chatId': chatDoc.id,
                });
              }
            }

            patients.sort((a, b) {
              final aTime = a['lastMessageTime'] as DateTime;
              final bTime = b['lastMessageTime'] as DateTime;
              return bTime.compareTo(aTime);
            });

            return patients;
          }),
    );
  }

  Future<void> sendAdminMessage({
    required String adminId,
    required String adminName,
    required String doctorId,
    required String patientId,
    required String message,
    required String messageType,
    String? mediaUrl,
    int? duration,
  }) async {
    try {
      final chatId = getChatId(doctorId, patientId);
      final messageId = _firestore
          .collection(FirestoreCollections.chats)
          .doc(chatId)
          .collection('messages')
          .doc()
          .id;

      final chatMessage = ChatMessageModel(
        id: messageId,
        senderId: adminId,
        receiverId: doctorId,
        message: message,
        messageType: messageType,
        timestamp: DateTime.now(),
        isRead: false,
        isDelivered: false,
        mediaUrl: mediaUrl,
        duration: duration,
        isAdminMessage: true,
        adminName: adminName,
      );

      await _firestore
          .collection(FirestoreCollections.chats)
          .doc(chatId)
          .collection('messages')
          .doc(messageId)
          .set(chatMessage.toMap());

      await _firestore.collection(FirestoreCollections.chats).doc(chatId).set({
        'lastMessage': messageType == 'text'
            ? '👑 Admin: $message'
            : '👑 Admin sent: $messageType',
        'lastMessageTime': FieldValue.serverTimestamp(),
        'lastMessageSenderId': adminId,
        'lastMessageSenderName': adminName,
        'lastMessageIsAdmin': true,
        'participants': [doctorId, patientId],
        'lastAdminMessage': {
          'adminId': adminId,
          'adminName': adminName,
          'message': message,
          'timestamp': FieldValue.serverTimestamp(),
        },
      }, SetOptions(merge: true));

      if (chatMessage.receiverId == doctorId) {
        await _updateUnreadCount(doctorId, chatId, true);
      } else if (chatMessage.receiverId == patientId) {
        await _updateUnreadCount(patientId, chatId, true);
      } else {
        await _updateUnreadCount(chatMessage.receiverId, chatId, true);
      }

      await _sendAdminNotification(
        doctorId: doctorId,
        patientId: patientId,
        adminName: adminName,
        message: message,
        chatId: chatId,
      );
    } catch (e) {
      rethrow;
    }
  }

  // Edit message
  //
  // Local-first: the Hive row is updated before the network is touched, so the
  // new text renders instantly and survives a cold start with no connection.
  // The server write is best-effort with a hard timeout — a device that is
  // offline leaves the row mutated, and the merge keeps a local mutation
  // until the server copy carries it too (see [preferLocalMutation]).
  Future<void> editMessage({
    required String chatId,
    required String messageId,
    required String newMessage,
    String? editorId,
  }) async {
    final trimmed = newMessage.trim();
    if (trimmed.isEmpty) {
      throw Exception('Message cannot be empty');
    }

    final messageRef = _firestore
        .collection(FirestoreCollections.chats)
        .doc(chatId)
        .collection('messages')
        .doc(messageId);

    // Validate against whatever copy is available (server when reachable,
    // local cache otherwise) so the rule holds offline too.
    ChatMessageModel? target;
    try {
      final messageDoc = await messageRef.get().timeout(
        const Duration(seconds: 8),
      );
      if (messageDoc.exists) {
        target = _messageModelFromDoc(messageDoc);
      }
    } catch (_) {
      // Offline / timed out — fall through to the local row.
    }
    if (target == null) {
      final localRow = OfflineChatService.instance.getMessage(
        chatId,
        messageId,
      );
      if (localRow != null) target = OfflineConverters.toDomain(localRow);
    }

    if (target == null) throw Exception('Message not found');
    if (editorId != null && target.senderId != editorId) {
      throw Exception('You can only edit your own messages');
    }
    if (target.messageType != 'text') {
      throw Exception('Only text messages can be edited');
    }
    if (target.isDeleted) {
      throw Exception('This message was deleted');
    }

    // 1) Optimistic local edit.
    final local = OfflineChatService.instance.getMessage(chatId, messageId);
    if (local != null) {
      await OfflineChatService.instance.saveMessage(
        local.copyWith(
          message: trimmed,
          isEdited: true,
          editedAt: DateTime.now(),
        ),
      );
    }

    // 2) Server write — a timeout is treated as "queued", not as a failure:
    //    the bubble already shows the new text and the merge keeps it.
    try {
      await messageRef
          .update({
            'message': trimmed,
            'isEdited': true,
            'editedAt': FieldValue.serverTimestamp(),
          })
          .timeout(const Duration(seconds: 15));
    } on TimeoutException {
      debugPrint('EDIT_QUEUED_FOR_RETRY messageId=$messageId (offline)');
      return;
    } catch (e) {
      // A genuine rejection must not leave the local copy contradicting the
      // server, so the optimistic row is rolled back and the error surfaces.
      if (local != null) {
        await OfflineChatService.instance.saveMessage(
          local.copyWith(
            message: target.message,
            isEdited: target.isEdited,
            editedAt: target.editedAt,
          ),
        );
      }
      rethrow;
    }

    // 3) Update the chat-list preview if this was the latest message.
    try {
      final chatRef = _firestore
          .collection(FirestoreCollections.chats)
          .doc(chatId);
      final chatDoc = await chatRef.get().timeout(const Duration(seconds: 8));
      if (chatDoc.data()?['lastMessageId'] == messageId) {
        await chatRef
            .update({'lastMessage': trimmed, 'lastMessageEdited': true})
            .timeout(const Duration(seconds: 8));
      }
    } catch (e) {
      debugPrint('Could not refresh chat preview after edit: $e');
    }

    debugPrint('✅ Message edited: $messageId');
  }

  // Delete message for everyone (single message convenience wrapper).
  Future<void> deleteMessageForEveryone({
    required String chatId,
    required String messageId,
    required String deletedByUserId,
  }) {
    return deleteMessagesForEveryone(
      chatId: chatId,
      messageIds: [messageId],
      deletedByUserId: deletedByUserId,
    );
  }

  // Delete one or more messages for every participant.
  //
  // Batched: a multi-select delete is one round trip, and the chat-list
  // preview is corrected inside the same batch when it pointed at a message
  // that just disappeared.
  Future<void> deleteMessagesForEveryone({
    required String chatId,
    required List<String> messageIds,
    required String deletedByUserId,
  }) async {
    if (messageIds.isEmpty) return;
    final ids = {...messageIds};

    final deletedAt = DateTime.now();

    // 1) Optimistic local deletion.
    for (final messageId in ids) {
      final local = OfflineChatService.instance.getMessage(chatId, messageId);
      if (local == null) continue;
      await OfflineChatService.instance.saveMessage(
        local.copyWith(
          isDeleted: true,
          deletedAt: deletedAt,
          deletedBy: deletedByUserId,
          message: 'This message was deleted',
        ),
      );
    }

    final batch = _firestore.batch();
    for (final messageId in ids) {
      batch.update(
        _firestore
            .collection(FirestoreCollections.chats)
            .doc(chatId)
            .collection('messages')
            .doc(messageId),
        {
          'isDeleted': true,
          'isDeletedForEveryone': true,
          'deletedBy': deletedByUserId,
          'deletedAt': Timestamp.fromDate(deletedAt),
          'message': 'This message was deleted',
          'mediaUrl': FieldValue.delete(),
        },
      );
    }

    // 2) Repair the chat-list preview when it referenced a deleted message.
    //
    // The candidate is read *excluding* every id in this batch, so the query
    // cannot hand back a message that is about to be (or already was) deleted.
    try {
      final chatRef = _firestore
          .collection(FirestoreCollections.chats)
          .doc(chatId);
      final chatDoc = await chatRef.get().timeout(const Duration(seconds: 8));
      final lastMessageId = chatDoc.data()?['lastMessageId'];
      if (lastMessageId != null && ids.contains(lastMessageId)) {
        final recent = await chatRef
            .collection('messages')
            .orderBy('timestamp', descending: true)
            .limit(20)
            .get()
            .timeout(const Duration(seconds: 8));
        final replacement = recent.docs
            .where(
              (doc) => !ids.contains(doc.id) && doc.data()['isDeleted'] != true,
            )
            .toList()
            .cast<QueryDocumentSnapshot<Map<String, dynamic>>>();
        if (replacement.isNotEmpty) {
          final previous = replacement.first.data();
          batch.update(chatRef, {
            'lastMessage': previous['message'] ?? 'Deleted message',
            'lastMessageTime': previous['timestamp'],
            'lastMessageSenderId': previous['senderId'],
            'lastMessageId': replacement.first.id,
          });
        } else {
          batch.update(chatRef, {
            'lastMessage': 'No messages',
            'lastMessageTime': FieldValue.serverTimestamp(),
          });
        }
      }
    } catch (e) {
      debugPrint('Could not refresh chat preview after delete: $e');
    }

    // 3) Server commit. A timeout keeps the local state (the mutation wins the
    //    merge until the server catches up); a real error rolls back.
    try {
      await batch.commit().timeout(const Duration(seconds: 15));
      debugPrint('✅ Deleted for everyone: ${ids.length} message(s)');
    } on TimeoutException {
      debugPrint(
        'DELETE_FOR_EVERYONE_QUEUED chatId=$chatId count=${ids.length}',
      );
    } catch (e) {
      for (final messageId in ids) {
        final local = OfflineChatService.instance.getMessage(chatId, messageId);
        if (local != null) {
          await OfflineChatService.instance.saveMessage(
            local.copyWith(isDeleted: false, deletedAt: null, deletedBy: null),
          );
        }
      }
      rethrow;
    }
  }

  // Delete message for me only (single message convenience wrapper).
  Future<void> deleteMessageForMe({
    required String chatId,
    required String messageId,
    required String userId,
  }) {
    return deleteMessagesForMe(
      chatId: chatId,
      messageIds: [messageId],
      userId: userId,
    );
  }

  // Hide one or more messages from this account only.
  //
  // The ids are recorded locally first, so the messages disappear immediately
  // and stay hidden across restarts without a server round-trip; the
  // `hidden_messages` subcollection is the cross-device mirror.
  Future<void> deleteMessagesForMe({
    required String chatId,
    required List<String> messageIds,
    required String userId,
  }) async {
    if (messageIds.isEmpty) return;
    final keys = messageIds
        .map((messageId) => OfflineChatService.messageKey(chatId, messageId))
        .toList();

    await OfflineChatService.instance.addHiddenMessageKeys(userId, keys);

    final batch = _firestore.batch();
    for (final messageId in messageIds) {
      final hiddenRef = _firestore
          .collection(FirestoreCollections.chats)
          .doc(chatId)
          .collection('hidden_messages')
          .doc('${userId}_$messageId');
      batch.set(hiddenRef, {
        'userId': userId,
        'messageId': messageId,
        'hiddenAt': FieldValue.serverTimestamp(),
      });
    }

    try {
      await batch.commit().timeout(const Duration(seconds: 15));
      debugPrint('✅ Hidden for user: ${messageIds.length} message(s)');
    } on TimeoutException {
      debugPrint(
        'DELETE_FOR_ME_QUEUED chatId=$chatId count=${messageIds.length}',
      );
    } catch (e) {
      // Only roll back if the write was genuinely rejected; offline devices
      // must not resurrect a message the user just hid.
      await OfflineChatService.instance.removeHiddenMessageKeys(userId, keys);
      rethrow;
    }
  }

  // Forward one or more messages into another conversation.
  //
  // Offline-first like every other send: each copy is queued locally with a
  // `Forwarded` marker, then uploaded in one batch when the network is up.
  Future<void> forwardMessages({
    required String senderId,
    required String receiverId,
    required List<ChatMessageModel> messages,
    String? receiverRole,
  }) async {
    if (messages.isEmpty) return;
    if (!MessageActionRules.isValidForwardTarget(
      senderId: senderId,
      recipientId: receiverId,
    )) {
      throw Exception('Cannot forward to this recipient');
    }

    final chatId = getChatId(senderId, receiverId);
    final isOffline = await _isOffline();

    // SOFT DELETE — forwarding into a brand-new conversation is a new business
    // action, exactly like the first message of any chat. Existing
    // conversations are untouched.
    if (!isOffline) {
      final chatExists = await _firestore
          .collection(FirestoreCollections.chats)
          .doc(chatId)
          .get()
          .then((doc) => doc.exists)
          .catchError((_) => true);

      if (!chatExists) {
        final blockedReason = await SoftDeleteService.newBusinessBlockedReason(
          receiverId,
        );
        if (blockedReason != null) {
          throw ChatNotAvailableException(blockedReason);
        }
      }
    }

    // Chronological order is the caller's (list order), but each copy needs a
    // distinct timestamp so the conversation renders in the same order as the
    // original even when the originals shared a millisecond.
    final baseTime = DateTime.now();
    final queued = <_QueuedForward>[];
    var offset = 0;
    for (final source in messages) {
      final messageId = _firestore
          .collection(FirestoreCollections.chats)
          .doc(chatId)
          .collection('messages')
          .doc()
          .id;
      final timestamp = baseTime.add(Duration(milliseconds: offset));
      offset += 500;

      final display = formatDisplayMessage(
        messageType: source.messageType,
        message: source.message,
        duration: source.duration,
        fileName: source.fileName,
      );

      await OfflineChatService.instance.saveMessage(
        OfflineChatMessage(
          messageId: messageId,
          senderId: senderId,
          receiverId: receiverId,
          message: display,
          timestamp: timestamp,
          messageType: source.messageType,
          deliveryStatus: OfflineDeliveryStatus.pending.name,
          readStatus: OfflineReadStatus.unread.name,
          mediaUrl: source.mediaUrl,
          duration: source.duration,
          fileName: source.fileName,
          callData: source.callData,
          replyTo: source.replyTo?.toMap().toString(),
          chatId: chatId,
          prescriptionId: source.prescriptionId,
          prescriptionNotePreview: source.prescriptionNotePreview,
          isForwarded: true,
        ),
      );

      queued.add(
        _QueuedForward(
          messageId: messageId,
          timestamp: timestamp,
          display: display,
          source: source,
        ),
      );
    }

    if (isOffline) return;

    final receiverOnline = receiverRole != null
        ? await isReceiverOnline(receiverId, receiverRole)
        : false;

    try {
      final batch = _firestore.batch();
      final messagesRef = _firestore
          .collection(FirestoreCollections.chats)
          .doc(chatId)
          .collection('messages');
      for (final item in queued) {
        batch.set(
          messagesRef.doc(item.messageId),
          ChatMessageModel(
            id: item.messageId,
            senderId: senderId,
            receiverId: receiverId,
            message: item.display,
            messageType: item.source.messageType,
            timestamp: item.timestamp,
            isRead: false,
            isDelivered: receiverOnline,
            mediaUrl: item.source.mediaUrl,
            duration: item.source.duration,
            fileName: item.source.fileName,
            callData: item.source.callData,
            replyTo: item.source.replyTo,
            prescriptionId: item.source.prescriptionId,
            prescriptionNotePreview: item.source.prescriptionNotePreview,
            isForwarded: true,
            deliveryStatus: receiverOnline
                ? MessageDeliveryState.delivered
                : MessageDeliveryState.sent,
          ).toMap(),
        );
      }

      batch.set(_firestore.collection(FirestoreCollections.chats).doc(chatId), {
        'lastMessage': queued.last.display,
        'lastMessageTime': FieldValue.serverTimestamp(),
        'lastMessageSenderId': senderId,
        'lastMessageId': queued.last.messageId,
        'participants': [senderId, receiverId],
      }, SetOptions(merge: true));

      await batch.commit().timeout(const Duration(seconds: 20));
      await _updateUnreadCount(receiverId, chatId, true);

      for (final item in queued) {
        await OfflineChatService.instance.updateDeliveryStatus(
          chatId,
          item.messageId,
          receiverOnline
              ? OfflineDeliveryStatus.delivered
              : OfflineDeliveryStatus.sent,
        );
      }
      debugPrint('✅ Forwarded ${queued.length} message(s) to $receiverId');
    } catch (e) {
      // Durable in the local outbox: `syncPendingMessages` uploads it.
      debugPrint('Forward queued for retry ($chatId): $e');
    }
  }

  /// The preview text a message contributes to the chat list / notification.
  ///
  /// Shared by [sendMessage] and [forwardMessages] so a forwarded copy shows
  /// exactly what the original would.
  static String formatDisplayMessage({
    required String messageType,
    required String message,
    int? duration,
    String? fileName,
  }) {
    switch (messageType) {
      case 'audio':
        if (duration != null) {
          final minutes = duration ~/ 60;
          final seconds = duration % 60;
          final durationText = minutes > 0
              ? '$minutes:${seconds.toString().padLeft(2, '0')}'
              : '0:$seconds'.padLeft(4, '0');
          return '🎤 Voice message ($durationText)';
        }
        return message;
      case 'image':
        return '📷 Image';
      case 'video':
        return '📥 Video';
      case 'document':
        return '📄 $message';
      case 'forwarded_report':
        return '📄 Medical Report';
      case 'prescription':
        return '📋 Prescription available — Tap to view';
      default:
        return message;
    }
  }

  // Send message with reply
  Future<void> sendMessageWithReply({
    required String senderId,
    required String receiverId,
    required String message,
    required String messageType,
    required ReplyData replyTo,
    String? mediaUrl,
    int? duration,
    String? receiverRole,
    String? fileName,
  }) async {
    final chatId = getChatId(senderId, receiverId);
    final messageId = _firestore
        .collection(FirestoreCollections.chats)
        .doc(chatId)
        .collection('messages')
        .doc()
        .id;

    DateTime timestamp = DateTime.now();
    // Guarantee monotonic ordering: ensure outgoing optimistic message timestamp
    // is never earlier than the latest message already recorded in this chat.
    final existingMessages = OfflineChatService.instance.getMessagesForChat(
      chatId,
    );
    if (existingMessages.isNotEmpty) {
      final latestExisting = existingMessages
          .map((m) => m.timestamp)
          .reduce((a, b) => a.isAfter(b) ? a : b);
      if (!timestamp.isAfter(latestExisting)) {
        timestamp = latestExisting.add(const Duration(milliseconds: 1));
      }
    }
    final isOffline = await _isOffline();

    String displayMessage = message;
    if (messageType == 'audio' && duration != null) {
      final minutes = duration ~/ 60;
      final seconds = duration % 60;
      final durationText = minutes > 0
          ? '$minutes:${seconds.toString().padLeft(2, '0')}'
          : '0:$seconds'.padLeft(4, '0');
      displayMessage = '🎤 Voice message ($durationText)';
    } else if (messageType == 'image') {
      displayMessage = '📷 Image';
    } else if (messageType == 'document') {
      displayMessage = '📄 $message';
    }

    // Persist locally first (offline-first).
    //
    // Always `pending`: nothing has been uploaded yet, so that is the honest
    // state. Pre-computing `sent`/`delivered` from a connectivity probe left a
    // message stuck at `sent` when the device reported connectivity but could
    // not actually reach the network — see `sendMessage`.
    final offlineMessage = OfflineChatMessage(
      messageId: messageId,
      senderId: senderId,
      receiverId: receiverId,
      message: displayMessage,
      timestamp: timestamp,
      messageType: messageType,
      deliveryStatus: OfflineDeliveryStatus.pending.name,
      readStatus: OfflineReadStatus.unread.name,
      mediaUrl: mediaUrl,
      duration: duration,
      fileName: fileName,
      replyTo: replyTo.toMap().toString(),
      chatId: chatId,
    );
    await OfflineChatService.instance.saveMessage(offlineMessage);

    if (isOffline) {
      return;
    }

    // Presence is only consulted now that we know we can upload. It decides
    // `sent` vs `delivered`, never whether to send.
    final isReceiverOnlineValue = receiverRole != null
        ? await isReceiverOnline(receiverId, receiverRole)
        : false;

    try {
      final chatMessage = ChatMessageModel(
        id: messageId,
        senderId: senderId,
        receiverId: receiverId,
        message: displayMessage,
        messageType: messageType,
        timestamp: timestamp,
        isRead: false,
        isDelivered: isReceiverOnlineValue,
        mediaUrl: mediaUrl,
        duration: duration,
        replyTo: replyTo,
        fileName: fileName,
        deliveryStatus: isReceiverOnlineValue
            ? MessageDeliveryState.delivered
            : MessageDeliveryState.sent,
      );

      await _firestore
          .collection(FirestoreCollections.chats)
          .doc(chatId)
          .collection('messages')
          .doc(messageId)
          .set(chatMessage.toMap());

      await _firestore.collection(FirestoreCollections.chats).doc(chatId).set({
        'lastMessage': displayMessage,
        'lastMessageTime': FieldValue.serverTimestamp(),
        'lastMessageSenderId': senderId,
        'lastMessageId': messageId,
        'participants': [senderId, receiverId],
      }, SetOptions(merge: true));

      await _updateUnreadCount(receiverId, chatId, true);

      await OfflineChatService.instance.updateDeliveryStatus(
        chatId,
        messageId,
        isReceiverOnlineValue
            ? OfflineDeliveryStatus.delivered
            : OfflineDeliveryStatus.sent,
      );

      // The `sendChatNotification` Cloud Function fires on this message
      // document's creation; the client does not send a second push.
    } catch (e) {
      // Already durable in the local outbox, so this is a failed *upload*, not a
      // failed send. Stays `pending` with a clock and is retried on the next
      // connectivity event. Rethrowing used to raise a "Failed to send message"
      // toast for a message the user could see queued.
      debugPrint('Error uploading reply $messageId, queued for retry: $e');
    }
  }

  // Get messages with hidden messages filtered
  Stream<List<ChatMessageModel>> getMessagesWithHiddenFilter(
    String userId,
    String otherUserId,
  ) {
    final chatId = getChatId(userId, otherUserId);

    return _firestore
        .collection(FirestoreCollections.chats)
        .doc(chatId)
        .collection('messages')
        .orderBy('timestamp', descending: false)
        .snapshots()
        .asyncMap((snapshot) async {
          // Get hidden messages for this user
          final hiddenDocs = await _firestore
              .collection(FirestoreCollections.chats)
              .doc(chatId)
              .collection('hidden_messages')
              .where('userId', isEqualTo: userId)
              .get();

          final hiddenMessageIds = hiddenDocs.docs
              .map((doc) => doc.data()['messageId'] as String)
              .toSet();

          final messages =
              snapshot.docs
                  .where((doc) => !hiddenMessageIds.contains(doc.id))
                  .map((doc) => ChatMessageModel.fromMap(doc.data()))
                  .toList()
                ..sort((a, b) {
                  final cmp = a.timestamp.compareTo(b.timestamp);
                  if (cmp != 0) return cmp;
                  return a.id.compareTo(b.id);
                });

          return messages;
        });
  }

  Future<void> _sendAdminNotification({
    required String doctorId,
    required String patientId,
    required String adminName,
    required String message,
    required String chatId,
  }) async {
    // Admin message notifications are sent by the `sendChatNotification`
    // Cloud Function when the message document is created. The client must not
    // read the recipients' tokens or send a second push.
  }

  // _sendNotification removed since it's unused and notifications are handled securely by backend.

  Stream<List<Map<String, dynamic>>> getAdminMessagesForChat(String chatId) {
    return _firestore
        .collection(FirestoreCollections.chats)
        .doc(chatId)
        .collection('messages')
        .where('isAdminMessage', isEqualTo: true)
        .orderBy('timestamp', descending: true)
        .snapshots()
        .map((snapshot) {
          return snapshot.docs.map((doc) => doc.data()).toList();
        });
  }

  // ════════════════════════════════════════════════════════════════════════
  // OFFLINE-FIRST (HIVE) INTERNALS
  // ════════════════════════════════════════════════════════════════════════

  Future<bool> _isOffline() async {
    try {
      final result = await Connectivity().checkConnectivity();
      return result == ConnectivityResult.none;
    } catch (_) {
      return true;
    }
  }

  /// Immediately return all locally cached messages for a chat without
  /// waiting for the network. Returns `[]` if the local DB is unavailable.
  List<ChatMessageModel> getMessagesFromCache(
    String userId,
    String otherUserId,
  ) {
    final chatId = getChatId(userId, otherUserId);
    final hidden = _localHiddenIds(userId, chatId);
    final cached = OfflineChatService.instance
        .getMessagesForChat(chatId)
        .where((m) => !hidden.contains(m.messageId));
    return cached.map(OfflineConverters.toDomain).toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  }

  /// Message ids this account hid locally with "Delete for Me".
  ///
  /// Kept beside the server-side `hidden_messages` set so a message disappears
  /// instantly and stays gone across restarts with no connection at all.
  Set<String> _localHiddenIds(String userId, String chatId) {
    final keys = OfflineChatService.instance.getHiddenMessageKeys(userId);
    if (keys.isEmpty) return const {};
    return keys
        .where((key) => key.startsWith('${chatId}_'))
        .map((key) => key.substring(chatId.length + 1))
        .toSet();
  }

  /// Size of the live Firestore window kept by [getMessagesOfflineFirst].
  /// The most recent messages update in real time; anything older lives in
  /// Hive and is paged in by [loadOlderMessages] when the user scrolls up.
  static const int _liveMessageWindow = 300;

  /// Page size for [loadOlderMessages].
  static const int _olderMessagePageSize = 100;

  /// In-flight guard so a fast scroll to the top cannot start overlapping
  /// page fetches.
  bool _olderMessagesLoading = false;

  /// True while an older-message page is being fetched — the chat screen
  /// renders a small top indicator from this.
  bool get isLoadingOlderMessages => _olderMessagesLoading;

  /// Fetches the next page of messages OLDER than [before] (defaults to the
  /// oldest locally cached message) and persists them into Hive. Any open
  /// [getMessagesOfflineFirst] stream picks the rows up from its box watcher
  /// and re-emits — no stream restart or screen rebuild is needed.
  ///
  /// Returns the number of messages fetched; 0 means the beginning of history
  /// was reached (or the fetch failed).
  Future<int> loadOlderMessages(
    String userId,
    String otherUserId, {
    DateTime? before,
  }) async {
    if (_olderMessagesLoading) return 0;
    _olderMessagesLoading = true;
    try {
      final chatId = getChatId(userId, otherUserId);

      DateTime? anchor = before;
      if (anchor == null) {
        final cached = OfflineChatService.instance.getMessagesForChat(chatId);
        if (cached.isNotEmpty) {
          anchor = cached
              .map((m) => m.timestamp)
              .reduce((a, b) => a.isBefore(b) ? a : b);
        }
      }
      // No anchor and nothing cached: the live window already starts at the
      // very beginning of the conversation.
      if (anchor == null) return 0;

      final snap = await _firestore
          .collection(FirestoreCollections.chats)
          .doc(chatId)
          .collection('messages')
          .orderBy('timestamp', descending: true)
          .startAfter([Timestamp.fromDate(anchor)])
          .limit(_olderMessagePageSize)
          .get();

      if (snap.docs.isEmpty) return 0;

      final rows = snap.docs
          .map(
            (doc) =>
                OfflineConverters.toOffline(_messageModelFromDoc(doc), chatId),
          )
          .toList();
      await OfflineChatService.instance.saveMessages(rows);
      debugPrint(
        '📜 Loaded ${rows.length} older messages for $chatId '
        '(before $anchor)',
      );
      return rows.length;
    } catch (e) {
      debugPrint('loadOlderMessages failed: $e');
      return 0;
    } finally {
      _olderMessagesLoading = false;
    }
  }

  /// Offline-first message stream:
  ///  1. Emits the Hive cache immediately (no network wait).
  ///  2. Subscribes to the Firestore stream and merges new/changed messages
  ///     into the local cache (de-duplicated by messageId) before emitting
  ///     the combined, sorted result.
  /// This mirrors WhatsApp-style local-first loading while the backend remains
  /// the sync source.
  Stream<List<ChatMessageModel>> getMessagesOfflineFirst(
    String userId,
    String otherUserId,
  ) {
    final chatId = getChatId(userId, otherUserId);
    final controller = StreamController<List<ChatMessageModel>>.broadcast();

    // 1. Emit local cache immediately
    Future.microtask(() {
      final cached = getMessagesFromCache(userId, otherUserId);
      if (!controller.isClosed) {
        controller.add(cached);
      }
    });

    Set<String> hiddenIds = {};
    List<ChatMessageModel> latestServerModels = [];

    void emitMerged() {
      if (controller.isClosed) return;

      // Server mirrors (cross-device) ∪ local "delete for me" marks (instant,
      // offline). Recomputed per emission so a delete lands on the next event
      // even though nothing was written to Firestore.
      final hidden = {...hiddenIds, ..._localHiddenIds(userId, chatId)};

      final visibleServerModels = latestServerModels
          .where((m) => !hidden.contains(m.id))
          .toList();

      // The box is already up to date (the snapshot listener persists only
      // the changed docs), so this merges and emits synchronously — no
      // write-then-read round trip per snapshot.
      final localList = OfflineChatService.instance
          .getMessagesForChat(chatId)
          .where((m) => !hidden.contains(m.messageId));

      final merged =
          _mergeDomainMessages(
            localList.map(OfflineConverters.toDomain).toList(),
            visibleServerModels,
          )..sort((a, b) {
            final cmp = a.timestamp.compareTo(b.timestamp);
            if (cmp != 0) return cmp;
            return a.id.compareTo(b.id);
          });

      if (!controller.isClosed) {
        controller.add(merged);
      }
    }

    // Persists ONLY the documents that actually changed in this snapshot.
    // The previous behaviour re-wrote every message in the conversation on
    // every emission (including metadata-only and typing-driven ones), which
    // scaled with history length instead of with what moved.
    void persistChanged(List<DocumentChange<Map<String, dynamic>>> changes) {
      final toSave = <OfflineChatMessage>[];
      for (final change in changes) {
        if (change.type == DocumentChangeType.removed) continue;
        final model = _messageModelFromDoc(change.doc);
        if (hiddenIds.contains(model.id)) continue;
        final local = OfflineChatService.instance.getMessage(chatId, model.id);
        // A locally queued (never uploaded) copy must never be clobbered by a
        // server row from an earlier attempt; `syncPendingMessages` owns that
        // message until it lands.
        if (local != null &&
            local.deliveryStatus == OfflineDeliveryStatus.pending.name) {
          continue;
        }
        // A local edit / delete-for-everyone that has not reached the server
        // yet is more recent than this snapshot, so it must not be written
        // back — otherwise the optimistic change would flash and revert.
        if (local != null &&
            preferLocalMutation(OfflineConverters.toDomain(local), model)) {
          continue;
        }
        toSave.add(OfflineConverters.toOffline(model, chatId));
      }
      if (toSave.isNotEmpty) {
        OfflineChatService.instance.saveMessages(toSave);
      }
    }

    // 2. Listen to hidden messages
    final hiddenSub = _firestore
        .collection(FirestoreCollections.chats)
        .doc(chatId)
        .collection('hidden_messages')
        .where('userId', isEqualTo: userId)
        .snapshots()
        .listen((snapshot) {
          hiddenIds = snapshot.docs
              .map((doc) => doc.data()['messageId'] as String)
              .toSet();
          emitMerged();
        });

    // 3. Listen to messages — bounded live window.
    //
    // The live listener covers only the most recent [_liveMessageWindow]
    // messages. Firestore's snapshot protocol already sends only document
    // *deltas* after the first delivery, but the first delivery (and every
    // cold-cache re-attach) used to pull the ENTIRE conversation, which for a
    // long-running chat meant megabytes of history downloaded just to render
    // the last few messages. Older messages are not lost: every row that ever
    // passed through this listener is persisted to Hive, and
    // [loadOlderMessages] pages anything older in on demand when the user
    // scrolls to the top of the conversation.
    final messagesSub = _firestore
        .collection(FirestoreCollections.chats)
        .doc(chatId)
        .collection('messages')
        .orderBy('timestamp', descending: true)
        .limit(_liveMessageWindow)
        .snapshots(includeMetadataChanges: true)
        .listen(
          (snapshot) {
            // Reversed back to ascending so downstream merge/sort semantics
            // are unchanged from the previous unbounded query.
            latestServerModels = snapshot.docs
                .map(_messageModelFromDoc)
                .toList()
                .reversed
                .toList();
            // Incremental write: metadata-only snapshots carry no changes and
            // cost zero writes; a new message persists exactly one row.
            persistChanged(snapshot.docChanges);
            emitMerged();
          },
          onError: (error) {
            if (!controller.isClosed) {
              controller.add(getMessagesFromCache(userId, otherUserId));
            }
          },
          cancelOnError: false,
        );

    // 4. Watch the local Hive box so a message written while offline (queued,
    // not yet uploaded) surfaces immediately instead of only after the next
    // Firestore snapshot or a screen re-entry.
    //
    // This path only *reads* the box and merges it with the latest server
    // models — it never writes back, so it cannot feed itself. Writes that
    // this stream itself persists are recognised by id (they all come from the
    // server snapshot) and skipped.
    StreamSubscription<BoxEvent>? boxSub;
    final box = OfflineChatService.instance.box;
    if (box != null) {
      boxSub = box.watch().listen((event) {
        if (controller.isClosed) return;
        final changed = event.value;
        if (changed == null || changed.chatId != chatId) return;

        final hidden = {...hiddenIds, ..._localHiddenIds(userId, chatId)};

        // A local write is only interesting when the server has not already
        // covered it: a queued message (not uploaded yet) or a mutation the
        // server snapshot still lacks. Anything else is a write-back this
        // stream itself made, and re-emitting it would feed itself.
        final serverCopy = latestServerModels
            .where((m) => m.id == changed.messageId)
            .toList();
        if (serverCopy.isNotEmpty) {
          final localCopy = OfflineChatService.instance.getMessage(
            chatId,
            changed.messageId,
          );
          final localModel = localCopy == null
              ? null
              : OfflineConverters.toDomain(localCopy);
          final isQueued =
              localCopy != null &&
              localCopy.deliveryStatus == OfflineDeliveryStatus.pending.name;
          final isLocalMutation =
              localModel != null &&
              preferLocalMutation(localModel, serverCopy.first);
          if (!isQueued && !isLocalMutation) return;
        }

        final localList = OfflineChatService.instance
            .getMessagesForChat(chatId)
            .where((m) => !hidden.contains(m.messageId));
        final merged =
            _mergeDomainMessages(
              localList.map(OfflineConverters.toDomain).toList(),
              latestServerModels.where((m) => !hidden.contains(m.id)).toList(),
            )..sort((a, b) {
              final cmp = a.timestamp.compareTo(b.timestamp);
              if (cmp != 0) return cmp;
              return a.id.compareTo(b.id);
            });

        controller.add(merged);
      });
    }

    // 2b. Local "delete for me" marks live in the chat-list box, not the
    // message box, so they need their own trigger to re-emit.
    final hiddenLocalSub = OfflineChatService.onHiddenChanged.listen(
      (_) => emitMerged(),
    );

    controller.onCancel = () {
      hiddenSub.cancel();
      messagesSub.cancel();
      hiddenLocalSub.cancel();
      boxSub?.cancel();
    };

    return controller.stream;
  }

  /// Builds a message model from a Firestore document, using the document id
  /// as the canonical message id and falling back to a stored field only for
  /// legacy docs that lack it.
  static ChatMessageModel _messageModelFromDoc(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data() ?? <String, dynamic>{};
    if (data['id'] == null || (data['id'] as String).isEmpty) {
      return ChatMessageModel.fromMap(<String, dynamic>{...data, 'id': doc.id});
    }
    return ChatMessageModel.fromMap(data);
  }

  List<ChatMessageModel> _mergeDomainMessages(
    List<ChatMessageModel> local,
    List<ChatMessageModel> server,
  ) {
    final byId = <String, ChatMessageModel>{};
    for (final m in server) {
      byId[m.id] = m;
    }
    for (final m in local) {
      final existing = byId[m.id];
      if (existing == null) {
        // Only in the local store: still queued, never uploaded.
        byId[m.id] = m;
      } else if (preferLocalMutation(m, existing)) {
        // Local edit / delete-for-everyone the server copy lacks yet.
        byId[m.id] = m;
      } else if (preferNewerDeliveryStatus(m, existing)) {
        byId[m.id] = m;
      }
      // Otherwise the server copy stands. It is the more advanced record once a
      // message has actually been uploaded.
    }
    return byId.values.toList();
  }

  /// Whether the local copy carries a user mutation the server copy lacks.
  ///
  /// An edit or a "delete for everyone" is written to Hive first so the UI can
  /// update with no round trip; while the Firestore write is still in flight
  /// (or timed out offline) every server snapshot is by definition older and
  /// must not win the merge. As soon as the server document carries the same
  /// flag, the condition stops matching and the server copy takes over.
  ///
  /// Static and pure so the rule is unit-testable.
  static bool preferLocalMutation(
    ChatMessageModel local,
    ChatMessageModel server,
  ) {
    if (local.isDeleted && !server.isDeleted) return true;
    if (local.isEdited && !server.isEdited) return true;
    return false;
  }

  /// Whether [local] carries a strictly more advanced receipt than [server].
  ///
  /// Advance-only, and deliberately asymmetric on a tie: the server copy wins
  /// when neither is further along. The previous boolean tick-count (`isDelivered
  /// + isRead`) scored a queued message and an uploaded-but-unacknowledged one
  /// identically at zero, and resolved the tie in favour of the **local** row
  /// — so a message that had been uploaded could keep rendering its pending
  /// clock indefinitely.
  ///
  /// Static and pure so the rule is unit-testable.
  static bool preferNewerDeliveryStatus(
    ChatMessageModel local,
    ChatMessageModel server,
  ) {
    return local.deliveryStatus.index > server.deliveryStatus.index;
  }

  /// Push all locally queued (pending) messages to the server, then update
  /// their local delivery status. Called automatically when connectivity
  /// returns.
  ///
  /// Idempotent. The document id *is* the locally generated `messageId`, so
  /// re-running this can never create a duplicate — a retry simply overwrites
  /// the same document. That is what makes it safe for the connectivity
  /// listener to fire repeatedly.
  Future<void> syncPendingMessages() async {
    if (await _isOffline()) return;

    final pending = OfflineChatService.instance.getPendingMessages();
    if (pending.isEmpty) return;

    // The outbox is shared by the device, but only the signed-in account may
    // flush it. Without this gate the cold-start sync (which runs before any
    // screen resolves the session) would push another account's queued
    // messages — and, with nobody signed in, would push them on behalf of a
    // logged-out user. An empty user id skips this attempt; the retry timer
    // picks it up once a session exists.
    final currentUserId = await _resolveSignedInUserId();
    if (currentUserId.isEmpty) return;

    for (final offline in pendingOutboxForUser(pending, currentUserId)) {
      final chatId = offline.chatId;
      final messageRef = _firestore
          .collection(FirestoreCollections.chats)
          .doc(chatId)
          .collection('messages')
          .doc(offline.messageId);

      try {
        // Has a previous attempt already created this document?
        //
        // The unread counter is incremented with `FieldValue.increment(1)`, so
        // an unconditional increment on every retry inflates the receiver's
        // badge once per attempt. A message can legitimately be retried (the
        // upload succeeded but the local status flip did not, leaving the row
        // `pending`), and the previous code counted each of those again. The
        // existence check makes the increment happen exactly once per message.
        final alreadyUploaded = (await messageRef.get()).exists;

        if (alreadyUploaded) {
          // The document is already on the server. Content is immutable
          // (doc id == messageId), and `isRead`/`isDelivered`/`readAt`/
          // `deliveredAt`/`deliveryStatus` are owned by the RECEIVING
          // device. The old unconditional `set()` re-wrote the full local
          // snapshot on every retry and silently rolled those receipts back
          // to false — the sender then watched read-ticks regress after a
          // reconnect. Nothing to write: existence only gates the unread
          // increment below.
          debugPrint(
            'MESSAGE_SYNC_SKIP messageId=${offline.messageId} '
            'chatId=$chatId (already on server)',
          );
        } else {
          await messageRef.set(OfflineConverters.toDomain(offline).toMap());
        }

        final lastMessage = offline.message;

        await _firestore.collection(FirestoreCollections.chats).doc(chatId).set(
          {
            'lastMessage': lastMessage,
            'lastMessageTime': FieldValue.serverTimestamp(),
            'lastMessageSenderId': offline.senderId,
            'lastMessageId': offline.messageId,
            'participants': [offline.senderId, offline.receiverId],
          },
          SetOptions(merge: true),
        );

        if (!alreadyUploaded) {
          // The `sendChatNotification` Cloud Function sends the push when the
          // message document is created. Sending here as well duplicated it.
          await _updateUnreadCount(offline.receiverId, chatId, true);
        }

        // Flipped to `sent` rather than the receiver-aware `delivered`: the
        // receiver's presence is not known at flush time, and guessing would
        // skip the single tick. The delivery transition is driven by the
        // receiver's own device (see `markIncomingMessagesDelivered`).
        await OfflineChatService.instance.updateDeliveryStatus(
          chatId,
          offline.messageId,
          OfflineDeliveryStatus.sent,
        );

        debugPrint(
          'MESSAGE_SYNCED messageId=${offline.messageId} chatId=$chatId '
          'wasAlreadyUploaded=$alreadyUploaded',
        );
      } catch (e) {
        // Left `pending` on purpose, so the next connectivity event retries it.
        print('Error syncing pending message ${offline.messageId}: $e');
      }
    }
  }

  /// Persist a newly received server message into the local Hive cache.
  Future<void> saveIncomingMessage(ChatMessageModel message) async {
    final chatId = getChatId(message.senderId, message.receiverId);
    await OfflineChatService.instance.saveMessage(
      OfflineConverters.toOffline(message, chatId),
    );
  }

  /// Filters the shared outbox down to messages authored by [currentUserId].
  /// Pure so the account-scoping rule is unit-testable; an empty user id
  /// yields an empty outbox (nobody is signed in, nothing may be sent).
  static List<OfflineChatMessage> pendingOutboxForUser(
    List<OfflineChatMessage> pending,
    String currentUserId,
  ) {
    if (currentUserId.isEmpty) return const [];
    return pending.where((m) => m.senderId == currentUserId).toList();
  }

  /// Resolves the signed-in user id from the persisted session blobs
  /// (`current_user` / `current_doctor`) — the same keys the call coordinator
  /// and notification service read, so all of them agree on "who is logged in".
  Future<String> _resolveSignedInUserId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final key in const ['current_user', 'current_doctor']) {
        final raw = prefs.getString(key);
        if (raw == null || raw.isEmpty) continue;
        try {
          final map = jsonDecode(raw) as Map<String, dynamic>;
          final id = (map['id'] ?? '').toString().trim();
          if (id.isNotEmpty) return id;
        } catch (_) {
          // Malformed blob — try the next key.
        }
      }
    } catch (e) {
      debugPrint('⚠️ Could not resolve signed-in user: $e');
    }
    return '';
  }

  /// Static so the launch-time call and the connectivity-listener call (on
  /// different controller instances) can never run two recoveries at once.
  static bool _recoveryInFlight = false;

  /// Launch-time / reconnect recovery for the local chat list (spec §9).
  ///
  /// Fetches the complete chat list once — and only — when the local Hive
  /// cache is empty or was never confirmed against the server, then persists
  /// it together with the sync marker. When the data is already complete this
  /// is a cheap local check with zero Firestore reads.
  ///
  /// Failures (offline, timeout) are swallowed: the chat screen's own stream
  /// refreshes on mount regardless, and the connectivity listener re-runs this
  /// when the network returns.
  Future<void> recoverChatListIfNeeded() async {
    if (_recoveryInFlight) return;
    final userId = await _resolveSignedInUserId();
    if (userId.isEmpty) return;
    if (!OfflineChatService.instance.needsChatListRecovery(userId)) return;

    _recoveryInFlight = true;
    try {
      final chats = await getRecentChats(
        userId,
      ).first.timeout(const Duration(seconds: 20));
      if (chats.isNotEmpty) {
        await OfflineChatService.instance.saveChatList(userId, chats);
        await OfflineChatService.instance.markSyncCompleted(userId);
      }
    } catch (e) {
      // Offline / timed out — retried by the connectivity hook.
      debugPrint('Chat list recovery deferred: $e');
    } finally {
      _recoveryInFlight = false;
    }
  }

  static StreamSubscription<ConnectivityResult>? _connectivitySub;
  static bool _connectivitySyncSetup = false;

  /// How often to re-attempt the outbox while something is still queued.
  ///
  /// Backstop for a connectivity interface that never reports a change, so it
  /// only runs when there is a pending message to flush.
  static const Duration _pendingRetryInterval = Duration(seconds: 20);

  static Timer? _pendingRetryTimer;

  /// Start listening for connectivity changes so that pending offline
  /// messages and cached data are synced automatically once the device is
  /// back online. Safe to call multiple times (idempotent).
  ///
  /// Two independent triggers, because `onConnectivityChanged` alone is not
  /// enough:
  ///
  ///   * the interface changed (wifi -> mobile, none -> wifi);
  ///   * a slow retry sweep.
  ///
  /// The sweep covers the case where the interface *never changes* — a device
  /// that reports "connected to wifi" continuously while the actual connection
  /// is dead (no data package, captive portal, upstream outage). The
  /// connectivity plugin only reports the interface, so no event is ever
  /// emitted when the network merely starts working again, and without the
  /// sweep a queued message would sit on its clock indefinitely. That is the
  /// "mobile data ON but no internet" case from the requirements.
  ///
  /// The sweep is gated on there actually being a pending message, so it costs
  /// an in-memory scan and nothing else in the common case.
  void setupConnectivitySync() {
    if (_connectivitySyncSetup) return;
    _connectivitySyncSetup = true;

    _connectivitySub = Connectivity().onConnectivityChanged.listen((result) {
      final isOffline = result == ConnectivityResult.none;
      if (!isOffline) {
        syncPendingMessages();
        // The local chat list may have been empty or incomplete while offline;
        // this is the automatic recovery pass (no user action required).
        unawaited(recoverChatListIfNeeded());
      }
    });

    _pendingRetryTimer ??= Timer.periodic(_pendingRetryInterval, (_) {
      // Reading the outbox is a synchronous in-memory Hive scan; only reach
      // for the network when there is genuinely something queued.
      if (OfflineChatService.instance.getPendingMessages().isNotEmpty) {
        syncPendingMessages();
      }
      // Internal-startup case: nobody was signed in when the app launched,
      // so the recovery pass was skipped. Cheap local no-op once complete.
      unawaited(recoverChatListIfNeeded());
    });
  }

  static void disposeConnectivitySync() {
    _connectivitySub?.cancel();
    _connectivitySub = null;
    _pendingRetryTimer?.cancel();
    _pendingRetryTimer = null;
    _connectivitySyncSetup = false;
  }
}
