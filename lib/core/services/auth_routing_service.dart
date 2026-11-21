import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:telemedicine/features/admin/presentation/admin_bottom_nav/admin_portal_wrapper.dart';
import 'package:telemedicine/features/auth/presentation/providers/user_provider.dart';
import 'package:telemedicine/features/auth/presentation/screens/complete_patient_profile_screen.dart';
import 'package:telemedicine/features/auth/presentation/screens/expired_patient_screen.dart';
import 'package:telemedicine/features/auth/presentation/screens/sign_in_screen.dart';
import 'package:telemedicine/features/payments/presentation/screens/payment_screen.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/data/models/user_model.dart';
import 'package:telemedicine/features/doctor_portal/presentation/bottom_nav/doctor_portal_wrapper.dart';
import 'package:telemedicine/features/patients/presentation/patient_portal_wrapper.dart';

/// Destination screens for patient post-login and startup routing.
enum PatientAuthDestination {
  /// First-time card login requiring mobile number and password setup
  completeProfile,

  /// Case A: Active & Valid Patient Card (`isExpired == false`) or approved patient
  /// -> Navigate directly to RoomChatScreen / PatientPortalWrapper.
  chatRoom,

  /// Case B: Expired Patient Card or Subscription (`isExpired == true`)
  /// -> Route to ExpiredPatientScreen to submit a renewal payment receipt.
  cardExpired,

  /// Case C: Regular Non-Card Patient without payment proof
  /// -> Route to PaymentScreen to complete initial payment.
  paymentProof,
}

/// Central routing service and navigation guard for patient post-login
/// and app startup flows.
class AuthRoutingService {
  AuthRoutingService._();

  /// Evaluates the correct destination for a patient user.
  ///
  /// - **Card-Based Login User:**
  ///   1. If first-time login without completed profile (phone + password),
  ///      routes to `CompletePatientProfileScreen`.
  ///   2. If expired, routes to `ExpiredPatientScreen`.
  ///   3. Otherwise, bypasses initial payment screen completely and routes to `PatientPortalWrapper`.
  ///
  /// - **Normal Sign-In User:**
  ///   1. If expired, routes to `ExpiredPatientScreen`.
  ///   2. If initial payment has not been completed, routes to `PaymentScreen`.
  ///   3. Once payment approved or active, routes to `PatientPortalWrapper`.
  static PatientAuthDestination evaluatePatientDestination(UserModel user) {
    if (user.isGuest) {
      return PatientAuthDestination.chatRoom;
    }

    final bool isCardUser = user.isPatientCard;

    // 1. First-time Card user setup check
    if (isCardUser && !user.isProfileCompleted) {
      return PatientAuthDestination.completeProfile;
    }

    // 2. Expiration check (Applies to BOTH Normal and Card users)
    if (user.isExpired) {
      return PatientAuthDestination.cardExpired;
    }

    // 3. Card-based users BYPASS the payment screen
    if (isCardUser) {
      return PatientAuthDestination.chatRoom;
    }

    // 4. Normal users must complete initial payment/subscription
    if (!user.ispayment && user.paymentStatus != 'approved') {
      return PatientAuthDestination.paymentProof;
    }

    return PatientAuthDestination.chatRoom;
  }

  /// Performs post-login navigation for a patient with a clean navigation stack.
  static void navigatePatientPostLogin(
    BuildContext context, {
    required UserModel user,
    bool clearStack = true,
  }) {
    final destination = evaluatePatientDestination(user);

    switch (destination) {
      case PatientAuthDestination.completeProfile:
        ToastService.instance.showInfo(
          'Please set up your mobile number and password to complete registration.',
        );
        _navigate(
          context,
          CompletePatientProfileScreen(
            patientUid: user.id,
            prefilledPhone: user.phoneNumber,
            isPhoneAuth: false,
          ),
          clearStack: clearStack,
        );
        break;

      case PatientAuthDestination.chatRoom:
        ToastService.instance.showSuccess('Welcome back, ${user.fullname}!');
        _navigate(
          context,
          const PatientPortalWrapper(),
          clearStack: clearStack,
        );
        break;

      case PatientAuthDestination.cardExpired:
        ToastService.instance.showError(
          'Your account subscription or card has expired. Please renew to continue.',
        );
        _navigate(
          context,
          const ExpiredPatientScreen(),
          clearStack: clearStack,
        );
        break;

      case PatientAuthDestination.paymentProof:
        ToastService.instance.showInfo('Please complete your subscription payment.');
        _navigate(context, const PaymentScreen(), clearStack: clearStack);
        break;
    }
  }

  static void _navigate(
    BuildContext context,
    Widget targetScreen, {
    required bool clearStack,
  }) {
    if (clearStack) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => targetScreen),
        (Route<dynamic> route) => false,
      );
    } else {
      Navigator.of(
        context,
      ).pushReplacement(MaterialPageRoute(builder: (_) => targetScreen));
    }
  }

  /// Safely routes the user to their appropriate base portal
  /// (DoctorPortalWrapper, AdminPortalWrapper, PatientPortalWrapper, or SignInScreen)
  /// based on their persistent session in SharedPreferences.
  /// Used for cold-start call termination or deep-link fallback when the navigator stack has no history.
  static Future<void> routeToAppropriatePortal(BuildContext context) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final doctorJson = prefs.getString('current_doctor');
      final userJson = prefs.getString('current_user');

      Widget portal = const SignInScreen();

      if (doctorJson != null && doctorJson.isNotEmpty) {
        portal = const DoctorPortalWrapper();
      } else if (userJson != null && userJson.isNotEmpty) {
        try {
          final userMap = json.decode(userJson) as Map<String, dynamic>;
          final role = (userMap['role'] ?? 'patient').toString().toLowerCase();
          if (role == 'admin') {
            portal = const AdminPortalWrapper();
          } else {
            portal = const PatientPortalWrapper();
          }
        } catch (_) {
          portal = const PatientPortalWrapper();
        }
      }

      if (!context.mounted) return;

      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => portal),
        (Route<dynamic> route) => false,
      );
    } catch (e) {
      debugPrint('⚠️ [AuthRoutingService] routeToAppropriatePortal error: $e');
      if (context.mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const SignInScreen()),
          (Route<dynamic> route) => false,
        );
      }
    }
  }
}

/// Alias for AuthRoutingService to match domain architecture naming.
typedef RootNavigationHandler = AuthRoutingService;

/// Dynamic Auth Wrapper widget that evaluates user authentication state,
/// role-based navigation, and patient card expiry.
class AuthWrapper extends ConsumerWidget {
  const AuthWrapper({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(userProvider);
    if (user == null) {
      return const SignInScreen();
    }

    if (user.role == 'admin') {
      return const AdminPortalWrapper();
    }

    if (user.role == 'doctor') {
      return const DoctorPortalWrapper();
    }

    if (user.isGuest) {
      return const PatientPortalWrapper();
    }

    if (user.role == 'patient') {
      final destination = AuthRoutingService.evaluatePatientDestination(user);
      switch (destination) {
        case PatientAuthDestination.completeProfile:
          return CompletePatientProfileScreen(
            patientUid: user.id,
            prefilledPhone: user.phoneNumber,
            isPhoneAuth: false,
          );
        case PatientAuthDestination.chatRoom:
          return const PatientPortalWrapper();
        case PatientAuthDestination.cardExpired:
          return const ExpiredPatientScreen();
        case PatientAuthDestination.paymentProof:
          return const PaymentScreen();
      }
    }

    return const SignInScreen();
  }
}
