import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemedicine/data/models/chat_model.dart';
import 'package:telemedicine/features/chat/presentation/controllers/chat_controller.dart';
import 'package:telemedicine/data/local/models/offline_chat_message.dart';
import 'package:telemedicine/data/local/offline_converters.dart';

ChatMessageModel _message({
  String id = 'm1',
  bool isRead = false,
  bool isDelivered = false,
  Object? deliveryStatus,
  Map<String, dynamic>? raw,
}) {
  final map = <String, dynamic>{
    'id': id,
    'senderId': 'me',
    'receiverId': 'you',
    'message': 'hello',
    'messageType': 'text',
    'timestamp': Timestamp.fromDate(DateTime(2026, 1, 1, 12)),
    'isRead': isRead,
    'isDelivered': isDelivered,
    if (deliveryStatus != null) 'deliveryStatus': deliveryStatus,
    ...?raw,
  };
  return ChatMessageModel.fromMap(map);
}

void main() {
  group('MessageDeliveryState.parse', () {
    test('round-trips every state', () {
      for (final state in MessageDeliveryState.values) {
        expect(MessageDeliveryState.parse(state.name), state);
      }
    });

    test('falls back to `sent` for an unknown or missing value', () {
      // A document written by a future client must not crash the reader.
      expect(MessageDeliveryState.parse('something-else'),
          MessageDeliveryState.sent);
      expect(MessageDeliveryState.parse(null), MessageDeliveryState.sent);
    });
  });

  group('legacy migration (documents with only the booleans)', () {
    test('read / delivered / sent map to the right states', () {
      expect(
        deriveLegacyDeliveryState(isRead: true, isDelivered: false),
        MessageDeliveryState.read,
      );
      expect(
        deriveLegacyDeliveryState(isRead: false, isDelivered: true),
        MessageDeliveryState.delivered,
      );
      expect(
        deriveLegacyDeliveryState(isRead: false, isDelivered: false),
        MessageDeliveryState.sent,
      );
      // Read always wins over delivered.
      expect(
        deriveLegacyDeliveryState(isRead: true, isDelivered: true),
        MessageDeliveryState.read,
      );
    });

    test('a legacy document is never `pending`', () {
      // It exists in Firestore, so it was certainly uploaded.
      expect(
        deriveLegacyDeliveryState(isRead: false, isDelivered: false),
        isNot(MessageDeliveryState.pending),
      );
    });

    test('fromMap applies the migration when the field is absent', () {
      expect(_message().deliveryStatus, MessageDeliveryState.sent);
      expect(
        _message(isRead: true).deliveryStatus,
        MessageDeliveryState.read,
      );
      expect(
        _message(isDelivered: true).deliveryStatus,
        MessageDeliveryState.delivered,
      );
    });

    test('fromMap prefers the explicit field when present', () {
      expect(
        _message(deliveryStatus: 'delivered').deliveryStatus,
        MessageDeliveryState.delivered,
      );
    });
  });

  group('OfflineConverters round trip', () {
    OfflineChatMessage _offline(String delivery) => OfflineChatMessage(
          messageId: 'm1',
          senderId: 'me',
          receiverId: 'you',
          message: 'hello',
          timestamp: DateTime(2026, 1, 1, 12),
          messageType: 'text',
          deliveryStatus: delivery,
          readStatus: 'unread',
          chatId: 'me_you',
        );

    test('a flushed message shows ONE tick, not two', () {
      // Regression: `toDomain` used to treat `sent` as delivered, so every
      // message that had been synced out of the outbox skipped straight to a
      // double tick and the single-tick stage was never visible.
      final result = OfflineConverters.toDomain(_offline('sent'));
      expect(result.deliveryStatus, MessageDeliveryState.sent);
      expect(result.isDelivered, isFalse);
    });

    test('a queued message stays pending', () {
      final result = OfflineConverters.toDomain(_offline('pending'));
      expect(result.deliveryStatus, MessageDeliveryState.pending);
      expect(result.isPending, isTrue);
      expect(result.isDelivered, isFalse);
    });

    test('a delivered local row maps to delivered', () {
      final result = OfflineConverters.toDomain(_offline('delivered'));
      expect(result.deliveryStatus, MessageDeliveryState.delivered);
      expect(result.isDelivered, isTrue);
    });

    test('deriveDeliveryState: read always wins', () {
      expect(
        deriveDeliveryState(
          localStatus: 'pending',
          isRead: true,
          isDelivered: true,
        ),
        MessageDeliveryState.read,
      );
    });

    test('deriveDeliveryState: the local row is authoritative for queueing',
        () {
      // Regression: a "most advanced wins" rule promoted this to `sent`,
      // because the row's booleans are derived from its status and so carry
      // no independent evidence that an upload happened.
      expect(
        deriveDeliveryState(
          localStatus: 'pending',
          isRead: false,
          isDelivered: false,
        ),
        MessageDeliveryState.pending,
      );
    });

    test('deriveDeliveryState: a stale boolean cannot un-queue a message', () {
      expect(
        deriveDeliveryState(
          localStatus: 'pending',
          isRead: false,
          isDelivered: true,
        ),
        MessageDeliveryState.pending,
      );
    });

    test('deriveDeliveryState: local sent is not promoted by a stale boolean',
        () {
      expect(
        deriveDeliveryState(
          localStatus: 'sent',
          isRead: false,
          isDelivered: false,
        ),
        MessageDeliveryState.sent,
      );
      expect(
        deriveDeliveryState(
          localStatus: 'delivered',
          isRead: false,
          isDelivered: false,
        ),
        MessageDeliveryState.delivered,
      );
    });

    test('toOffline does not collapse sent into delivered', () {
      final offline = OfflineConverters.toOffline(
        _message(deliveryStatus: 'sent'),
        'me_you',
      );
      expect(offline.deliveryStatus, 'sent');
    });

    test('toOffline keeps read as delivered (the local max)', () {
      final offline = OfflineConverters.toOffline(
        _message(isRead: true, isDelivered: true),
        'me_you',
      );
      expect(offline.deliveryStatus, 'delivered');
      expect(offline.readStatus, 'read');
    });
  });

  group('toMap never persists `pending`', () {
    test('a queued model is written to the server as `sent`', () {
      // A document in Firestore has, by definition, been uploaded. Writing
      // `pending` would tell the receiver something untrue.
      final map = _message(
        deliveryStatus: 'pending',
        raw: {'deliveryStatus': 'pending'},
      ).toMap();
      expect(map['deliveryStatus'], 'sent');
    });

    test('the explicit state is written when it is not pending', () {
      final map = _message(deliveryStatus: 'read').toMap();
      expect(map['deliveryStatus'], 'read');
    });
  });

  group('withDeliveryStatus (advance-only)', () {
    test('advances forward and keeps the booleans consistent', () {
      final sent = _message(deliveryStatus: 'sent');
      final delivered = sent.withDeliveryStatus(MessageDeliveryState.delivered);
      expect(delivered.deliveryStatus, MessageDeliveryState.delivered);
      expect(delivered.isDelivered, isTrue);
      expect(delivered.isRead, isFalse);

      final read = delivered.withDeliveryStatus(MessageDeliveryState.read);
      expect(read.deliveryStatus, MessageDeliveryState.read);
      expect(read.isRead, isTrue);
      expect(read.isDelivered, isTrue);
    });

    test('refuses to go backwards', () {
      // Firestore snapshots can arrive out of order; a late `sent` must not
      // downgrade a message the receiver has already read.
      final read = _message(deliveryStatus: 'read');
      expect(
        read.withDeliveryStatus(MessageDeliveryState.sent),
        same(read),
      );
      expect(
        read.withDeliveryStatus(MessageDeliveryState.delivered),
        same(read),
      );
    });

    test('staying put is a no-op', () {
      final sent = _message(deliveryStatus: 'sent');
      expect(
        sent.withDeliveryStatus(MessageDeliveryState.sent),
        same(sent),
      );
    });
  });

  group('merge prefers the server copy on a tie', () {
    test('an uploaded message does not keep its pending clock', () {
      // Regression: the old tick-count scored local-pending and
      // server-sent identically at zero and resolved the tie in favour of the
      // LOCAL row, so a synced message could render its clock indefinitely.
      final localPending = _message(deliveryStatus: 'pending');
      final serverSent = _message(deliveryStatus: 'sent');
      expect(
        ChatController.preferNewerDeliveryStatus(localPending, serverSent),
        isFalse,
        reason: 'server copy must win the tie',
      );
    });

    test('a genuinely queued message is kept as pending', () {
      final localPending = _message(deliveryStatus: 'pending');
      final serverDelivered = _message(deliveryStatus: 'delivered');
      expect(
        ChatController.preferNewerDeliveryStatus(localPending, serverDelivered),
        isFalse,
      );
    });

    test('a more advanced local copy does win', () {
      final localRead = _message(
        isRead: true,
        isDelivered: true,
        deliveryStatus: 'read',
      );
      final serverSent = _message(deliveryStatus: 'sent');
      expect(
        ChatController.preferNewerDeliveryStatus(localRead, serverSent),
        isTrue,
      );
    });
  });

  group('acceptance walkthroughs', () {
    test('no internet: clock, then one tick on reconnect', () {
      // 1. Queued locally, nothing uploaded.
      final queued = OfflineConverters.toDomain(
        OfflineChatMessage(
          messageId: 'm1',
          senderId: 'me',
          receiverId: 'you',
          message: 'hi',
          timestamp: DateTime(2026, 1, 1, 12),
          messageType: 'text',
          deliveryStatus: 'pending',
          readStatus: 'unread',
          chatId: 'me_you',
        ),
      );
      expect(queued.deliveryStatus, MessageDeliveryState.pending);

      // 2. Connectivity returns and the outbox flushes it as `sent`.
      final flushed = OfflineConverters.toDomain(
        OfflineChatMessage(
          messageId: 'm1',
          senderId: 'me',
          receiverId: 'you',
          message: 'hi',
          timestamp: DateTime(2026, 1, 1, 12),
          messageType: 'text',
          deliveryStatus: 'sent',
          readStatus: 'unread',
          chatId: 'me_you',
        ),
      );
      expect(flushed.deliveryStatus, MessageDeliveryState.sent);
    });

    test('sent -> delivered -> read as the receiver comes online then reads', () {
      var message = _message(deliveryStatus: 'sent');
      expect(message.deliveryStatus, MessageDeliveryState.sent);

      message = message.withDeliveryStatus(MessageDeliveryState.delivered);
      expect(message.deliveryStatus, MessageDeliveryState.delivered);

      message = message.withDeliveryStatus(MessageDeliveryState.read);
      expect(message.deliveryStatus, MessageDeliveryState.read);
    });

    test('a message sent while the receiver is online is delivered immediately',
        () {
      final message = _message(
        isDelivered: true,
        deliveryStatus: 'delivered',
      );
      expect(message.deliveryStatus, MessageDeliveryState.delivered);
      expect(message.isPending, isFalse);
    });
  });
}
