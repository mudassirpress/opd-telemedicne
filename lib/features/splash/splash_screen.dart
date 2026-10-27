import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:telemedicine/admin_portal/admin_bottom_nav/admin_portal_wrapper.dart';
import 'package:telemedicine/auth/auth_provider/user_provider.dart';
import 'package:telemedicine/auth/auth_screen/expired_patient_screen.dart';
import 'package:telemedicine/auth/doctor_profile/update_doctor_profile.dart';
import 'package:telemedicine/auth/user_controller/doctor_controller.dart';
import 'package:telemedicine/auth/auth_screen/sign_in_screen.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/doctor_portal/bottom_nav/doctor_portal_wrapper.dart';
import 'package:telemedicine/features/patient/patient_portal_wrapper.dart';
import 'package:telemedicine/core/services/fcm_service.dart';
import 'package:telemedicine/core/services/notification_service.dart';
import 'package:telemedicine/core/theme/app_theme.dart';
import 'package:telemedicine/auth/payment/payment_screen.dart';
import 'package:telemedicine/core/services/auth_routing_service.dart';

class FirstSplashScreen extends ConsumerStatefulWidget {
  const FirstSplashScreen({super.key});

  @override
  ConsumerState<FirstSplashScreen> createState() => _FirstSplashScreenState();
}

class _FirstSplashScreenState extends ConsumerState<FirstSplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;
  late Animation<double> _fadeAnimation;
  String _appVersion = '';

  /// True while the doctor's `price` / `description` are being verified
  /// against Firestore, so the splash shows a real loading state instead of
  /// pretending the portal is about to open.
  bool _isCheckingDoctorProfile = false;

  @override
  void initState() {
    super.initState();
    _loadAppVersion();
    _setupAnimations();
    _checkAndNavigate();
  }

  void _setupAnimations() {
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..forward();

    _animation = Tween<double>(
      begin: 0,
      end: 1,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));

    _fadeAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.2, 1.0, curve: Curves.easeIn),
      ),
    );
  }

  Future<void> _loadAppVersion() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      if (mounted) {
        setState(() {
          _appVersion =
              'Version ${packageInfo.version} (${packageInfo.buildNumber})';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _appVersion = 'Version 1.0.0';
        });
      }
    }
  }

  Future<void> saveUserFCMToken(String userId, String userRole) async {
    final fcmService = FcmTokenService();
    await fcmService.updateToken(userId, userRole);
  }

  // In FirstSplashScreen - _verifySession method (already implemented)
  Future<bool> _verifySession() async {
    try {
      final patientController = ref.read(patientControllerProvider);
      final currentUser = patientController.currentUser;

      if (currentUser != null && currentUser.role == 'patient') {
        print('🔐 Verifying patient session...');
        final currentDeviceId = await patientController.getDeviceId();
        final storedDeviceId = currentUser.deviceId;

        if (storedDeviceId != null &&
            storedDeviceId.isNotEmpty &&
            storedDeviceId != currentDeviceId) {
          print('⚠️ Device mismatch detected! Session invalid.');

          if (mounted) {
            await showDialog(
              context: context,
              barrierDismissible: false,
              builder: (context) => AlertDialog(
                title: const Text('Session Expired'),
                content: const Text(
                  'This account is logged in on another device. Please login again from your original device.',
                ),
                actions: [
                  TextButton(
                    onPressed: () async {
                      await patientController.signOut();
                      if (mounted) {
                        Navigator.of(context).pop();
                      }
                    },
                    child: const Text('OK'),
                  ),
                ],
              ),
            );
          }
          return false;
        }
        return true;
      }
      return true;
    } catch (e) {
      // Fail OPEN: a transient error while verifying the device id must not
      // dump a valid cached session onto the sign-in screen. A real device
      // mismatch is still caught by the explicit comparison above.
      print('❌ Session verification error (failing open): $e');
      return true;
    }
  }

  /// Sends a logged-in doctor either to the portal or — when the profile is
  /// still missing its `price` or `description` — to the existing profile
  /// completion screen, while the splash itself acts as the loading state.
  ///
  /// The decision is made from the Firestore document, not the cached
  /// session, so doctors registered before those fields existed are caught
  /// on app restart too, and doctors who already filled them are never sent
  /// back here.
  Future<void> _navigateToDoctorDestination(
    DoctorController doctorController,
  ) async {
    setState(() {
      _isCheckingDoctorProfile = true;
    });

    final needsCompletion = await doctorController.requiresProfileCompletion();

    if (!mounted) return;

    if (needsCompletion) {
      print('Doctor profile incomplete - redirecting to Complete Profile');
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const UpdateDoctorProfile()),
      );
    } else {
      print('Navigating to Doctor Portal (Doctor logged in)');
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const DoctorPortalWrapper()),
      );
    }
  }

  Future<void> _checkAndNavigate() async {
    // Wait for splash screen animation
    await Future.delayed(const Duration(seconds: 3));

    if (!mounted) return;

    // Load saved user data - wait for completion
    final patientController = ref.read(patientControllerProvider);
    final doctorController = ref.read(doctorControllerProvider);

    // IMPORTANT: Wait for both loads to complete
    await Future.wait([
      patientController.loadSavedUser(),
      doctorController.loadDoctorFromLocalStorage(),
    ]);

    // Give a small delay to ensure state is updated
    await Future.delayed(const Duration(milliseconds: 100));

    // Now check if any user is logged in
    final patientUser = patientController.currentUser;
    final doctorUser = doctorController.currentDoctor;

    print('=== Navigation Check ===');
    print(
      'Patient User: ${patientUser?.fullname}, Role: ${patientUser?.role}, ID: ${patientUser?.id}',
    );
    print(
      'Doctor User: ${doctorUser?.fullname}, DoctorId: ${doctorUser?.doctorId}',
    );
    print('========================');

    // Refresh the FCM token in Firestore on every launch so pushes never target
    // a stale token (fixes notifications after reinstall/token rotation).
    String? signedInId;
    String? signedInRole;
    if (patientUser != null && patientUser.id.isNotEmpty) {
      signedInId = patientUser.id;
      signedInRole = patientUser.role;
    } else if (doctorUser != null &&
        doctorUser.doctorId != null &&
        doctorUser.doctorId!.isNotEmpty) {
      signedInId = doctorUser.id;
      signedInRole = 'doctor';
    }
    if (signedInId != null && signedInRole != null) {
      // Fire-and-forget: the token refresh is a Firestore write that can only
      // complete once the server acks. Awaiting it froze the splash forever
      // for signed-in users starting the app offline.
      unawaited(
        saveUserFCMToken(signedInId, signedInRole).catchError((Object e) {
          print('❌ Failed to refresh FCM token on launch: $e');
        }),
      );
    }

    // Perform session verification for logged in users
    bool sessionValid = await _verifySession();

    if (!sessionValid && mounted) {
      print('Session invalid - redirecting to login');
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const SignInScreen()),
      );
      NotificationService.markAppReady();
      return;
    }

    if (mounted) {
      // Priority 1: Check if user has admin role
      if (patientUser != null && patientUser.role == 'admin') {
        print('Navigating to Admin Portal (Admin logged in)');
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => const AdminPortalWrapper(),
          ),
        );
      }
      // Priority 2: Check if doctor is logged in (has doctorId)
      else if (doctorUser != null &&
          doctorUser.doctorId != null &&
          doctorUser.doctorId!.isNotEmpty) {
        print('Verifying doctor profile before opening the portal');
        await _navigateToDoctorDestination(doctorController);
      }
      // Priority 3: Check if patient or guest is logged in
      else if (patientUser != null &&
          (patientUser.role == 'patient' || patientUser.isGuest)) {
        final destination =
            AuthRoutingService.evaluatePatientDestination(patientUser);
        switch (destination) {
          case PatientAuthDestination.chatRoom:
            print('Navigating to Chat Room (Patient logged in)');
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(
                builder: (context) => const PatientPortalWrapper(),
              ),
            );
            break;
          case PatientAuthDestination.cardExpired:
            print('Patient Card expired – redirecting to ExpiredPatientScreen');
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(
                builder: (context) => const ExpiredPatientScreen(),
              ),
            );
            break;
          case PatientAuthDestination.paymentProof:
            print('Payment required – redirecting to PaymentScreen');
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(builder: (context) => const PaymentScreen()),
            );
            break;
        }
      }
      // Priority 4: Check if shared account is logged in
      else if (patientUser != null &&
          patientUser.role == 'doctor' &&
          patientUser.phoneNumber == '03000000000') {
        // Legacy shared account: no dedicated selection screen exists, so it
        // must at least land on sign-in instead of freezing on the splash.
        print('Shared account detected - redirecting to Sign In');
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => const SignInScreen()),
        );
      }
      // Priority 5: Check if regular doctor (without doctorId) is logged in
      else if (patientUser != null && patientUser.role == 'doctor') {
        if (doctorController.currentDoctor != null) {
          print('Verifying doctor profile before opening the portal');
          await _navigateToDoctorDestination(doctorController);
        } else {
          // No doctor session to verify against: this legacy account keeps
          // its old routing, since the completion screen can only save
          // through a doctor session.
          print('Navigating to Doctor Portal (Regular doctor)');
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (context) => const DoctorPortalWrapper()),
          );
        }
      }
      // Priority 6: No user logged in
      else {
        print('No user logged in - Navigating to Sign In Screen');
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => const SignInScreen()),
        );
      }
    }

    // Role routing is done. Release any notification navigation that was
    // buffered during startup, otherwise the `pushReplacement` above would
    // have wiped the destination off the stack.
    NotificationService.markAppReady();
  }

  @override
  Widget build(BuildContext context) {
    final logoWidth = math.min(context.sw * 0.75, context.contentMaxWidth * 0.9);
    final logoHeight = math.min(context.sh * 0.30, math.max(logoWidth * 0.7, 120.0));

    return Scaffold(
      backgroundColor: Colors.white,
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(8.0),
          child: Text(
            _appVersion,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: context.fs(12),
              color: Colors.grey[600],
            ),
          ),
        ),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // LOGO
            FadeTransition(
              opacity: _fadeAnimation,
              child: Container(
                height: logoHeight,
                width: logoWidth,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Image.asset(
                  "assets/images/opd online.png",
                  fit: BoxFit.contain,
                ),
              ),
            ),
            // Loading state while the logged-in doctor's required profile
            // fields are verified — the portal stays unreachable until then.
            if (_isCheckingDoctorProfile) ...[
              const SizedBox(height: 32),
              const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: AppColors.primaryRed,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Checking your doctor profile...',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: context.fs(13),
                  color: Colors.grey[600],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

class ECGPainter extends CustomPainter {
  final double progress;
  ECGPainter(this.progress);

  @override
  void paint(Canvas canvas, Size size) {
    Paint paint = Paint()
      ..color = const Color.fromARGB(255, 139, 0, 0)
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;

    Path path = Path();
    double width = size.width;
    double height = size.height / 2;
    double length = width * progress;

    path.moveTo(0, height);
    double waveLength = width * 0.4;

    if (length > waveLength * 0.1) {
      path.lineTo(waveLength * 0.1, height);
      path.lineTo(waveLength * 0.15, height - height * 0.5);
      path.lineTo(waveLength * 0.2, height + height * 0.4);
      path.lineTo(waveLength * 0.27, height - height * 0.15);
      path.lineTo(waveLength * 0.33, height);
    }

    if (length > waveLength * 0.5) {
      path.lineTo(waveLength * 0.4, height);
      path.lineTo(waveLength * 0.49, height - height * 0.8);
      path.lineTo(waveLength * 0.53, height);
      path.lineTo(waveLength * 0.56, height + height * 0.6);
      path.lineTo(waveLength * 0.65, height);
    }

    if (length > waveLength * 0.8) {
      path.lineTo(width - width * 0.05, height);
    }

    canvas.drawPath(path, paint);

    if (progress >= .37) {
      Paint circlePaint = Paint()..color = const Color.fromARGB(255, 139, 0, 0);
      canvas.drawCircle(Offset(width - width * 0.02, height), 6, circlePaint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
