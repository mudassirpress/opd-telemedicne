import 'package:flutter_test/flutter_test.dart';
import 'package:telemedicine/core/services/auth_routing_service.dart';
import 'package:telemedicine/data/models/user_model.dart';

void main() {
  group('Patient Card Expiry and Routing Logic', () {
    test('isPatientCard identifies card users correctly across identifiers', () {
      final cardUserByLoginType = UserModel(
        id: 'p1',
        fullname: 'Alice',
        deviceId: 'd1',
        idcard: '123',
        password: 'pass',
        token: 'tok',
        role: 'patient',
        phoneNumber: '+923001234567',
        ispayment: false,
        totalPayment: 0,
        loginType: 'patientId',
      );
      expect(cardUserByLoginType.isPatientCard, isTrue);
      expect(cardUserByLoginType.isPatientIdUser, isTrue);

      final cardUserByPatientId = UserModel(
        id: 'p2',
        fullname: 'Bob',
        deviceId: 'd2',
        idcard: '456',
        password: 'pass',
        token: 'tok',
        role: 'patient',
        phoneNumber: '+923001234568',
        ispayment: false,
        totalPayment: 0,
        patientId: '202410190001',
      );
      expect(cardUserByPatientId.isPatientCard, isTrue);

      final cardUserByCardStatus = UserModel(
        id: 'p3',
        fullname: 'Charlie',
        deviceId: 'd3',
        idcard: '789',
        password: 'pass',
        token: 'tok',
        role: 'patient',
        phoneNumber: '+923001234569',
        ispayment: false,
        totalPayment: 0,
        cardStatus: 'Active',
      );
      expect(cardUserByCardStatus.isPatientCard, isTrue);

      final regularPatient = UserModel(
        id: 'p4',
        fullname: 'David',
        deviceId: 'd4',
        idcard: '999',
        password: 'pass',
        token: 'tok',
        role: 'patient',
        phoneNumber: '+923001234570',
        ispayment: false,
        totalPayment: 0,
      );
      expect(regularPatient.isPatientCard, isFalse);
    });

    test('fromMap resolves expiry date across multiple field aliases with null safety', () {
      final now = DateTime.now();
      final futureDate = now.add(const Duration(days: 90));

      // 1. Direct 'expiryDate' as ISO String
      final model1 = UserModel.fromMap({
        'id': 'p1',
        'fullname': 'User 1',
        'expiryDate': futureDate.toIso8601String(),
      });
      expect(model1.expiryDate, isNotNull);
      expect(model1.isExpired, isFalse);

      // 2. 'patientCardExpiryDate' alias
      final model2 = UserModel.fromMap({
        'id': 'p2',
        'fullname': 'User 2',
        'patientCardExpiryDate': futureDate.toIso8601String(),
      });
      expect(model2.expiryDate, isNotNull);
      expect(model2.isExpired, isFalse);

      // 3. 'cardValidUntil' alias
      final model3 = UserModel.fromMap({
        'id': 'p3',
        'fullname': 'User 3',
        'cardValidUntil': futureDate.toIso8601String(),
      });
      expect(model3.expiryDate, isNotNull);
      expect(model3.isExpired, isFalse);

      // 4. Epoch integer timestamp
      final model4 = UserModel.fromMap({
        'id': 'p4',
        'fullname': 'User 4',
        'patientCardExpiryDate': futureDate.millisecondsSinceEpoch,
      });
      expect(model4.expiryDate, isNotNull);
      expect(model4.isExpired, isFalse);

      // 5. Malformed or missing date fallback
      final model5 = UserModel.fromMap({
        'id': 'p5',
        'fullname': 'User 5',
        'expiryDate': 'invalid-date-format',
      });
      expect(model5.expiryDate, isNull);
      expect(model5.isExpired, isFalse); // Graceful fallback
    });

    test('isExpired detects past dates and cardStatus', () {
      final pastDate = DateTime.now().subtract(const Duration(days: 2));
      final futureDate = DateTime.now().add(const Duration(days: 30));

      final activeUser = UserModel(
        id: 'u1',
        fullname: 'Active User',
        deviceId: '',
        idcard: '',
        password: '',
        token: '',
        role: 'patient',
        phoneNumber: '',
        ispayment: false,
        totalPayment: 0,
        patientId: '202410190001',
        expiryDate: futureDate,
      );
      expect(activeUser.isExpired, isFalse);

      final expiredUser = UserModel(
        id: 'u2',
        fullname: 'Expired User',
        deviceId: '',
        idcard: '',
        password: '',
        token: '',
        role: 'patient',
        phoneNumber: '',
        ispayment: false,
        totalPayment: 0,
        patientId: '202410190002',
        expiryDate: pastDate,
      );
      expect(expiredUser.isExpired, isTrue);

      final statusExpiredUser = UserModel(
        id: 'u3',
        fullname: 'Status Expired User',
        deviceId: '',
        idcard: '',
        password: '',
        token: '',
        role: 'patient',
        phoneNumber: '',
        ispayment: false,
        totalPayment: 0,
        patientId: '202410190003',
        cardStatus: 'Expired',
      );
      expect(statusExpiredUser.isExpired, isTrue);
    });

    test('AuthRoutingService: Case A - Active & Valid Card routes to chatRoom without payment screen', () {
      final activeCardPatient = UserModel(
        id: 'p_active',
        fullname: 'Active Patient',
        deviceId: 'dev1',
        idcard: '111',
        password: 'pass',
        token: 'tok',
        role: 'patient',
        phoneNumber: '+923001111111',
        ispayment: false,
        totalPayment: 0,
        paymentImage: null, // Note: No payment proof uploaded, because card was issued offline/card
        patientId: '202410190001',
        expiryDate: DateTime.now().add(const Duration(days: 60)),
      );

      final destination = AuthRoutingService.evaluatePatientDestination(activeCardPatient);
      expect(destination, equals(PatientAuthDestination.chatRoom));
    });

    test('AuthRoutingService: Case B - Expired Card routes to cardExpired (renewal screen)', () {
      final expiredCardPatient = UserModel(
        id: 'p_expired',
        fullname: 'Expired Patient',
        deviceId: 'dev2',
        idcard: '222',
        password: 'pass',
        token: 'tok',
        role: 'patient',
        phoneNumber: '+923002222222',
        ispayment: false,
        totalPayment: 0,
        patientId: '202410190002',
        expiryDate: DateTime.now().subtract(const Duration(days: 5)),
      );

      final destination = AuthRoutingService.evaluatePatientDestination(expiredCardPatient);
      expect(destination, equals(PatientAuthDestination.cardExpired));
    });

    test('AuthRoutingService: Case C - Regular Non-Card Patient without paymentImage routes to paymentProof', () {
      final regularUnpaidPatient = UserModel(
        id: 'p_regular_unpaid',
        fullname: 'Regular Unpaid Patient',
        deviceId: 'dev3',
        idcard: '333',
        password: 'pass',
        token: 'tok',
        role: 'patient',
        phoneNumber: '+923003333333',
        ispayment: false,
        totalPayment: 0,
        paymentImage: null,
      );

      final destination = AuthRoutingService.evaluatePatientDestination(regularUnpaidPatient);
      expect(destination, equals(PatientAuthDestination.paymentProof));
    });

    test('AuthRoutingService: Regular Patient with submitted paymentImage routes to chatRoom', () {
      final regularPaidPatient = UserModel(
        id: 'p_regular_paid',
        fullname: 'Regular Paid Patient',
        deviceId: 'dev4',
        idcard: '444',
        password: 'pass',
        token: 'tok',
        role: 'patient',
        phoneNumber: '+923004444444',
        ispayment: true,
        totalPayment: 500,
        paymentImage: 'https://cloudinary.com/proof.jpg',
        paymentStatus: 'approved',
      );

      final destination = AuthRoutingService.evaluatePatientDestination(regularPaidPatient);
      expect(destination, equals(PatientAuthDestination.chatRoom));
    });
  });
}
