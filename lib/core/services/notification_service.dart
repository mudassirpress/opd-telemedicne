import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:telemedicine/core/services/fcm_token_service.dart';
import 'package:telemedicine/firebase_options.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/features/auth/presentation/controllers/patient_controller.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/core/services/audio_service.dart';
import 'package:telemedicine/core/services/call_ringtone_service.dart';
import 'package:telemedicine/core/services/incoming_call_coordinator.dart';
import 'package:telemedicine/core/services/callkit_service.dart';
import 'package:telemedicine/features/doctor_portal/presentation/bottom_nav/doctor_portal_tab_provider.dart';
import 'package:telemedicine/features/doctor_portal/presentation/bottom_nav/doctor_portal_wrapper.dart';
import 'package:telemedicine/features/doctor_portal/presentation/shared_reports/doctor_shared_reports_screen.dart';
import 'package:telemedicine/features/patients/presentation/patient_portal_tab_provider.dart';
import 'package:telemedicine/features/patients/presentation/patient_portal_wrapper.dart';
import 'package:telemedicine/features/calls/presentation/call_screen.dart';
import 'package:telemedicine/features/calls/presentation/incoming_call_screen.dart';
import 'package:telemedicine/features/calling/screens/active_call_screen.dart';
import 'package:telemedicine/features/chat/presentation/chat_screen.dart';
import 'package:telemedicine/features/admin/presentation/notifications/admin_complaint_detail_screen.dart';
import 'package:telemedicine/features/admin/presentation/notifications/admin_payment_screen.dart';
import 'package:telemedicine/features/complaints/presentation/submit_complaint_screen.dart';
import 'package:telemedicine/features/chat/presentation/room_chat_screen.dart';
import 'package:telemedicine/data/local/offline_chat_service.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FirebaseMessaging _fcm = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  bool _isInit = false;
  bool _bootstrapDone = false;
  bool _channelsReady = false;

  /// Stable per-`callId` notification id. A repeat delivery reuses the same
  /// id *and* the same tag, so Android replaces the existing notification
  /// instead of stacking a second identical one in the tray.
  static int notificationIdForCall(String callId) =>
      callId.hashCode.abs() % 100000;

  static String notificationTagForCall(String callId) => 'call_$callId';

  // Navigation key for accessing context from anywhere
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  static const MethodChannel _callPlatformChannel = MethodChannel(
    'telemedicine/call_platform',
  );

  // WhatsApp-style notification deduplication and active chat tracking
  static String? activeChatId;

  /// Set when [initialize] consumed a notification that *launched* the app
  /// (a local notification tap/action or an FCM initial message).
  ///
  /// [SmartLaunchCoordinator] reads this before it builds a direct destination
  /// so the same cold-start tap is routed exactly once: by this service, which
  /// applies the payment lock and conversation authorization. When this is
  /// false the Smart wrapper keeps its own fallback routing.
  static bool coldStartNotificationConsumed = false;
  static NotificationResponse? coldStartNotificationResponse;

  // ─────────────────────────────────────────────────────────────
  // PAYMENT NOTIFICATION DE-DUPLICATION / NAVIGATION GUARDS
  // ─────────────────────────────────────────────────────────────

  // One submission/decision can reach the device more than once: the app sends
  // the push itself and the server delivery retries it, and a system-rendered
  // notification plus a locally shown one can both deliver a tap. Both sets are
  // keyed by `notificationId` (falling back to `paymentId`) so a given payment
  // event is displayed once and navigated to once.
  final Set<String> _displayedPaymentNotificationIds = {};
  final Set<String> _navigatedPaymentNotificationIds = {};

  /// Message ids whose tap already opened their conversation.
  ///
  /// The `activeChatId` guard alone cannot stop a double delivery (tray tap +
  /// full-screen intent, or a system and a local notification for one push):
  /// both taps are processed before the first `ChatScreen.initState` has had a
  /// chance to set `activeChatId`, so both pushed a copy. The id is the stable
  /// event key. Insertion-ordered and bounded so a long session cannot grow it
  /// without limit.
  final Set<String> _navigatedChatNotificationIds = <String>{};

  /// Completed once the splash screen has finished role-based routing.
  ///
  /// A notification tap that cold-starts the app is delivered from `main()`
  /// *before* `runApp`, and the splash screen then replaces the whole stack
  /// with `pushReplacement`. Buffering the navigation until routing is done is
  /// what keeps the destination from being wiped off the stack.
  static final Completer<void> _appReadyCompleter = Completer<void>();

  /// Set by `ChatRoomScreen`. Invoked with the authoritative Firestore payment
  /// status when an approval/rejection notification is tapped, so an
  /// already-open Room Chat unlocks (or re-locks) instantly with no restart.
  static void Function(String status)? onPaymentStatusRefreshRequested;

  static bool get isAppReady => _appReadyCompleter.isCompleted;

  /// Called by the splash screen once it has routed to the portal for the
  /// signed-in role. Safe to call more than once.
  static void markAppReady() {
    if (!_appReadyCompleter.isCompleted) {
      debugPrint('✅ App marked ready — flushing buffered navigations');
      _appReadyCompleter.complete();
    }
  }

  // ─────────────────────────────────────────────────────────────
  // CHANNEL IDs
  // ─────────────────────────────────────────────────────────────

  /// Key used for de-duplication. Prefers `notificationId` (unique per push)
  /// and falls back to `paymentId` (unique per submission) so either
  /// identifier alone is enough to suppress a repeat.
  String _paymentNotificationKey(Map<String, dynamic> data) {
    final notificationId = (data['notificationId'] ?? '').toString();
    if (notificationId.isNotEmpty) return 'n:$notificationId';
    final paymentId = (data['paymentId'] ?? '').toString();
    if (paymentId.isNotEmpty) return 'p:$paymentId';
    return '';
  }

  // ─────────────────────────────────────────────────────────────
  // APPOINTMENT NOTIFICATION DE-DUPLICATION / NAVIGATION GUARDS
  //
  // Same contract as the payment sets above: one appointment event may reach
  // the device once and navigate once, keyed on `notificationId` with a
  // fallback to `appointmentId`.
  // ─────────────────────────────────────────────────────────────

  final Set<String> _displayedAppointmentNotificationIds = {};
  final Set<String> _navigatedAppointmentNotificationIds = {};

  String _appointmentNotificationKey(Map<String, dynamic> data) {
    final notificationId = (data['notificationId'] ?? '').toString();
    if (notificationId.isNotEmpty) return 'n:$notificationId';
    final appointmentId = (data['appointmentId'] ?? '').toString();
    if (appointmentId.isNotEmpty) {
      // The event type is part of the identity: one appointment emits a
      // reminder, a late warning, a cancellation and a no-show over its life,
      // and without the type the first would swallow the rest.
      final type = (data['type'] ?? '').toString();
      return 'a:$type:$appointmentId';
    }
    return '';
  }

  // Channel IDs
  static const String chatChannelId = NotificationChannels.chat;
  static const String callChannelId = NotificationChannels.call;
  static const String incomingCallsChannelId =
      NotificationChannels.incomingCalls;
  static const String generalChannelId = NotificationChannels.general;
  static const String passwordResetChannelId =
      NotificationChannels.passwordReset;

  /// Where a notification action tapped in the *background* isolate is parked
  /// so the main isolate can finish it. A static field cannot be used for this:
  /// the two isolates have separate memories.
  static const String _kPendingNotificationAction =
      'pending_notification_action';

  /// Bump when an IMMUTABLE property of the call channel changes.
  ///
  /// Android 8+ freezes a channel's sound, vibration and importance at first
  /// creation and silently ignores every later `createNotificationChannel`
  /// call for the same id. The call channel originally had no sound (the
  /// system's short "ping" instead of a ringtone), so the only way to give
  /// already-installed devices the ringtone is to DELETE the old channel and
  /// recreate it — once, gated on this version number.
  static const int callChannelVersion = 4;
  static const String _kCallChannelVersion = 'call_channel_version';

  /// v3: channel ids moved to `*_channel` and the chat channel gained
  /// `Importance.max`; both are immutable after first creation.
  static const int chatChannelVersion = 3;
  static const String _kChatChannelVersion = 'chat_channel_version';

  // ─────────────────────────────────────────────────────────────
  // INIT
  // ─────────────────────────────────────────────────────────────

  /// App-bootstrap half of the notification stack, called from `main()`
  /// *before* `runApp()`.
  ///
  /// It requests both permission layers (FCM/APNs and the Android 13+
  /// `POST_NOTIFICATIONS` runtime grant) and registers the channels, so the
  /// very first push of this process — including one that arrives while the
  /// app is still building its first frame — has a valid channel to target.
  ///
  /// Safe to call more than once; [initialize] reuses the result.
  Future<void> bootstrap() async {
    if (_bootstrapDone) return;

    // Wire the coordinator to this service's plugin + navigator before anything
    // that can throw. Everything that decides *whether* a call is shown/opened
    // runs in the coordinator; everything that *draws* it runs here. Binding
    // first means the background isolate can still post the ONE incoming-call
    // notification even if a later permission/listener step fails.
    _bindIncomingCallHooks();

    await _requestNotificationPermissions();

    // A notification-plugin failure must never prevent the app from starting:
    // `bootstrap()` runs before `runApp`, so an escaping exception would leave
    // the user on the native splash forever. A failed channel registration is
    // logged, and the background handler retries it in its own isolate.
    try {
      await _initializeNotificationChannels();
    } catch (e, s) {
      debugPrint('⚠️ Notification channel bootstrap failed: $e\n$s');
    }

    _bootstrapDone = true;
  }

  /// Requests every permission the notification pipeline needs.
  ///
  /// Android 13 (API 33) blocks ALL notifications — including FCM-delivered
  /// ones — until `POST_NOTIFICATIONS` is granted at runtime. The manifest
  /// declaration alone is not enough, and `FirebaseMessaging.requestPermission`
  /// does not ask for it on Android. Both layers are requested here, from the
  /// main isolate, before `runApp`.
  Future<void> _requestNotificationPermissions() async {
    try {
      await _fcm.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        criticalAlert: true,
        provisional: false,
      );
    } catch (e) {
      debugPrint('⚠️ FCM permission request failed: $e');
    }

    try {
      final androidPlugin = _localNotifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      // No-op below API 33 (returns true), so this is safe on every version.
      final granted = await androidPlugin?.requestNotificationsPermission();
      debugPrint('🔔 Android notification permission granted=$granted');
    } catch (e) {
      debugPrint('⚠️ Android notification permission request failed: $e');
    }

    try {
      final canFullScreen = await _callPlatformChannel.invokeMethod<bool>(
        'canUseFullScreenIntent',
      );
      debugPrint('🔔 Android full-screen intent allowed=$canFullScreen');
    } catch (_) {}
  }

  /// Checks if full-screen intent is allowed (relevant for Android 14+).
  Future<bool> checkFullScreenIntentPermission() async {
    try {
      return await _callPlatformChannel.invokeMethod<bool>(
            'canUseFullScreenIntent',
          ) ??
          true;
    } catch (_) {
      return true;
    }
  }

  /// Opens the system settings to grant full-screen intent permission on Android 14+.
  Future<void> openFullScreenIntentSettings() async {
    try {
      await _callPlatformChannel.invokeMethod<void>(
        'openFullScreenIntentSettings',
      );
    } catch (e) {
      debugPrint('Could not open full-screen intent settings: $e');
    }
  }

  Future<void> initialize() async {
    if (_isInit) return;

    await bootstrap();

    tz.initializeTimeZones();
    try {
      final String timeZoneName = tz.local.name;
      tz.setLocalLocation(tz.getLocation(timeZoneName));
    } catch (_) {}

    try {
      await _fcm.setForegroundNotificationPresentationOptions(
        // We handle display ourselves to avoid duplicates
        alert: false,
        badge: true,
        sound: false,
      );
    } catch (e) {
      debugPrint('⚠️ Foreground presentation options not applied: $e');
    }

    try {
      await _setupNotificationHandlers();
    } catch (e) {
      debugPrint('⚠️ Notification handlers not fully wired: $e');
    }

    // Keep the receiver's latest FCM token in Firestore so the server
    // never pushes to a stale/rotated token.
    try {
      _registerTokenRefresh();
    } catch (e) {
      debugPrint('⚠️ FCM token refresh listener not started: $e');
    }

    _isInit = true;
    debugPrint('✅ NotificationService initialized');
  }

  /// The bare minimum needed by an isolate that only has to *post* the
  /// incoming-call notification: the FCM background isolate
  /// (`_firebaseMessagingBackgroundHandler`) and the Workmanager re-notify
  /// task.
  ///
  /// It deliberately skips everything that only makes sense in the main
  /// isolate — the permission request, `FirebaseMessaging.onMessage`, the
  /// token listener and the tap-navigation drain. What it *does* build is the
  /// `call` channel plus the plugin callbacks, without which the notification
  /// (and its Accept/Decline actions) could not be posted at all, and the
  /// coordinator hooks, without which `registerIncomingCall` would have no
  /// presenter in this isolate.
  Future<void> initializeForBackground() async {
    if (_isInit) return;

    _bindIncomingCallHooks();

    try {
      await _initializeNotificationChannels();
    } catch (e) {
      debugPrint('⚠️ Background notification init failed: $e');
      return;
    }

    _isInit = true;
    _bootstrapDone = true;
    debugPrint('✅ NotificationService initialized (background isolate)');
  }

  /// Connects [IncomingCallCoordinator] to this service's notification plugin
  /// and navigator.
  void _bindIncomingCallHooks() {
    IncomingCallCoordinator.bindHooks(
      IncomingCallHooks(
        present: presentIncomingCallNotification,
        dismiss: (callId) => _cancelCallNotification(callId),
        openIncomingCallScreen: _openIncomingCallScreen,
        openCallScreen: _openCallScreen,
        awaitAppReady: _waitForAppReady,
      ),
    );
  }

  /// Registers every Android notification channel this app posts to.
  ///
  /// Android 8+ freezes a channel's importance, sound and vibration at first
  /// creation. The `*ChannelVersion` counters below are therefore bumped
  /// together with any immutable setting change: an existing install deletes
  /// the old channels once and recreates them with what this build expects.
  Future<void> _initializeNotificationChannels() async {
    if (_channelsReady) return;

    const AndroidNotificationChannel chatChannel = AndroidNotificationChannel(
      chatChannelId,
      'Chat Messages',
      description: 'Notifications for incoming chat messages',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
      showBadge: true,
      enableLights: true,
    );

    // The ONE incoming-call channel. `AndroidNotificationCategory.call` on the
    // notification itself makes Android treat it as an actual call, so the
    // Accept/Decline actions render inline and a full-screen intent is allowed.
    //
    // The channel owns the sound for the case the app process cannot: a killed
    // or force-stopped app has no Dart isolate (and therefore no looping
    // in-app ringtone) when the call push lands. The ringtone is the app's own
    // res/raw/call_ringtoun.mp3, set on the channel so the system can play it
    // before any Flutter code runs.
    //
    // In the foreground the per-notification `playSound` flag is turned off in
    // `presentIncomingCallNotification`, so the looping MediaPlayer is the only
    // ringtone the user hears there. That is what prevents a double ring.
    const AndroidNotificationChannel callChannel = AndroidNotificationChannel(
      callChannelId,
      'Incoming Calls',
      description: 'Incoming voice and video call notifications',
      importance: Importance.max,
      playSound: true,
      sound: RawResourceAndroidNotificationSound('call_ringtoun'),
      enableVibration: true,
      showBadge: true,
      enableLights: true,
      audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
    );

    const AndroidNotificationChannel generalChannel =
        AndroidNotificationChannel(
          generalChannelId,
          'General',
          description: 'General notifications',
          importance: Importance.defaultImportance,
        );

    const AndroidNotificationChannel passwordResetChannel =
        AndroidNotificationChannel(
          passwordResetChannelId,
          'Password Reset',
          description: 'Notifications for password reset requests',
          importance: Importance.high,
          enableVibration: true,
          playSound: true,
          enableLights: true,
        );

    const AndroidNotificationChannel missedCallsChannel =
        AndroidNotificationChannel(
          NotificationChannels.missedCalls,
          'Missed Calls',
          description: 'Notifications for missed voice and video calls',
          importance: Importance.high,
          enableVibration: true,
          playSound: true,
          showBadge: true,
        );

    final androidPlugin = _localNotifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();

    // Android 8+ freezes a channel's sound and importance at first creation.
    // Delete the current *and* legacy IDs once so the renamed channels are
    // created fresh with Importance.max and the ringtone.
    try {
      final prefs = await SharedPreferences.getInstance();
      final installedChat = prefs.getInt(_kChatChannelVersion) ?? 0;
      if (installedChat < chatChannelVersion && androidPlugin != null) {
        for (final id in <String>{
          chatChannelId,
          NotificationChannels.legacyChat,
        }) {
          await androidPlugin.deleteNotificationChannel(channelId: id);
        }
        await prefs.setInt(_kChatChannelVersion, chatChannelVersion);
      }
    } catch (e) {
      debugPrint('⚠️ Could not version-bump the chat channel: $e');
    }

    await androidPlugin?.createNotificationChannel(chatChannel);

    // Same migration for the call channel: devices that installed the app
    // while the call channel was still sound-less (or under its legacy id)
    // must have it deleted once so the ringtone takes effect.
    try {
      final prefs = await SharedPreferences.getInstance();
      final installed = prefs.getInt(_kCallChannelVersion) ?? 0;
      if (installed < callChannelVersion && androidPlugin != null) {
        for (final id in <String>{
          callChannelId,
          NotificationChannels.legacyCall,
          NotificationChannels.incomingCalls,
          'incoming_calls_channel',
        }) {
          await androidPlugin.deleteNotificationChannel(channelId: id);
        }
        await prefs.setInt(_kCallChannelVersion, callChannelVersion);
      }
    } catch (e) {
      debugPrint('⚠️ Could not version-bump the call channel: $e');
    }

    await androidPlugin?.createNotificationChannel(callChannel);

    // The dedicated `incoming_calls` channel required for Android call heads-up & lock screen
    const AndroidNotificationChannel dedicatedIncomingCalls =
        AndroidNotificationChannel(
          NotificationChannels.incomingCalls,
          'Incoming Calls',
          description: 'Incoming voice and video call notifications',
          importance: Importance.max,
          playSound: true,
          sound: RawResourceAndroidNotificationSound('call_ringtoun'),
          enableVibration: true,
          showBadge: true,
          enableLights: true,
          audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
        );
    await androidPlugin?.createNotificationChannel(dedicatedIncomingCalls);

    // Also register alias 'incoming_calls_channel' with identical high-priority settings
    const AndroidNotificationChannel incomingCallsAlias =
        AndroidNotificationChannel(
          'incoming_calls_channel',
          'Incoming Calls',
          description: 'Incoming voice and video call notifications',
          importance: Importance.max,
          playSound: true,
          sound: RawResourceAndroidNotificationSound('call_ringtoun'),
          enableVibration: true,
          showBadge: true,
          enableLights: true,
          audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
        );
    await androidPlugin?.createNotificationChannel(incomingCallsAlias);
    await androidPlugin?.createNotificationChannel(generalChannel);
    await androidPlugin?.createNotificationChannel(passwordResetChannel);
    await androidPlugin?.createNotificationChannel(missedCallsChannel);

    const DarwinInitializationSettings iOSSettings =
        DarwinInitializationSettings(
          requestAlertPermission: true,
          requestBadgePermission: true,
          requestSoundPermission: true,
          defaultPresentAlert: true,
          defaultPresentBadge: true,
          defaultPresentSound: true,
        );

    // Dedicated monochrome vector. The launcher icon becomes an empty white
    // square on many Android launchers when used as the small icon.
    const AndroidInitializationSettings androidSettings =
        AndroidInitializationSettings('@drawable/ic_notification');

    const InitializationSettings settings = InitializationSettings(
      android: androidSettings,
      iOS: iOSSettings,
    );

    await _localNotifications.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: _onNotificationTap,
      onDidReceiveBackgroundNotificationResponse: _onBackgroundNotificationTap,
    );

    _channelsReady = true;
    debugPrint('✅ Notification channels registered');
  }

  /// Picks up a notification action/body tap that *launched* the app.
  ///
  /// `flutter_local_notifications` only pushes `didReceiveNotificationResponse`
  /// to `onNewIntent` — i.e. when the app was already running. When the app was
  /// killed and the Accept/Decline action started it, the action sits on the
  /// activity's launch intent and is only reachable through
  /// `getNotificationAppLaunchDetails()`.
  ///
  /// The previous code never called it, so pressing Accept or Decline on the
  /// incoming-call notification of a *killed* app started the app and then did
  /// absolutely nothing. This is that missing read.
  Future<void> _drainNotificationLaunchDetails() async {
    try {
      final details = await _localNotifications
          .getNotificationAppLaunchDetails();
      final response = details?.notificationResponse;
      if (response == null) return;
      if (details?.didNotificationLaunchApp != true) return;
      if (response.payload == null || response.payload!.isEmpty) return;

      // This tap is now owned by the navigation below. [SmartLaunchCoordinator]
      // must not build a second destination for it.
      coldStartNotificationConsumed = true;
      coldStartNotificationResponse = response;
      debugPrint(
        '📲 App launched from a notification: actionId=${response.actionId}',
      );
      _onNotificationTap(response);
    } catch (e) {
      debugPrint('Could not read notification launch details: $e');
    }
  }

  Future<void> _setupNotificationHandlers() async {
    // Cold start from a notification action. Must run after the plugin is
    // initialised (the callback above) and before anything else reacts, so the
    // Accept/Decline action is the first thing the app processes.
    await _drainNotificationLaunchDetails();

    // Foreground
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      debugPrint('📨 FCM_MESSAGE_RECEIVED (foreground) ${message.messageId}');
      _handleForegroundMessage(message);
    });

    // App opened from terminated
    RemoteMessage? initialMessage = await _fcm.getInitialMessage();
    if (initialMessage != null) {
      // Same single-owner rule as the local-notification launch details above.
      coldStartNotificationConsumed = true;
      _handleMessageNavigation(initialMessage);
    }

    // App opened from background
    FirebaseMessaging.onMessageOpenedApp.listen(_handleMessageNavigation);
  }

  /// Keep the receiver's FCM token fresh in Firestore whenever Firebase rotates
  /// the registration token (reinstall, app update, expiry, etc.). Without this
  /// pushes to an old token are silently lost.
  void _registerTokenRefresh() {
    _fcm.onTokenRefresh.listen((String newToken) async {
      debugPrint('🔥 FCM token refreshed');
      if (newToken.isEmpty) return;

      try {
        final prefs = await SharedPreferences.getInstance();
        final doctorJson = prefs.getString('current_doctor');
        final userJson = prefs.getString('current_user');
        bool updated = false;

        if (doctorJson != null && doctorJson.isNotEmpty) {
          try {
            final map = jsonDecode(doctorJson) as Map<String, dynamic>;
            final docId = map['id']?.toString();
            if (docId != null && docId.isNotEmpty) {
              await FCMServiceV2().updateToken(docId, 'doctor');
              debugPrint('🔥 FCM token refreshed for doctor: $docId');
              updated = true;
            }
          } catch (_) {}
        }

        if (userJson != null && userJson.isNotEmpty) {
          try {
            final map = jsonDecode(userJson) as Map<String, dynamic>;
            final patId = map['id']?.toString();
            final patRole = map['role']?.toString() ?? 'patient';
            if (patId != null && patId.isNotEmpty) {
              await FCMServiceV2().updateToken(patId, patRole);
              debugPrint('🔥 FCM token refreshed for $patRole: $patId');
              updated = true;
            }
          } catch (_) {}
        }

        if (!updated) {
          debugPrint('FCM token refresh: no signed-in user found');
          return;
        }
      } catch (e) {
        debugPrint('Error saving refreshed FCM token: $e');
      }
    });
  }

  // ─────────────────────────────────────────────────────────────
  // FOREGROUND MESSAGE HANDLER
  // ─────────────────────────────────────────────────────────────

  void _handleForegroundMessage(RemoteMessage message) {
    final data = message.data;

    if (data['type'] == 'password_reset_otp') {
      showPasswordResetOtpLocalNotification(message);
      return;
    }

    if (data['type'] == 'password_reset') {
      _showPasswordResetLocalNotification(data);
      return;
    }

    if (data['type'] == 'call_probe') {
      final probeId = data['probeId']?.toString() ?? '';
      final callId = data['callId']?.toString() ?? '';
      final doctorId =
          data['doctorId']?.toString() ?? data['receiverId']?.toString() ?? '';
      if (probeId.isNotEmpty && callId.isNotEmpty) {
        debugPrint(
          '⚡ [FOREGROUND] Received call_probe: $probeId for call: $callId',
        );
        unawaited(
          FirebaseFirestore.instance
              .collection(FirestoreCollections.calls)
              .doc(callId)
              .update({
                'probeAckId': probeId,
                'probeAckReceivedAt': FieldValue.serverTimestamp(),
              }),
        );
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
      }
      return;
    }

    if (data['type'] == 'call_cancel') {
      final callId = (data['callId'] ?? '').toString();
      debugPrint('📞 [FOREGROUND] Received call_cancel for callId=$callId');
      if (callId.isNotEmpty) {
        unawaited(IncomingCallCoordinator.instance.dismissNotification(callId));
      }
      return;
    }

    if (data['type'] == 'missed_call' || data['type'] == 'MISSED_CALL') {
      final callId = (data['callId'] ?? '').toString();
      final callerName = (data['callerName'] ?? 'Doctor').toString();
      final callType = (data['callType'] ?? 'call').toString();
      final callerImage = data['callerImage']?.toString();
      debugPrint(
        '📞 [FOREGROUND] Received missed_call push for callId=$callId',
      );
      if (callId.isNotEmpty) {
        unawaited(IncomingCallCoordinator.instance.dismissNotification(callId));
        unawaited(CallKitService.instance.hide(callId));
        unawaited(
          showMissedCallNotification(
            callId: callId,
            callerName: callerName,
            callType: callType,
            callerImage: callerImage,
          ),
        );
      }
      return;
    }

    if (data['type'] == 'call' || data.containsKey('callId')) {
      debugPrint(
        '📞 FCM call push received (foreground) callId=${data['callId']} '
        'callerName=${data['callerName']} callType=${data['callType']} '
        'callerId=${data['callerId']}',
      );
      // The coordinator decides whether this delivery is the one that owns the
      // Incoming Call screen. A second delivery of the same callId is dropped
      // there, so nothing else needs to check for duplicates.
      unawaited(
        IncomingCallCoordinator.instance.registerIncomingCall(
          data,
          origin: IncomingCallOrigin.foregroundPush,
        ),
      );
      return;
    }

    if (FcmMessageType.isPayment(data['type'] as String?)) {
      // payment_submitted (admin), payment_approved / payment_rejected
      // (patient) and the legacy payment_proof all land here.
      _showPaymentLocalNotification(data);
      return;
    }

    if (FcmMessageType.isAppointment(data['type'] as String?)) {
      // appointment_payment_* (admin / patient), new_appointment_request
      // (doctor) and appointment_confirmed (patient).
      _showAppointmentLocalNotification(data);
      return;
    }

    if (data['type'] == 'report_shared') {
      _showReportSharedLocalNotification(data);
      return;
    }

    final chatType = (data['type'] ?? '').toString().toLowerCase();
    final isCall = data['type'] == 'call' || data.containsKey('callId');
    if (chatType == 'chat_message' ||
        chatType == 'chat' ||
        data.containsKey('chatId') ||
        data.containsKey('chat_id') ||
        (message.notification != null &&
            !isCall &&
            !FcmMessageType.isPayment(data['type'] as String?) &&
            !FcmMessageType.isAppointment(data['type'] as String?) &&
            data['type'] != 'report_shared' &&
            data['type'] != 'password_reset' &&
            data['type'] != 'password_reset_otp' &&
            data['type'] != 'call_probe')) {
      final chatId = (data['chatId'] ?? data['chat_id'])?.toString();
      if (chatId != null && (activeChatId == null || activeChatId != chatId)) {
        unawaited(OfflineChatService.applyChatPushPayload(data));
      }

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
      showWhatsAppStyleChatNotification(mergedData);
      FCMServiceV2().onMessageReceived?.call(mergedData);
      return;
    }
  }

  // ─────────────────────────────────────────────────────────────
  // INCOMING CALL — the ONE notification
  //
  // This service is a pure presenter. Whether a call may be shown at all is
  // decided by [IncomingCallCoordinator.registerIncomingCall]; the coordinator
  // has already de-duplicated by `callId` by the time we get here.
  //
  // The notification is deliberately NOT handed to `flutter_callkit_incoming`
  // any more. That plugin rendered its own native incoming-call heads-up with
  // its own Accept/Decline buttons *in addition to* this one, and those
  // buttons ran a second accept implementation. Two notifications, two
  // actions, two code paths for one call.
  // ─────────────────────────────────────────────────────────────

  /// Presents the single incoming-call notification for [payload].
  ///
  /// The notification id and tag are both derived from `callId`, so a repeat
  /// presentation replaces the existing notification instead of adding a
  /// second one to the tray.
  Future<void> presentIncomingCallNotification(
    IncomingCallPayload payload,
  ) async {
    final callId = payload.callId;
    if (callId.isEmpty) return;

    final notificationId = notificationIdForCall(callId);

    // The channel owns the ringtone for the headless/killed path. When the app
    // is actually on screen we silence the notification instead and let the
    // looping in-app player ring, otherwise both would play at once.
    final bool appVisible = _isAppForegrounded();

    // Android 14+ can revoke the full-screen-intent grant from non-calling
    // apps. Asking the platform (instead of always requesting it) keeps the
    // notification a normal high-importance heads-up in that case, which still
    // rings and still offers Accept/Decline, rather than being dropped.
    final bool canFullScreen = await checkFullScreenIntentPermission();
    if (!canFullScreen) {
      debugPrint(
        '⚠️ Full-screen intent not allowed — showing call as a heads-up '
        'notification instead (callId=$callId)',
      );
    }

    // Fast rendering: do not block incoming call presentation on network avatar download
    await _localNotifications.show(
      id: notificationId,
      title: payload.callerName,
      body: payload.isVideo ? 'Incoming video call' : 'Incoming voice call',
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          NotificationChannels.incomingCalls,
          'Incoming Calls',
          channelDescription: 'Incoming voice and video call notifications',
          importance: Importance.max,
          priority: Priority.max,
          fullScreenIntent: canFullScreen,
          category: AndroidNotificationCategory.call,
          audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
          icon: '@drawable/ic_notification',
          visibility: NotificationVisibility.public,
          // Same tag => a repeat delivery replaces, never stacks.
          tag: notificationTagForCall(callId),
          ongoing: true,
          autoCancel: false,
          // Foreground: the looping in-app player rings, so the notification is
          // silent (channel sound would double it). Background/killed: the app
          // has no player, so the channel's raw ringtone is what makes the call
          // audible.
          playSound: !appVisible,
          silent: appVisible,
          enableVibration: !appVisible,
          sound: const RawResourceAndroidNotificationSound('call_ringtoun'),
          // Accept must open the app: it has to land the user on the live Call
          // screen. `showsUserInterface: true` routes the action to the main
          // isolate through `onNewIntent`, which is the only reliable path for
          // that.
          //
          // Decline must NOT open the app. `showsUserInterface: false` routes
          // it to `onDidReceiveBackgroundNotificationResponse`, where the
          // transition is applied headlessly. The intent is also persisted so
          // the main isolate can finish the job if the headless engine could
          // not start.
          actions: const <AndroidNotificationAction>[
            AndroidNotificationAction(
              CallActionIds.accept,
              'Accept',
              showsUserInterface: true,
              cancelNotification: true,
            ),
            AndroidNotificationAction(
              CallActionIds.decline,
              'Decline',
              showsUserInterface: false,
              cancelNotification: true,
            ),
          ],
          additionalFlags: Int32List.fromList(<int>[
            4,
          ]), // Notification.FLAG_INSISTENT for continuous ringing
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
          interruptionLevel: InterruptionLevel.critical,
          categoryIdentifier: 'incoming_call',
        ),
      ),
      // The payload is the normalized call map, so the tap handler reads the
      // exact same keys whichever action button was pressed.
      payload: jsonEncode(payload.toMap()),
    );

    // Loop the app's ringtone for as long as this call is ringing, starting
    // the moment the call is presented rather than only when (or if) the
    // Incoming Call screen opens. Covers foreground ringing and a backgrounded
    // app whose Activity is still alive; the channel sound above covers the
    // killed-app case. Idempotent, and a headless isolate (background FCM
    // handler, Workmanager task) simply logs the missing Activity and moves on
    // — the notification's own sound still plays.
    // The looping in-app ringtone is managed cleanly by IncomingCallScreen / CallAudioService
    // to avoid duplicate audio streams when the app is visible.

    debugPrint(
      '📞 Incoming call notification shown id=$notificationId callId=$callId '
      'appVisible=$appVisible',
    );
  }

  /// Whether the main app window is currently resumed.
  ///
  /// Returns `false` in a background/headless isolate — where the binding was
  /// never initialised and no window exists — which is exactly what routes the
  /// call notification to the channel ringtone there.
  bool _isAppForegrounded() {
    try {
      return WidgetsBinding.instance.lifecycleState ==
          AppLifecycleState.resumed;
    } catch (_) {
      return false;
    }
  }

  /// Downloads (and caches) a remote avatar so the notification can show the
  /// caller's face. Never throws: a missing avatar only costs the icon.
  Future<AndroidBitmap<Object>?> _downloadAvatarForNotification(
    String url,
    String ownerId,
  ) async {
    try {
      final dir = await getTemporaryDirectory();
      final fileName = 'avatar_${ownerId}_${url.hashCode}.png';
      final file = File('${dir.path}/$fileName');

      if (!await file.exists()) {
        // Bounded: this runs on the path that opens the Incoming Call screen
        // in the foreground, so a hanging connection must never delay the
        // ring UI.
        final response = await http
            .get(Uri.parse(url))
            .timeout(const Duration(seconds: 3));
        if (response.statusCode == 200) {
          await file.writeAsBytes(response.bodyBytes);
        }
      }

      if (await file.exists()) {
        return FilePathAndroidBitmap(file.path);
      }
    } catch (e) {
      debugPrint('Error downloading caller image for notification: $e');
    }
    return null;
  }

  /// Removes the incoming-call notification for [callId] (by id *and* by tag,
  /// so a notification posted with either identity is cleared).
  ///
  /// Also stops the looped in-app ringtone: every way a ringing call can end
  /// (accept, decline, miss, caller cancel, ring timeout, handover) funnels
  /// through the coordinator's [dismissNotification], which calls this hook.
  Future<void> _cancelCallNotification(String callId) async {
    if (callId.isEmpty) return;
    final id = notificationIdForCall(callId);

    await _localNotifications.cancel(id: id);
    final androidPlugin = _localNotifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await androidPlugin?.cancel(id: id, tag: notificationTagForCall(callId));
    unawaited(SystemRingtonePlayer.stopDefaultRingtone());
    unawaited(CallRingtoneService.instance.stopRingtone());
    debugPrint('🔕 Incoming call notification dismissed: $callId');
  }

  /// Public dismiss entry point. Delegates to the coordinator so the
  /// auto-dismiss timer, the "active call" pointer and the notification all
  /// stay consistent no matter who asks.
  Future<void> dismissCallNotification(String callId) =>
      IncomingCallCoordinator.instance.dismissNotification(callId);

  /// Public "this call is over" entry point. Releases the `callId` claim so
  /// the next call from the same caller is not mistaken for a duplicate.
  Future<void> clearCallRecord(String callId) =>
      IncomingCallCoordinator.instance.clearCallRecord(callId);

  /// Displays a persistent, high-priority Missed Call notification banner in the system tray.
  Future<void> showMissedCallNotification({
    required String callId,
    required String callerName,
    required String callType,
    String? callerImage,
  }) async {
    try {
      await _initializeNotificationChannels();
      final id = notificationIdForCall(callId);
      final isVideo = callType.toLowerCase() == 'video';
      final title = 'Missed ${isVideo ? 'video' : 'voice'} call';
      final body = 'You missed a call from $callerName';

      final androidDetails = AndroidNotificationDetails(
        NotificationChannels.missedCalls,
        'Missed Calls',
        channelDescription: 'Notifications for missed voice and video calls',
        importance: Importance.high,
        priority: Priority.high,
        showWhen: true,
        autoCancel: true,
        category: AndroidNotificationCategory.missedCall,
        color: const Color(0xFFE53935),
      );

      const iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        categoryIdentifier: 'MISSED_CALL',
      );

      final details = NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      );

      await _localNotifications.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: details,
        payload: jsonEncode({
          'type': 'missed_call',
          'callId': callId,
          'callerName': callerName,
          'callType': callType,
        }),
      );
      debugPrint('📞 Missed call notification shown for callId=$callId');
    } catch (e, s) {
      debugPrint('❌ Failed to show missed call notification: $e\n$s');
    }
  }

  /// Displays a standard heads-up notification with Action buttons for non-OPD
  /// calls or general consultations.
  Future<void> showStandardHeadsUpCallNotification(
    Map<String, dynamic> data,
  ) async {
    try {
      await _initializeNotificationChannels();
      final callId = data['callId']?.toString() ?? '';
      final id = notificationIdForCall(callId);
      final callerName = (data['callerName'] ?? 'Caller').toString();
      final callType = (data['callType'] ?? 'audio').toString();
      final isVideo = callType.toLowerCase() == 'video';

      const androidDetails = AndroidNotificationDetails(
        NotificationChannels.general,
        'General Consultations',
        channelDescription: 'Heads-up notification for non-OPD requests',
        importance: Importance.max,
        priority: Priority.high,
        playSound: true,
        category: AndroidNotificationCategory.call,
        actions: <AndroidNotificationAction>[
          AndroidNotificationAction(
            'accept_call',
            'Accept',
            showsUserInterface: true,
          ),
          AndroidNotificationAction(
            'decline_call',
            'Decline',
            cancelNotification: true,
          ),
        ],
      );

      const iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      );

      await _localNotifications.show(
        id: id,
        title: 'Incoming ${isVideo ? 'Video' : 'Voice'} Call',
        body: '$callerName is calling you',
        notificationDetails: const NotificationDetails(
          android: androidDetails,
          iOS: iosDetails,
        ),
        payload: jsonEncode(data),
      );
      debugPrint('📞 Heads-up call notification shown for callId=$callId');
    } catch (e, s) {
      debugPrint('❌ Failed to show heads-up call notification: $e\n$s');
    }
  }

  /// Replays a call that was pushed while the app was dead.
  ///
  /// The payload is consumed exactly once; a second call returns immediately.
  /// Runs after the splash screen has finished routing, so the Incoming Call
  /// screen it opens is not wiped by the splash's `pushReplacement`.
  Future<void> checkPendingCallAction() async {
    // A notification action pressed from the tray is handled by the durable
    // pending-action store (see [_onBackgroundNotificationTap]); the call
    // itself is resolved from Firestore inside the coordinator.
    await _drainPendingNotificationAction();

    final pending = await IncomingCallCoordinator.instance.consumePendingCall();
    if (pending == null) return;

    debugPrint('📞 Recovering pending incoming call ${pending.callId}');

    await IncomingCallCoordinator.instance.registerIncomingCall(
      pending.toMap(),
      origin: IncomingCallOrigin.recovery,
    );
  }

  // ─────────────────────────────────────────────────────────────
  // NAVIGATION — bound to the coordinator as hooks
  // ─────────────────────────────────────────────────────────────

  /// Pushes the app's custom Incoming Call screen. Kept here because the
  /// payment lock and the navigator key live in this service.
  Future<bool> _openIncomingCallScreen(
    IncomingCallPayload payload, {
    bool autoAccept = false,
  }) async {
    // A payment-locked patient must not reach the call screen, even when the
    // doctor initiated the call. The Room Chat already blocks the live call
    // stream; this closes the push-tap route to the same screen.
    final lockStatus = await _resolveActiveFeatureLock();
    if (lockStatus != null) {
      await _routeLockedPatientToRoomChat(lockStatus);
      return false;
    }

    if (!await _waitForAppReady()) return false;

    final navigator = await _waitForNavigator();
    if (navigator == null) {
      debugPrint('⚠️ No navigator context for call navigation');
      return false;
    }

    if (IncomingCallScreen.isIncomingCallScreenOpen) {
      debugPrint(
        '⚠️ An Incoming Call screen is already on the stack — not pushing '
        'another for ${payload.callId}',
      );
      return false;
    }

    IncomingCallCoordinator.instance.markScreenOpened(payload.callId);

    debugPrint(
      '📞 Opening IncomingCallScreen callId=${payload.callId} '
      'caller=${payload.callerName} type=${payload.callType} '
      'room=${payload.roomId}',
    );

    // The notification deliberately stays in the tray while the screen is
    // open: it is the "still ringing" indicator, it survives the user
    // backgrounding the app mid-ring, and every exit from the call
    // (accept / decline / miss / handover / ring timeout) clears it through
    // `IncomingCallCoordinator.dismissNotification`. The Accept action cannot
    // push a second Call screen on top of this one — the coordinator's
    // `accept` de-duplicates by `callId` and `isScreenOpenFor` keeps the
    // handover on the screen that is already there.
    IncomingCallScreen.isIncomingCallScreenOpen = true;
    navigator.push(
      MaterialPageRoute(
        settings: const RouteSettings(name: '/incoming_call'),
        builder: (_) => IncomingCallScreen(
          callId: payload.callId,
          callerName: payload.callerName,
          callerImage: payload.callerImage,
          channelId: payload.channelId,
          callType: payload.callType,
          callerId: payload.callerId,
          callerType: payload.callerType,
          autoAccept: autoAccept,
        ),
      ),
    );
    return true;
  }

  /// Pushes the live ActiveCallScreen. Used when the accept came straight from the
  /// notification's Accept button, so no Incoming Call screen was ever shown.
  Future<bool> _openCallScreen(
    IncomingCallPayload payload,
    String currentUserId,
  ) async {
    // If call screen is already mounted on the stack, skip duplicate navigation
    if (IncomingCallCoordinator.instance.isScreenOpenFor(payload.callId)) {
      debugPrint(
        '📞 Call screen already open for callId=${payload.callId} — skipping duplicate push',
      );
      return true;
    }

    // Same payment gate as [_openIncomingCallScreen]: a locked patient who
    // taps the notification's Accept action must not reach the live call.
    final lockStatus = await _resolveActiveFeatureLock();
    if (lockStatus != null) {
      await _routeLockedPatientToRoomChat(lockStatus);
      return false;
    }

    if (!await _waitForAppReady()) return false;

    final navigator = await _waitForNavigator();
    if (navigator == null) return false;

    // Filled in from Firestore so a notification action never navigates with
    // the half-populated push payload.
    final enriched =
        await IncomingCallCoordinator.instance.enrichFromFirestore(payload) ??
        payload;

    final currentUserName =
        await IncomingCallCoordinator.instance.resolveCurrentUserName();

    IncomingCallCoordinator.instance.markScreenOpened(enriched.callId);

    // If IncomingCallScreen is currently open on navigator, replace it; otherwise push
    if (IncomingCallScreen.isIncomingCallScreenOpen && navigator.canPop()) {
      navigator.pushReplacement(
        MaterialPageRoute(
          settings: const RouteSettings(name: '/active_call_screen'),
          builder: (_) => ActiveCallScreen(
            callId: enriched.callId,
            roomId: enriched.channelId,
            otherUserId: enriched.callerId,
            otherUserName: enriched.callerName,
            otherUserRole: enriched.callerType,
            otherUserImage: enriched.callerImage,
            currentUserId: currentUserId,
            currentUserName: currentUserName,
            isCaller: false,
          ),
        ),
      );
    } else {
      navigator.push(
        MaterialPageRoute(
          settings: const RouteSettings(name: '/active_call_screen'),
          builder: (_) => ActiveCallScreen(
            callId: enriched.callId,
            roomId: enriched.channelId,
            otherUserId: enriched.callerId,
            otherUserName: enriched.callerName,
            otherUserRole: enriched.callerType,
            otherUserImage: enriched.callerImage,
            currentUserId: currentUserId,
            currentUserName: currentUserName,
            isCaller: false,
          ),
        ),
      );
    }
    debugPrint(
      '📞 ActiveCallScreen opened from notification accept callId=${enriched.callId}',
    );
    return true;
  }

  // ─────────────────────────────────────────────────────────────
  // NOTIFICATION TAPS
  //
  // Both the Accept and the Decline action button, and the body tap, are
  // handled here and nowhere else. They all call the same
  // [IncomingCallCoordinator] entry points that the Incoming Call screen's
  // own buttons call, so there is exactly one accept implementation and one
  // decline implementation in the app.
  // ─────────────────────────────────────────────────────────────

  void _onNotificationTap(NotificationResponse response) {
    debugPrint(
      '🔔 Notification tapped | actionId: ${response.actionId} | '
      'isolate: ${Isolate.current.debugName ?? 'main'}',
    );

    if (response.payload == null) return;

    final data = _parsePayload(response.payload!);
    final actionId = response.actionId;

    // Password reset actions
    if (actionId == 'confirm_reset') {
      _handleConfirmPasswordReset(data);
      return;
    }
    if (actionId == 'decline_reset') {
      _handleDeclinePasswordReset(data);
      return;
    }

    final isCallPayload =
        data['type'] == FcmMessageType.call || data.containsKey('callId');

    if (!isCallPayload) {
      if (data['type'] == 'password_reset') {
        // Body tap only opens the app. Confirming a password reset is a
        // sensitive action and must come from the explicit Confirm button —
        // never from tapping the notification body.
        debugPrint(
          '🔓 Password reset notification body tapped — no action taken',
        );
      } else {
        _handleMessageNavigationFromPayload(data);
      }
      return;
    }

    final payload = IncomingCallPayload.tryParse(data);
    if (payload == null) {
      debugPrint('⚠️ Call notification without callId — ignoring tap');
      return;
    }

    // A tap is a user gesture, not a delivery, so it is not claim-gated: a
    // user must always be able to open a call they are being ringed for.
    if (actionId == CallActionIds.accept) {
      unawaited(_acceptFromNotification(payload));
      return;
    }
    if (actionId == CallActionIds.decline) {
      unawaited(_declineFromNotification(payload));
      return;
    }

    // Body tap: open the app's own Incoming Call screen. No accept/decline is
    // implied — the user still has to choose.
    unawaited(_openCallFromNotificationTap(payload));
  }

  /// A tray tap is still an untrusted payload until the coordinator confirms
  /// it belongs to the signed-in user and the call is still ringing.
  Future<void> _openCallFromNotificationTap(IncomingCallPayload payload) async {
    final validated = await IncomingCallCoordinator.instance
        .registerIncomingCall(
          payload.toMap(),
          origin: IncomingCallOrigin.notificationTap,
        );
    if (validated == null) {
      await _cancelCallNotification(payload.callId);
      return;
    }
    await IncomingCallCoordinator.instance.openIncomingCallScreen(validated);
  }

  /// Accept pressed on the notification.
  ///
  /// The coordinator owns the transition, so this is the *same* accept the
  /// Incoming Call screen's button performs. A second press — a duplicate
  /// PendingIntent delivery, a stale notification, or the background isolate
  /// having already applied the transition — is dropped there.
  Future<void> _acceptFromNotification(IncomingCallPayload payload) async {
    debugPrint('📞 Accept pressed on notification callId=${payload.callId}');
    // The notification goes first: the coordinator dismisses it as part of the
    // transition, and doing it up-front means the tray is never stale if the
    // navigation below is slow.
    await _cancelCallNotification(payload.callId);
    final validated = await IncomingCallCoordinator.instance
        .registerIncomingCall(
          payload.toMap(),
          origin: IncomingCallOrigin.notificationTap,
        );
    if (validated == null) {
      debugPrint(
        '⚠️ Notification accept ignored for ${payload.callId} '
        '(not for this user, expired, or no longer ringing)',
      );
      return;
    }
    final opened = await IncomingCallCoordinator.instance
        .acceptAndOpenCallScreen(validated);
    if (!opened) {
      debugPrint(
        '⚠️ Notification accept did not open the call screen for '
        '${payload.callId} (already handled or no longer ringing)',
      );
    }
  }

  /// Decline pressed on the notification. No navigation: the caller simply
  /// sees the call turn to "rejected".
  Future<void> _declineFromNotification(IncomingCallPayload payload) async {
    debugPrint('📞 Decline pressed on notification callId=${payload.callId}');
    await _cancelCallNotification(payload.callId);
    await CallRingtoneService.instance.stopRingtone();
    await SystemRingtonePlayer.stopDefaultRingtone();
    final validated = await IncomingCallCoordinator.instance
        .registerIncomingCall(
          payload.toMap(),
          origin: IncomingCallOrigin.notificationTap,
        );
    if (validated == null) {
      debugPrint(
        '⚠️ Notification decline ignored for ${payload.callId} '
        '(not for this user, expired, or no longer ringing)',
      );
      return;
    }
    final handled = await IncomingCallCoordinator.instance
        .declineFromNotification(validated);
    if (!handled) {
      debugPrint(
        '⚠️ Notification decline ignored for ${payload.callId} '
        '(already handled or no longer ringing)',
      );
    }
  }

  @pragma('vm:entry-point')
  static void _onBackgroundNotificationTap(NotificationResponse response) {
    // This runs in a *separate* background isolate spawned by
    // flutter_local_notifications — NOT the main isolate. Storing the intent
    // in a static field here (as this method used to) was invisible to
    // `checkPendingCallAction()`, which runs in the main isolate, so an
    // Accept/Decline pressed while the app was in the background was silently
    // dropped. The intent is therefore persisted, where both isolates can see
    // it, and the transition is applied immediately from this isolate.
    final raw = response.payload;
    if (raw == null) return;

    Map<String, dynamic> data;
    try {
      data = jsonDecode(raw) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('Error parsing background payload: $e');
      return;
    }

    final String action;
    switch (response.actionId) {
      case 'confirm_reset':
        action = 'confirm_reset';
        break;
      case 'decline_reset':
        action = 'decline_reset';
        break;
      case CallActionIds.accept:
        action = CallActionIds.accept;
        break;
      case CallActionIds.decline:
        action = CallActionIds.decline;
        break;
      default:
        action = CallActionIds.open;
    }

    // Durable copy. A static field lives in *this* isolate only, so it is
    // invisible to the main isolate — the exact reason an Accept/Decline
    // pressed from the tray used to be lost. The main isolate drains this key
    // on start-up, and the coordinator's cross-isolate claim makes the replay
    // a no-op when the transition below already succeeded.
    unawaited(_persistPendingNotificationAction(data, action));

    // Apply the call transition from this isolate so it works even if the
    // process is never brought back to the foreground. `accept`/`decline` are
    // idempotent across isolates (SharedPreferences-backed claims), so if the
    // app *does* come up and replay this action, the second attempt is a
    // no-op instead of a duplicate accept.
    if (action != CallActionIds.accept && action != CallActionIds.decline) {
      return;
    }

    unawaited(
      _runIncomingCallActionFromBackground(
        data: data,
        isAccept: action == CallActionIds.accept,
      ),
    );
  }

  /// Writes the tapped action where the main isolate can find it.
  static Future<void> _persistPendingNotificationAction(
    Map<String, dynamic> data,
    String action,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kPendingNotificationAction,
        jsonEncode(<String, dynamic>{'action': action, 'data': data}),
      );
    } catch (e) {
      debugPrint('Could not persist the pending notification action: $e');
    }
  }

  /// Consumes and applies a notification action recorded by the background
  /// isolate.
  ///
  /// For Accept this is what actually opens the Call screen: the headless
  /// isolate can flip the Firestore status to `accepted` but has no navigator.
  /// For Decline the transition is already applied and the coordinator reports
  /// it as a duplicate, so this is a cheap no-op.
  Future<void> _drainPendingNotificationAction() async {
    Map<String, dynamic>? record;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kPendingNotificationAction);
      if (raw == null || raw.isEmpty) return;
      // Remove first: a crash mid-handling must not replay the action.
      await prefs.remove(_kPendingNotificationAction);
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) record = decoded;
    } catch (e) {
      debugPrint('Could not read the pending notification action: $e');
      return;
    }
    if (record == null) return;

    final action = (record['action'] ?? '').toString();
    final data = record['data'];
    if (data is! Map<String, dynamic>) return;

    switch (action) {
      case 'confirm_reset':
        _handleConfirmPasswordReset(data);
        break;
      case 'decline_reset':
        _handleDeclinePasswordReset(data);
        break;
      case CallActionIds.accept:
        final payload = IncomingCallPayload.tryParse(data);
        if (payload != null) {
          await _acceptFromNotification(payload);
        }
        break;
      case CallActionIds.decline:
        final payload = IncomingCallPayload.tryParse(data);
        if (payload != null) {
          await _declineFromNotification(payload);
        }
        break;
      case CallActionIds.open:
        final payload = IncomingCallPayload.tryParse(data);
        if (payload != null) {
          await IncomingCallCoordinator.instance.openIncomingCallScreen(
            payload,
          );
        }
        break;
    }
  }

  /// Background-isolate half of a notification Accept/Decline.
  static Future<void> _runIncomingCallActionFromBackground({
    required Map<String, dynamic> data,
    required bool isAccept,
  }) async {
    try {
      // Firebase must be up before Firestore is touched, and the local
      // notification plugin before we try to dismiss the notification.
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
      await NotificationService().initializeForBackground();
    } catch (e) {
      debugPrint('Background isolate init for call action failed: $e');
    }

    final payload = IncomingCallPayload.tryParse(data);
    if (payload == null) {
      debugPrint('⚠️ Background call action without callId — ignored');
      return;
    }

    final service = NotificationService();
    await service._cancelCallNotification(payload.callId);
    await CallRingtoneService.instance.stopRingtone();
    await SystemRingtonePlayer.stopDefaultRingtone();

    if (isAccept) {
      // The transition is what matters here. Opening the Call screen needs a
      // navigator, which does not exist in this isolate; when the Accept button
      // brings the app up (it sets showsUserInterface), the main isolate
      // re-reads the call status and routes to the live screen.
      final outcome = await IncomingCallCoordinator.instance.accept(
        payload.callId,
      );
      debugPrint(
        '📞 Background accept callId=${payload.callId} handled=${outcome.handled}'
        '${outcome.handled ? '' : ' (${outcome.reason})'}',
      );
      return;
    }

    final outcome = await IncomingCallCoordinator.instance.decline(
      payload.callId,
    );
    debugPrint(
      '📞 Background decline callId=${payload.callId} handled=${outcome.handled}'
      '${outcome.handled ? '' : ' (${outcome.reason})'}',
    );
  }

  // ─────────────────────────────────────────────────────────────
  // CHAT NOTIFICATION
  // ─────────────────────────────────────────────────────────────

  /// Longest text preview shown for a chat message.
  static const int _chatPreviewMaxChars = 120;

  /// User-visible preview for a chat notification.
  ///
  /// Standardized chat preview: media
  /// messages get a fixed label instead of a raw URL/filename, and text is
  /// collapsed and bounded. The background system notification already carries
  /// this body; without the same rule here a foreground or data-only delivery
  /// showed "https://…" for a photo or the file name for a document.
  String _chatNotificationPreview(Map<String, dynamic> data) {
    final type = (data['messageType'] ?? data['message_type'] ?? '')
        .toString()
        .toLowerCase();
    final raw = (data['messageText'] ?? data['message'] ?? data['body'] ?? '')
        .toString()
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    switch (type) {
      case 'image':
      case 'photo':
        return '📷 Sent an image';
      case 'audio':
      case 'voice':
        return '🎤 Sent a voice message';
      case 'video':
        return '🎥 Sent a video';
      case 'call_recording':
        return '🎙️ Sent a call recording';
      case 'document':
        if (raw.isEmpty) return '📄 Sent a document';
        return raw.startsWith('📄') ? raw : '📄 $raw';
      default:
        if (raw.isEmpty) return 'Sent an attachment';
        if (raw.length <= _chatPreviewMaxChars) return raw;
        return '${raw.substring(0, _chatPreviewMaxChars - 1)}…';
    }
  }

  Future<void> showWhatsAppStyleChatNotification(
    Map<String, dynamic> data,
  ) async {
    final chatId =
        (data['chatId'] ??
                data['chat_id'] ??
                data['senderId'] ??
                'general_chat')
            .toString();
    final messageId = (data['messageId'] ?? data['message_id'])?.toString();

    // 1. Deduplication using SharedPreferences (Cross-Isolate safe).
    //
    // The burn happens AFTER a successful `show` below. Burning it up front
    // meant that a display failure (plugin error, channel missing) permanently
    // consumed the messageId, so a redelivered push could never show it again
    // — the message arrived but the user never saw a notification.
    if (messageId != null && messageId.isNotEmpty) {
      final prefs = await SharedPreferences.getInstance();
      final shownMessages = prefs.getStringList('shown_chat_messages') ?? [];
      if (shownMessages.contains(messageId)) {
        debugPrint('Duplicate message notification suppressed: $messageId');
        return;
      }
    }

    // 2. Foreground suppression (if user is in this exact chat)
    if (activeChatId != null &&
        (activeChatId == chatId ||
            activeChatId == data['chatId']?.toString() ||
            activeChatId == data['chat_id']?.toString())) {
      debugPrint(
        'Suppressed notification because user is in active chat: $activeChatId',
      );
      return;
    }

    final senderName = data['senderName'] ?? data['title'] ?? 'New Message';
    final messageText = _chatNotificationPreview(data);
    final profileImage = data['senderProfileImage'] ?? '';
    final senderId = data['senderId'] ?? 'unknown_sender';

    AndroidBitmap<Object>? largeIcon;
    final prefs = await SharedPreferences.getInstance();

    // 3. Download sender profile image for Android large icon.
    //
    // Hard timeout: `http.get` has none of its own, and a stalled avatar URL
    // (unreachable CDN, blackholed network) used to hang this whole async
    // chain — the FCM message had been received but the notification was
    // shown minutes later or never. The notification must never depend on a
    // decorative image download.
    if (profileImage.isNotEmpty && profileImage.startsWith('http')) {
      try {
        final dir = await getTemporaryDirectory();
        final fileName = 'avatar_${senderId}_${profileImage.hashCode}.png';
        final file = File('${dir.path}/$fileName');

        if (!await file.exists()) {
          final response = await http
              .get(Uri.parse(profileImage))
              .timeout(const Duration(seconds: 3));
          if (response.statusCode == 200) {
            await file.writeAsBytes(response.bodyBytes);
          }
        }

        if (await file.exists()) {
          largeIcon = FilePathAndroidBitmap(file.path);
        }
      } catch (e) {
        debugPrint('Error downloading profile image for notification: $e');
      }
    }

    // 4. Message Grouping via SharedPreferences (MessagingStyle)
    final historyKey = 'chat_history_$chatId';
    final historyJson = prefs.getString(historyKey) ?? '[]';
    List<dynamic> history = [];
    try {
      history = jsonDecode(historyJson) as List<dynamic>;
    } catch (_) {}

    history.add({
      'text': messageText,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'senderName': senderName,
    });

    if (history.length > 7) {
      history.removeRange(0, history.length - 7);
    }
    await prefs.setString(historyKey, jsonEncode(history));

    final person = Person(name: senderName);

    final messages = history.map((msg) {
      // Cached history rows are untyped JSON — a media-only message or a
      // row written by an older build must not throw inside the notification
      // path.
      final dynamic raw = msg is Map ? msg['text'] : null;
      final dynamic rawTs = msg is Map ? msg['timestamp'] : null;
      return Message(
        raw?.toString() ?? '',
        rawTs is int
            ? DateTime.fromMillisecondsSinceEpoch(rawTs)
            : DateTime.now(),
        person,
      );
    }).toList();

    final messagingStyle = MessagingStyleInformation(
      const Person(name: 'Me'),
      conversationTitle: null,
      groupConversation: false,
      messages: messages,
    );

    await _localNotifications.show(
      id:
          chatId.hashCode &
          0x7FFFFFFF, // Use chatId to group natively and update the same notification bubble
      title: senderName,
      body: messageText,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          chatChannelId,
          'Chat Messages',
          channelDescription: 'Notifications for incoming chat messages',
          importance: Importance.max,
          priority: Priority.max,
          category: AndroidNotificationCategory.message,
          icon: '@drawable/ic_notification',
          styleInformation: messagingStyle,
          largeIcon: largeIcon,
          playSound: true,
          enableVibration: true,
          tag: 'chat_$chatId',
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: jsonEncode(data),
    );

    // Burn the messageId only now that the notification actually went up, so
    // a failed `show` above can be retried by a redelivered push.
    if (messageId != null) {
      final shownMessages = prefs.getStringList('shown_chat_messages') ?? [];
      if (!shownMessages.contains(messageId)) {
        shownMessages.add(messageId);
        if (shownMessages.length > 50) {
          shownMessages.removeRange(0, shownMessages.length - 50);
        }
        await prefs.setStringList('shown_chat_messages', shownMessages);
      }
    }

    debugPrint(
      'CHAT_NOTIFICATION_DISPLAYED chatId=$chatId messageId=$messageId '
      'senderName=$senderName',
    );
  }

  // ─────────────────────────────────────────────────────────────
  // PAYMENT NOTIFICATIONS (submitted / approved / rejected)
  // ─────────────────────────────────────────────────────────────

  void _showPaymentLocalNotification(Map<String, dynamic> data) {
    final type = data['type'] as String?;
    final key = _paymentNotificationKey(data);

    // Suppress repeat deliveries of the same payment event.
    if (key.isNotEmpty && !_displayedPaymentNotificationIds.add(key)) {
      debugPrint('⚠️ Duplicate payment notification suppressed: $key');
      return;
    }

    final String title;
    final String body;

    switch (type) {
      case FcmMessageType.paymentApproved:
        title = 'Payment Approved';
        body = 'Your payment has been approved. You can now access the app.';
        break;
      case FcmMessageType.paymentRejected:
        title = 'Payment Rejected';
        body =
            'Your payment has been rejected. '
            'Please check your payment and submit again.';
        break;
      default:
        // payment_submitted (and legacy payment_proof): the title is the
        // patient's name so the admin recognises who submitted.
        final patientName = (data['patientName'] ?? '').toString();
        title = patientName.isEmpty ? 'New Payment Proof' : patientName;
        body = 'Payment proof submitted';
    }

    // Derive the local id from notificationId/paymentId so a redelivery
    // *replaces* the existing notification instead of stacking a second
    // identical one in the tray.
    final int id = key.isEmpty
        ? (DateTime.now().millisecondsSinceEpoch.hashCode & 0x7FFFFFFF)
        : (key.hashCode.abs() % 100000) + 1000;

    debugPrint('💳 Payment notification shown | type=$type key=$key id=$id');

    _localNotifications.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          generalChannelId,
          'General',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: jsonEncode(data),
    );
  }

  // ─────────────────────────────────────────────────────────────
  // APPOINTMENT NOTIFICATIONS
  // ─────────────────────────────────────────────────────────────

  void _showAppointmentLocalNotification(Map<String, dynamic> data) {
    final type = data['type'] as String?;
    final key = _appointmentNotificationKey(data);

    // Suppress repeat deliveries of the same appointment event.
    if (key.isNotEmpty && !_displayedAppointmentNotificationIds.add(key)) {
      debugPrint('⚠️ Duplicate appointment notification suppressed: $key');
      return;
    }

    final doctorName = (data['doctorName'] ?? '').toString();
    final patientName = (data['patientName'] ?? '').toString();

    final String title;
    final String body;

    switch (type) {
      case FcmMessageType.appointmentPaymentApproved:
        title = 'Payment Approved';
        body =
            'Your appointment payment with Dr. $doctorName has been approved.';
        break;
      case FcmMessageType.appointmentPaymentRejected:
        title = 'Payment Rejected';
        body = 'Your appointment payment with Dr. $doctorName was rejected.';
        break;
      case FcmMessageType.newAppointmentRequest:
        title = 'New Appointment Request';
        body = '$patientName sent you an appointment request.';
        break;
      case FcmMessageType.appointmentConfirmed:
        title = 'Appointment Confirmed';
        body =
            'Dr. $doctorName confirmed your appointment for '
            '${data['date'] ?? ''} at ${data['time'] ?? ''}.';
        break;
      case FcmMessageType.appointmentStart:
        // The sender already baked this recipient's copy into the payload, so
        // the foreground banner reads exactly like the OS-rendered one the
        // app is not running to draw.
        final sentTitle = (data[AppointmentPayloadKeys.title] ?? '').toString();
        final sentBody = (data[AppointmentPayloadKeys.body] ?? '').toString();
        title = sentTitle.isEmpty
            ? AppointmentDefaults.appointmentStartTitle
            : sentTitle;
        body = sentBody.isEmpty
            ? AppointmentDefaults.appointmentStartBody(
                doctorName.isNotEmpty ? 'Dr. $doctorName' : patientName,
              )
            : sentBody;
        break;
      default:
        {
          // The lifecycle pushes (reminder, joined, late, grace ending,
          // cancelled, no-show, booking paused) all carry this recipient's
          // copy in the payload — same contract as appointment_start above, so
          // the foreground banner reads exactly like the OS-rendered one.
          final sentTitle = (data[AppointmentPayloadKeys.title] ?? '')
              .toString();
          final sentBody = (data[AppointmentPayloadKeys.body] ?? '').toString();
          if (sentTitle.isNotEmpty || sentBody.isNotEmpty) {
            title = sentTitle.isEmpty ? 'Appointment Update' : sentTitle;
            body = sentBody;
            break;
          }
          if (type == FcmMessageType.appointmentPaymentSubmitted) {
            // appointment_payment_submitted → admin, with no baked copy.
            title = 'Appointment Payment Submitted';
            body =
                '$patientName submitted payment for an appointment with '
                'Dr. $doctorName.';
            break;
          }
          title = 'Appointment Update';
          body = doctorName.isNotEmpty
              ? 'Dr. $doctorName updated your appointment.'
              : '$patientName updated the appointment.';
        }
    }

    final int id = key.isEmpty
        ? (DateTime.now().millisecondsSinceEpoch.hashCode & 0x7FFFFFFF)
        : (key.hashCode.abs() % 100000) + 5000;

    debugPrint(
      '📅 Appointment notification shown | type=$type key=$key id=$id',
    );

    _localNotifications.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          generalChannelId,
          'General',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: jsonEncode(data),
    );
  }

  // ─────────────────────────────────────────────────────────────
  // REPORT SHARED NOTIFICATION
  // ─────────────────────────────────────────────────────────────

  void _showReportSharedLocalNotification(Map<String, dynamic> data) {
    final patientName = data['patientName'] ?? 'A patient';
    final reportName = data['reportName'] ?? 'medical report';

    _localNotifications.show(
      id: DateTime.now().millisecondsSinceEpoch.hashCode & 0x7FFFFFFF,
      title: patientName,
      body:
          'A patient has shared a medical report with you. '
          '($reportName)',
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          generalChannelId,
          'General',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: jsonEncode(data),
    );
  }

  // ─────────────────────────────────────────────────────────────
  // PASSWORD RESET
  // ─────────────────────────────────────────────────────────────

  void showPasswordResetOtpLocalNotification(RemoteMessage message) {
    final title = message.notification?.title ?? 'OPD Security Code';
    final body =
        message.notification?.body ??
        (message.data['otp'] != null
            ? 'Your password reset verification code is ${message.data['otp']}.'
            : 'Your password reset verification code has arrived.');

    _localNotifications.show(
      id: DateTime.now().millisecondsSinceEpoch.hashCode & 0x7FFFFFFF,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          passwordResetChannelId,
          'Password Reset',
          channelDescription: 'Password reset notifications',
          importance: Importance.max,
          priority: Priority.high,
          visibility: NotificationVisibility.private,
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: jsonEncode(message.data),
    );
  }

  Future<void> showPasswordResetOtpNotificationDirect({
    required String otp,
    String? title,
    String? body,
  }) async {
    final notificationTitle = title ?? 'OPD Security Code';
    final notificationBody =
        body ??
        'Your password reset verification code is $otp. It expires in 5 minutes.';

    await _localNotifications.show(
      id: DateTime.now().millisecondsSinceEpoch.hashCode & 0x7FFFFFFF,
      title: notificationTitle,
      body: notificationBody,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          passwordResetChannelId,
          'Password Reset',
          channelDescription: 'Password reset notifications',
          importance: Importance.max,
          priority: Priority.high,
          visibility: NotificationVisibility.private,
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: jsonEncode({'type': 'password_reset_otp', 'otp': otp}),
    );
  }

  void _showPasswordResetLocalNotification(Map<String, dynamic> data) async {
    final payloadData = {
      'type': 'password_reset',
      'userId': data['userId'],
      'resetToken': data['resetToken'],
      'phoneNumber': data['phoneNumber'],
    };

    await _localNotifications.show(
      id: DateTime.now().millisecondsSinceEpoch.hashCode & 0x7FFFFFFF,
      title: 'Password Reset Request',
      body: 'Do you want to reset your password for your account?',
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          passwordResetChannelId,
          'Password Reset',
          channelDescription: 'Password reset notifications',
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.message,
          actions: const <AndroidNotificationAction>[
            AndroidNotificationAction(
              'confirm_reset',
              'Confirm Reset',
              showsUserInterface: true,
            ),
            AndroidNotificationAction(
              'decline_reset',
              'Decline',
              showsUserInterface: true,
            ),
          ],
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
          interruptionLevel: InterruptionLevel.critical,
          categoryIdentifier: 'password_reset_category',
        ),
      ),
      payload: jsonEncode(payloadData),
    );
  }

  // ─────────────────────────────────────────────────────────────
  // PASSWORD RESET HANDLERS
  // ─────────────────────────────────────────────────────────────

  void _handleConfirmPasswordReset(Map<String, dynamic> data) async {
    final userId = data['userId'] ?? '';
    final resetToken = data['resetToken'] ?? '';
    final phoneNumber = data['phoneNumber'] ?? '';

    final patientController = PatientController();
    final confirmed = await patientController.confirmPasswordReset(
      userId,
      resetToken,
    );

    if (!confirmed) return;

    // Re-resolve the navigator AFTER the await: the app may have been
    // backgrounded/disposed while the network call ran.
    final navigator = navigatorKey.currentState;
    if (navigator == null) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      ToastService.instance.showSuccess(
        'Password reset confirmed successfully.',
      );
    });
  }

  void _handleDeclinePasswordReset(Map<String, dynamic> data) async {
    final userId = data['userId'] ?? '';
    final resetToken = data['resetToken'] ?? '';
    final phoneNumber = data['phoneNumber'] ?? '';

    try {
      final patientController = PatientController();
      final declined = await patientController.declinePasswordReset(
        userId,
        resetToken,
      );
      if (!declined) return;

      // Re-resolve the navigator AFTER the await (see confirm handler).
      final navigator = navigatorKey.currentState;
      if (navigator == null) return;

      WidgetsBinding.instance.addPostFrameCallback((_) {
        ToastService.instance.showInfo('Password reset request was declined.');
      });
    } catch (e) {
      debugPrint('Error declining reset: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────
  // NAVIGATION HELPERS
  // ─────────────────────────────────────────────────────────────

  void _handleMessageNavigation(RemoteMessage message) {
    _handleMessageNavigationFromPayload(message.data);
  }

  void _handleMessageNavigationFromPayload(Map<String, dynamic> data) {
    final type = (data['type'] as String?) ?? '';
    if (type == 'call' || data.containsKey('callId')) {
      // A push that was *opened* rather than delivered (notification tap,
      // `onMessageOpenedApp`, cold start) lands here. It goes through the same
      // coordinator path as a delivery, so it cannot push a second Incoming
      // Call screen.
      final payload = IncomingCallPayload.tryParse(data);
      if (payload == null) {
        debugPrint('⚠️ Call payload without callId — ignoring navigation');
        return;
      }
      unawaited(_openCallFromNotificationTap(payload));
    } else if (FcmMessageType.isPayment(data['type'] as String?)) {
      // Payment and appointment payloads carry a `chatId` too, so they MUST
      // be matched before the chat branch — otherwise every appointment tap
      // fell into `_navigateToChat` with an empty senderId and opened a
      // broken ChatScreen.
      _handlePaymentNotificationTap(data);
    } else if (FcmMessageType.isAppointment(data['type'] as String?)) {
      _handleAppointmentNotificationTap(data);
    } else if (type == 'report_shared') {
      unawaited(_navigateToDoctorSharedReports());
    } else if (type == 'chat_message' ||
        type == 'chat' ||
        (data['chatId'] != null &&
            data['chatId'].toString().isNotEmpty &&
            data['senderId'] != null &&
            data['senderId'].toString().isNotEmpty)) {
      final messageId = (data['messageId'] ?? data['message_id'] ?? '')
          .toString();
      if (messageId.isNotEmpty &&
          !_navigatedChatNotificationIds.add(messageId)) {
        debugPrint(
          '🔁 Chat notification $messageId already handled — ignoring',
        );
        return;
      }
      if (_navigatedChatNotificationIds.length > 100) {
        _navigatedChatNotificationIds.remove(
          _navigatedChatNotificationIds.first,
        );
      }
      debugPrint(
        'CHAT_NOTIFICATION_TAPPED chatId=${data['chatId']} '
        'senderId=${data['senderId']} senderName=${data['senderName']}',
      );
      _navigateToChat(
        senderId: data['senderId'] ?? '',
        senderName: data['senderName'] ?? 'User',
        otherUserImage:
            data['senderProfileImage'] ?? data['otherUserImage'] ?? '',
        chatId: data['chatId'],
      );
    }
  }

  // ─────────────────────────────────────────────────────────────
  // PAYMENT NOTIFICATION TAP FLOW
  //
  //   payment_submitted / payment_proof → admin → AdminPaymentScreen
  //                                            (focused on the patient)
  //   payment_approved                 → patient → Room Chat, unlocked
  //   payment_rejected                 → patient → Payment / Pending screen
  //                                            (still restricted)
  //
  // Every entry point (foreground tap, onMessageOpenedApp, getInitialMessage)
  // funnels through [_handlePaymentNotificationTap] so the once-only rule and
  // the navigation guard can never be bypassed.
  // ─────────────────────────────────────────────────────────────

  Future<void> _handlePaymentNotificationTap(Map<String, dynamic> data) async {
    final type = data['type'] as String?;
    final key = _paymentNotificationKey(data);

    // "Processed only once": a notificationId/paymentId may drive a single
    // navigation, no matter how many deliveries or taps it produces.
    if (key.isNotEmpty && !_navigatedPaymentNotificationIds.add(key)) {
      debugPrint('🔁 Payment notification $key already handled — ignoring');
      return;
    }

    final patientId = (data['patientId'] ?? '').toString();
    final paymentId = (data['paymentId'] ?? '').toString();

    if (type == FcmMessageType.complaintReply) {
      debugPrint('📬 Patient complaint reply notification tapped');
      await _navigateToPatientComplaintReply();
      return;
    }

    if (type == FcmMessageType.paymentComplaint) {
      final complaintId = (data['complaintId'] ?? '').toString();
      debugPrint(
        '💳 Admin payment complaint notification tapped complaintId=$complaintId',
      );
      await _navigateToAdminComplaint(complaintId: complaintId);
      return;
    }

    if (type == FcmMessageType.paymentSubmitted ||
        type == FcmMessageType.paymentProof ||
        type == FcmMessageType.paymentProofSubmitted) {
      final isAppt =
          (data['paymentType'] ?? '').toString() == 'appointment_booking';
      debugPrint(
        '💳 Admin payment notification tapped patientId=$patientId isAppt=$isAppt',
      );
      await _navigateToAdminPayment(
        patientId: patientId,
        paymentId: paymentId,
        isAppointment: isAppt,
      );
      return;
    }

    final approved = type == FcmMessageType.paymentApproved;
    debugPrint(
      '💳 Patient payment notification tapped approved=$approved '
      'patientId=$patientId',
    );
    await _navigateToPatientPaymentStatus(
      approved: approved,
      patientId: patientId,
    );
  }

  // ─────────────────────────────────────────────────────────────
  // APPOINTMENT NOTIFICATION TAP FLOW
  //
  //   appointment_payment_submitted → admin   → AdminPaymentScreen,
  //                                             opened on the appointment tab
  //   appointment_payment_approved  → patient → Appointments tab
  //   appointment_payment_rejected  → patient → Appointments tab
  //   appointment_confirmed         → patient → Appointments tab
  //   new_appointment_request       → doctor  → Doctor Appointments tab
  //   appointment_start             → both    → that appointment's Room Chat
  //                                             conversation, directly
  //   appointment_reminder / _joined / _late / _grace_ending
  //                               → both    → the same conversation (the copy
  //                                             promises "Tap to open the chat")
  //   appointment_cancelled / _no_show / booking_frozen
  //                               → both    → Appointments tab
  //
  // Like the payment flow, every entry point funnels through one handler so
  // the once-only rule and the role check can never be bypassed.
  // ─────────────────────────────────────────────────────────────

  Future<void> _handleAppointmentNotificationTap(
    Map<String, dynamic> data,
  ) async {
    final type = data['type'] as String?;
    final key = _appointmentNotificationKey(data);

    if (key.isNotEmpty && !_navigatedAppointmentNotificationIds.add(key)) {
      debugPrint('🔁 Appointment notification $key already handled — ignoring');
      return;
    }

    if (type == FcmMessageType.appointmentPaymentSubmitted) {
      await _navigateToAdminAppointmentPayment(
        patientId: (data['patientId'] ?? '').toString(),
      );
      return;
    }

    if (type == FcmMessageType.appointmentStart) {
      await _openAppointmentChat(data);
      return;
    }

    // The lifecycle notices all promise "Tap to open the chat" — the
    // reminder, the counterpart-joined ping and the late / grace warnings
    // land in the conversation, as soon as the payload can name both sides
    // (a freeze push, sent to admins too, cannot and must not).
    final opensChat =
        type == FcmMessageType.appointmentReminder ||
        type == FcmMessageType.appointmentJoined ||
        type == FcmMessageType.appointmentDoctorLate ||
        type == FcmMessageType.appointmentPatientLate ||
        type == FcmMessageType.appointmentGraceEnding;
    if (opensChat) {
      final patientId = (data[AppointmentPayloadKeys.patientId] ?? '')
          .toString();
      final doctorId = (data[AppointmentPayloadKeys.doctorId] ?? '').toString();
      if (patientId.isNotEmpty && doctorId.isNotEmpty) {
        await _openAppointmentChat(data);
        return;
      }
    }

    // Cancelled / no-show / booking paused, and every older type: the
    // appointments tab, whichever portal is signed in.
    final role = await _currentSessionRole();
    if (role == UserRoles.doctor) {
      await _navigateToDoctorAppointments();
    } else if (role == UserRoles.admin) {
      // Admins also receive lifecycle notices (no_show, booking_frozen) as
      // FYI — they must never be dumped into the patient portal.
      debugPrint('ℹ️ Admin appointment notice — no navigation applied');
    } else {
      await _navigateToPatientAppointments();
    }
  }

  /// Opens the exact Room Chat conversation the appointment lives in.
  ///
  /// The payload carries both participants and the `chatId` computed from
  /// them, so the tap lands the user straight in the conversation instead of
  /// asking them to find it in the Room Chat list — and it works even when the
  /// conversation was never opened before, because the id is derived rather
  /// than stored.
  Future<void> _openAppointmentChat(Map<String, dynamic> data) async {
    final patientId = (data[AppointmentPayloadKeys.patientId] ?? '').toString();
    final doctorId = (data[AppointmentPayloadKeys.doctorId] ?? '').toString();
    final chatId = (data[AppointmentPayloadKeys.chatId] ?? '').toString();

    if (patientId.isEmpty || doctorId.isEmpty) {
      debugPrint('⚠️ appointment_start without both participants — ignoring');
      return;
    }

    final isDoctor = (await _currentSessionRole()) == UserRoles.doctor;
    final otherUserName = isDoctor
        ? (data[AppointmentPayloadKeys.patientName] ?? '').toString()
        : (data[AppointmentPayloadKeys.doctorName] ?? '').toString();
    final otherUserImage = isDoctor
        ? (data[AppointmentPayloadKeys.patientImage] ?? '').toString()
        : (data[AppointmentPayloadKeys.doctorImage] ?? '').toString();

    debugPrint(
      '📅 appointment_start tapped → chatId=$chatId '
      'role=${isDoctor ? 'doctor' : 'patient'}',
    );

    // `_navigateToChat` is fire-and-forget (`void ... async`): it waits for
    // the app and the navigator itself, so nothing upstream may await it.
    _navigateToChat(
      senderId: isDoctor ? patientId : doctorId,
      senderName: otherUserName.isEmpty
          ? (isDoctor ? 'Patient' : 'Doctor')
          : otherUserName,
      otherUserImage: otherUserImage,
      chatId: chatId.isEmpty ? null : chatId,
    );
  }

  Future<void> _navigateToAdminAppointmentPayment({
    required String patientId,
  }) async {
    final role = await _currentSessionRole();
    if (role != UserRoles.admin) {
      debugPrint('🚫 Ignoring appointment payment notification — role=$role');
      return;
    }

    if (!await _waitForAppReady()) return;
    final navigator = await _waitForNavigator();
    if (navigator == null || !navigator.mounted) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (AdminPaymentScreen.isAdminPaymentScreenOpen) {
        debugPrint('⚠️ AdminPaymentScreen already open — not pushing again');
        return;
      }
      AdminPaymentScreen.isAdminPaymentScreenOpen = true;
      navigator.push(
        MaterialPageRoute(
          settings: const RouteSettings(name: '/admin_payment'),
          builder: (_) => AdminPaymentScreen(
            focusPatientId: patientId,
            initialSegment: AdminPaymentSegment.appointment,
          ),
        ),
      );
    });
  }

  Future<void> _navigateToAdminComplaint({required String complaintId}) async {
    final role = await _currentSessionRole();
    if (role != UserRoles.admin) {
      debugPrint(
        '🚫 Suppressing admin complaint push for non-admin user (role=$role)',
      );
      return;
    }

    if (!await _waitForAppReady()) return;
    final navigator = await _waitForNavigator();
    if (navigator == null || !navigator.mounted) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      navigator.push(
        MaterialPageRoute(
          settings: const RouteSettings(name: '/admin_complaint_detail'),
          builder: (_) => AdminComplaintDetailScreen(complaintId: complaintId),
        ),
      );
    });
  }

  Future<void> _navigateToPatientAppointments() async {
    if (!await _waitForAppReady()) return;

    final navigator = await _waitForNavigator();
    if (navigator == null || !navigator.mounted) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      navigator.pushAndRemoveUntil(
        MaterialPageRoute(
          settings: const RouteSettings(name: '/patient_portal'),
          builder: (_) => const PatientPortalWrapper(
            initialTab: PatientPortalTab.appointments,
          ),
        ),
        (route) => route.isFirst,
      );
    });
  }

  Future<void> _navigateToDoctorAppointments() async {
    if (!await _waitForAppReady()) return;
    await Future.delayed(const Duration(milliseconds: 250));

    final navigator = await _waitForNavigator();
    if (navigator == null || !navigator.mounted) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      navigator.pushAndRemoveUntil(
        MaterialPageRoute(
          settings: const RouteSettings(name: '/doctor_portal'),
          builder: (_) => const DoctorPortalWrapper(
            initialTab: DoctorPortalTab.appointments,
          ),
        ),
        (route) => route.isFirst,
      );
    });
  }

  /// Admin destination. Deep-links to the specific patient so the relevant
  /// payment record is selected and scrolled to, and refuses to open for
  /// non-admin sessions.
  Future<void> _navigateToAdminPayment({
    required String patientId,
    required String paymentId,
    bool isAppointment = false,
  }) async {
    final role = await _currentSessionRole();
    if (role != UserRoles.admin) {
      debugPrint(
        '🚫 Ignoring admin payment notification — current role is '
        '${role ?? 'none'}',
      );
      return;
    }

    if (!await _waitForAppReady()) return;

    final navigator = await _waitForNavigator();
    if (navigator == null || !navigator.mounted) {
      debugPrint('⚠️ No navigator available for admin payment navigation');
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      // The same notification can be delivered by the system tray *and* by our
      // own local notification. The screen-level flag is set synchronously
      // here, so the second delivery sees it within the same frame.
      if (AdminPaymentScreen.isAdminPaymentScreenOpen) {
        debugPrint('⚠️ AdminPaymentScreen already open — not pushing again');
        return;
      }
      AdminPaymentScreen.isAdminPaymentScreenOpen = true;

      navigator.push(
        MaterialPageRoute(
          settings: const RouteSettings(name: '/admin_payment'),
          builder: (_) => AdminPaymentScreen(
            focusPatientId: patientId,
            focusPaymentId: paymentId,
            initialSegment: isAppointment
                ? AdminPaymentSegment.appointment
                : AdminPaymentSegment.account,
          ),
        ),
      );
    });
  }

  Future<void> _navigateToPatientComplaintReply() async {
    if (!await _waitForAppReady()) return;
    final navigator = await _waitForNavigator();
    if (navigator == null || !navigator.mounted) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      navigator.push(
        MaterialPageRoute(
          settings: const RouteSettings(name: '/complaint_reply'),
          builder: (_) => const SubmitComplaintScreen(),
        ),
      );
    });
  }

  /// Patient destination for `payment_approved` / `payment_rejected`.
  ///
  /// The push payload is only a hint that something changed. The authoritative
  /// status is re-read from Firestore *before* any routing decision, so a stale
  /// or unread payload can neither unlock the app nor lift the lock. When the
  /// Room Chat is already on screen it is woken up in place (its own Firestore
  /// poller then applies the change) instead of being pushed a second time.
  Future<void> _navigateToPatientPaymentStatus({
    required bool approved,
    required String patientId,
  }) async {
    final latestStatus = await _fetchLatestPaymentStatus(patientId);

    if (latestStatus == null) {
      debugPrint(
        '⚠️ Could not verify payment status from Firestore — staying locked',
      );
    } else if (approved != _isUnlockedStatus(latestStatus)) {
      debugPrint(
        '⚠️ Payload said approved=$approved but Firestore says '
        '$latestStatus — trusting Firestore',
      );
    }

    if (!await _waitForAppReady()) return;

    // On a cold start the splash routes the patient to Room Chat in the very
    // next frame. Give that frame time to land so the check below sees the
    // real screen state instead of routing a second copy on top of it.
    await Future.delayed(const Duration(milliseconds: 250));

    if (ChatRoomScreen.isChatRoomScreenOpen) {
      onPaymentStatusRefreshRequested?.call(latestStatus ?? '');
      return;
    }

    final navigator = await _waitForNavigator();
    if (navigator == null || !navigator.mounted) {
      debugPrint('⚠️ No navigator available for patient payment navigation');
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Re-check: the screen may have been built while we awaited Firestore.
      if (ChatRoomScreen.isChatRoomScreenOpen) {
        onPaymentStatusRefreshRequested?.call(latestStatus ?? '');
        return;
      }

      // `pushAndRemoveUntil` keeps a single home route so repeated taps cannot
      // stack Room Chat copies.
      navigator.pushAndRemoveUntil(
        MaterialPageRoute(
          settings: const RouteSettings(name: '/chat_room'),
          builder: (_) => const PatientPortalWrapper(),
        ),
        (route) => route.isFirst,
      );
    });
  }

  static bool _isUnlockedStatus(String status) =>
      status == PaymentStatus.approved || status == 'completed';

  /// Reads the payment status straight from Firestore. Deliberately does not
  /// consult the cached session.
  Future<String?> _fetchLatestPaymentStatus(String patientId) async {
    if (patientId.isEmpty) return null;
    try {
      final doc = await FirebaseFirestore.instance
          .collection(FirestoreCollections.patients)
          .doc(patientId)
          .get();
      if (!doc.exists) return null;
      final status = doc.data()?['paymentStatus'] as String?;
      debugPrint('🔎 Latest Firestore payment status: $status');
      return (status == null || status.isEmpty) ? null : status;
    } catch (e) {
      debugPrint('Error reading latest payment status: $e');
      return null;
    }
  }

  /// Role of the signed-in session, read from the persisted session blob.
  ///
  /// Checks the patient blob first and falls back to the doctor blob —
  /// without the fallback every doctor notification tap was treated as a
  /// patient and routed into the patient portal.
  Future<String?> _currentSessionRole() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userJson = prefs.getString('current_user');
      if (userJson != null && userJson.isNotEmpty) {
        final map = jsonDecode(userJson) as Map<String, dynamic>;
        return map['role']?.toString();
      }
      final doctorJson = prefs.getString('current_doctor');
      if (doctorJson != null && doctorJson.isNotEmpty) {
        final map = jsonDecode(doctorJson) as Map<String, dynamic>;
        return map['role']?.toString() ?? UserRoles.doctor;
      }
    } catch (e) {
      debugPrint('Error resolving session role: $e');
    }
    return null;
  }

  /// The signed-in session's payment status when it *blocks* active features —
  /// `pending` or `rejected` — otherwise `null` (unlocked).
  ///
  /// Mirrors `_ChatRoomScreenState._isLocked` exactly, so a chat or call push
  /// can never drop a payment-rejected patient straight into an active screen
  /// and bypass the Room Chat gate. The status is read from Firestore rather
  /// than the cached session so a decision the admin has just made is honoured
  /// on the very next tap.
  ///
  /// Returns `null` (fail open) when the session cannot be resolved at all, so
  /// a malformed or missing session can never silently swallow a legitimate tap.
  Future<String?> _resolveActiveFeatureLock() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('current_user');
      if (raw == null || raw.isEmpty) return null;

      final session = jsonDecode(raw) as Map<String, dynamic>;

      // Doctors are never payment-gated.
      if (session['role']?.toString() == 'doctor') return null;

      final patientId = session['id']?.toString() ?? '';
      if (patientId.isEmpty) return null;

      // Patient Card logins bypass the payment flow entirely.
      if (session['loginType']?.toString() == 'patientId') return null;
      if ((session['patientId']?.toString() ?? '').isNotEmpty) return null;

      // `null` status means "no payment submitted yet", which the Room Chat
      // treats as locked too (it shows the payment-required section). A failed
      // read is indistinguishable from that, and locking closed is the safe
      // direction: the patient lands on Room Chat, which re-reads the real
      // status and shows the correct section.
      final status = await _fetchLatestPaymentStatus(patientId);
      if (status == null) return 'none';
      if (_isUnlockedStatus(status)) return null;
      return status;
    } catch (e) {
      debugPrint('Error resolving payment lock: $e');
      return null;
    }
  }

  /// Sends a payment-locked patient to the Room Chat, which renders only the
  /// payment rejection section (with the FAB hidden) rather than the
  /// destination they tapped. Reuses the same wake-in-place logic as the
  /// payment-decision flow so an already-open Room Chat simply re-locks.
  Future<void> _routeLockedPatientToRoomChat(String lockStatus) async {
    debugPrint(
      '🔒 Payment "$lockStatus" — redirecting to Room Chat instead of the '
      'tapped destination',
    );

    if (!await _waitForAppReady()) return;

    if (ChatRoomScreen.isChatRoomScreenOpen) {
      onPaymentStatusRefreshRequested?.call(lockStatus);
      return;
    }

    final navigator = await _waitForNavigator();
    if (navigator == null || !navigator.mounted) {
      debugPrint('⚠️ No navigator available to show the payment lock screen');
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (ChatRoomScreen.isChatRoomScreenOpen) {
        onPaymentStatusRefreshRequested?.call(lockStatus);
        return;
      }
      navigator.pushAndRemoveUntil(
        MaterialPageRoute(
          settings: const RouteSettings(name: '/chat_room'),
          builder: (_) => const PatientPortalWrapper(),
        ),
        (route) => route.isFirst,
      );
    });
  }

  /// Waits for the splash screen to finish role routing, with a ceiling so a
  /// wedged splash can never deadlock a notification tap.
  Future<bool> _waitForAppReady() async {
    if (isAppReady) return true;
    final ready = await Future.any(<Future<bool>>[
      _appReadyCompleter.future.then((_) => true),
      Future<bool>.delayed(const Duration(seconds: 15), () => false),
    ]);
    if (!ready) {
      debugPrint('⚠️ Timed out waiting for app-ready before navigating');
    }
    return ready;
  }

  Future<NavigatorState?> _waitForNavigator() async {
    int retries = 0;
    while (navigatorKey.currentState == null && retries < 20) {
      await Future.delayed(const Duration(milliseconds: 100));
      retries++;
    }
    return navigatorKey.currentState;
  }

  /// Confirms the tapped conversation exists, belongs to the signed-in user
  /// and is addressed by the payload's sender. Fails closed: an offline read
  /// or a malformed document must not open an arbitrary chat.
  Future<bool> _isChatTapAuthorized({
    required String? chatId,
    required String senderId,
  }) async {
    final id = (chatId ?? '').trim();
    if (id.isEmpty) return false;

    final currentUserId = await IncomingCallCoordinator.instance
        .resolveCurrentUserId();
    if (currentUserId.isEmpty) return false;
    if (senderId.isNotEmpty && senderId == currentUserId) return false;

    try {
      final doc = await FirebaseFirestore.instance
          .collection(FirestoreCollections.chats)
          .doc(id)
          .get()
          .timeout(const Duration(seconds: 5));
      if (!doc.exists) return false;
      final rawParticipants = doc.data()?['participants'];
      if (rawParticipants is! List) return false;
      final participants = rawParticipants
          .map((value) => value.toString())
          .toSet();
      if (!participants.contains(currentUserId)) return false;
      if (senderId.isNotEmpty && !participants.contains(senderId)) {
        return false;
      }
      return true;
    } catch (e) {
      debugPrint('⚠️ Could not validate chat $id: $e');
      return false;
    }
  }

  void _navigateToChat({
    required String senderId,
    required String senderName,
    required String otherUserImage,
    String? chatId,
  }) async {
    // Same rule as the call route: a chat push must not open `ChatScreen` (and
    // with it the call button) for a patient whose payment is not approved.
    final lockStatus = await _resolveActiveFeatureLock();
    if (lockStatus != null) {
      await _routeLockedPatientToRoomChat(lockStatus);
      return;
    }

    // Never route on a chatId copied from an untrusted payload. The signed-in
    // user must actually be a participant of that conversation, and the sender
    // in the payload must be the other participant.
    if (!await _isChatTapAuthorized(chatId: chatId, senderId: senderId)) {
      debugPrint(
        '🚫 Chat notification tap rejected: chatId=$chatId '
        'senderId=$senderId is not a conversation of this user',
      );
      return;
    }

    // Cold-start taps must wait for splash routing, otherwise the navigator
    // is usually still null and the tap was silently dropped.
    if (!await _waitForAppReady()) return;

    final navigator = await _waitForNavigator();
    if (navigator == null || !navigator.mounted) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (activeChatId == chatId && chatId != null) return;

      navigator.push(
        MaterialPageRoute(
          builder: (context) => ChatScreen(
            otherUserImage: otherUserImage,
            otherUserId: senderId,
            otherUserName: senderName,
          ),
        ),
      );
    });
  }

  Future<void> _navigateToDoctorSharedReports() async {
    // Doctor-only destination: a patient tapping a stray report_shared
    // notification must not land on the doctor's report screen.
    final role = await _currentSessionRole();
    if (role != UserRoles.doctor) {
      debugPrint('🚫 Ignoring report_shared tap — role=$role');
      return;
    }

    if (!await _waitForAppReady()) return;

    final navigator = await _waitForNavigator();
    if (navigator == null || !navigator.mounted) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      navigator.push(
        MaterialPageRoute(
          builder: (context) => const DoctorSharedReportsScreen(),
        ),
      );
    });
  }

  // ─────────────────────────────────────────────────────────────
  // MISC PUBLIC API
  // ─────────────────────────────────────────────────────────────

  Future<String?> getToken() => FCMServiceV2().getToken();

  /// Kept as the single app-facing entry point used by the auth flows; all
  /// token persistence lives in [FcmTokenService].
  Future<void> saveTokenToFirestore(String userId, String role) =>
      FCMServiceV2().updateToken(userId, role);

  Map<String, dynamic> _parsePayload(String payload) {
    try {
      return Map<String, dynamic>.from(jsonDecode(payload));
    } catch (_) {
      // Fallback manual parse
      try {
        String clean = payload.replaceAll('{', '').replaceAll('}', '');
        final result = <String, dynamic>{};
        for (String pair in clean.split(',')) {
          final parts = pair.split(':');
          if (parts.length == 2) {
            final key = parts[0].trim().replaceAll('"', '');
            var value = parts[1].trim();
            if (value.startsWith('"') && value.endsWith('"')) {
              value = value.substring(1, value.length - 1);
            }
            result[key] = value;
          }
        }
        return result;
      } catch (_) {
        return {};
      }
    }
  }

  void dispose() {}
}
