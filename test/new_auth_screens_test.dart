import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemedicine/features/auth/presentation/screens/doctor_login_screen.dart';
import 'package:telemedicine/features/auth/presentation/screens/sign_in_screen.dart';
import 'package:telemedicine/features/auth/presentation/screens/sign_up_selection_screen.dart';
import 'package:telemedicine/features/auth/presentation/screens/sign_up_with_card_screen.dart';
import 'package:telemedicine/features/auth/presentation/screens/sign_up_without_card_screen.dart';
import 'package:telemedicine/features/auth/presentation/screens/welcome_screen.dart';

void main() {
  Widget createTestWidget(Widget screen) {
    return ProviderScope(
      child: MaterialApp(
        home: screen,
      ),
    );
  }

  group('New Authentication Screens Tests', () {
    testWidgets('Screen 1: WelcomeScreen renders header, hero, service grid, and 3 buttons', (tester) async {
      await tester.pumpWidget(createTestWidget(const WelcomeScreen()));

      expect(find.text('Sign Up'), findsWidgets);
      expect(find.text('Create a new account'), findsOneWidget);
      expect(find.text('Sign In'), findsOneWidget);
      expect(find.text('Already have an account?'), findsOneWidget);
      expect(find.text('Doctor Login'), findsOneWidget);

      expect(find.textContaining('24/7'), findsWidgets);
      expect(find.textContaining('Digital'), findsWidgets);
      expect(find.textContaining('Radiology'), findsWidgets);
      expect(find.textContaining('Dental'), findsWidgets);
    });

    testWidgets('Screen 2: SignUpSelectionScreen renders options and navigation cards', (tester) async {
      await tester.pumpWidget(createTestWidget(const SignUpSelectionScreen()));

      expect(find.text('Sign Up'), findsOneWidget);
      expect(find.text('Create Your Patient Account'), findsOneWidget);
      expect(find.text('Sign Up with Card'), findsOneWidget);
      expect(find.text('Sign Up without Card'), findsOneWidget);
      expect(find.textContaining('subscription card'), findsOneWidget);
      expect(find.textContaining('create a new account'), findsOneWidget);
    });

    testWidgets('Screen 3: SignUpWithCardScreen renders card graphic, form, and info notice', (tester) async {
      await tester.pumpWidget(createTestWidget(const SignUpWithCardScreen()));

      expect(find.text('Sign Up with Card'), findsOneWidget);
      expect(find.text('Enter Card Details'), findsOneWidget);
      expect(find.textContaining('12-digit card number'), findsWidgets);
      expect(find.text('Verify Card'), findsOneWidget);
      expect(find.textContaining('Your subscription will be activated'), findsOneWidget);
    });

    testWidgets('Screen 4: SignUpWithoutCardScreen renders form fields without email and with terms checkbox', (tester) async {
      await tester.pumpWidget(createTestWidget(const SignUpWithoutCardScreen()));

      expect(find.text('Sign Up without Card'), findsOneWidget);
      expect(find.text('Create Your Account'), findsOneWidget);
      expect(find.text('Full Name'), findsOneWidget);
      expect(find.text('Mobile Number'), findsOneWidget);
      expect(find.text('Create Password'), findsOneWidget);
      expect(find.text('Confirm Password'), findsOneWidget);

      // Verify email field is NOT present
      expect(find.text('Email (Optional)'), findsNothing);
      expect(find.text('Email'), findsNothing);

      expect(find.text('Create Account'), findsOneWidget);
      expect(find.byType(Checkbox), findsOneWidget);
    });

    testWidgets('Screen 5: SignInScreen renders patient login fields, remember me, and OTP button', (tester) async {
      await tester.pumpWidget(createTestWidget(const SignInScreen()));

      expect(find.text('Sign In'), findsWidgets);
      expect(find.text('Welcome Back'), findsOneWidget);
      expect(find.text('Mobile Number or Patient ID'), findsOneWidget);
      expect(find.text('Password'), findsOneWidget);
      expect(find.text('Remember Me'), findsOneWidget);
      expect(find.text('Forgot Password?'), findsOneWidget);
      expect(find.text('Sign In with OTP'), findsOneWidget);

      // Trigger empty submission to test validation errors
      await tester.tap(find.text('Sign In').first);
      await tester.pumpAndSettle();

      expect(find.text('Please enter your Mobile Number or Patient ID'), findsOneWidget);
      expect(find.text('Please enter your password'), findsOneWidget);
    });

    testWidgets('Screen 6: DoctorLoginScreen renders doctor login header, fields, and login button', (tester) async {
      await tester.pumpWidget(createTestWidget(const DoctorLoginScreen()));

      expect(find.text('Doctor Login'), findsWidgets);
      expect(find.text('Access your OPD Telemedicine doctor account.'), findsOneWidget);
      expect(find.text('Doctor ID / Registered Mobile'), findsOneWidget);
      expect(find.text('Password'), findsOneWidget);
      expect(find.text('Login'), findsOneWidget);
      expect(find.text('Forgot Password?'), findsOneWidget);
    });
  });
}

