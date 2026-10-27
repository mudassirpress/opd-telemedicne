import 'package:flutter_test/flutter_test.dart';
import 'package:telemedicine/features/auth/presentation/controllers/doctor_controller.dart';
import 'package:telemedicine/data/models/user_model.dart';

/// A doctor document in whatever shape the given keys produce — everything
/// else falls back to the fields every record has carried forever.
UserModel doctorFrom(Map<String, dynamic> fields) => UserModel.fromMap({
  'id': 'doctor-doc-1',
  'fullname': 'Dr. Amina Khan',
  'role': 'doctor',
  'doctorId': '4711',
  ...fields,
});

void main() {
  group('existing doctor profile completion gate', () {
    test('an unknown (null) profile is treated as incomplete', () {
      expect(DoctorController.isMissingRequiredProfileFields(null), isTrue);
    });

    test('a document written before the fields existed is incomplete', () {
      expect(
        DoctorController.isMissingRequiredProfileFields(doctorFrom(const {})),
        isTrue,
      );
    });

    test('the `0` placeholder admin seeds stays incomplete', () {
      expect(
        DoctorController.isMissingRequiredProfileFields(
          doctorFrom(const {
            'price': 0,
            'consultationFee': 0,
            'description': '',
          }),
        ),
        isTrue,
      );
    });

    test('a price alone is still incomplete without a description', () {
      expect(
        DoctorController.isMissingRequiredProfileFields(
          doctorFrom(const {'price': 1500}),
        ),
        isTrue,
      );
    });

    test('a description alone is still incomplete without a price', () {
      expect(
        DoctorController.isMissingRequiredProfileFields(
          doctorFrom(const {'description': 'Cardiologist'}),
        ),
        isTrue,
      );
    });

    test('a blank or whitespace-only description is incomplete', () {
      expect(
        DoctorController.isMissingRequiredProfileFields(
          doctorFrom(const {'price': 1500, 'description': ''}),
        ),
        isTrue,
      );
      expect(
        DoctorController.isMissingRequiredProfileFields(
          doctorFrom(const {'price': 1500, 'description': '   '}),
        ),
        isTrue,
      );
    });

    test('a missing key and an explicit null behave the same', () {
      expect(
        DoctorController.isMissingRequiredProfileFields(
          doctorFrom(const {'price': 1500, 'description': null}),
        ),
        isTrue,
      );
      expect(
        DoctorController.isMissingRequiredProfileFields(
          doctorFrom(const {'price': null, 'description': 'Text'}),
        ),
        isTrue,
      );
    });

    test('a completed profile is never redirected again', () {
      expect(
        DoctorController.isMissingRequiredProfileFields(
          doctorFrom(const {
            'price': 1500,
            'description': 'Cardiologist with 12 years of experience',
          }),
        ),
        isFalse,
      );
    });

    test('the legacy consultationFee spelling satisfies the price', () {
      expect(
        DoctorController.isMissingRequiredProfileFields(
          doctorFrom(const {
            'consultationFee': 1500,
            'description': 'General physician',
          }),
        ),
        isFalse,
      );
    });

    test('a hand-edited String price is accepted', () {
      expect(
        DoctorController.isMissingRequiredProfileFields(
          doctorFrom(const {
            'price': '1750',
            'description': 'General physician',
          }),
        ),
        isFalse,
      );
    });

    test('a raw Firestore document is parsed into a doctor', () {
      final doctor = DoctorController.doctorFromProfileData(const {
        'id': 'doctor-doc-1',
        'fullname': 'Dr. Amina Khan',
        'price': 1500,
        'description': 'Cardiologist',
      });

      expect(doctor.role, 'doctor');
      expect(doctor.consultationPrice, 1500);
      expect(doctor.description, 'Cardiologist');
      expect(DoctorController.isMissingRequiredProfileFields(doctor), isFalse);
    });
  });
}
