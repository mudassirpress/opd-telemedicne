import 'package:flutter_test/flutter_test.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/core/services/incoming_call_coordinator.dart';

/// Standardized payload as the Cloud Function now sends it.
Map<String, dynamic> _fcmCallPayload({
  String callId = 'call-1',
  String callerName = 'Dr. Asha',
  String callType = 'audio',
  String channelId = 'room-1',
  String? roomId,
  String? callerType,
}) {
  return <String, dynamic>{
    CallPayloadKeys.type: FcmMessageType.call,
    CallPayloadKeys.callId: callId,
    CallPayloadKeys.callerId: 'doc-1',
    CallPayloadKeys.callerName: callerName,
    CallPayloadKeys.callerImage: 'https://example.com/a.png',
    CallPayloadKeys.callerType: callerType ?? 'doctor',
    CallPayloadKeys.receiverId: 'pat-1',
    CallPayloadKeys.callType: callType,
    CallPayloadKeys.channelId: channelId,
    if (roomId != null) CallPayloadKeys.roomId: roomId,
    CallPayloadKeys.timestamp: '1700000000000',
  };
}

void main() {
  group('CallStatus state machine', () {
    test('accepts the three legal incoming-call outcomes', () {
      expect(CallStatus.canTransition('ringing', 'accepted'), isTrue);
      expect(CallStatus.canTransition('ringing', 'declined'), isTrue);
      expect(CallStatus.canTransition('ringing', 'missed'), isTrue);
      expect(CallStatus.canTransition('incoming', 'ringing'), isTrue);
    });

    test('only a still-ringing call may be accepted or declined', () {
      expect(CallStatus.canAccept('ringing'), isTrue);
      expect(CallStatus.canAccept('incoming'), isTrue);
      expect(CallStatus.canAccept('accepted'), isFalse);
      expect(CallStatus.canAccept('ended'), isFalse);
      expect(CallStatus.canAccept('missed'), isFalse);

      expect(CallStatus.canDecline('ringing'), isTrue);
      expect(CallStatus.canDecline('accepted'), isFalse);
      expect(CallStatus.canDecline('rejected'), isFalse);
    });

    test('a call can never be both accepted and declined', () {
      // Accept first...
      expect(CallStatus.canTransition('ringing', 'accepted'), isTrue);
      // ...a decline afterwards is rejected.
      expect(
        CallStatus.canTransition('accepted', 'declined'),
        isFalse,
        reason: 'accepting must terminally exclude declining',
      );
      expect(CallStatus.canDecline('accepted'), isFalse);
    });

    test('declining first blocks a later accept', () {
      expect(CallStatus.canTransition('ringing', 'declined'), isTrue);
      expect(CallStatus.canTransition('declined', 'accepted'), isFalse);
      expect(CallStatus.canAccept('declined'), isFalse);
    });

    test('terminal states are dead ends', () {
      for (final terminal in CallStatus.terminal) {
        expect(CallStatus.isTerminal(terminal), isTrue);
        for (final target in <String>[
          'accepted',
          'declined',
          'missed',
          'ended',
          'cancelled',
          'ringing',
        ]) {
          expect(
            CallStatus.canTransition(terminal, target),
            isFalse,
            reason: '$terminal -> $target must be rejected',
          );
        }
      }
    });

    test('unknown current state is treated as still ringing', () {
      // A push can beat the Firestore read, so `null` must not block a real
      // call.
      expect(CallStatus.canAccept(null), isTrue);
      expect(CallStatus.canTransition(null, 'accepted'), isTrue);
      expect(CallStatus.isTerminal(null), isFalse);
    });
  });

  group('IncomingCallPayload', () {
    test('parses the standardized FCM payload', () {
      final payload = IncomingCallPayload.tryParse(_fcmCallPayload());
      expect(payload, isNotNull);
      expect(payload!.callId, 'call-1');
      expect(payload.callerId, 'doc-1');
      expect(payload.callerName, 'Dr. Asha');
      expect(payload.callerImage, 'https://example.com/a.png');
      expect(payload.receiverId, 'pat-1');
      expect(payload.callerType, 'doctor');
      expect(payload.callType, 'audio');
      expect(payload.isVideo, isFalse);
      expect(payload.channelId, 'room-1');
      expect(payload.roomId, 'room-1');
    });

    test('roomId falls back to channelId and vice versa', () {
      final fromChannel = IncomingCallPayload.tryParse(
        _fcmCallPayload(roomId: null),
      );
      expect(fromChannel!.roomId, 'room-1');
      expect(fromChannel.channelId, 'room-1');

      final fromRoom = IncomingCallPayload.tryParse(<String, dynamic>{
        ..._fcmCallPayload(),
        CallPayloadKeys.channelId: '',
        CallPayloadKeys.roomId: 'room-9',
      });
      expect(fromRoom!.channelId, 'room-9');
      expect(fromRoom.roomId, 'room-9');
    });

    test('rejects a payload with no callId', () {
      // Without a callId the event cannot be de-duplicated, so dropping it is
      // the only way to guarantee a single notification.
      expect(IncomingCallPayload.tryParse(<String, dynamic>{}), isNull);
      expect(
        IncomingCallPayload.tryParse(<String, dynamic>{
          CallPayloadKeys.callerName: 'Dr. Asha',
        }),
        isNull,
      );
    });

    test('never lets a push blank out a known caller name', () {
      final payload = IncomingCallPayload.tryParse(
        _fcmCallPayload(callerName: ''),
      );
      expect(payload!.callerName, 'Unknown Caller');
    });

    test('normalizes the call type and the caller role', () {
      expect(
        IncomingCallPayload.tryParse(
          _fcmCallPayload(callType: 'VIDEO'),
        )!.callType,
        'video',
      );
      expect(
        IncomingCallPayload.tryParse(
          _fcmCallPayload(callType: 'garbage'),
        )!.callType,
        'audio',
      );
      expect(
        IncomingCallPayload.tryParse(
          _fcmCallPayload(callerType: 'patient'),
        )!.callerType,
        'patient',
      );
    });

    test('survives a round-trip through its wire form', () {
      // The notification payload is the serialized map, and the tap handler
      // re-parses it. The `callId` must survive so the action can find the
      // call.
      final original = IncomingCallPayload.tryParse(_fcmCallPayload())!;
      final decoded = IncomingCallPayload.tryParse(original.toMap())!;
      expect(decoded.callId, original.callId);
      expect(decoded.callerName, original.callerName);
      expect(decoded.channelId, original.channelId);
      expect(decoded.roomId, original.roomId);
      expect(decoded.receiverId, original.receiverId);
    });

    test('parses a Firestore call document shape too', () {
      // The lost-push watcher feeds raw call documents into the same parser.
      final payload = IncomingCallPayload.tryParse(<String, dynamic>{
        'id': 'call-7',
        'callId': 'call-7',
        'callerId': 'doc-2',
        'callerName': 'Dr. Roy',
        'callerImage': null,
        'callerType': 'doctor',
        'receiverId': 'pat-2',
        'channelId': 'room-7',
        'callType': 'video',
        'callStatus': 'ringing',
        'startTime': '2026-01-01T00:00:00.000',
      });
      expect(payload, isNotNull);
      expect(payload!.callId, 'call-7');
      expect(payload.callerImage, '');
      expect(payload.isVideo, isTrue);
    });
  });

  group('Call action ids', () {
    test('the notification and the app agree on the action ids', () {
      // These are the literal ids baked into the notification's
      // AndroidNotificationAction list and read back by the tap handlers.
      expect(CallActionIds.accept, 'accept_call');
      expect(CallActionIds.decline, 'decline_call');
      expect(CallActionIds.open, 'open_call');
    });
  });
}
