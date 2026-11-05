import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:telemedicine/features/auth/presentation/providers/user_provider.dart';
import 'package:telemedicine/features/patients/presentation/screens/patient_profile_screen.dart';
import 'package:telemedicine/features/doctors/presentation/screens/doctor_profile_screen.dart';
import 'package:telemedicine/features/doctors/presentation/screens/update_doctor_profile_screen.dart';
import 'package:telemedicine/features/patients/presentation/screens/edit_patient_profile_screen.dart';
import 'package:telemedicine/data/models/user_model.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'notifications_enabled': true,
      'app_language': 'English',
    });
  });

  testWidgets('PatientProfileScreen displays title and sections', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    final mockPatient = UserModel(
      id: 'patient_123',
      fullname: 'Muhammad Ali',
      deviceId: 'dev_123',
      idcard: '1234567890123',
      password: '',
      token: 'tok_123',
      role: 'patient',
      phoneNumber: '+923001234567',
      ispayment: true,
      totalPayment: 1000.0,
      gender: 'Male',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          userProvider.overrideWith((ref) => mockPatient),
        ],
        child: const MaterialApp(
          home: PatientProfileScreen(),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // Verify Title
    expect(find.text('Profile & Settings', skipOffstage: false), findsOneWidget);

    // Verify Patient Header Info
    expect(find.text('Muhammad Ali', skipOffstage: false), findsOneWidget);
    expect(find.text('+923001234567', skipOffstage: false), findsOneWidget);

    // Verify Grouped Section Headers
    expect(find.text('ACCOUNT', skipOffstage: false), findsOneWidget);
    expect(find.text('PREFERENCES', skipOffstage: false), findsOneWidget);
    expect(find.text('SUPPORT', skipOffstage: false), findsOneWidget);

    // Verify Account Items
    expect(find.text('Manage Profile', skipOffstage: false), findsOneWidget);
    expect(find.text('My Prescriptions', skipOffstage: false), findsOneWidget);

    // Verify Preferences Items
    expect(find.text('Notifications', skipOffstage: false), findsOneWidget);
    expect(find.text('Language', skipOffstage: false), findsOneWidget);

    // Verify Support Items
    expect(find.text('Help Center', skipOffstage: false), findsOneWidget);
    expect(find.text('Terms & Policies', skipOffstage: false), findsOneWidget);
    expect(find.text('About Us', skipOffstage: false), findsOneWidget);

    // Verify Destructive Actions
    expect(find.text('Logout', skipOffstage: false), findsOneWidget);
    expect(find.text('Delete Account', skipOffstage: false), findsOneWidget);
  });

  testWidgets('DoctorProfileScreen displays title and sections', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    final mockDoctor = UserModel(
      id: 'doc_123',
      doctorId: '4567',
      fullname: 'Dr. Tariq Khan',
      deviceId: 'dev_doc_123',
      idcard: '1234567890124',
      password: '',
      token: 'tok_doc_123',
      role: 'doctor',
      phoneNumber: '+923331122334',
      ispayment: true,
      totalPayment: 0.0,
      highestDegree: 'MBBS, FCPS Cardiology',
      price: 1500.0,
      consultationFee: 1500.0,
      languages: ['English', 'Urdu'],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentDoctorProvider.overrideWith((ref) => mockDoctor),
          userProvider.overrideWith((ref) => mockDoctor),
        ],
        child: const MaterialApp(
          home: DoctorProfileScreen(),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // Verify Title
    expect(find.text('Profile & Settings', skipOffstage: false), findsOneWidget);

    // Verify Grouped Section Headers
    expect(find.text('ACCOUNT', skipOffstage: false), findsOneWidget);
    expect(find.text('PREFERENCES', skipOffstage: false), findsOneWidget);
    expect(find.text('SUPPORT', skipOffstage: false), findsOneWidget);

    // Verify Account Items
    expect(find.text('Manage Profile', skipOffstage: false), findsOneWidget);
    expect(find.text('Professional Information', skipOffstage: false), findsOneWidget);
    expect(find.text('Doctor Account Details', skipOffstage: false), findsOneWidget);

    // Verify Preferences
    expect(find.text('Available for Consultations', skipOffstage: false), findsOneWidget);
    expect(find.text('Notifications', skipOffstage: false), findsOneWidget);
    expect(find.text('Language', skipOffstage: false), findsOneWidget);

    // Verify Support Items
    expect(find.text('Help Center', skipOffstage: false), findsOneWidget);
    expect(find.text('Terms & Policies', skipOffstage: false), findsOneWidget);
    expect(find.text('About Us', skipOffstage: false), findsOneWidget);

    // Verify Destructive Actions
    expect(find.text('Logout', skipOffstage: false), findsOneWidget);
    expect(find.text('Deactivate Account', skipOffstage: false), findsOneWidget);
  });

  testWidgets('EditPatientProfileScreen renders form fields', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    final mockPatient = UserModel(
      id: 'patient_123',
      fullname: 'Ayesha Bibi',
      deviceId: 'dev_123',
      idcard: '1234567890123',
      password: '',
      token: 'tok_123',
      role: 'patient',
      phoneNumber: '+923009876543',
      ispayment: true,
      totalPayment: 1000.0,
      gender: 'Female',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          userProvider.overrideWith((ref) => mockPatient),
        ],
        child: const MaterialApp(
          home: EditPatientProfileScreen(),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Manage Profile', skipOffstage: false), findsOneWidget);
    expect(find.text('Full Name', skipOffstage: false), findsOneWidget);
    expect(find.text('Phone Number', skipOffstage: false), findsOneWidget);
    expect(find.text('Gender', skipOffstage: false), findsOneWidget);
    expect(find.text('Save Changes', skipOffstage: false), findsOneWidget);
  });

  testWidgets('UpdateDoctorProfileScreen renders matching doctor form fields', (tester) async {
    final mockDoctor = UserModel(
      id: 'doc_123',
      doctorId: '4567',
      fullname: 'Dr. Tariq Khan',
      deviceId: 'dev_doc_123',
      idcard: '1234567890124',
      password: '',
      token: 'tok_doc_123',
      role: 'doctor',
      phoneNumber: '+923331122334',
      ispayment: true,
      totalPayment: 0.0,
      highestDegree: 'MBBS, FCPS Cardiology',
      price: 1500.0,
      consultationFee: 1500.0,
      languages: ['English', 'Urdu'],
      gender: 'Male',
      description: 'Senior Consultant Cardiologist with 15 years experience.',
    );

    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentDoctorProvider.overrideWith((ref) => mockDoctor),
          userProvider.overrideWith((ref) => mockDoctor),
        ],
        child: const MaterialApp(
          home: UpdateDoctorProfileScreen(),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Complete Profile', skipOffstage: false), findsOneWidget);
    expect(find.text('Full Name', skipOffstage: false), findsOneWidget);
    expect(find.text('Phone Number', skipOffstage: false), findsOneWidget);
    expect(find.text('Gender', skipOffstage: false), findsOneWidget);
    expect(find.text('Highest Qualification / Degree', skipOffstage: false), findsOneWidget);
    expect(find.text('Consultation Fee (PKR)', skipOffstage: false), findsOneWidget);
    expect(find.text('Consultation Languages', skipOffstage: false), findsOneWidget);
    expect(find.text('Professional Summary / Bio', skipOffstage: false), findsOneWidget);
    expect(find.text('YouTube Introduction Video (Optional)', skipOffstage: false), findsOneWidget);
    expect(find.text('Save Changes', skipOffstage: false), findsOneWidget);
  });
}
