import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/features/auth/presentation/providers/user_provider.dart';

/// Helper service to enter and exit guest mode cleanly.
class GuestModeService {
  GuestModeService._();

  /// Switches the current session into read-only Guest Mode.
  static void enterGuestMode(WidgetRef ref) {
    ref.read(patientControllerProvider).signInAsGuest();
  }

  /// Exits Guest Mode if the current active session is a guest session.
  static void exitGuestMode(WidgetRef ref) {
    final currentUser = ref.read(patientControllerProvider).currentUser;
    if (currentUser != null && currentUser.isGuest) {
      ref.read(patientControllerProvider).signOut();
    }
  }
}
