// lib/core/services/smart_launch_coordinator.dart
import 'dart:async';
import 'dart:convert';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:telemedicine/admin_portal/admin_bottom_nav/admin_portal_wrapper.dart';
import 'package:telemedicine/auth/auth_provider/user_provider.dart';
import 'package:telemedicine/auth/auth_screen/expired_patient_screen.dart';
import 'package:telemedicine/auth/auth_screen/sign_in_screen.dart';
import 'package:telemedicine/auth/doctor_profile/update_doctor_profile.dart';
import 'package:telemedicine/auth/payment/payment_screen.dart';
import 'package:telemedicine/auth/user_controller/doctor_controller.dart';
import 'package:telemedicine/auth/user_controller/patient_controller.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/core/services/auth_routing_service.dart';
import 'package:telemedicine/core/services/incoming_call_coordinator.dart';
import 'package:telemedicine/core/services/notification_service.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/doctor_portal/bottom_nav/doctor_portal_wrapper.dart';
import 'package:telemedicine/features/patient/patient_portal_wrapper.dart';
import 'package:telemedicine/features/splash/splash_screen.dart';
import 'package:telemedicine/home_widget/chat_call/call/call_screen.dart';
import 'package:telemedicine/home_widget/chat_call/call/incoming_call.dart';
import 'package:telemedicine/home_widget/chat_call/chat/chat_screen.dart';

/// The kind of destination target determined at startup.
enum LaunchTargetType {
  /// User tapped the app launcher icon on the home screen.
  /// Shows the normal OPD Online splash screen.
  normal,

  /// App launched from tapping a chat message notification.
  /// Bypasses the splash screen and opens the chat directly.
  chat,

  /// App launched from an incoming-call notification tap or full-screen intent.
  /// Bypasses the splash screen and opens the incoming-call UI directly.
  incomingCall,

  /// App launched from the notification's "Accept" action.
  /// Bypasses the splash screen and opens the active call screen directly.
  activeCall,

  /// App launched from the notification's "Decline" action.
  /// Bypasses the splash screen and terminates the call without showing call UI.
  declineCall,

  /// App launched from payment or appointment notification.
  payment,
  appointment,
  reportShared,
}

/// Represents the startup launch target and its metadata.
@immutable
class LaunchTarget {
  final LaunchTargetType type;
  final Map<String, dynamic> data;
  final String? actionId;

  const LaunchTarget({
    required this.type,
    this.data = const <String, dynamic>{},
    this.actionId,
  });

  bool get isNormal => type == LaunchTargetType.normal;
  bool get isChat => type == LaunchTargetType.chat;
  bool get isIncomingCall => type == LaunchTargetType.incomingCall;
  bool get isActiveCall => type == LaunchTargetType.activeCall;
  bool get isDeclineCall => type == LaunchTargetType.declineCall;

  @override
  String toString() => 'LaunchTarget(type: $type, actionId: $actionId, data: $data)';
}

/// Central coordinator that determines the launch source before rendering the initial
/// Flutter route, allowing chat and call notifications to bypass the splash screen.
class SmartLaunchCoordinator {
  SmartLaunchCoordinator._();

  static LaunchTarget? _cachedLaunchTarget;
  static bool _hasDetermined = false;

  /// Determines the launch target once at application startup.
  static Future<LaunchTarget> determineLaunchTarget() async {
    if (_hasDetermined && _cachedLaunchTarget != null) {
      return _cachedLaunchTarget!;
    }

    try {
      // 1. Check local notifications launch details (notification body tap, action button, fullScreenIntent)
      final localNotifications = FlutterLocalNotificationsPlugin();
      final localDetails = await localNotifications.getNotificationAppLaunchDetails();

      if (localDetails != null && localDetails.didNotificationLaunchApp) {
        final response = localDetails.notificationResponse;
        if (response != null && response.payload != null && response.payload!.isNotEmpty) {
          final data = _parsePayload(response.payload!);
          final target = _resolveTargetFromData(data, actionId: response.actionId);
          if (target != null) {
            debugPrint('🚀 [SMART_LAUNCH] Launched from local notification: $target');
            _cachedLaunchTarget = target;
            _hasDetermined = true;
            return target;
          }
        }
      }

      // 2. Check SharedPreferences pending notification action (set by background isolate)
      try {
        final prefs = await SharedPreferences.getInstance();
        final pendingActionRaw = prefs.getString('pending_notification_action');
        if (pendingActionRaw != null && pendingActionRaw.isNotEmpty) {
          final decoded = jsonDecode(pendingActionRaw);
          if (decoded is Map<String, dynamic>) {
            final action = (decoded['action'] ?? '').toString();
            final data = decoded['data'] is Map<String, dynamic>
                ? decoded['data'] as Map<String, dynamic>
                : <String, dynamic>{};
            final target = _resolveTargetFromData(data, actionId: action);
            if (target != null) {
              debugPrint('🚀 [SMART_LAUNCH] Launched from pending notification action: $target');
              _cachedLaunchTarget = target;
              _hasDetermined = true;
              return target;
            }
          }
        }
      } catch (e) {
        debugPrint('⚠️ [SMART_LAUNCH] Error inspecting pending notification action: $e');
      }

      // 3. Check FCM initial message (system-rendered notification tap from terminated state)
      final fcmInitial = await FirebaseMessaging.instance.getInitialMessage();
      if (fcmInitial != null && fcmInitial.data.isNotEmpty) {
        final target = _resolveTargetFromData(fcmInitial.data);
        if (target != null) {
          debugPrint('🚀 [SMART_LAUNCH] Launched from FCM initial message: $target');
          _cachedLaunchTarget = target;
          _hasDetermined = true;
          return target;
        }
      }
    } catch (e) {
      debugPrint('⚠️ [SMART_LAUNCH] Error determining launch target: $e');
    }

    debugPrint('🚀 [SMART_LAUNCH] Normal app launch (launcher icon) -> Normal Splash');
    _cachedLaunchTarget = const LaunchTarget(type: LaunchTargetType.normal);
    _hasDetermined = true;
    return _cachedLaunchTarget!;
  }

  static LaunchTarget? _resolveTargetFromData(
    Map<String, dynamic> data, {
    String? actionId,
  }) {
    final type = (data['type'] ?? '').toString();
    final isCall = type == 'call' || type == 'incoming_call' || data.containsKey('callId');

    if (isCall) {
      if (actionId == CallActionIds.accept) {
        return LaunchTarget(
          type: LaunchTargetType.activeCall,
          data: data,
          actionId: actionId,
        );
      }
      if (actionId == CallActionIds.decline) {
        return LaunchTarget(
          type: LaunchTargetType.declineCall,
          data: data,
          actionId: actionId,
        );
      }
      return LaunchTarget(
        type: LaunchTargetType.incomingCall,
        data: data,
        actionId: actionId,
      );
    }

    if (FcmMessageType.isPayment(type)) {
      return LaunchTarget(type: LaunchTargetType.payment, data: data, actionId: actionId);
    }

    if (FcmMessageType.isAppointment(type)) {
      return LaunchTarget(type: LaunchTargetType.appointment, data: data, actionId: actionId);
    }

    if (type == 'report_shared') {
      return LaunchTarget(type: LaunchTargetType.reportShared, data: data, actionId: actionId);
    }

    final isChat = type == 'chat' ||
        type == 'chat_message' ||
        (data.containsKey('chatId') && (data.containsKey('senderId') || data.containsKey('otherUserId')));

    if (isChat) {
      return LaunchTarget(type: LaunchTargetType.chat, data: data, actionId: actionId);
    }

    return null;
  }

  static Map<String, dynamic> _parsePayload(String payload) {
    try {
      return Map<String, dynamic>.from(jsonDecode(payload) as Map);
    } catch (_) {
      try {
        final clean = payload.replaceAll('{', '').replaceAll('}', '');
        final result = <String, dynamic>{};
        for (final pair in clean.split(',')) {
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
        return <String, dynamic>{};
      }
    }
  }

  /// Builds the initial root widget according to the determined launch target.
  static Widget buildRootWidget(LaunchTarget target) {
    if (target.isNormal) {
      return const FirstSplashScreen();
    }
    return SmartDirectLaunchWrapper(target: target);
  }
}

/// Widget that directly loads authenticated session and renders the intended destination
/// (ChatScreen, IncomingCallScreen, or CallScreen) without rendering the normal splash screen.
class SmartDirectLaunchWrapper extends ConsumerStatefulWidget {
  final LaunchTarget target;

  const SmartDirectLaunchWrapper({
    super.key,
    required this.target,
  });

  @override
  ConsumerState<SmartDirectLaunchWrapper> createState() =>
      _SmartDirectLaunchWrapperState();
}

class _SmartDirectLaunchWrapperState
    extends ConsumerState<SmartDirectLaunchWrapper> {
  bool _isLoading = true;
  Widget? _destination;

  @override
  void initState() {
    super.initState();
    _handleDirectLaunch();
  }

  Future<void> _handleDirectLaunch() async {
    final patientController = ref.read(patientControllerProvider);
    final doctorController = ref.read(doctorControllerProvider);

    // 1. Restore authenticated user sessions rapidly from local persistent storage
    await Future.wait([
      patientController.loadSavedUser(),
      doctorController.loadDoctorFromLocalStorage(),
    ]);

    final patientUser = patientController.currentUser;
    final doctorUser = doctorController.currentDoctor;
    final bool isAuthenticated =
        (patientUser != null && patientUser.id.isNotEmpty) ||
        (doctorUser != null && (doctorUser.doctorId ?? '').isNotEmpty);

    // If the user is logged out, route to SignInScreen with preserved destination
    if (!isAuthenticated) {
      debugPrint('🔒 [SMART_LAUNCH] User not authenticated -> redirecting to SignInScreen');
      NotificationService.markAppReady();
      if (mounted) {
        setState(() {
          _destination = const SignInScreen();
          _isLoading = false;
        });
      }
      return;
    }

    final String userRole =
        doctorUser != null && (doctorUser.doctorId ?? '').isNotEmpty
            ? 'doctor'
            : (patientUser?.role ?? 'patient');

    // Doctor profile completion check
    if (userRole == 'doctor' && doctorUser != null) {
      final needsCompletion = await doctorController.requiresProfileCompletion();
      if (needsCompletion) {
        debugPrint('🩺 [SMART_LAUNCH] Doctor profile incomplete -> redirecting to UpdateDoctorProfile');
        NotificationService.markAppReady();
        if (mounted) {
          setState(() {
            _destination = const UpdateDoctorProfile();
            _isLoading = false;
          });
        }
        return;
      }
    }

    // Patient card / payment checks
    if (userRole == 'patient' && patientUser != null) {
      final dest = AuthRoutingService.evaluatePatientDestination(patientUser);
      if (dest == PatientAuthDestination.cardExpired) {
        debugPrint('💳 [SMART_LAUNCH] Patient card expired -> ExpiredPatientScreen');
        NotificationService.markAppReady();
        if (mounted) {
          setState(() {
            _destination = const ExpiredPatientScreen();
            _isLoading = false;
          });
        }
        return;
      }
      if (dest == PatientAuthDestination.paymentProof) {
        debugPrint('💳 [SMART_LAUNCH] Patient payment required -> PaymentScreen');
        NotificationService.markAppReady();
        if (mounted) {
          setState(() {
            _destination = const PaymentScreen();
            _isLoading = false;
          });
        }
        return;
      }
    }

    final Widget basePortal = userRole == 'doctor'
        ? const DoctorPortalWrapper()
        : (userRole == 'admin'
            ? const AdminPortalWrapper()
            : const PatientPortalWrapper());

    // A notification tap that cold-started the app was already dispatched by
    // `NotificationService.initialize()` before `runApp`. That service owns the
    // destination (it applies the payment lock and chat authorization and
    // de-duplicates calls), so rendering a second one here is what used to put
    // two chat screens / two incoming-call screens on the stack. Rendering the
    // portal and marking the app ready lets the pending navigation land on it.
    if (NotificationService.coldStartNotificationConsumed) {
      debugPrint(
        '🚀 [SMART_LAUNCH] Cold-start notification handled by '
        'NotificationService -> base portal',
      );
      NotificationService.markAppReady();
      if (mounted) {
        setState(() {
          _destination = basePortal;
          _isLoading = false;
        });
      }
      return;
    }

    // 2. Handle call decline action
    if (widget.target.isDeclineCall) {
      final data = widget.target.data;
      final callId = (data['callId'] ?? '').toString();
      if (callId.isNotEmpty) {
        debugPrint('📞 [SMART_LAUNCH] Handling call decline for $callId');
        await IncomingCallCoordinator.instance.decline(callId);
      }
      NotificationService.markAppReady();
      if (mounted) {
        setState(() {
          _destination = basePortal;
          _isLoading = false;
        });
      }
      return;
    }

    // 3. Route directly based on the launch target
    if (widget.target.isChat) {
      final data = widget.target.data;
      final otherUserId = (data['senderId'] ?? data['otherUserId'] ?? '').toString();
      final otherUserName = (data['senderName'] ?? data['otherUserName'] ?? 'User').toString();
      final otherUserImage = (data['senderProfileImage'] ?? data['otherUserImage'] ?? '').toString();

      if (otherUserId.isEmpty) {
        debugPrint('⚠️ [SMART_LAUNCH] Chat target missing otherUserId -> fallback to base portal');
        NotificationService.markAppReady();
        if (mounted) {
          setState(() {
            _destination = basePortal;
            _isLoading = false;
          });
        }
        return;
      }

      debugPrint(
        '💬 [SMART_LAUNCH] Direct deep link to ChatScreen with $otherUserName ($otherUserId)',
      );

      NotificationService.markAppReady();
      if (mounted) {
        setState(() {
          _destination = _StackWithBasePortal(
            basePortal: basePortal,
            child: ChatScreen(
              otherUserId: otherUserId,
              otherUserName: otherUserName,
              otherUserImage: otherUserImage,
            ),
          );
          _isLoading = false;
        });
      }
      return;
    }

    if (widget.target.isIncomingCall) {
      final data = widget.target.data;
      final payload = IncomingCallPayload.tryParse(data);

      if (payload == null) {
        debugPrint('⚠️ [SMART_LAUNCH] Malformed call payload -> fallback to base portal');
        NotificationService.markAppReady();
        if (mounted) {
          setState(() {
            _destination = basePortal;
            _isLoading = false;
          });
        }
        return;
      }

      // Check whether call is still ringing
      final validated = await IncomingCallCoordinator.instance.registerIncomingCall(
        payload.toMap(),
        origin: IncomingCallOrigin.notificationTap,
      );

      NotificationService.markAppReady();

      if (validated == null) {
        debugPrint('⚠️ [SMART_LAUNCH] Tapped call no longer ringing -> safe home screen');
        ToastService.instance.showInfo('This call has ended or expired.');
        if (mounted) {
          setState(() {
            _destination = basePortal;
            _isLoading = false;
          });
        }
        return;
      }

      debugPrint('📞 [SMART_LAUNCH] Direct deep link to IncomingCallScreen callId=${payload.callId}');
      if (mounted) {
        setState(() {
          _destination = IncomingCallScreen(
            callId: payload.callId,
            callerName: payload.callerName,
            callerImage: payload.callerImage,
            channelId: payload.channelId,
            callerId: payload.callerId,
            callType: payload.callType,
            callerType: payload.callerType,
            autoAccept: false,
          );
          _isLoading = false;
        });
      }
      return;
    }

    if (widget.target.isActiveCall) {
      final data = widget.target.data;
      final payload = IncomingCallPayload.tryParse(data);

      if (payload != null) {
        final currentUserId =
            await IncomingCallCoordinator.instance.resolveCurrentUserId();

        final accepted =
            await IncomingCallCoordinator.instance.accept(payload.callId);

        NotificationService.markAppReady();

        if (accepted.handled && currentUserId.isNotEmpty) {
          debugPrint('📞 [SMART_LAUNCH] Direct deep link to CallScreen callId=${payload.callId}');
          if (mounted) {
            setState(() {
              _destination = CallScreen(
                channelId: payload.channelId,
                callId: payload.callId,
                callType: payload.callType,
                otherUserName: payload.callerName,
                otherUserImage: payload.callerImage,
                currentUserId: currentUserId,
                otherUserId: payload.callerId,
                otherUserType: payload.callerType,
                isCaller: false,
              );
              _isLoading = false;
            });
          }
          return;
        }
      }

      NotificationService.markAppReady();
      if (mounted) {
        setState(() {
          _destination = basePortal;
          _isLoading = false;
        });
      }
      return;
    }

    // Default fallback
    NotificationService.markAppReady();
    if (mounted) {
      setState(() {
        _destination = basePortal;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading || _destination == null) {
      // Lightweight solid scaffold matching the native background to prevent any flash
      return const Scaffold(
        backgroundColor: Colors.white,
        body: SizedBox.expand(),
      );
    }
    return _destination!;
  }
}

/// Helper that mounts the destination screen with the portal in the backstack,
/// so pressing the Android back button smoothly returns the user to the portal.
class _StackWithBasePortal extends StatelessWidget {
  final Widget basePortal;
  final Widget child;

  const _StackWithBasePortal({
    required this.basePortal,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Navigator(
      onGenerateRoute: (settings) {
        return MaterialPageRoute<void>(
          builder: (context) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  settings: RouteSettings(name: child.runtimeType.toString()),
                  builder: (_) => child,
                ),
              );
            });
            return basePortal;
          },
        );
      },
    );
  }
}
