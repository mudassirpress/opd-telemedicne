import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:telemedicine/features/admin/presentation/admin_bottom_nav/admin_portal_wrapper.dart';
import 'package:telemedicine/features/auth/presentation/providers/user_provider.dart';
import 'package:telemedicine/features/auth/presentation/screens/expired_patient_screen.dart';
import 'package:telemedicine/features/auth/presentation/screens/sign_in_screen.dart';
import 'package:telemedicine/features/payments/presentation/screens/payment_screen.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/data/models/user_model.dart';
import 'package:telemedicine/features/doctor_portal/presentation/bottom_nav/doctor_portal_wrapper.dart';
import 'package:telemedicine/features/patients/presentation/patient_portal_wrapper.dart';

/// Destination screens for patient post-login and startup routing.
enum PatientAuthDestination {
  /// Case A: Active & Valid Patient Card (`isExpired == false`) or approved patient
  /// -> Navigate directly to RoomChatScreen / PatientPortalWrapper.
  chatRoom,

  /// Case B: Expired Patient Card (`isExpired == true`)
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
  /// - **Case A: Active & Valid Card (`isExpired == false`):**
  ///   Users with a valid Patient Card bypass the payment screen and land
  ///   directly on RoomChatScreen / PatientPortalWrapper.
  ///
  /// - **Case B: Expired Card (`isExpired == true`):**
  ///   Patient Card has expired. Redirects to ExpiredPatientScreen for renewal.
  ///
  /// - **Case C: Regular Non-Card Patient:**
  ///   Standard patients must submit payment proof if missing (`paymentImage` empty),
  ///   or proceed to the portal once approved.
  static PatientAuthDestination evaluatePatientDestination(UserModel user) {
    if (user.isGuest) {
      return PatientAuthDestination.chatRoom;
    }

    if (user.isPatientCard) {
      if (user.isExpired) {
        return PatientAuthDestination.cardExpired;
      }
      return PatientAuthDestination.chatRoom;
    }

    // If regular user has an expired validity date
    if (user.isExpired) {
      return PatientAuthDestination.cardExpired;
    }

    // Standard patients (approved, pending, rejected, or not submitted) land on
    // the portal in full or restricted mode without being trapped on PaymentScreen.
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
          'Your Patient Card has expired. Please renew your payment to continue.',
        );
        _navigate(
          context,
          const ExpiredPatientScreen(),
          clearStack: clearStack,
        );
        break;

      case PatientAuthDestination.paymentProof:
        ToastService.instance.showInfo('Please complete payment to continue');
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
