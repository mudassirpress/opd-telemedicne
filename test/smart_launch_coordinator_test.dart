import 'package:flutter_test/flutter_test.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/core/services/smart_launch_coordinator.dart';
import 'package:telemedicine/features/splash/splash_screen.dart';

void main() {
  group('SmartLaunchCoordinator Target Resolution Tests', () {
    test('Launcher launch defaults to normal LaunchTarget', () {
      const target = LaunchTarget(type: LaunchTargetType.normal);
      expect(target.isNormal, isTrue);
      expect(target.isChat, isFalse);
      expect(target.isIncomingCall, isFalse);
      expect(target.isActiveCall, isFalse);
      expect(target.isDeclineCall, isFalse);
    });

    test('Chat notification resolves to chat LaunchTarget', () {
      const target = LaunchTarget(
        type: LaunchTargetType.chat,
        data: <String, dynamic>{
          'type': 'chat',
          'chatId': 'chat_123',
          'senderId': 'doc_456',
          'senderName': 'Dr. Test',
        },
      );
      expect(target.isNormal, isFalse);
      expect(target.isChat, isTrue);
      expect(target.data['chatId'], 'chat_123');
      expect(target.data['senderId'], 'doc_456');
    });

    test('Incoming call notification body tap resolves to incomingCall', () {
      const target = LaunchTarget(
        type: LaunchTargetType.incomingCall,
        data: <String, dynamic>{
          'type': 'call',
          'callId': 'call_abc',
          'callerName': 'Patient John',
        },
      );
      expect(target.isIncomingCall, isTrue);
      expect(target.isActiveCall, isFalse);
      expect(target.isNormal, isFalse);
    });

    test('Incoming call Accept action resolves to activeCall', () {
      const target = LaunchTarget(
        type: LaunchTargetType.activeCall,
        actionId: CallActionIds.accept,
        data: <String, dynamic>{
          'type': 'call',
          'callId': 'call_abc',
          'callerName': 'Patient John',
        },
      );
      expect(target.isActiveCall, isTrue);
      expect(target.isIncomingCall, isFalse);
      expect(target.actionId, CallActionIds.accept);
    });

    test('Incoming call Decline action resolves to declineCall', () {
      const target = LaunchTarget(
        type: LaunchTargetType.declineCall,
        actionId: CallActionIds.decline,
        data: <String, dynamic>{
          'type': 'call',
          'callId': 'call_abc',
        },
      );
      expect(target.isDeclineCall, isTrue);
      expect(target.actionId, CallActionIds.decline);
    });

    test('buildRootWidget returns FirstSplashScreen for normal launch', () {
      const normalTarget = LaunchTarget(type: LaunchTargetType.normal);
      final widget = SmartLaunchCoordinator.buildRootWidget(normalTarget);
      expect(widget, isA<FirstSplashScreen>());
    });

    test('buildRootWidget returns SmartDirectLaunchWrapper for chat notification', () {
      const chatTarget = LaunchTarget(
        type: LaunchTargetType.chat,
        data: <String, dynamic>{
          'chatId': 'c1',
          'senderId': 's1',
        },
      );
      final widget = SmartLaunchCoordinator.buildRootWidget(chatTarget);
      expect(widget, isA<SmartDirectLaunchWrapper>());
      expect(widget is FirstSplashScreen, isFalse);
    });

    test('buildRootWidget returns SmartDirectLaunchWrapper for incoming call notification', () {
      const callTarget = LaunchTarget(
        type: LaunchTargetType.incomingCall,
        data: <String, dynamic>{
          'callId': 'call_xyz',
        },
      );
      final widget = SmartLaunchCoordinator.buildRootWidget(callTarget);
      expect(widget, isA<SmartDirectLaunchWrapper>());
      expect(widget is FirstSplashScreen, isFalse);
    });
  });
}
