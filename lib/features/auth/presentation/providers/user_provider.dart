import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/data/models/user_model.dart';
import 'package:telemedicine/features/auth/presentation/controllers/doctor_controller.dart';
import 'package:telemedicine/features/auth/presentation/controllers/patient_controller.dart';
import 'package:telemedicine/features/auth/presentation/controllers/patient_id_controller.dart';

// Provider for PatientController instance
final patientControllerProvider = ChangeNotifierProvider<PatientController>((
  ref,
) {
  return PatientController();
});

// Provider for PatientIdController instance
final patientIdControllerProvider = ChangeNotifierProvider<PatientIdController>(
  (ref) {
    return PatientIdController();
  },
);

// Provider to watch loading state
final isLoadingProvider = Provider<bool>((ref) {
  return ref.watch(patientControllerProvider).isLoading;
});

// Provider to watch error message
final errorMessageProvider = Provider<String>((ref) {
  return ref.watch(patientControllerProvider).errorMessage;
});

// Provider to watch current user (this will auto-update)
final currentUserProvider = Provider<UserModel?>((ref) {
  final controller = ref.watch(patientControllerProvider);
  return controller.currentUser;
});

final currentDoctorProvider = Provider<UserModel?>((ref) {
  final controller = ref.watch(doctorControllerProvider);
  return controller.currentDoctor;
});

final userProvider = Provider<UserModel?>((ref) {
  final currentPatient = ref.watch(currentUserProvider);
  final currentDoctor = ref.watch(currentDoctorProvider);
  return currentPatient ?? currentDoctor;
});

// Provider to check if user is logged in
final isLoggedInProvider = Provider<bool>((ref) {
  return ref.watch(patientControllerProvider).isLoggedIn();
});
