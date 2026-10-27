// lib/features/reports/presentation/report_history/medical_history_item.dart
//
// A patient's Report History is the union of two independent record types:
//
//   • uploaded reports  (`reports`,   keyed by userId)
//   • prescriptions    (`prescriptions`, keyed by patientId)
//
// Both are real, separately stored records in Firestore. Rather than
// duplicating a prescription into the `reports` collection — which would create
// a second source of truth that could drift — Report History projects both
// collections into this one item type and sorts them together.
//
// [MedicalHistoryItem] deliberately carries the *source* model rather than a
// flattened copy of its fields, so the card can read exactly what it needs
// (`prescription.note`, `report.fileUrl`, …) and so the type system guarantees
// a prescription row can never be handed a report action or vice versa.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/features/auth/presentation/providers/user_provider.dart';
import 'package:telemedicine/data/models/prescription_model.dart';
import 'package:telemedicine/data/models/report_model.dart';
import 'package:telemedicine/features/doctor_portal/presentation/prescriptions/prescription_controller.dart';
import 'package:telemedicine/features/reports/presentation/report_controller/report_controller.dart';

enum MedicalHistoryKind { report, prescription }

@immutable
class MedicalHistoryItem {
  /// Firestore document id of the underlying record.
  final String id;
  final MedicalHistoryKind kind;

  /// Row heading — the report type, or "Prescription".
  final String title;

  /// Who issued it. Empty for a patient-uploaded report (the patient is the
  /// author), the doctor's name for a prescription.
  final String issuerName;

  /// The note / description body shown as the preview.
  final String description;

  /// When the record was created. Used both for display and for ordering.
  final DateTime date;

  /// Exactly one of these is non-null, matching [kind].
  final ReportModel? report;
  final PrescriptionModel? prescription;

  const MedicalHistoryItem._({
    required this.id,
    required this.kind,
    required this.title,
    required this.issuerName,
    required this.description,
    required this.date,
    this.report,
    this.prescription,
  });

  factory MedicalHistoryItem.fromReport(ReportModel report) {
    return MedicalHistoryItem._(
      id: report.id,
      kind: MedicalHistoryKind.report,
      title: report.reportType,
      issuerName: '',
      description: report.description,
      // `uploadDate` is the list's existing sort key for reports; keep using it
      // so merged ordering matches the order the screen had before.
      date: report.uploadDate,
      report: report,
    );
  }

  factory MedicalHistoryItem.fromPrescription(PrescriptionModel prescription) {
    return MedicalHistoryItem._(
      id: prescription.prescriptionId,
      kind: MedicalHistoryKind.prescription,
      title: 'Prescription',
      issuerName: prescription.doctorName,
      description: prescription.note,
      date: prescription.createdAt,
      prescription: prescription,
    );
  }

  bool get isPrescription => kind == MedicalHistoryKind.prescription;

  /// Only a report has a file behind it. A prescription must never be routed
  /// through the file downloader — there is no URL to open.
  String get fileUrl => report?.fileUrl ?? '';

  IconData get icon {
    if (isPrescription) return Icons.medical_information_rounded;
    return ReportType.fromString(title).icon;
  }

  /// Matches the free-text search over the visible fields.
  bool matches(String rawQuery) {
    final query = rawQuery.trim().toLowerCase();
    if (query.isEmpty) return true;
    return title.toLowerCase().contains(query) ||
        description.toLowerCase().contains(query) ||
        issuerName.toLowerCase().contains(query);
  }
}

/// Merged, realtime history for the signed-in patient.
///
/// Both underlying queries are realtime snapshots, so a prescription saved by a
/// doctor lands in the patient's Report History without a refresh, a reopen or
/// an app restart.
final medicalHistoryProvider =
    StreamProvider.autoDispose<List<MedicalHistoryItem>>((ref) {
      final userId = ref.watch(userProvider.select((user) => user?.id));
      if (userId == null || userId.isEmpty) {
        return Stream.value(const <MedicalHistoryItem>[]);
      }

      final reportController = ref.read(reportControllerProvider);
      final prescriptionController = ref.read(prescriptionControllerProvider);

      final controller = StreamController<List<MedicalHistoryItem>>();
      var reportItems = const <ReportModel>[];
      var prescriptionItems = const <PrescriptionModel>[];

      void emit() {
        if (controller.isClosed) return;
        final merged = <MedicalHistoryItem>[
          ...reportItems.map(MedicalHistoryItem.fromReport),
          ...prescriptionItems.map(MedicalHistoryItem.fromPrescription),
        ]..sort((a, b) => b.date.compareTo(a.date));
        controller.add(merged);
      }

      // One bad source must not blank the whole screen: each is subscribed with
      // its own error handler, and whatever did load is still shown.
      void onError(Object error, StackTrace stackTrace, String source) {
        debugPrint('Medical history: $source stream error — $error');
      }

      // Emit an initial (possibly empty) merge: without this, if BOTH sources
      // errored before their first event, `emit()` never ran and this stream
      // produced nothing at all — Report History sat on its loading spinner
      // forever with no error and no empty state.
      emit();

      final reportSub = reportController.getUserReports().listen((items) {
        reportItems = items;
        emit();
      }, onError: (Object e, StackTrace s) => onError(e, s, 'reports'));

      final prescriptionSub = prescriptionController
          .streamForPatient(userId)
          .listen(
            (items) {
              prescriptionItems = items;
              emit();
            },
            onError: (Object e, StackTrace s) => onError(e, s, 'prescriptions'),
          );

      controller.onCancel = () async {
        await reportSub.cancel();
        await prescriptionSub.cancel();
      };

      return controller.stream;
    });
