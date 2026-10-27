// Tests for the local-first chat list sync rules.
//
// These are the decision points behind the offline-first behaviour:
//
//   * when the local cache is considered missing/incomplete and must be
//     recovered automatically (no manual refresh, no logout);
//   * how an incoming chat FCM push patches the cached list — preview,
//     unread badge and ordering — while staying idempotent under
//     redelivery (spec §4/§9);
//   * that the shared outbox can only ever be flushed by the signed-in
//     account (spec §6 account isolation).

import 'package:flutter_test/flutter_test.dart';
import 'package:telemedicine/home_widget/chat_call/chat/chat_controller/chat_controller.dart';
import 'package:telemedicine/offline_db/models/offline_chat_message.dart';
import 'package:telemedicine/offline_db/offline_chat_service.dart';

Map<String, dynamic> _entry({
  required String chatId,
  String lastMessageId = '',
  int unreadCount = 0,
  DateTime? lastMessageTime,
}) {
  return {
    'chatId': chatId,
    'otherUserId': 'u2',
    'otherUserName': 'Peer',
    'lastMessage': 'old',
    'lastMessageId': lastMessageId,
    'lastMessageSenderId': 'u2',
    'unreadCount': unreadCount,
    'lastMessageTime': lastMessageTime ?? DateTime(2026, 1, 1, 9),
  };
}

OfflineChatMessage _pending(String id, {String senderId = 'user-a'}) {
  return OfflineChatMessage(
    messageId: id,
    senderId: senderId,
    receiverId: 'user-b',
    message: 'queued',
    timestamp: DateTime(2026, 1, 1, 10),
    messageType: 'text',
    deliveryStatus: OfflineDeliveryStatus.pending.name,
    readStatus: OfflineReadStatus.unread.name,
    chatId: 'user-a_user-b',
  );
}

void main() {
  group('needsRecovery (automatic cache validation, §9)', () {
    test('empty local cache always recovers', () {
      expect(
        OfflineChatService.needsRecovery(
          hasCachedList: false,
          syncCompleted: false,
        ),
        isTrue,
      );
      expect(
        OfflineChatService.needsRecovery(
          hasCachedList: false,
          syncCompleted: true,
        ),
        isTrue,
      );
    });

    test('cache present but never confirmed against the server recovers', () {
      // e.g. a cache written by an older build, or a fetch that only ever
      // served from Firestore's local cache — it may be partial.
      expect(
        OfflineChatService.needsRecovery(
          hasCachedList: true,
          syncCompleted: false,
        ),
        isTrue,
      );
    });

    test('complete cache does not refetch (zero Firestore reads)', () {
      expect(
        OfflineChatService.needsRecovery(
          hasCachedList: true,
          syncCompleted: true,
        ),
        isFalse,
      );
    });
  });

  group('patchChatListForPush (FCM → cached list, §4)', () {
    final when = DateTime(2026, 1, 2, 15);

    test('updates preview, receipts, unread badge and moves the chat to top',
        () {
      final chats = [
        _entry(chatId: 'c1', lastMessageTime: DateTime(2026, 1, 2, 14)),
        _entry(
          chatId: 'c2',
          unreadCount: 2,
          lastMessageTime: DateTime(2026, 1, 2, 12),
        ),
      ];

      final patched = OfflineChatService.patchChatListForPush(
        chats,
        chatId: 'c2',
        messageId: 'm9',
        senderId: 'u2',
        messageText: 'Hello',
        timestamp: when,
      );

      expect(patched, isNotNull);
      // Sorted newest-first: the pushed chat now leads.
      expect(patched!.first['chatId'], 'c2');
      expect(patched.first['lastMessage'], 'Hello');
      expect(patched.first['lastMessageId'], 'm9');
      expect(patched.first['lastMessageSenderId'], 'u2');
      expect(patched.first['lastMessageTime'], when);
      // Unread incremented from 2 → 3; delivered-to-us, not yet read.
      expect(patched.first['unreadCount'], 3);
      expect(patched.first['lastMessageDelivered'], isTrue);
      expect(patched.first['lastMessageRead'], isFalse);
      // The untouched chat survives.
      expect(patched.last['chatId'], 'c1');
      expect(patched.last['unreadCount'], 0);
    });

    test('a redelivered push (same messageId) does not double-count', () {
      final chats = [
        _entry(
          chatId: 'c1',
          lastMessageId: 'm9',
          unreadCount: 3,
          lastMessageTime: when,
        ),
      ];

      expect(
        OfflineChatService.patchChatListForPush(
          chats,
          chatId: 'c1',
          messageId: 'm9',
          senderId: 'u2',
          messageText: 'Hello',
          timestamp: when,
        ),
        isNull,
      );
      // Original untouched.
      expect(chats.first['unreadCount'], 3);
    });

    test('a chat missing from the cache is not invented from the payload', () {
      // Building a half-filled tile (no profile, no role) would render a
      // broken row; the mount-time enrichment pass builds it properly.
      expect(
        OfflineChatService.patchChatListForPush(
          [_entry(chatId: 'c1')],
          chatId: 'brand-new-chat',
          messageId: 'm1',
          senderId: 'u2',
          messageText: 'Hi',
          timestamp: when,
        ),
        isNull,
      );
    });

    test('tolerates cached timestamps stored as ISO strings', () {
      final chats = [
        {
          'chatId': 'c1',
          'lastMessageId': 'm0',
          'lastMessageTime': '2026-01-02T14:00:00.000',
          'unreadCount': 1,
        },
        {
          'chatId': 'c2',
          'lastMessageId': 'm1',
          'lastMessageTime': '2026-01-02T15:00:00.000',
          'unreadCount': 0,
        },
      ];

      final patched = OfflineChatService.patchChatListForPush(
        chats,
        chatId: 'c1',
        messageId: 'm2',
        senderId: 'u2',
        messageText: 'newest',
        timestamp: DateTime(2026, 1, 2, 16),
      );

      expect(patched, isNotNull);
      expect(patched!.first['chatId'], 'c1');
      expect(patched.first['lastMessageTime'], isA<DateTime>());
      expect(patched.first['unreadCount'], 2);
    });
  });

  group('pendingOutboxForUser (account isolation, §6)', () {
    final pending = [
      _pending('m1', senderId: 'user-a'),
      _pending('m2', senderId: 'user-b'),
      _pending('m3', senderId: 'user-a'),
    ];

    test('only the signed-in account\'s messages are flushed', () {
      final scoped = ChatController.pendingOutboxForUser(pending, 'user-a');
      expect(scoped.map((m) => m.messageId), ['m1', 'm3']);
    });

    test('nobody signed in → nothing may be sent', () {
      expect(ChatController.pendingOutboxForUser(pending, ''), isEmpty);
    });

    test('unknown account → other accounts\' queued messages stay queued', () {
      expect(
        ChatController.pendingOutboxForUser(pending, 'user-z'),
        isEmpty,
      );
    });
  });
}
