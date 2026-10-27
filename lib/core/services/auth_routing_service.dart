import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/admin_portal/admin_bottom_nav/admin_portal_wrapper.dart';
import 'package:telemedicine/auth/auth_provider/user_provider.dart';
import 'package:telemedicine/auth/auth_screen/expired_patient_screen.dart';
import 'package:telemedicine/auth/auth_screen/sign_in_screen.dart';
import 'package:telemedicine/auth/payment/payment_screen.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/data/models/user_model.dart';
import 'package:telemedicine/doctor_portal/bottom_nav/doctor_portal_wrapper.dart';
import 'package:telemedicine/features/patient/patient_portal_wrapper.dart';

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
        ToastService.instance.showInfo(
          'Please complete payment to continue',
        );
        _navigate(
          context,
          const PaymentScreen(),
          clearStack: clearStack,
        );
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
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => targetScreen),
      );
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
