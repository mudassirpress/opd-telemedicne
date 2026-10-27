import 'package:flutter_test/flutter_test.dart';
import 'package:telemedicine/data/models/appointment_model.dart';
import 'package:telemedicine/data/models/user_model.dart';
import 'package:telemedicine/features/appointments/presentation/appointment_controller.dart';

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
  group('doctor price / description — documents written before the fields',
      () {
    test('a document with neither field parses without throwing', () {
      final doctor = doctorFrom(const {});

      expect(doctor.price, isNull);
      expect(doctor.description, isNull);
      expect(doctor.consultationFee, 0);
      expect(doctor.consultationPrice, 0);
    });

    test('the legacy consultationFee still resolves to the price', () {
      final doctor = doctorFrom(const {'consultationFee': 1500});

      expect(doctor.price, isNull);
      expect(doctor.consultationFee, 1500);
      expect(doctor.consultationPrice, 1500);
    });

    test('a document carrying only `price` resolves to the same amount', () {
      final doctor = doctorFrom(const {'price': 2000});

      expect(doctor.price, 2000);
      expect(doctor.consultationFee, 2000);
      expect(doctor.consultationPrice, 2000);
    });

    test('a hand-edited String price is read instead of crashing', () {
      final doctor = doctorFrom(const {'price': '1750'});

      expect(doctor.price, 1750);
      expect(doctor.consultationPrice, 1750);
    });

    test('a `0` price placeholder falls back to a real legacy fee', () {
      final doctor = doctorFrom(const {'price': 0, 'consultationFee': 1500});

      expect(doctor.price, 0);
      expect(doctor.consultationFee, 1500);
    });

    test('a non-String description is coerced rather than cast', () {
      final doctor = doctorFrom(const {'description': 42});

      expect(doctor.description, '42');
    });

    test('a missing description stays null instead of becoming ""', () {
      final doctor = doctorFrom(const {'price': 1500});

      expect(doctor.description, isNull);
    });
  });

  group('doctor price / description — save and read back', () {
    test('toMap writes both price spellings and the description', () {
      final doctor = doctorFrom(const {
        'price': 1500,
        'description': 'Cardiologist with 12 years of experience',
      });

      final map = doctor.toMap();

      expect(map['price'], 1500);
      expect(map['consultationFee'], 1500);
      expect(map['description'], 'Cardiologist with 12 years of experience');
    });

    test('a round-trip keeps price and description intact', () {
      final doctor = doctorFrom(const {
        'price': 1500,
        'description': 'Cardiologist with 12 years of experience',
      });

      final reloaded = UserModel.fromMap(doctor.toMap());

      expect(reloaded.price, 1500);
      expect(reloaded.consultationFee, 1500);
      expect(reloaded.description, 'Cardiologist with 12 years of experience');
    });

    test('copyWith keeps every unrelated doctor field', () {
      final doctor = doctorFrom(const {
        'highestDegree': 'MBBS, FCPS',
        'price': 1500,
        'description': 'Old text',
        'phoneNumber': '+92 300 0000000',
        'languages': <String>['English', 'Urdu'],
      });

      final updated = doctor.copyWith(
        price: 2500,
        consultationFee: 2500,
        description: 'New text',
      );

      expect(updated.price, 2500);
      expect(updated.consultationFee, 2500);
      expect(updated.description, 'New text');
      expect(updated.fullname, 'Dr. Amina Khan');
      expect(updated.highestDegree, 'MBBS, FCPS');
      expect(updated.phoneNumber, '+92 300 0000000');
      expect(updated.doctorId, '4711');
      expect(updated.languages, <String>['English', 'Urdu']);
    });

    test('an old doctor can gain a price and description through copyWith', () {
      final oldDoctor = doctorFrom(const {'consultationFee': 1500});

      final updated = oldDoctor.copyWith(
        price: 1500,
        consultationFee: 1500,
        description: 'Added later',
      );

      expect(updated.price, 1500);
      expect(updated.description, 'Added later');
      expect(updated.toMap()['description'], 'Added later');
    });
  });

  group('appointment payment uses the selected doctor price', () {
    test('priceOf prefers `price`, then the legacy fee, then 0', () {
      expect(
        AppointmentController.priceOf(const {'price': 2000}),
        2000,
      );
      expect(
        AppointmentController.priceOf(const {'consultationFee': 1500}),
        1500,
      );
      expect(
        AppointmentController.priceOf(const {
          'price': 2000,
          'consultationFee': 1500,
        }),
        2000,
      );
      // An old document with neither key must resolve, never throw.
      expect(AppointmentController.priceOf(const {}), 0);
      expect(AppointmentController.priceOf(const {'price': null}), 0);
    });

    test('pricingFor reads the doctor document, not a hardcoded amount', () {
      final pricing = AppointmentController.pricingFor(
        doctor: const {'price': 2500, 'discountPercentage': 30},
        videoWatched: false,
      );

      expect(pricing.consultationFee, 2500);
      expect(pricing.payableAmount, 2500);

      final discounted = AppointmentController.pricingFor(
        doctor: const {'price': 2500, 'discountPercentage': 30},
        videoWatched: true,
      );

      expect(discounted.discountApplied, isTrue);
      expect(discounted.payableAmount, 1750);
    });

    test('an unset price renders "Not set", never "PKR 0"', () {
      final pricing = AppointmentController.pricingFor(
        doctor: const {},
        videoWatched: false,
      );

      expect(pricing.consultationFee, 0);
      expect(pricing.feeLabel, 'Not set');
      expect(pricing.payableLabel, 'Not set');
      expect(pricing.feeLabel, isNot(contains('0')));
    });

    test('a set price renders the doctor amount in the app currency', () {
      final pricing = AppointmentController.pricingFor(
        doctor: const {'consultationFee': 1500},
        videoWatched: false,
      );

      expect(pricing.feeLabel, 'PKR 1500');
      expect(pricing.payableLabel, 'PKR 1500');
    });

    test('an appointment keeps the price it was booked at', () {
      final appointment = AppointmentModel.fromMap('appt-1', const {
        'patientId': 'p1',
        'doctorId': 'd1',
        'price': 2500,
        'consultationFee': 2500,
      });

      expect(appointment.price, 2500);
      expect(appointment.consultationFee, 2500);
      expect(appointment.toMap()['price'], 2500);

      // An appointment written before the field existed still parses.
      final legacy = AppointmentModel.fromMap('appt-2', const {
        'patientId': 'p1',
        'doctorId': 'd1',
        'consultationFee': 1500,
      });

      expect(legacy.price, 1500);
      expect(legacy.consultationFee, 1500);
    });
  });
}
