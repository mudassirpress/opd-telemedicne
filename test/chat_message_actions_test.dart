import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemedicine/data/models/chat_model.dart';
import 'package:telemedicine/features/chat/presentation/chat_action/message_action_rules.dart';
import 'package:telemedicine/features/chat/presentation/chat_action/swipe_to_reply_wrapper.dart';
import 'package:telemedicine/features/chat/presentation/controllers/chat_controller.dart';
import 'package:telemedicine/features/chat/presentation/chat_screen.dart';
import 'package:telemedicine/data/local/offline_converters.dart';

ChatMessageModel message({
  String id = 'm1',
  String senderId = 'me',
  String messageType = 'text',
  bool isDeleted = false,
  bool isEdited = false,
  bool isForwarded = false,
  String message = 'hello',
  String? mediaUrl,
}) {
  return ChatMessageModel(
    id: id,
    senderId: senderId,
    receiverId: senderId == 'me' ? 'you' : 'me',
    message: message,
    messageType: messageType,
    timestamp: DateTime(2026, 1, 1, 12),
    isDeleted: isDeleted,
    isEdited: isEdited,
    isForwarded: isForwarded,
    mediaUrl: mediaUrl,
  );
}

void main() {
  group('MessageActionRules.isSelectable', () {
    test('accepts every plain message type', () {
      for (final type in const [
        'text',
        'image',
        'video',
        'audio',
        'document',
        'call_recording',
        'forwarded_report',
      ]) {
        expect(
          MessageActionRules.isSelectable(message(messageType: type), 'me'),
          isTrue,
          reason: '$type should be selectable',
        );
      }
    });

    test('rejects rich cards and deleted messages', () {
      expect(
        MessageActionRules.isSelectable(
          message(messageType: 'prescription'),
          'me',
        ),
        isFalse,
      );
      expect(
        MessageActionRules.isSelectable(
          message(messageType: 'appointment'),
          'me',
        ),
        isFalse,
      );
      expect(
        MessageActionRules.isSelectable(message(isDeleted: true), 'me'),
        isFalse,
      );
    });
  });

  group('MessageActionRules single-message rules', () {
    test('edit: own text only, never a deleted message', () {
      expect(MessageActionRules.canEdit(message(), 'me'), isTrue);
      expect(MessageActionRules.canEdit(message(), 'you'), isFalse);
      expect(
        MessageActionRules.canEdit(message(messageType: 'image'), 'me'),
        isFalse,
      );
      expect(
        MessageActionRules.canEdit(message(isDeleted: true), 'me'),
        isFalse,
      );
    });

    test('delete for me: any non-deleted message', () {
      expect(MessageActionRules.canDeleteForMe(message()), isTrue);
      expect(
        MessageActionRules.canDeleteForMe(message(senderId: 'you')),
        isTrue,
      );
      expect(
        MessageActionRules.canDeleteForMe(message(isDeleted: true)),
        isFalse,
      );
    });

    test('delete for everyone: own non-deleted message only', () {
      expect(MessageActionRules.canDeleteForEveryone(message(), 'me'), isTrue);
      expect(
        MessageActionRules.canDeleteForEveryone(message(senderId: 'you'), 'me'),
        isFalse,
      );
      expect(
        MessageActionRules.canDeleteForEveryone(message(isDeleted: true), 'me'),
        isFalse,
      );
    });

    test('download: a non-deleted image that still has a remote file', () {
      expect(MessageActionRules.canDownload(message()), isFalse);
      expect(
        MessageActionRules.canDownload(
          message(messageType: 'image', mediaUrl: 'https://x/y.jpg'),
        ),
        isTrue,
      );
      expect(
        MessageActionRules.canDownload(
          message(messageType: 'image', mediaUrl: ''),
        ),
        isFalse,
      );
      expect(
        MessageActionRules.canDownload(
          message(
            messageType: 'image',
            mediaUrl: 'https://x/y.jpg',
            isDeleted: true,
          ),
        ),
        isFalse,
      );
    });
  });

  group('MessageActionRules.resolveForSelection', () {
    test('empty selection offers nothing', () {
      final actions = MessageActionRules.resolveForSelection(const [], 'me');
      expect(actions.isEmpty, isTrue);
    });

    test('your own single text message: reply, edit, forward, delete', () {
      final actions = MessageActionRules.resolveForSelection([message()], 'me');
      expect(actions.canReply, isTrue);
      expect(actions.canEdit, isTrue);
      expect(actions.canDownload, isFalse);
      expect(actions.canForward, isTrue);
      expect(actions.canDeleteForMe, isTrue);
      expect(actions.canDeleteForEveryone, isTrue);
    });

    test(
      "someone else's single text message: reply, forward, delete for me",
      () {
        final actions = MessageActionRules.resolveForSelection([
          message(senderId: 'you'),
        ], 'me');
        expect(actions.canReply, isTrue);
        expect(actions.canEdit, isFalse);
        expect(actions.canDeleteForMe, isTrue);
        expect(actions.canDeleteForEveryone, isFalse);
        expect(actions.canForward, isTrue);
      },
    );

    test('a single image offers download and hides edit', () {
      final actions = MessageActionRules.resolveForSelection([
        message(messageType: 'image', mediaUrl: 'https://x/y.jpg'),
      ], 'me');
      expect(actions.canDownload, isTrue);
      expect(actions.canEdit, isFalse);
      expect(actions.canReply, isTrue);
      expect(actions.canForward, isTrue);
    });

    test(
      'multi-select drops reply/edit/download, keeps forward and delete',
      () {
        final actions = MessageActionRules.resolveForSelection([
          message(),
          message(id: 'm2', messageType: 'image', mediaUrl: 'https://x/y.jpg'),
          message(id: 'm3', messageType: 'call_recording'),
        ], 'me');
        expect(actions.canReply, isFalse);
        expect(actions.canEdit, isFalse);
        expect(actions.canDownload, isFalse);
        expect(actions.canForward, isTrue);
        expect(actions.canDeleteForMe, isTrue);
        expect(actions.canDeleteForEveryone, isTrue);
      },
    );

    test('mixed ownership hides "delete for everyone" but keeps "for me"', () {
      final actions = MessageActionRules.resolveForSelection([
        message(),
        message(id: 'm2', senderId: 'you'),
      ], 'me');
      expect(actions.canDeleteForMe, isTrue);
      expect(actions.canDeleteForEveryone, isFalse);
      expect(actions.canForward, isTrue);
    });

    test('a selection containing a rich card cannot be forwarded', () {
      final actions = MessageActionRules.resolveForSelection([
        message(),
        message(id: 'm2', messageType: 'prescription'),
      ], 'me');
      expect(actions.canForward, isFalse);
      expect(actions.canDeleteForMe, isTrue);
    });
  });

  group('MessageActionRules.isValidForwardTarget', () {
    test('rejects empty ids and self-forwarding', () {
      expect(
        MessageActionRules.isValidForwardTarget(
          senderId: 'a',
          recipientId: 'b',
        ),
        isTrue,
      );
      expect(
        MessageActionRules.isValidForwardTarget(
          senderId: 'a',
          recipientId: 'a',
        ),
        isFalse,
      );
      expect(
        MessageActionRules.isValidForwardTarget(senderId: '', recipientId: 'b'),
        isFalse,
      );
      expect(
        MessageActionRules.isValidForwardTarget(senderId: 'a', recipientId: ''),
        isFalse,
      );
    });
  });

  group('ChatMessageModel forwarding + deletion fields', () {
    test('fromMap reads the forwarded flag and deletedAt', () {
      final deletedAt = DateTime(2026, 2, 3, 9, 30);
      final model = ChatMessageModel.fromMap({
        'id': 'm1',
        'senderId': 'me',
        'receiverId': 'you',
        'message': 'hi',
        'messageType': 'text',
        'timestamp': Timestamp.fromDate(DateTime(2026, 1, 1)),
        'isForwarded': true,
        'deletedAt': Timestamp.fromDate(deletedAt),
      });

      expect(model.isForwarded, isTrue);
      expect(model.deletedAt, deletedAt);
      expect(model.isDeletedForEveryone, isFalse);
    });

    test('a document deleted by a newer client still reads as deleted', () {
      final model = ChatMessageModel.fromMap({
        'id': 'm1',
        'senderId': 'me',
        'receiverId': 'you',
        'message': 'hi',
        'messageType': 'text',
        'timestamp': Timestamp.fromDate(DateTime(2026, 1, 1)),
        'isDeletedForEveryone': true,
      });

      expect(model.isDeleted, isTrue);
      expect(model.isDeletedForEveryone, isTrue);
      expect(model.getDisplayMessage(), 'This message was deleted');
    });

    test('toMap mirrors the deletion flag for older readers', () {
      final model = message(isDeleted: true, isForwarded: true);
      final map = model.toMap();

      expect(map['isDeleted'], isTrue);
      expect(map['isDeletedForEveryone'], isTrue);
      expect(map['isForwarded'], isTrue);
      expect(map['deletedAt'], isNull);
    });

    test('copyWith keeps the new fields', () {
      final model = message(isForwarded: true);
      final copy = model.copyWith(message: 'edited');

      expect(copy.isForwarded, isTrue);
      expect(copy.message, 'edited');
      expect(copy.id, model.id);
    });
  });

  group('OfflineConverters round-trip', () {
    test('keeps isForwarded and deletedAt', () {
      final deletedAt = DateTime(2026, 3, 1, 8);
      final original = message(isForwarded: true).copyWith(
        isDeleted: true,
        deletedAt: deletedAt,
        message: 'This message was deleted',
      );

      final offline = OfflineConverters.toOffline(original, 'a_b');
      final back = OfflineConverters.toDomain(offline);

      expect(back.isForwarded, isTrue);
      expect(back.isDeleted, isTrue);
      expect(back.deletedAt, deletedAt);
      expect(back.message, 'This message was deleted');
    });
  });

  group('ChatController.preferLocalMutation', () {
    test('a local deletion outranks a server copy that still has the text', () {
      expect(
        ChatController.preferLocalMutation(message(isDeleted: true), message()),
        isTrue,
      );
      expect(
        ChatController.preferLocalMutation(
          message(isDeleted: true),
          message(isDeleted: true),
        ),
        isFalse,
      );
    });

    test('a local edit outranks a server copy that has not caught up', () {
      expect(
        ChatController.preferLocalMutation(message(isEdited: true), message()),
        isTrue,
      );
      expect(
        ChatController.preferLocalMutation(message(), message(isEdited: true)),
        isFalse,
      );
    });

    test('untouched messages never prefer the local copy', () {
      expect(ChatController.preferLocalMutation(message(), message()), isFalse);
    });
  });

  group('ChatController.formatDisplayMessage', () {
    test('matches the previews sendMessage already produced', () {
      expect(
        ChatController.formatDisplayMessage(
          messageType: 'image',
          message: 'raw.jpg',
        ),
        '📷 Image',
      );
      expect(
        ChatController.formatDisplayMessage(
          messageType: 'video',
          message: 'clip.mp4',
        ),
        '📥 Video',
      );
      expect(
        ChatController.formatDisplayMessage(
          messageType: 'document',
          message: 'report.pdf',
        ),
        '📄 report.pdf',
      );
      expect(
        ChatController.formatDisplayMessage(
          messageType: 'audio',
          message: 'note.ogg',
          duration: 65,
        ),
        '🎤 Voice message (1:05)',
      );
      expect(
        ChatController.formatDisplayMessage(
          messageType: 'text',
          message: 'hello',
        ),
        'hello',
      );
    });
  });

  group('SwipeToReplyWrapper', () {
    Widget wrap({required VoidCallback onReply, bool enabled = true}) {
      return MaterialApp(
        home: Scaffold(
          body: SwipeToReplyWrapper(
            enabled: enabled,
            onReply: onReply,
            child: Container(width: 240, height: 120, color: Colors.black),
          ),
        ),
      );
    }

    Future<void> dragBy(WidgetTester tester, Offset delta) async {
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(SwipeToReplyWrapper)),
      );
      // Two steps so the recogniser has to survive the arena slop the way a
      // real finger does, rather than being handed one impossible jump.
      await gesture.moveBy(delta * 0.25);
      await tester.pump(const Duration(milliseconds: 16));
      await gesture.moveBy(delta * 0.75);
      await tester.pump(const Duration(milliseconds: 16));
      await gesture.up();
      await tester.pumpAndSettle();
    }

    testWidgets('fires onReply once the drag passes the threshold', (
      tester,
    ) async {
      var calls = 0;
      await tester.pumpWidget(wrap(onReply: () => calls++));

      await dragBy(tester, const Offset(70, 0));

      expect(calls, 1);
    });

    testWidgets('stays quiet below the threshold', (tester) async {
      var calls = 0;
      await tester.pumpWidget(wrap(onReply: () => calls++));

      await dragBy(tester, const Offset(20, 0));

      expect(calls, 0);
    });

    testWidgets('swiping left also replies', (tester) async {
      var calls = 0;
      await tester.pumpWidget(wrap(onReply: () => calls++));

      await dragBy(tester, const Offset(-70, 0));

      expect(calls, 1);
    });

    testWidgets('a disabled wrapper never replies', (tester) async {
      var calls = 0;
      await tester.pumpWidget(wrap(onReply: () => calls++, enabled: false));

      await dragBy(tester, const Offset(80, 0));

      expect(calls, 0);
    });
  });

  group('MessageActionRules.isOwnMessage', () {
    test('compares the authenticated id with the stored senderId only', () {
      expect(
        MessageActionRules.isOwnMessage(message(senderId: 'u1'), 'u1'),
        isTrue,
      );
      expect(
        MessageActionRules.isOwnMessage(message(senderId: 'u2'), 'u1'),
        isFalse,
      );
      // Patient and doctor are interchangeable labels: only the ids matter,
      // so the same rule serves patient→doctor and doctor→patient chats.
      expect(
        MessageActionRules.isOwnMessage(
          message(senderId: 'patient-3'),
          'patient-3',
        ),
        isTrue,
      );
      expect(
        MessageActionRules.isOwnMessage(
          message(senderId: 'doctor-7'),
          'patient-3',
        ),
        isFalse,
      );
    });

    test('tolerates stray whitespace, never matches an empty id', () {
      expect(
        MessageActionRules.isOwnMessage(message(senderId: ' u1 '), 'u1'),
        isTrue,
      );
      expect(
        MessageActionRules.isOwnMessage(message(senderId: ''), 'u1'),
        isFalse,
      );
      expect(
        MessageActionRules.isOwnMessage(message(senderId: 'u1'), ''),
        isFalse,
      );
      expect(
        MessageActionRules.isOwnMessage(message(senderId: '  '), 'u1'),
        isFalse,
      );
    });

    test('Firestore documents and offline rows answer identically', () {
      final sent = message(senderId: 'u1');

      final fromMap = ChatMessageModel.fromMap(sent.toMap());
      expect(MessageActionRules.isOwnMessage(fromMap, 'u1'), isTrue);

      final fromCache = OfflineConverters.toDomain(
        OfflineConverters.toOffline(sent, 'u1_u2'),
      );
      expect(MessageActionRules.isOwnMessage(fromCache, 'u1'), isTrue);
      expect(MessageActionRules.isOwnMessage(fromCache, 'u2'), isFalse);
    });
  });

  group('chatMessageRowAlignment', () {
    test('pins my messages to the right and received ones to the left', () {
      expect(
        chatMessageRowAlignment(message(senderId: 'u1'), 'u1'),
        Alignment.centerRight,
      );
      expect(
        chatMessageRowAlignment(message(senderId: 'u2'), 'u1'),
        Alignment.centerLeft,
      );
      // A message with no usable senderId is never treated as mine.
      expect(
        chatMessageRowAlignment(message(senderId: ''), 'u1'),
        Alignment.centerLeft,
      );
    });
  });

  group('message row alignment inside the chat list', () {
    /// Mirrors the composition the chat screen uses for every message row:
    /// the bubble Column (whose crossAxisAlignment carries the isMe signal),
    /// optionally the swipe-to-reply wrapper, and the explicit Align that
    /// pins the side.
    Widget chatRow({
      required ChatMessageModel message,
      required String currentUserId,
      required bool behindSwipeWrapper,
    }) {
      final isMe = MessageActionRules.isOwnMessage(message, currentUserId);
      Widget bubble = Container(
        margin: const EdgeInsets.only(bottom: 8),
        constraints: const BoxConstraints(maxWidth: 460),
        child: Column(
          crossAxisAlignment: isMe
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              color: isMe ? Colors.blue : Colors.white,
              child: Text(message.message),
            ),
          ],
        ),
      );
      if (behindSwipeWrapper) {
        bubble = SwipeToReplyWrapper(onReply: () {}, child: bubble);
      }
      return Align(
        alignment: chatMessageRowAlignment(message, currentUserId),
        child: bubble,
      );
    }

    testWidgets('own messages stay on the right even behind the swipe wrapper, '
        'received stay on the left', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                chatRow(
                  message: message(senderId: 'u1', message: 'mine-wrapped'),
                  currentUserId: 'u1',
                  behindSwipeWrapper: true,
                ),
                chatRow(
                  message: message(senderId: 'u2', message: 'theirs-wrapped'),
                  currentUserId: 'u1',
                  behindSwipeWrapper: true,
                ),
                chatRow(
                  message: message(senderId: 'u1', message: 'mine-plain'),
                  currentUserId: 'u1',
                  behindSwipeWrapper: false,
                ),
                chatRow(
                  message: message(senderId: 'u2', message: 'theirs-plain'),
                  currentUserId: 'u1',
                  behindSwipeWrapper: false,
                ),
              ],
            ),
          ),
        ),
      );

      double xOf(String text) => tester
          .renderObject<RenderBox>(
            find
                .ancestor(of: find.text(text), matching: find.byType(Container))
                .first,
          )
          .localToGlobal(Offset.zero)
          .dx;

      final viewport = tester.getSize(find.byType(ListView)).width;
      expect(xOf('mine-wrapped'), greaterThan(viewport * 0.6));
      expect(xOf('mine-plain'), greaterThan(viewport * 0.6));
      expect(xOf('theirs-wrapped'), lessThan(40));
      expect(xOf('theirs-plain'), lessThan(40));
    });
  });
}
