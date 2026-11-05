import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/core/services/fcm_token_service.dart';
import 'package:telemedicine/core/services/callkit_service.dart';
import 'package:telemedicine/core/services/call_service.dart';
import 'package:telemedicine/core/services/incoming_call_coordinator.dart';
import 'package:telemedicine/core/services/notification_service.dart';
import 'package:telemedicine/app/theme/app_theme.dart';
import 'package:telemedicine/features/appointments/presentation/appointment_lifecycle_service.dart';
import 'package:telemedicine/core/services/smart_launch_coordinator.dart';
import 'package:telemedicine/core/services/single_device_session_service.dart';
import 'package:telemedicine/core/services/timezone_service.dart';
import 'package:workmanager/workmanager.dart';
import 'firebase_options.dart';
import 'package:telemedicine/features/calls/presentation/controllers/call_controller.dart';
import 'package:telemedicine/features/chat/presentation/controllers/chat_controller.dart';
import 'package:telemedicine/data/local/hive_db_service.dart';
import 'package:telemedicine/data/local/offline_chat_service.dart';

/// Single log funnel for every error handler below, including the ones that
/// run outside the widget tree (background isolate, Workmanager task).
void _logError(String message, Object error, StackTrace? stack) {
  debugPrint('❌ $message: $error');
  if (stack != null) {
    debugPrint(stack.toString());
  }
}

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    WidgetsFlutterBinding.ensureInitialized();
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );

    final data = message.data;

    // Pre-call reachability probe handshake: immediately acknowledge probe without ringing
    if (data['type'] == 'call_probe') {
      final probeId = data['probeId']?.toString() ?? '';
      final callId = data['callId']?.toString() ?? '';
      final doctorId =
          data['doctorId']?.toString() ?? data['receiverId']?.toString() ?? '';
      if (probeId.isNotEmpty && callId.isNotEmpty) {
        debugPrint(
          '⚡ [BACKGROUND] Received call_probe: $probeId for call: $callId',
        );
        try {
          await FirebaseFirestore.instance
              .collection(FirestoreCollections.calls)
              .doc(callId)
              .update({
                'probeAckId': probeId,
                'probeAckReceivedAt': FieldValue.serverTimestamp(),
              });
          if (doctorId.isNotEmpty) {
            unawaited(
              FirebaseFirestore.instance
                  .collection(FirestoreCollections.doctors)
                  .doc(doctorId)
                  .update({
                    'lastCallAckAt': FieldValue.serverTimestamp(),
                    'lastSeen': FieldValue.serverTimestamp(),
                  }),
            );
          }
        } catch (e) {
          debugPrint('Error writing probe ack in background: $e');
        }
      }
      return;
    }

    if (data['type'] == 'call_cancel') {
      final callId = (data['callId'] ?? '').toString();
      debugPrint('📞 [BACKGROUND] Received call_cancel for callId=$callId');
      if (callId.isNotEmpty) {
        await NotificationService().initializeForBackground();
        await CallKitService.instance.hide(callId);
        await IncomingCallCoordinator.instance.dismissNotification(callId);
      }
      return;
    }

    // Handle Missed Call push notifications
    if (data['type'] == 'missed_call' || data['type'] == 'MISSED_CALL') {
      final callId = (data['callId'] ?? '').toString();
      final callerName = (data['callerName'] ?? 'Doctor').toString();
      final callType = (data['callType'] ?? 'call').toString();
      final callerImage = data['callerImage']?.toString();
      debugPrint(
        '📞 [BACKGROUND] Received missed_call push for callId=$callId caller=$callerName',
      );
      if (callId.isNotEmpty) {
        await CallKitService.instance.hide(callId);
        await NotificationService().initializeForBackground();
        await NotificationService().dismissCallNotification(callId);
        await NotificationService().showMissedCallNotification(
          callId: callId,
          callerName: callerName,
          callType: callType,
          callerImage: callerImage,
        );
      }
      return;
    }

    if (_isCallPayload(data)) {
      final callId = (data['callId'] ?? '').toString();
      final timestampStr = data['timestamp']?.toString();
      final expiresAtStr = data['expiresAt']?.toString();
      final now = DateTime.now().millisecondsSinceEpoch;

      // 1. Conflict Prevention: Local age/expiration check to prevent stale calls from ringing
      bool isStale = false;
      if (expiresAtStr != null && int.tryParse(expiresAtStr) != null) {
        final expiresAt = int.parse(expiresAtStr);
        if (now >= expiresAt) isStale = true;
      } else if (timestampStr != null && int.tryParse(timestampStr) != null) {
        final timestamp = int.parse(timestampStr);
        // If ringing push was dispatched more than 40s ago, it is stale
        if (now - timestamp > 40000) isStale = true;
      }

      if (isStale) {
        debugPrint(
          '⚠️ [BACKGROUND] Stale incoming call push for callId=$callId. Showing missed call instead.',
        );
        if (callId.isNotEmpty) {
          await NotificationService().initializeForBackground();
          await NotificationService().showMissedCallNotification(
            callId: callId,
            callerName: data['callerName']?.toString() ?? 'Doctor',
            callType: data['callType']?.toString() ?? 'call',
            callerImage: data['callerImage']?.toString(),
          );
        }
        return;
      }

      // 2. Authoritative check against Firestore to ensure call is still ringing
      if (callId.isNotEmpty) {
        try {
          final doc = await FirebaseFirestore.instance
              .collection(FirestoreCollections.calls)
              .doc(callId)
              .get();
          if (doc.exists) {
            final status =
                doc.data()?['callStatus']?.toString() ??
                doc.data()?['status']?.toString();
            if (status != null && !CallStatus.isRinging(status)) {
              debugPrint(
                '⚠️ [BACKGROUND] Call $callId is already $status. Aborting ring.',
              );
              if (status == CallStatus.missed) {
                await NotificationService().initializeForBackground();
                await NotificationService().showMissedCallNotification(
                  callId: callId,
                  callerName: data['callerName']?.toString() ?? 'Doctor',
                  callType: data['callType']?.toString() ?? 'call',
                  callerImage: data['callerImage']?.toString(),
                );
              }
              return;
            }
          }
        } catch (e) {
          debugPrint(
            '⚠️ [BACKGROUND] Error checking call status in Firestore: $e',
          );
        }
      }

      // Route based on targetModule:
      // - 'opd_telemedicine': Native full-screen CallKit UI with accept/reject.
      // - Other/general: Standard heads-up notification with action pills.
      final targetModule =
          data['targetModule']?.toString().toLowerCase() ?? 'opd_telemedicine';
      final isOpdTelemedicine =
          targetModule == 'opd_telemedicine' || targetModule.isEmpty;

      if (isOpdTelemedicine) {
        // Headless isolate: prefer the native CallKit/full-screen surface. If the
        // plugin cannot present (for example on a platform where it is not
        // registered), fall back to the existing local-notification presenter.
        final payload = IncomingCallPayload.tryParse(data);
        if (payload != null && !payload.isExpired) {
          final shown = await CallKitService.instance.showIncomingCall(payload);
          if (shown) {
            await CallKitService.instance.acknowledgeDelivery(payload);
            return;
          }
        }

        await NotificationService().initializeForBackground();
        await IncomingCallCoordinator.instance.registerIncomingCall(
          data,
          origin: IncomingCallOrigin.backgroundPush,
        );
        return;
      } else {
        // Non-OPD module or general consultation request: standard heads-up alert
        await NotificationService().initializeForBackground();
        await NotificationService().showStandardHeadsUpCallNotification(data);
        return;
      }
    }

    if (data['type'] == 'password_reset_otp') {
      if (message.notification == null) {
        try {
          await NotificationService().initializeForBackground();
          NotificationService().showPasswordResetOtpLocalNotification(message);
        } catch (e, s) {
          _logError(
            'Background password reset notification display failed',
            e,
            s,
          );
        }
      }
      return;
    }

    if (_isChatMessagePayload(data, message)) {
      await OfflineChatService.applyChatPushPayload(data);

      try {
        await NotificationService().initializeForBackground();
        final mergedData = Map<String, dynamic>.from(data);
        if (message.notification != null) {
          mergedData['senderName'] =
              message.notification!.title ??
              data['senderName'] ??
              data['title'] ??
              'New Message';
          mergedData['messageText'] =
              message.notification!.body ??
              data['messageText'] ??
              data['message'] ??
              '';
        }

        // On iOS the APNs `alert` in a background push is rendered by the
        // system itself. Posting a local notification for it as well would show
        // the message twice. On Android a notification-bearing message never
        // reaches this isolate while backgrounded, so the local `show()` is the
        // only copy there (and the required path for data-only pushes).
        final bool systemRendersTray =
            message.notification != null &&
            defaultTargetPlatform == TargetPlatform.iOS;

        if (systemRendersTray) {
          debugPrint(
            'CHAT_NOTIFICATION_SYSTEM_RENDERED messageId=${message.messageId}',
          );
        } else {
          await NotificationService().showWhatsAppStyleChatNotification(
            mergedData,
          );
        }
      } catch (e, s) {
        _logError('Background chat notification display failed', e, s);
      }
      return;
    }
  } catch (e, s) {
    _logError('FCM background handler failed', e, s);
  }
}

/// Whether a background payload is an incoming chat message worth mirroring
/// into the local cache.
bool _isChatMessagePayload(
  Map<String, dynamic> data, [
  RemoteMessage? message,
]) {
  final type = data['type']?.toString().toLowerCase();
  if (type == 'chat_message' || type == 'chat') return true;
  if (data.containsKey('chatId') || data.containsKey('chat_id')) return true;
  if ((data.containsKey('messageId') || data.containsKey('message_id')) &&
      (data.containsKey('senderId') || data.containsKey('sender_id'))) {
    return true;
  }
  if (message?.notification != null) {
    final isOther =
        _isCallPayload(data) ||
        data['type'] == 'password_reset_otp' ||
        data['type'] == 'password_reset' ||
        data['type'] == 'report_shared' ||
        data['type'] == 'call_probe' ||
        FcmMessageType.isPayment(data['type']?.toString()) ||
        FcmMessageType.isAppointment(data['type']?.toString());
    if (!isOther) return true;
  }
  return false;
}

/// Workmanager callback: re-rings the tray for a call nobody has answered
/// after the first notification, so a phone that swallowed the first
/// heads-up still gets a second chance.
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    if (taskName != 'checkCallStatus' || inputData == null) return true;

    try {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
      await NotificationService().initializeForBackground();

      final callId = (inputData['callId'] ?? '').toString();
      if (callId.isEmpty) return true;

      final doc = await FirebaseFirestore.instance
          .collection(FirestoreCollections.calls)
          .doc(callId)
          .get();
      if (!doc.exists || doc.data()?['callStatus'] != CallStatus.ringing) {
        return true;
      }

      // The coordinator spent its `callId` claim on the original delivery, so
      // re-registering would be dropped as a duplicate. This task only has to
      // post the presenter again while the call is still ringing.
      final payload = IncomingCallPayload.tryParse(<String, dynamic>{
        ...?doc.data(),
        CallPayloadKeys.callId: callId,
      });
      if (payload != null) {
        await NotificationService().presentIncomingCallNotification(payload);
      }
    } catch (e, s) {
      _logError('checkCallStatus worker failed', e, s);
    }
    return true;
  });
}

bool _isCallPayload(Map<String, dynamic> data) {
  final rawType = data[CallPayloadKeys.type]?.toString().toLowerCase();
  if (rawType == 'missed_call' ||
      rawType == 'call_cancel' ||
      rawType == 'call_probe') {
    return false;
  }
  return (rawType != null && FcmMessageType.isCall(rawType)) ||
      (data.containsKey(CallPayloadKeys.callId) && rawType != 'chat_message');
}

/// Installs the three global error hooks *before* anything else can throw.
///
/// Without them a framework error is only shown as a red debug screen (and
/// silently swallowed in release), and an uncaught async error kills the zone
/// without any trace — which is exactly what makes "the call notification
/// stopped working" impossible to diagnose.
void _installErrorHandlers() {
  // Errors thrown by the framework (build/layout/gesture callbacks).
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    _logError('Flutter framework error', details.exception, details.stack);
  };

  // Errors that escape every zone — the ones that would otherwise crash the
  // isolate. Returning `true` marks them as handled so the app keeps running.
  ui.PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    _logError('Uncaught platform error', error, stack);
    return true;
  };

  // A failing build must not take the whole app down in release. In debug the
  // red screen with the stack trace is still the most useful thing to show.
  ErrorWidget.builder = (FlutterErrorDetails details) {
    if (!kReleaseMode) return ErrorWidget(details.exception);
    return const ColoredBox(
      color: Color(0xFFECEFF3),
      child: Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'Something went wrong.\nPlease restart the app.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xFF1F2F44)),
          ),
        ),
      ),
    );
  };
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _installErrorHandlers();

  // Everything below runs inside a guarded zone so a startup failure is
  // logged instead of dying silently. Deliberately not awaited: the guarded
  // future's own errors are reported by [runZonedGuarded]'s handler.
  runZonedGuarded<void>(
    () async {
      // Initialize WorkManager safely so a plugin channel error does not crash app bootstrap
      try {
        await Workmanager().initialize(callbackDispatcher);
      } catch (e, st) {
        debugPrint('⚠️ Workmanager initialization skipped or failed: $e\n$st');
      }

      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );

      // Pass all uncaught "fatal" errors from the framework to Crashlytics
      FlutterError.onError = (details) {
        FlutterError.presentError(details);
        _logError('Flutter framework error', details.exception, details.stack);
        FirebaseCrashlytics.instance.recordFlutterFatalError(details);
      };

      // Pass all uncaught asynchronous errors that escape a zone to Crashlytics
      ui.PlatformDispatcher.instance.onError = (error, stack) {
        _logError('Uncaught platform error', error, stack);
        FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
        return true;
      };

      // Initialize the local offline database (Hive) for chat & call history.
      await HiveDBService.initialize();

      // Register background handler — must happen before runApp so a push that
      // arrives while the app is still starting is not dropped.
      FirebaseMessaging.onBackgroundMessage(
        _firebaseMessagingBackgroundHandler,
      );

      // Bootstrap notifications before the first frame: requests the FCM/APNs
      // and Android 13+ POST_NOTIFICATIONS permissions, then registers the
      // chat/call channels. A push that arrives during start-up therefore
      // already has a valid channel instead of falling back to a default one.
      await NotificationService().bootstrap();

      // Initialize notification service (foreground FCM listener, notification
      // taps and the coordinator hooks).
      await NotificationService().initialize();

      // Bind CallKit/full-screen call events. This must run after the
      // coordinator hooks above, because accept navigates into the app.
      await CallKitService.instance.configure();

      // Determine startup target before rendering Flutter UI so notification launches
      // (chat, incoming calls, etc.) bypass the splash screen.
      final launchTarget = await SmartLaunchCoordinator.determineLaunchTarget();

      runApp(ProviderScope(child: MyApp(initialLaunchTarget: launchTarget)));
    },
    (Object error, StackTrace stack) {
      _logError('Uncaught error in root zone', error, stack);
      FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
    },
  );
}

class MyApp extends StatefulWidget {
  final LaunchTarget? initialLaunchTarget;

  const MyApp({super.key, this.initialLaunchTarget});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  final FCMServiceV2 _fcmService = FCMServiceV2();
  final NotificationService _notificationService = NotificationService();

  /// Throttle for the resume-time token refresh: a merge-write per resume is
  /// cheap, but a foreground⇄background flip-flop loop should not hammer
  /// Firestore. One refresh per hour is far more than enough to keep the
  /// stored token current.
  DateTime _lastResumeTokenRefresh = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeApp();
  }

  /// App resumed from background.
  ///
  /// Three things must re-happen, none of which may block the first frame:
  ///
  ///  1. FCM token refresh (throttled). Firebase can rotate the registration
  ///     token while the app is terminated (app update, reinstall, periodic
  ///     rotation). The stored token then goes dead and every chat push fails
  ///     silently against it until the next cold start re-registered it.
  ///     Re-registering on resume closes that window.
  ///  2. Flush the offline message outbox — connectivity may have returned
  ///     while the app was suspended and the connectivity listener missed it.
  ///  3. Chat-list recovery if the cache was never confirmed.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;

    final now = DateTime.now();
    if (now.difference(_lastResumeTokenRefresh).inHours >= 1) {
      _lastResumeTokenRefresh = now;
      unawaited(_refreshFcmTokenForCurrentUser());
    }

    unawaited(_validateActiveSessionOnResume());
    unawaited(_syncTimezoneForCurrentUser());
    unawaited(ChatController().syncPendingMessages());
    unawaited(ChatController().recoverChatListIfNeeded());
  }

  /// Verifies that this device still holds the active session when resumed from background.
  Future<void> _validateActiveSessionOnResume() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      String? userId;
      String? role;

      final doctorJson = prefs.getString('current_doctor');
      if (doctorJson != null && doctorJson.isNotEmpty) {
        try {
          final map = jsonDecode(doctorJson) as Map<String, dynamic>;
          userId = map['id']?.toString();
          role = 'doctor';
        } catch (_) {}
      }

      if (userId == null || userId.isEmpty) {
        final userJson = prefs.getString('current_user');
        if (userJson != null && userJson.isNotEmpty) {
          try {
            final map = jsonDecode(userJson) as Map<String, dynamic>;
            userId = map['id']?.toString();
            role = map['role']?.toString() ?? 'patient';
          } catch (_) {}
        }
      }

      if (userId == null || userId.isEmpty) return;

      final collection = role == 'doctor'
          ? 'telemedicine_doctors'
          : 'telemedicine_patient';

      final isValid = await SingleDeviceSessionService.validateCurrentSession(
        collectionName: collection,
        documentId: userId,
      );

      if (!isValid) {
        debugPrint(
          '🔒 [Lifecycle] Session invalidated remotely while app was suspended. Forcing logout.',
        );
        await SingleDeviceSessionService.handleForcedLogout(null);
      }
    } catch (e) {
      debugPrint('⚠️ [Lifecycle] Error validating session on resume: $e');
    }
  }

  /// Re-reads the persisted session and merge-writes this device's current
  /// FCM token onto the signed-in user's document. No-op when signed out.
  Future<void> _refreshFcmTokenForCurrentUser() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      String? userId;
      String? role;

      final userJson = prefs.getString('current_user');
      if (userJson != null && userJson.isNotEmpty) {
        try {
          final map = jsonDecode(userJson) as Map<String, dynamic>;
          userId = map['id']?.toString();
          role = map['role']?.toString();
        } catch (_) {}
      }

      if (userId == null || userId.isEmpty) {
        final doctorJson = prefs.getString('current_doctor');
        if (doctorJson != null && doctorJson.isNotEmpty) {
          try {
            final map = jsonDecode(doctorJson) as Map<String, dynamic>;
            userId = map['id']?.toString();
            role = 'doctor';
          } catch (_) {}
        }
      }

      if (userId == null || userId.isEmpty) return;

      await _fcmService.updateToken(userId, role ?? 'patient');
      debugPrint('🔁 FCM token re-registered on resume for $role: $userId');
    } catch (e, s) {
      _logError('Resume FCM token refresh failed', e, s);
    }
  }

  Future<void> _initializeApp() async {
    try {
      await _requestPermissions();

      // FCM registration and device token management:
      // The client keeps its device registration token current (see `FcmTokenService.updateToken`).

      // Offline-first sync: set up connectivity listener so pending messages are
      // pushed to the server the moment the device is back online.
      ChatController().setupConnectivitySync();
      await ChatController().syncPendingMessages();

      // Local-first chat list: on every launch, detect a missing or never-
      // confirmed local cache and fetch it once (a no-op with zero Firestore
      // reads when the cache is already complete). Runs unawaited so startup
      // is not held up; failures retry via the connectivity listener.
      unawaited(ChatController().recoverChatListIfNeeded());

      // Pre-warm Zego engine to avoid UI freeze when starting a call
      CallController().preWarmEngine();

      // Check for any pending call actions from terminated state
      await _notificationService.checkPendingCallAction();

      // Lost-push safety net: Firestore watcher for calls still ringing for
      // this device (see [registerIncomingCall]).
      unawaited(_listenForActiveCalls());

      // Appointment clock: expiry and the one-shot start alarm need time to
      // pass, and Firestore cannot start one on its own. The scheduled Cloud
      // Function covers the terminated case; this covers the open app.
      unawaited(AppointmentLifecycleService.instance.start());

      // Sync canonical device timezone with server profile
      unawaited(_syncTimezoneForCurrentUser());
    } catch (e, s) {
      _logError('App initialization failed', e, s);
    }
  }

  /// Syncs canonical IANA timezone for the authenticated user/doctor document.
  Future<void> _syncTimezoneForCurrentUser() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      String? userId;
      String? collectionName;

      final doctorJson = prefs.getString('current_doctor');
      if (doctorJson != null && doctorJson.isNotEmpty) {
        try {
          final map = jsonDecode(doctorJson) as Map<String, dynamic>;
          userId = map['id']?.toString();
          collectionName = 'telemedicine_doctors';
        } catch (_) {}
      }

      if (userId == null || userId.isEmpty) {
        final userJson = prefs.getString('current_user');
        if (userJson != null && userJson.isNotEmpty) {
          try {
            final map = jsonDecode(userJson) as Map<String, dynamic>;
            userId = map['id']?.toString();
            collectionName = 'telemedicine_patient';
          } catch (_) {}
        }
      }

      if (userId == null || userId.isEmpty || collectionName == null) return;
      await TimezoneService.syncUserTimezone(
        collectionName: collectionName,
        documentId: userId,
      );
    } catch (e) {
      debugPrint('⚠️ Timezone sync error: $e');
    }
  }

  /// Watches for calls this device should be ringing for and feeds every one
  /// of them through the coordinator, which decides — by app state, not by
  /// who called it — whether a notification, a screen, or both go up.
  ///
  /// [CallService] filters `calling`/`incoming`/`ringing` client-side instead
  /// of querying only `ringing`: the caller's first write is `calling`, so the
  /// old query missed every call that had not been acknowledged yet.
  Future<void> _listenForActiveCalls() async {
    // The signed-in session is written a moment after the splash resolves, so
    // give it a few attempts instead of silently never watching.
    var userId = '';
    for (var attempt = 0; attempt < 6 && userId.isEmpty; attempt++) {
      userId = await IncomingCallCoordinator.instance.resolveCurrentUserId();
      if (userId.isEmpty) {
        await Future<void>.delayed(const Duration(seconds: 5));
      }
    }

    if (userId.isEmpty) {
      debugPrint('⚠️ Call watcher not started: no signed-in user');
      return;
    }

    await CallService.instance.watchIncomingCalls(userId);
  }

  Future<void> _requestPermissions() async {
    // Notification permission is requested earlier, in
    // `NotificationService.bootstrap()` before `runApp`, so it is deliberately
    // not repeated here. These are the call/media permissions this screen
    // needs once the app is running.
    await [
      Permission.microphone,
      Permission.camera,
      Permission.ignoreBatteryOptimizations, // Add this for better reliability
    ].request();

    // Request ignore battery optimizations
    if (await Permission.ignoreBatteryOptimizations.isDenied) {
      await Permission.ignoreBatteryOptimizations.request();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(CallService.instance.stopWatchingIncomingCalls());
    AppointmentLifecycleService.instance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: NotificationService.navigatorKey,
      debugShowCheckedModeBanner: false,
      title: 'Telemedicine App',
      theme: AppTheme.light(),
      // Keeps the layout usable when the user raises the system font size:
      // scaling still happens (up to 1.25x) but is capped so fixed chrome
      // like the chat header, bottom navigation and buttons never overflow.
      builder: (context, child) {
        final mq = MediaQuery.of(context);
        final clamped = mq.textScaler.scale(1.0).clamp(0.9, 1.25);
        return MediaQuery(
          data: mq.copyWith(textScaler: TextScaler.linear(clamped)),
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: SmartLaunchCoordinator.buildRootWidget(
        widget.initialLaunchTarget ??
            const LaunchTarget(type: LaunchTargetType.normal),
      ),
    );
  }
}
