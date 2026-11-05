// lib/features/calls/presentation/incoming_call_screen.dart
//
// Clean bridge to the new Voice Calling Incoming Call screen.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/features/auth/presentation/providers/user_provider.dart';
import 'package:telemedicine/features/calling/controllers/call_controller.dart'
    as new_calling;
import 'package:telemedicine/features/calling/screens/active_call_screen.dart';
import 'package:telemedicine/features/calling/screens/incoming_call_screen.dart'
    as new_ui;

class IncomingCallScreen extends ConsumerStatefulWidget {
  final String callId;
  final String callerName;
  final String callerImage;
  final String channelId;
  final String callType;
  final String callerId;
  final String callerType;
  final bool autoAccept;

  static bool isIncomingCallScreenOpen = false;

  const IncomingCallScreen({
    super.key,
    required this.callId,
    required this.callerName,
    required this.callerImage,
    required this.channelId,
    required this.callerId,
    this.callType = 'audio',
    this.callerType = 'doctor',
    this.autoAccept = false,
  });

  @override
  ConsumerState<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends ConsumerState<IncomingCallScreen> {
  @override
  void initState() {
    super.initState();
    IncomingCallScreen.isIncomingCallScreenOpen = true;

    if (widget.autoAccept) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _handleAutoAccept());
    }
  }

  Future<void> _handleAutoAccept() async {
    final user = ref.read(userProvider);
    final success = await new_calling.CallController.instance.acceptCall(
      widget.callId,
      userId: user?.id,
      userName: user?.fullname,
    );
    if (!mounted) return;
    if (success) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => ActiveCallScreen(
            callId: widget.callId,
            roomId: widget.channelId,
            otherUserId: widget.callerId,
            otherUserName: widget.callerName,
            otherUserRole: widget.callerType,
            otherUserImage: widget.callerImage,
            currentUserId: user?.id ?? '',
            currentUserName: user?.fullname ?? '',
            isCaller: false,
          ),
        ),
      );
    }
  }

  @override
  void dispose() {
    IncomingCallScreen.isIncomingCallScreenOpen = false;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(userProvider);

    return new_ui.IncomingCallScreen(
      callId: widget.callId,
      roomId: widget.channelId,
      callerId: widget.callerId,
      callerName: widget.callerName,
      callerRole: widget.callerType,
      callerImage: widget.callerImage,
      currentUserId: user?.id ?? '',
      currentUserName: user?.fullname ?? '',
    );
  }
}
