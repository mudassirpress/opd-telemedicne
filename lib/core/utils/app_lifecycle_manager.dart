// lib/core/utils/app_lifecycle_manager.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/features/auth/presentation/providers/user_provider.dart';
import 'package:telemedicine/features/auth/presentation/controllers/doctor_controller.dart';
import 'package:telemedicine/features/calls/presentation/controllers/call_controller.dart';

class AppLifecycleManager extends WidgetsBindingObserver {
  final WidgetRef ref;
  bool _isRegistered = false;

  AppLifecycleManager(this.ref);

  void start() {
    if (!_isRegistered) {
      WidgetsBinding.instance.addObserver(this);
      _isRegistered = true;
    }
  }

  void dispose() {
    if (_isRegistered) {
      WidgetsBinding.instance.removeObserver(this);
      _isRegistered = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      CallController().handleAppKilledDuringCall();
    }

    // ── Doctor presence ──────────────────────────────────────────────────
    final doctorController = ref.read(doctorControllerProvider);
    final currentDoctor = doctorController.currentDoctor;

    if (currentDoctor != null) {
      switch (state) {
        case AppLifecycleState.resumed:
          // Resume automated foreground heartbeat timer
          doctorController.startPresenceTracking();
          break;
        case AppLifecycleState.paused:
        case AppLifecycleState.detached:
        case AppLifecycleState.inactive:
        case AppLifecycleState.hidden:
          // Stop foreground timer to conserve battery; do NOT overwrite manual intent.
          doctorController.stopPresenceTracking();
          break;
      }
    }

    // ── Patient presence ─────────────────────────────────────────────────
    final patientController = ref.read(patientControllerProvider);
    final currentPatient = patientController.currentUser;

    if (currentPatient != null && currentPatient.role == 'patient') {
      switch (state) {
        case AppLifecycleState.resumed:
          patientController.updatePatientOnlineStatus(true);
          patientController.startPresenceTracking();
          break;
        case AppLifecycleState.paused:
        case AppLifecycleState.detached:
        case AppLifecycleState.inactive:
        case AppLifecycleState.hidden:
          patientController.updatePatientOnlineStatus(false);
          patientController.stopPresenceTracking();
          break;
      }
    }
  }
}
