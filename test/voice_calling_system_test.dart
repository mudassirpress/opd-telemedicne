// test/voice_calling_system_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:telemedicine/features/calling/domain/call_model.dart';
import 'package:telemedicine/features/calling/domain/call_state_machine.dart';
import 'package:telemedicine/features/calling/domain/call_status.dart';
import 'package:telemedicine/features/calling/services/zego_call_service.dart';
import 'package:telemedicine/features/calling/widgets/call_timer.dart';

void main() {
  group('CallingStatus state machine rules', () {
    test('legal transitions in happy path voice calling', () {
      expect(CallingStatus.canTransition(CallingStatus.initiating, CallingStatus.calling), isTrue);
      expect(CallingStatus.canTransition(CallingStatus.calling, CallingStatus.ringing), isTrue);
      expect(CallingStatus.canTransition(CallingStatus.ringing, CallingStatus.accepted), isTrue);
      expect(CallingStatus.canTransition(CallingStatus.accepted, CallingStatus.connecting), isTrue);
      expect(CallingStatus.canTransition(CallingStatus.connecting, CallingStatus.connected), isTrue);
      expect(CallingStatus.canTransition(CallingStatus.connected, CallingStatus.ended), isTrue);
    });

    test('rejections and cancellations are legal from ringing states', () {
      expect(CallingStatus.canTransition(CallingStatus.calling, CallingStatus.cancelled), isTrue);
      expect(CallingStatus.canTransition(CallingStatus.ringing, CallingStatus.rejected), isTrue);
      expect(CallingStatus.canTransition(CallingStatus.ringing, CallingStatus.missed), isTrue);
      expect(CallingStatus.canTransition(CallingStatus.calling, CallingStatus.busy), isTrue);
    });

    test('terminal states are dead ends and cannot be resurrected', () {
      for (final term in CallingStatus.terminal) {
        expect(CallingStatus.isTerminal(term), isTrue);
        expect(CallingStatus.canTransition(term, CallingStatus.calling), isFalse);
        expect(CallingStatus.canTransition(term, CallingStatus.ringing), isFalse);
        expect(CallingStatus.canTransition(term, CallingStatus.connected), isFalse);
      }
    });

    test('canAccept and canDecline guards', () {
      expect(CallingStatus.canAccept(CallingStatus.calling), isTrue);
      expect(CallingStatus.canAccept(CallingStatus.ringing), isTrue);
      expect(CallingStatus.canAccept(CallingStatus.connected), isFalse);
      expect(CallingStatus.canAccept(CallingStatus.ended), isFalse);
      expect(CallingStatus.canAccept(CallingStatus.cancelled), isFalse);

      expect(CallingStatus.canDecline(CallingStatus.calling), isTrue);
      expect(CallingStatus.canDecline(CallingStatus.ringing), isTrue);
      expect(CallingStatus.canDecline(CallingStatus.rejected), isFalse);
      expect(CallingStatus.canDecline(CallingStatus.ended), isFalse);
    });
  });

  group('CallStateMachine instance tests', () {
    test('tracks and rejects illegal transitions', () {
      final sm = CallStateMachine(callId: 'call_test_1');
      expect(sm.currentStatus, CallingStatus.initiating);

      expect(sm.transitionTo(CallingStatus.calling), isTrue);
      expect(sm.currentStatus, CallingStatus.calling);

      expect(sm.transitionTo(CallingStatus.ringing), isTrue);
      expect(sm.currentStatus, CallingStatus.ringing);

      expect(sm.transitionTo(CallingStatus.accepted), isTrue);
      expect(sm.currentStatus, CallingStatus.accepted);

      // Illegal: cannot go from accepted straight back to ringing
      expect(sm.transitionTo(CallingStatus.ringing), isFalse);
      expect(sm.currentStatus, CallingStatus.accepted);

      expect(sm.transitionTo(CallingStatus.connected), isTrue);
      expect(sm.currentStatus, CallingStatus.connected);

      expect(sm.transitionTo(CallingStatus.ended), isTrue);
      expect(sm.currentStatus, CallingStatus.ended);
      expect(sm.isTerminal, isTrue);

      // Cannot leave terminal
      expect(sm.transitionTo(CallingStatus.connected), isFalse);
    });
  });

  group('VoiceCallModel serialization & compatibility', () {
    test('toMap and fromMap preserves all Section 8 fields', () {
      final now = DateTime.utc(2026, 11, 2, 10, 30, 0);
      final model = VoiceCallModel(
        callId: 'call_999',
        callerId: 'doc_1',
        callerName: 'Dr. John',
        callerRole: 'doctor',
        callerImage: 'https://example.com/doc.jpg',
        receiverId: 'pat_1',
        receiverName: 'Alice',
        receiverRole: 'patient',
        receiverImage: 'https://example.com/pat.jpg',
        callType: 'audio',
        roomId: 'room_999',
        status: CallingStatus.connected,
        createdAt: now,
        acceptedAt: now.add(const Duration(seconds: 4)),
        connectedAt: now.add(const Duration(seconds: 6)),
        endedAt: now.add(const Duration(seconds: 120)),
        duration: 114,
        endReason: 'normal_hangup',
        missedCall: false,
        rejectedBy: null,
        callerDeviceId: 'dev_caller',
        receiverDeviceId: 'dev_receiver',
      );

      final map = model.toMap();
      expect(map['callId'], 'call_999');
      expect(map['id'], 'call_999');
      expect(map['callerRole'], 'doctor');
      expect(map['receiverRole'], 'patient');
      expect(map['callType'], 'audio');
      expect(map['roomId'], 'room_999');
      expect(map['channelId'], 'room_999');
      expect(map['status'], CallingStatus.connected);
      expect(map['callStatus'], CallingStatus.connected);
      expect(map['duration'], 114);

      final parsed = VoiceCallModel.fromMap(map);
      expect(parsed.callId, 'call_999');
      expect(parsed.callerName, 'Dr. John');
      expect(parsed.receiverName, 'Alice');
      expect(parsed.status, CallingStatus.connected);
      expect(parsed.duration, 114);
      expect(parsed.endReason, 'normal_hangup');
      expect(parsed.channelId, 'room_999');
    });
  });

  group('ZegoCallService user ID sanitization', () {
    test('formats raw user ID to alphanumeric and underscore', () {
      expect(ZegoCallService.formatZegoUserId('user-123@abc'), 'user_123_abc');
      expect(ZegoCallService.formatZegoUserId('doc.special#1'), 'doc_special_1');
      expect(ZegoCallService.formatZegoUserId(''), 'user_default');
    });
  });

  group('CallTimerWidget duration formatting', () {
    test('formats seconds into MM:SS and HH:MM:SS', () {
      expect(CallTimerWidget.formatDuration(0), '00:00');
      expect(CallTimerWidget.formatDuration(59), '00:59');
      expect(CallTimerWidget.formatDuration(65), '01:05');
      expect(CallTimerWidget.formatDuration(3665), '01:01:05');
    });
  });
}

