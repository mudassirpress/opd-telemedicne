// lib/features/calling/services/call_lifecycle_service.dart

import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:telemedicine/features/calling/services/call_audio_service.dart';
import 'package:telemedicine/features/calling/services/zego_call_service.dart';

class CallLifecycleService {
  CallLifecycleService._();
  static final CallLifecycleService instance = CallLifecycleService._();

  final Connectivity _connectivity = Connectivity();
  StreamSubscription<ConnectivityResult>? _connectivitySub;
  Timer? _reconnectWatchdog;

  void startMonitoring({required VoidCallback onNetworkRestored}) {
    _connectivitySub?.cancel();
    _connectivitySub = _connectivity.onConnectivityChanged.listen((result) {
      if (result != ConnectivityResult.none) {
        debugPrint('🌐 [CallLifecycleService] Connectivity restored: $result');
        onNetworkRestored();
      } else {
        debugPrint('⚠️ [CallLifecycleService] Connectivity lost!');
      }
    });
  }

  void stopMonitoring() {
    _connectivitySub?.cancel();
    _connectivitySub = null;
    _reconnectWatchdog?.cancel();
    _reconnectWatchdog = null;
  }

  /// Clean teardown when user logs out of the app.
  Future<void> onUserLogout() async {
    stopMonitoring();
    await CallAudioService.instance.cleanup();
    await ZegoCallService.instance.destroy();
  }
}

