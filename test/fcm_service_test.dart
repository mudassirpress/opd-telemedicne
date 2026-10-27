import 'package:flutter_test/flutter_test.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/core/services/fcm_service.dart';
import 'package:telemedicine/core/services/notification_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FcmTokenService & Channel Alignment', () {
    test('FcmTokenService singleton returns identical instance', () {
      final instance1 = FcmTokenService();
      final instance2 = FcmTokenService();
      expect(identical(instance1, instance2), isTrue);
    });

    test('Channel IDs match across NotificationService and AppConstants', () {
      expect(NotificationChannels.chat, 'chat_notifications_channel');
      expect(NotificationService.chatChannelId, 'chat_notifications_channel');
      expect(NotificationChannels.call, 'call_notifications_channel');
      expect(NotificationService.callChannelId, 'call_notifications_channel');
    });

    test('Legacy channel ids stay distinct from the current ones', () {
      expect(NotificationChannels.legacyChat, isNot(NotificationChannels.chat));
      expect(NotificationChannels.legacyCall, isNot(NotificationChannels.call));
    });

    test('FCM message types include chat and call definitions', () {
      expect(FcmMessageType.chat, 'chat');
      expect(FcmMessageType.chatMessage, 'chat_message');
      expect(FcmMessageType.isCall('call'), isTrue);
      expect(FcmMessageType.isCall('chat'), isFalse);
    });
  });
}

