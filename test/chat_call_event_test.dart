import 'package:flutter_test/flutter_test.dart';
import 'package:telemedicine/data/models/chat_call_event.dart';

void main() {
  group('ChatCallStatus', () {
    test('normalizes every live spelling used by the call backend', () {
      expect(ChatCallStatus.parse('in_progress'), ChatCallStatus.ongoing);
      expect(ChatCallStatus.parse('CONNECTED'), ChatCallStatus.connected);
      expect(ChatCallStatus.parse('no answer'), ChatCallStatus.missed);
      expect(ChatCallStatus.parse('declined'), ChatCallStatus.rejected);
    });

    test('an unknown value is never treated as a recording', () {
      expect(ChatCallStatus.parse('something-new'), ChatCallStatus.completed);
    });

    test('live and terminal sets do not overlap', () {
      for (final status in ChatCallStatus.values) {
        expect(status.isLive && status.isTerminal, isFalse);
      }
    });
  });

  group('ChatCallEvent.fromMessageData', () {
    test('keeps the callId so the live document can be watched', () {
      final event = ChatCallEvent.fromMessageData(
        messageType: 'audio',
        message: 'Audio call in progress',
        callData: const {'callId': 'call-123', 'callStatus': 'ongoing'},
        timestamp: DateTime(2026, 10, 30, 10),
      );

      expect(event.callId, 'call-123');
      expect(event.status, ChatCallStatus.ongoing);
      expect(event.isLive, isTrue);
    });

    test('legacy body without callData still renders a useful event', () {
      final event = ChatCallEvent.fromMessageData(
        messageType: 'video',
        message: 'Missed video call',
      );

      expect(event.callId, isNull);
      expect(event.status, ChatCallStatus.missed);
      expect(event.title, 'Missed video call');
    });

    test('reads duration from callData before parsing the body', () {
      final event = ChatCallEvent.fromMessageData(
        messageType: 'audio',
        message: 'Call duration: 2:05',
        callData: const {'duration': 185},
      );

      expect(event.durationSeconds, 185);
      expect(event.hasDuration, isTrue);
    });

    test('falls back to a duration embedded in the legacy body', () {
      final event = ChatCallEvent.fromMessageData(
        messageType: 'audio',
        message: 'Audio call ended. Duration: 1:07',
        duration: 5,
      );

      expect(event.durationSeconds, 67);
    });

    test('call_recording always wins over a stale call status', () {
      final event = ChatCallEvent.fromMessageData(
        messageType: 'call_recording',
        message: '',
        callData: const {'callStatus': 'connected'},
      );

      expect(event.status, ChatCallStatus.recorded);
      expect(event.isRecording, isTrue);
    });

    test('copyWith can replace a stale live body with a terminal status', () {
      final event = ChatCallEvent.fromMessageData(
        messageType: 'audio',
        message: 'Audio call in progress',
        callData: const {'callId': 'call-1', 'callStatus': 'connected'},
      );
      final ended = event.copyWith(status: ChatCallStatus.completed);

      expect(ended.status, ChatCallStatus.completed);
      expect(ended.isTerminal, isTrue);
      expect(ended.callId, 'call-1');
    });
  });
}
