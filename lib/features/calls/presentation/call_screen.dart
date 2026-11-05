// lib/features/calls/presentation/call_screen.dart
//
// Clean bridge routing to OutgoingCallScreen or ActiveCallScreen.

import 'package:flutter/material.dart';
import 'package:telemedicine/features/calling/controllers/call_controller.dart';
import 'package:telemedicine/features/calling/screens/active_call_screen.dart';
import 'package:telemedicine/features/calling/screens/outgoing_call_screen.dart';

class CallScreen extends StatelessWidget {
  final String channelId;
  final String callId;
  final String callType;
  final String otherUserName;
  final String otherUserImage;
  final bool isCaller;
  final String currentUserId;
  final String? currentUserName;
  final String otherUserId;
  final String otherUserType;

  const CallScreen({
    super.key,
    required this.channelId,
    required this.callId,
    required this.callType,
    required this.otherUserName,
    required this.otherUserImage,
    required this.currentUserId,
    this.currentUserName,
    required this.otherUserId,
    required this.otherUserType,
    this.isCaller = true,
  });

  @override
  Widget build(BuildContext context) {
    final activeCall = CallController.instance.activeCall;
    final userName = currentUserName?.isNotEmpty == true
        ? currentUserName!
        : (isCaller
            ? (activeCall?.callerName ?? 'User')
            : (activeCall?.receiverName ?? 'User'));

    if (isCaller) {
      return OutgoingCallScreen(
        callId: callId,
        receiverId: otherUserId,
        receiverName: otherUserName,
        receiverRole: otherUserType,
        receiverImage: otherUserImage,
        currentUserId: currentUserId,
        currentUserName: userName,
      );
    } else {
      return ActiveCallScreen(
        callId: callId,
        roomId: channelId,
        otherUserId: otherUserId,
        otherUserName: otherUserName,
        otherUserRole: otherUserType,
        otherUserImage: otherUserImage,
        currentUserId: currentUserId,
        currentUserName: userName,
        isCaller: false,
      );
    }
  }
}
