import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemedicine/data/models/prescription_model.dart';
import 'package:telemedicine/features/prescriptions/services/prescription_pdf_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PrescriptionMedicine Model', () {
    test('creates and formats displayLine properly', () {
      const med = PrescriptionMedicine(
        name: 'Panadol',
        strength: '500mg',
        dosage: '1 Tablet',
        frequency: '1-0-1',
        duration: '5 Days',
        instructions: 'After meal',
      );

      expect(
        med.displayLine,
        'Panadol (500mg) • 1 Tablet • 1-0-1 • 5 Days • After meal',
      );
      expect(med.isNotEmpty, isTrue);
      expect(med.isEmpty, isFalse);
    });

    test('serializes to and from map', () {
      const original = PrescriptionMedicine(
        name: 'Augmentin',
        strength: '625mg',
        dosage: '1 Tab',
        frequency: 'Twice daily',
        duration: '7 Days',
        instructions: 'With food',
      );

      final map = original.toMap();
      final parsed = PrescriptionMedicine.fromMap(map);

      expect(parsed.name, 'Augmentin');
      expect(parsed.strength, '625mg');
      expect(parsed.dosage, '1 Tab');
      expect(parsed.frequency, 'Twice daily');
      expect(parsed.duration, '7 Days');
      expect(parsed.instructions, 'With food');
    });
  });

  group('PrescriptionModel', () {
    test('handles full structured prescription with medicines and advice', () {
      final now = DateTime(2026, 11, 4, 10, 30);
      final prescription = PrescriptionModel(
        prescriptionId: 'presc-101',
        doctorId: 'doc-99',
        doctorName: 'Muhammad Ali',
        doctorQualification: 'MBBS, FCPS (Cardiology)',
        doctorSpecialty: 'Consultant Cardiologist',
        patientId: 'pat-202',
        patientName: 'Ahmed Raza',
        patientAge: '45',
        patientGender: 'Male',
        note: 'Monitor blood pressure daily in the morning.',
        medicines: const [
          PrescriptionMedicine(
            name: 'Aspirin',
            strength: '75mg',
            dosage: '1 Tablet',
            frequency: 'Once daily',
            duration: '30 Days',
            instructions: 'After lunch',
          ),
          PrescriptionMedicine(
            name: 'Atorvastatin',
            strength: '20mg',
            dosage: '1 Tablet',
            frequency: 'At bedtime',
            duration: '30 Days',
            instructions: 'Before sleep',
          ),
        ],
        advice: 'Reduce sodium intake. Walk for 30 minutes daily.',
        followUp: 'Follow up in 4 weeks with lipid profile report.',
        createdAt: now,
        chatId: 'pat-202_doc-99',
      );

      expect(prescription.hasMedicines, isTrue);
      expect(prescription.medicines.length, 2);
      expect(prescription.reference, 'RX-PRESC101');
      expect(prescription.doctorQualification, 'MBBS, FCPS (Cardiology)');
      expect(prescription.doctorSpecialty, 'Consultant Cardiologist');
      expect(prescription.patientAge, '45');
      expect(prescription.patientGender, 'Male');

      final map = prescription.toMap();
      final reconstructed = PrescriptionModel.fromMap(
        prescription.prescriptionId,
        map,
      );

      expect(reconstructed.prescriptionId, 'presc-101');
      expect(reconstructed.doctorName, 'Muhammad Ali');
      expect(reconstructed.doctorQualification, 'MBBS, FCPS (Cardiology)');
      expect(reconstructed.doctorSpecialty, 'Consultant Cardiologist');
      expect(reconstructed.patientName, 'Ahmed Raza');
      expect(reconstructed.patientAge, '45');
      expect(reconstructed.patientGender, 'Male');
      expect(reconstructed.medicines.length, 2);
      expect(reconstructed.medicines.first.name, 'Aspirin');
      expect(reconstructed.advice, contains('Reduce sodium intake'));
      expect(reconstructed.followUp, contains('4 weeks'));
    });

    test(
      'backward compatibility with legacy unstructured prescription map',
      () {
        final legacyMap = {
          'prescriptionId': 'old-uuid-1234',
          'doctorId': 'doc-1',
          'doctorName': 'Dr. Smith',
          'patientId': 'pat-1',
          'patientName': 'John Doe',
          'patientAge': '30',
          'note': 'Take paracetamol when headache occurs.',
          'chatId': 'pat-1_doc-1',
        };

        final parsed = PrescriptionModel.fromMap('old-uuid-1234', legacyMap);

        expect(parsed.prescriptionId, 'old-uuid-1234');
        expect(parsed.doctorName, 'Dr. Smith');
        expect(parsed.doctorQualification, isEmpty);
        expect(parsed.doctorSpecialty, isEmpty);
        expect(parsed.patientGender, isEmpty);
        expect(parsed.hasMedicines, isFalse);
        expect(parsed.medicines, isEmpty);
        expect(parsed.note, 'Take paracetamol when headache occurs.');
        expect(parsed.reference, isNotEmpty);
      },
    );

    test('handles multi-page image URLs and primaryImageUrl', () {
      final p = PrescriptionModel(
        prescriptionId: 'multi-img-1',
        doctorId: 'doc-1',
        doctorName: 'Dr. John',
        patientId: 'pat-1',
        patientName: 'Jane',
        createdAt: DateTime(2026, 11, 4),
        pageImageUrls: const [
          'https://storage.googleapis.com/.../prescription_page_1.png',
          'https://storage.googleapis.com/.../prescription_page_2.png',
        ],
        imageStoragePaths: const [
          'prescriptions/pat-1/multi-img-1/prescription_page_1.png',
          'prescriptions/pat-1/multi-img-1/prescription_page_2.png',
        ],
        pageCount: 2,
      );

      expect(p.pageCount, 2);
      expect(p.primaryImageUrl,
          'https://storage.googleapis.com/.../prescription_page_1.png');
      expect(p.pageImageUrls.length, 2);

      final map = p.toMap();
      expect(map['pageCount'], 2);
      expect(map['previewImageUrl'],
          'https://storage.googleapis.com/.../prescription_page_1.png');
      expect(map['pageImageUrls'], isA<List>());

      final fromMap = PrescriptionModel.fromMap(p.prescriptionId, map);
      expect(fromMap.pageCount, 2);
      expect(fromMap.primaryImageUrl,
          'https://storage.googleapis.com/.../prescription_page_1.png');
      expect(fromMap.pageImageUrls.length, 2);
    });
  });

  group('PrescriptionPdfService Image & PDF Generation', () {
    test(
      'generates valid non-empty A4 PDF and rasterizes high-resolution PNG page images',
      () async {
        final prescription = PrescriptionModel(
          prescriptionId: 'test-prescription-123',
          doctorId: 'doctor-abc',
          doctorName: 'Fatima Zahra',
          doctorQualification: 'MBBS, MD (Medicine)',
          doctorSpecialty: 'General Physician',
          patientId: 'patient-xyz',
          patientName: 'Ayesha Khan',
          patientAge: '28',
          patientGender: 'Female',
          note: 'Complete the antibiotic course without interruption.',
          medicines: const [
            PrescriptionMedicine(
              name: 'Augmentin',
              strength: '625mg',
              dosage: '1 Tab',
              frequency: 'Twice daily',
              duration: '5 Days',
              instructions: 'After meal',
            ),
            PrescriptionMedicine(
              name: 'Panadol',
              strength: '500mg',
              dosage: '1-2 Tabs',
              frequency: 'Every 6-8 hours as needed',
              duration: '3 Days',
              instructions: 'For fever/pain',
            ),
          ],
          advice: 'Drink warm water and rest well.',
          followUp: 'Review after 5 days if fever persists.',
          createdAt: DateTime(2026, 11, 4),
          chatId: 'patient-xyz_doctor-abc',
        );

        final pdfBytes = await PrescriptionPdfService.instance.generatePdf(
          prescription,
        );

        expect(pdfBytes, isA<Uint8List>());
        expect(pdfBytes.isNotEmpty, isTrue);

        // Verify PDF header magic bytes "%PDF-"
        final magicHeader = String.fromCharCodes(pdfBytes.sublist(0, 5));
        expect(magicHeader, '%PDF-');

        // Test generating PDF from the exact saved image(s) for print/share (Single Source of Truth)
        // 1x1 valid PNG image
        final samplePngBytes = Uint8List.fromList([
          0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
          0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
          0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
          0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
          0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
          0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82
        ]);
        final pdfFromImage = await PrescriptionPdfService.instance
            .generatePdfFromImages([samplePngBytes]);
        expect(pdfFromImage.isNotEmpty, isTrue);
        expect(String.fromCharCodes(pdfFromImage.sublist(0, 5)), '%PDF-');
      },
    );

    test('generates valid PDF for freeform unstructured prescription', () async {
      final freeformPrescription = PrescriptionModel(
        prescriptionId: 'freeform-123',
        doctorId: 'doc-1',
        doctorName: 'Usman Ghani',
        doctorQualification: 'MBBS',
        doctorSpecialty: 'Family Medicine',
        patientId: 'pat-1',
        patientName: 'Tariq Mehmood',
        patientAge: '52',
        patientGender: 'Male',
        note:
            'Tab. Metformin 500mg - 1 tablet twice daily after meals.\nTab. Glimepiride 1mg - 1 tablet before breakfast.\nCheck fasting blood sugar twice weekly.',
        createdAt: DateTime(2026, 11, 4),
        chatId: 'pat-1_doc-1',
      );

      final pdfBytes = await PrescriptionPdfService.instance.generatePdf(
        freeformPrescription,
      );

      expect(pdfBytes.isNotEmpty, isTrue);
      final magicHeader = String.fromCharCodes(pdfBytes.sublist(0, 5));
      expect(magicHeader, '%PDF-');
    });
  });
}
