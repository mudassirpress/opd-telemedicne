import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemedicine/data/models/user_model.dart';
import 'package:telemedicine/features/auth/presentation/providers/user_provider.dart';
import 'package:telemedicine/features/doctor_portal/presentation/prescriptions/prescription_screen.dart';

void main() {
  testWidgets('PrescriptionFormScreen pumps and renders without throwing', (
    tester,
  ) async {
    final user = UserModel(
      id: 'doctor-1',
      fullname: 'Dr. Test',
      role: 'doctor',
      deviceId: 'dev-1',
      idcard: '12345',
      password: 'pass',
      token: 'tok',
      phoneNumber: '03001234567',
      ispayment: true,
      totalPayment: 0,
      highestDegree: 'MBBS',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          userProvider.overrideWith((ref) => user),
        ],
        child: const MaterialApp(
          home: PrescriptionFormScreen(
            chatId: 'chat-123',
            patientId: 'patient-456',
            patientName: 'Jane Doe',
          ),
        ),
      ),
    );

    await tester.pump();
    expect(find.text('New Prescription'), findsOneWidget);
    expect(find.text('Save Prescription'), findsOneWidget);
    expect(find.byType(TextField), findsWidgets);
  });

  testWidgets('PrescriptionScreen pumps and renders without throwing', (
    tester,
  ) async {
    final user = UserModel(
      id: 'doctor-1',
      fullname: 'Dr. Test',
      role: 'doctor',
      deviceId: 'dev-1',
      idcard: '12345',
      password: 'pass',
      token: 'tok',
      phoneNumber: '03001234567',
      ispayment: true,
      totalPayment: 0,
      highestDegree: 'MBBS',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          userProvider.overrideWith((ref) => user),
        ],
        child: const MaterialApp(
          home: PrescriptionScreen(
            chatId: 'chat-123',
            patientId: 'patient-456',
            patientName: 'Jane Doe',
          ),
        ),
      ),
    );

    await tester.pump();
    expect(find.text('Prescriptions'), findsOneWidget);
    expect(find.text('New Prescription'), findsOneWidget);
  });
}
