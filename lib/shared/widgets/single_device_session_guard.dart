import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:telemedicine/core/services/single_device_session_service.dart';

/// Wraps any dashboard or portal (e.g. DoctorPortalWrapper, PatientPortalWrapper)
/// to automatically enforce single-device active session in real-time.
class SingleDeviceSessionGuard extends StatefulWidget {
  final Widget child;
  final String collectionName;
  final String documentId;

  const SingleDeviceSessionGuard({
    super.key,
    required this.child,
    required this.collectionName,
    required this.documentId,
  });

  @override
  State<SingleDeviceSessionGuard> createState() =>
      _SingleDeviceSessionGuardState();
}

class _SingleDeviceSessionGuardState extends State<SingleDeviceSessionGuard> {
  StreamSubscription<DocumentSnapshot>? _sessionSub;
  bool _isLoggedOut = false;

  @override
  void initState() {
    super.initState();
    _startListening();
  }

  Future<void> _startListening() async {
    final currentDeviceId = await SingleDeviceSessionService.getDeviceId();
    if (!mounted) return;

    _sessionSub = SingleDeviceSessionService.listenForSessionChanges(
      collectionName: widget.collectionName,
      documentId: widget.documentId,
      currentDeviceId: currentDeviceId,
      onSessionInvalidated: _onSessionTerminated,
    );
  }

  void _onSessionTerminated() {
    if (_isLoggedOut || !mounted) return;
    _isLoggedOut = true;

    SingleDeviceSessionService.handleForcedLogout(
      context,
      message:
          'This account has been accessed from another device. For your security, this session has been terminated.',
    );
  }

  @override
  void dispose() {
    _sessionSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
