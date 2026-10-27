// Tests for the merged Report History item.
//
// The merged list is the union of two Firestore collections, so the two things
// worth pinning are: (a) both kinds survive the merge and interleave by date,
// and (b) a prescription can never expose a report's file-backed fields, which
// is what would send a prescription row into the file downloader.

import 'package:flutter_test/flutter_test.dart';
import 'package:telemedicine/data/models/prescription_model.dart';
import 'package:telemedicine/data/models/report_model.dart';
import 'package:telemedicine/features/reports/presentation/report_history/medical_history_item.dart';

ReportModel report({
  required String id,
  required String type,
  required DateTime uploaded,
  String description = '',
}) {
  return ReportModel(
    id: id,
    userId: 'patient-1',
    reportType: type,
    description: description,
    fileUrl: 'https://example.com/$id.pdf',
    reportDate: uploaded,
    uploadDate: uploaded,
  );
}

PrescriptionModel prescription({
  required String id,
  required String doctor,
  required DateTime createdAt,
  String note = '',
}) {
  return PrescriptionModel(
    prescriptionId: id,
    doctorId: 'doctor-1',
    doctorName: doctor,
    patientId: 'patient-1',
    patientName: 'Patient One',
    note: note,
    createdAt: createdAt,
    chatId: 'patient-1_doctor-1',
  );
}

void main() {
  group('projection', () {
    test('a report keeps its file url and type, and has no issuer', () {
      final item = MedicalHistoryItem.fromReport(
        report(
          id: 'r1',
          type: 'Laboratory Test',
          uploaded: DateTime(2026, 3, 1),
          description: 'CBC',
        ),
      );

      expect(item.kind, MedicalHistoryKind.report);
      expect(item.isPrescription, isFalse);
      expect(item.title, 'Laboratory Test');
      expect(item.fileUrl, 'https://example.com/r1.pdf');
      expect(item.description, 'CBC');
      // A patient-uploaded report has no issuing doctor to show.
      expect(item.issuerName, isEmpty);
      expect(item.prescription, isNull);
      expect(item.report, isNotNull);
    });

    test(
      'a prescription carries the doctor, note and issue date, but no file',
      () {
        final item = MedicalHistoryItem.fromPrescription(
          prescription(
            id: 'p1',
            doctor: 'Dr. Ahmed',
            createdAt: DateTime(2026, 4, 2),
            note: 'Paracetamol 500mg twice daily',
          ),
        );

        expect(item.kind, MedicalHistoryKind.prescription);
        expect(item.isPrescription, isTrue);
        expect(item.title, 'Prescription');
        expect(item.issuerName, 'Dr. Ahmed');
        expect(item.description, 'Paracetamol 500mg twice daily');
        expect(item.date, DateTime(2026, 4, 2));
        // Critical: an empty fileUrl keeps the row out of the downloader, which
        // would otherwise Uri.parse('') and fail.
        expect(item.fileUrl, isEmpty);
        expect(item.report, isNull);
        expect(item.prescription, isNotNull);
      },
    );

    test('the two kinds project to distinct icons', () {
      final reportItem = MedicalHistoryItem.fromReport(
        report(id: 'r1', type: 'Laboratory Test', uploaded: DateTime(2026)),
      );
      final prescriptionItem = MedicalHistoryItem.fromPrescription(
        prescription(id: 'p1', doctor: 'Dr. Ahmed', createdAt: DateTime(2026)),
      );
      expect(reportItem.icon, isNot(prescriptionItem.icon));
    });
  });

  group('merging', () {
    test('interleaves both kinds newest first', () {
      final items = <MedicalHistoryItem>[
        MedicalHistoryItem.fromReport(
          report(id: 'r1', type: 'Radiology', uploaded: DateTime(2026, 1, 5)),
        ),
        MedicalHistoryItem.fromPrescription(
          prescription(
            id: 'p1',
            doctor: 'Dr. Ahmed',
            createdAt: DateTime(2026, 3, 9),
          ),
        ),
        MedicalHistoryItem.fromReport(
          report(
            id: 'r2',
            type: 'Medical Record',
            uploaded: DateTime(2026, 2, 2),
          ),
        ),
      ]..sort((a, b) => b.date.compareTo(a.date));

      expect(items.map((i) => i.id).toList(), ['p1', 'r2', 'r1']);
    });

    test('a prescription is not collapsed into a report — no duplication', () {
      // The prescription lives only in `prescriptions`. Projecting it must not
      // synthesise a report row for the same event.
      final source = [
        prescription(
          id: 'p1',
          doctor: 'Dr. Ahmed',
          createdAt: DateTime(2026, 3, 9),
        ),
      ];

      final merged = source
          .map(MedicalHistoryItem.fromPrescription)
          .toList(growable: false);

      expect(merged, hasLength(1));
      expect(merged.single.report, isNull);
      expect(merged.single.prescription?.prescriptionId, 'p1');
    });
  });

  group('search', () {
    final items = [
      MedicalHistoryItem.fromReport(
        report(
          id: 'r1',
          type: 'Laboratory Test',
          uploaded: DateTime(2026),
          description: 'Complete blood count',
        ),
      ),
      MedicalHistoryItem.fromPrescription(
        prescription(
          id: 'p1',
          doctor: 'Dr. Ahmed',
          createdAt: DateTime(2026),
          note: 'Paracetamol 500mg',
        ),
      ),
    ];

    test('an empty query matches everything', () {
      expect(items.every((i) => i.matches('')), isTrue);
      expect(items.every((i) => i.matches('   ')), isTrue);
    });

    test('matches report type and description', () {
      expect(items[0].matches('laboratory'), isTrue);
      expect(items[0].matches('blood count'), isTrue);
      expect(items[0].matches('paracetamol'), isFalse);
    });

    test('matches a prescription by doctor name and note', () {
      expect(items[1].matches('ahmed'), isTrue);
      expect(items[1].matches('paracetamol'), isTrue);
      expect(items[1].matches('prescription'), isTrue);
      expect(items[1].matches('radiology'), isFalse);
    });
  });
}
