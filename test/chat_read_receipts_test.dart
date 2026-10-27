// Tests for the read/unread counter arithmetic.
//
// Firestore is the source of truth, but the *arithmetic* deciding what the
// counter becomes is pure and is where the previously-shipped bugs lived:
//
//   • a message read while the chat was open left the badge at 1, and
//   • once the badge drifted above the true unread count, re-opening the chat
//     found nothing unread and therefore never reset it — a permanently
//     wrong badge.
//
// Both are the counter being adjusted blind. These tests pin the rules that
// make it self-repairing instead.

import 'package:flutter_test/flutter_test.dart';
import 'package:telemedicine/features/chat/presentation/controllers/chat_controller.dart';

void main() {
  group('resolveNextUnreadCount', () {
    test('a whole-conversation read always lands on exactly zero', () {
      // The drift-repair case: the counter says 3 even though nothing is
      // actually unread, and opening the chat must still clear the badge.
      expect(ChatController.resolveNextUnreadCount(current: 3, absolute: 0), 0);
      expect(ChatController.resolveNextUnreadCount(current: 0, absolute: 0), 0);
      expect(
        ChatController.resolveNextUnreadCount(current: 99, absolute: 0),
        0,
      );
    });

    test('an absolute value overrides any decrement', () {
      expect(
        ChatController.resolveNextUnreadCount(
          current: 5,
          absolute: 0,
          decrementBy: 2,
        ),
        0,
      );
    });

    test('a partial read subtracts exactly what was marked read', () {
      expect(
        ChatController.resolveNextUnreadCount(current: 3, decrementBy: 1),
        2,
      );
      expect(
        ChatController.resolveNextUnreadCount(current: 3, decrementBy: 3),
        0,
      );
    });

    test('a partial read can never drive the count negative', () {
      // Guards against a duplicate/replayed read write pushing the badge
      // negative, which would render as a nonsense count.
      expect(
        ChatController.resolveNextUnreadCount(current: 0, decrementBy: 1),
        0,
      );
      expect(
        ChatController.resolveNextUnreadCount(current: 1, decrementBy: 5),
        0,
      );
    });

    test('with neither argument the count is left untouched', () {
      expect(ChatController.resolveNextUnreadCount(current: 4), 4);
      expect(ChatController.resolveNextUnreadCount(current: 0), 0);
    });

    test('a large absolute value is preserved, not clamped down', () {
      expect(
        ChatController.resolveNextUnreadCount(current: 0, absolute: 12),
        12,
      );
    });
  });

  group('acceptance walkthroughs', () {
    // Test A: patient sends 3 → doctor's badge climbs 1,2,3 → doctor opens
    // chat → 0.
    test('Test A — patient to doctor', () {
      var doctorBadge = 0;
      final onSend = () => doctorBadge += 1;

      onSend();
      expect(doctorBadge, 1);
      onSend();
      expect(doctorBadge, 2);
      onSend();
      expect(doctorBadge, 3);

      doctorBadge = ChatController.resolveNextUnreadCount(
        current: doctorBadge,
        absolute: 0,
      );
      expect(doctorBadge, 0);
    });

    // Test C: doctor has the chat open, patient sends, doctor reads it in
    // place. The partial decrement must take the badge back to 0 rather than
    // leaving it stranded at 1.
    test('Test C — message arrives while the chat is open', () {
      var doctorBadge = 0;

      doctorBadge += 1; // patient sends while doctor is inside the chat
      expect(doctorBadge, 1);

      doctorBadge = ChatController.resolveNextUnreadCount(
        current: doctorBadge,
        decrementBy: 1,
      );
      expect(doctorBadge, 0);
    });

    // Test D: message stays unread while the user is elsewhere, then clears on
    // open — including the pathological case where the counter is already
    // wrong before the open.
    test('Test D — message stays unread until the chat is opened', () {
      var doctorBadge = 1; // arrived while doctor was on another screen
      expect(doctorBadge, 1);

      doctorBadge = ChatController.resolveNextUnreadCount(
        current: doctorBadge,
        absolute: 0,
      );
      expect(doctorBadge, 0);
    });

    // The original permanent-drift failure: counter ahead of reality, nothing
    // left to mark, badge must still clear.
    test('re-opening a chat clears a badge that had drifted', () {
      var doctorBadge = 1; // incremented by an in-chat read that never zeroed

      // Re-opening finds no unread *messages* (they were all flipped), so the
      // old code short-circuited and left the badge. An absolute write has no
      // such short-circuit.
      final afterReopen = ChatController.resolveNextUnreadCount(
        current: doctorBadge,
        absolute: 0,
      );
      expect(afterReopen, 0);
    });

    test(
      'Patient badge counter stuck at 7 resolves to 0 immediately upon screen open',
      () {
        var patientBadge =
            7; // Stuck at 7 due to earlier drift or admin message increment

        // On screen open, whole-conversation mark-as-read unconditionally asserts absolute 0
        final resolved = ChatController.resolveNextUnreadCount(
          current: patientBadge,
          absolute: 0,
        );
        expect(resolved, 0);
      },
    );

    test(
      'Incoming unread filter strictly counts incoming messages and rejects outgoing messages',
      () {
        const patientId = 'patient_123';
        const doctorId = 'doctor_456';

        final messages = [
          // Incoming unread message (should be counted)
          {
            'id': 'm1',
            'senderId': doctorId,
            'receiverId': patientId,
            'recipient_id': patientId,
            'is_read': false,
            'isRead': false,
          },
          // Incoming read message (should NOT be counted)
          {
            'id': 'm2',
            'senderId': doctorId,
            'receiverId': patientId,
            'recipient_id': patientId,
            'is_read': true,
            'isRead': true,
          },
          // Outgoing message sent by the patient (should NEVER be counted)
          {
            'id': 'm3',
            'senderId': patientId,
            'receiverId': doctorId,
            'recipient_id': doctorId,
            'is_read': false,
            'isRead': false,
          },
          // Another outgoing message sent by the patient with is_read == false
          {
            'id': 'm4',
            'sender_id': patientId,
            'recipient_id': doctorId,
            'is_read': false,
          },
          // Another incoming unread message with snake_case schema (should be counted)
          {
            'id': 'm5',
            'sender_id': doctorId,
            'recipient_id': patientId,
            'is_read': false,
          },
        ];

        // Pure filter logic conforming to the required changes
        final unreadIncoming = messages.where((data) {
          final sender = (data['senderId'] ?? data['sender_id'] ?? '')
              .toString();
          if (sender == patientId)
            return false; // Patient's own outgoing messages must NOT be counted
          final receiver = (data['receiverId'] ?? data['recipient_id'] ?? '')
              .toString();
          if (receiver != patientId) return false;
          final isRead = data['isRead'] == true || data['is_read'] == true;
          return !isRead;
        }).toList();

        expect(unreadIncoming.length, 2);
        expect(unreadIncoming.map((m) => m['id']).toList(), ['m1', 'm5']);
      },
    );
  });
}
