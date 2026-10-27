import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemedicine/data/models/user_model.dart';
import 'package:telemedicine/shared/widgets/auth_layout.dart';
import 'package:telemedicine/shared/widgets/custom_textfield.dart';

void main() {
  group('UserModel Gender & copyWith tests', () {
    test('copyWith updates gender without losing existing fields', () {
      final user = UserModel(
        id: 'patient_123',
        fullname: 'Ali Khan',
        deviceId: 'dev_1',
        idcard: '123456789012',
        password: '',
        token: 'tok_1',
        role: 'patient',
        phoneNumber: '+923001234567',
        ispayment: true,
        totalPayment: 1500,
        gender: 'Male',
      );

      final updated = user.copyWith(gender: 'Female');
      expect(updated.gender, 'Female');
      expect(updated.fullname, 'Ali Khan');
      expect(updated.id, 'patient_123');
      expect(updated.ispayment, true);
    });
  });

  group('MetallicInput Error Text Placement tests', () {
    testWidgets('renders error text outside and below the rounded container',
        (tester) async {
      final formKey = GlobalKey<FormState>();
      final controller = TextEditingController();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Form(
              key: formKey,
              child: MetallicInput(
                hintText: 'Full Name',
                icon: Icons.person_rounded,
                controller: controller,
                validator: (val) =>
                    (val == null || val.trim().isEmpty) ? 'Name is required' : null,
              ),
            ),
          ),
        ),
      );

      // Initially no error text
      expect(find.text('Name is required'), findsNothing);

      // Trigger validation
      formKey.currentState!.validate();
      await tester.pumpAndSettle();

      // Error text must be visible
      expect(find.text('Name is required'), findsOneWidget);

      // Find the Padding widget wrapping the error text
      final errorPaddingFinder = find.ancestor(
        of: find.text('Name is required'),
        matching: find.byType(Padding),
      );
      expect(errorPaddingFinder, findsWidgets);

      // Verify padding is top: 6, left: 20, right: 20
      final paddingWidget = tester.widget<Padding>(errorPaddingFinder.first);
      expect(
        paddingWidget.padding,
        const EdgeInsets.only(top: 6, left: 20, right: 20),
      );
    });
  });

  group('GenderDropdownField tests', () {
    testWidgets('renders Gender dropdown with options and outside error',
        (tester) async {
      final formKey = GlobalKey<FormState>();
      String? selectedGender;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                return Form(
                  key: formKey,
                  child: GenderDropdownField(
                    value: selectedGender,
                    showLabel: true,
                    labelText: 'Gender',
                    onChanged: (val) {
                      setState(() {
                        selectedGender = val;
                      });
                    },
                    validator: (val) =>
                        (val == null || val.isEmpty) ? 'Please select your gender' : null,
                  ),
                );
              },
            ),
          ),
        ),
      );

      // Initial state
      expect(find.text('Select Gender'), findsOneWidget);
      expect(find.text('Please select your gender'), findsNothing);

      // Trigger form validation to test error placement
      formKey.currentState!.validate();
      await tester.pumpAndSettle();

      expect(find.text('Please select your gender'), findsOneWidget);

      final errorPaddingFinder = find.ancestor(
        of: find.text('Please select your gender'),
        matching: find.byType(Padding),
      );
      final paddingWidget = tester.widget<Padding>(errorPaddingFinder.first);
      expect(
        paddingWidget.padding,
        const EdgeInsets.only(top: 6, left: 20, right: 20),
      );

      // Tap dropdown to open options
      await tester.tap(find.text('Select Gender'), warnIfMissed: false);
      await tester.pumpAndSettle();

      // Options: Male, Female, Other
      expect(find.text('Male'), findsWidgets);
      expect(find.text('Female'), findsWidgets);
      expect(find.text('Other'), findsWidgets);

      // Select 'Male'
      await tester.tap(find.text('Male').last);
      await tester.pumpAndSettle();

      expect(selectedGender, 'Male');
      expect(find.text('Please select your gender'), findsNothing);
    });
  });

  group('MyTextfield Error Text Placement tests', () {
    testWidgets('renders error text outside and below the rounded container',
        (tester) async {
      final formKey = GlobalKey<FormState>();
      final controller = TextEditingController();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Form(
              key: formKey,
              child: MyTextfield(
                hintText: 'Enter value',
                prefixIcon: Icons.edit,
                controller: controller,
                validator: (val) =>
                    (val == null || val.isEmpty) ? 'Field cannot be empty' : null,
              ),
            ),
          ),
        ),
      );

      formKey.currentState!.validate();
      await tester.pumpAndSettle();

      expect(find.text('Field cannot be empty'), findsOneWidget);

      final errorPaddingFinder = find.ancestor(
        of: find.text('Field cannot be empty'),
        matching: find.byType(Padding),
      );
      final paddingWidget = tester.widget<Padding>(errorPaddingFinder.first);
      expect(
        paddingWidget.padding,
        const EdgeInsets.only(top: 6, left: 20, right: 20),
      );
    });
  });
}
