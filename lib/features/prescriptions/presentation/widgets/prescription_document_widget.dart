import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/data/models/prescription_model.dart';

/// Professional on-screen document renderer that matches the official
/// OPD Telemedicine prescription design.
///
/// Design rules:
/// - Pure white medical paper look
/// - OPD navy & blue brand palette (#062B72, #163B6E)
/// - Doctor credentials fetched dynamically
/// - Patient metadata (Name, Date, Age, Gender, Ref)
/// - Prominent Rx symbol
/// - Structured medicines and verbatim written notes
/// - Additional advice and follow-up
/// - Explicitly NO signature line or section
class PrescriptionDocumentWidget extends StatelessWidget {
  final PrescriptionModel prescription;

  const PrescriptionDocumentWidget({super.key, required this.prescription});

  static const Color opdNavy = Color(0xFF062B72);
  static const Color opdBlue = Color(0xFF163B6E);
  static const Color opdTextDark = Color(0xFF1F2F44);
  static const Color opdTextMuted = Color(0xFF5E7188);
  static const Color opdBorder = Color(0xFFD8E3EF);
  static const Color opdLightBg = Color(0xFFF4F8FC);
  static const Color opdRowAlt = Color(0xFFFAFCFE);

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat('dd MMM yyyy');
    final formattedDate = dateFormat.format(prescription.createdAt);

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: opdBorder, width: 1.2),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0F233C).withValues(alpha: 0.08),
            blurRadius: 20,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      padding: EdgeInsets.all(context.rsp(18)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(context),
          const SizedBox(height: 12),
          _buildDivider(),
          const SizedBox(height: 14),
          _buildPatientInfoBox(context, formattedDate),
          const SizedBox(height: 18),
          _buildRxLine(context),
          const SizedBox(height: 12),

          // Structured Medicines (if available)
          if (prescription.hasMedicines) ...[
            _buildMedicinesSection(context),
            const SizedBox(height: 16),
          ],

          // Written prescription notes (if available)
          if (prescription.note.trim().isNotEmpty) ...[
            _buildTextSection(
              context: context,
              title: prescription.hasMedicines
                  ? 'General Prescription / Instructions'
                  : 'Prescription & Directions',
              content: prescription.note.trim(),
            ),
            const SizedBox(height: 14),
          ],

          // Additional advice (if available)
          if (prescription.advice.trim().isNotEmpty) ...[
            _buildTextSection(
              context: context,
              title: 'Additional Medical Advice',
              content: prescription.advice.trim(),
            ),
            const SizedBox(height: 14),
          ],

          // Follow-up instructions (if available)
          if (prescription.followUp.trim().isNotEmpty) ...[
            _buildFollowUpBox(context, prescription.followUp.trim()),
            const SizedBox(height: 16),
          ],

          const SizedBox(height: 10),
          _buildFooter(context),
        ],
      ),
    );
  }

  /// Top Document Header with OPD Logo and Doctor Credentials.
  Widget _buildHeader(BuildContext context) {
    final doctorName = prescription.doctorName.trim();
    final degree = prescription.doctorQualification.trim();
    final specialty = prescription.doctorSpecialty.trim();

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // OPD Telemedicine Logo
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: opdLightBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: opdBorder),
          ),
          padding: const EdgeInsets.all(4),
          child: Image.asset(
            'assets/images/opd online.png',
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => const Icon(
              Icons.medical_services_rounded,
              color: opdNavy,
              size: 26,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'OPD TELEMEDICINE',
                style: TextStyle(
                  fontSize: context.fs(13),
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.6,
                  color: opdNavy,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'Official Medical Consultation',
                style: TextStyle(
                  fontSize: context.fs(10.5),
                  color: opdTextMuted,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        // Doctor Information
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              'Dr. $doctorName',
              style: TextStyle(
                fontSize: context.fs(14),
                fontWeight: FontWeight.w700,
                color: opdNavy,
              ),
            ),
            if (degree.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                degree,
                style: TextStyle(
                  fontSize: context.fs(11),
                  fontWeight: FontWeight.w600,
                  color: opdBlue,
                ),
              ),
            ],
            if (specialty.isNotEmpty) ...[
              const SizedBox(height: 1),
              Text(
                specialty,
                style: TextStyle(
                  fontSize: context.fs(10.5),
                  color: opdTextMuted,
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildDivider() {
    return Container(
      height: 2.5,
      decoration: BoxDecoration(
        color: opdNavy,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }

  /// Patient Information Box.
  Widget _buildPatientInfoBox(BuildContext context, String formattedDate) {
    final patientName = prescription.patientName.trim().isEmpty
        ? 'Patient'
        : prescription.patientName.trim();
    final age = prescription.patientAge.trim().isEmpty
        ? '—'
        : '${prescription.patientAge.trim()} Yrs';
    final gender = prescription.patientGender.trim().isEmpty
        ? '—'
        : prescription.patientGender.trim();

    return Container(
      padding: EdgeInsets.symmetric(horizontal: context.rsp(14), vertical: 10),
      decoration: BoxDecoration(
        color: opdLightBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: opdBorder, width: 0.9),
      ),
      child: Wrap(
        spacing: context.rsp(16),
        runSpacing: 8,
        alignment: WrapAlignment.spaceBetween,
        children: [
          _buildInfoItem(context, 'PATIENT NAME', patientName, isPrimary: true),
          _buildInfoItem(context, 'DATE', formattedDate),
          _buildInfoItem(context, 'AGE', age),
          _buildInfoItem(context, 'GENDER', gender),
          _buildInfoItem(context, 'REF ID', prescription.reference),
        ],
      ),
    );
  }

  Widget _buildInfoItem(
    BuildContext context,
    String label,
    String value, {
    bool isPrimary = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: context.fs(9),
            fontWeight: FontWeight.w700,
            color: opdTextMuted,
            letterSpacing: 0.4,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            fontSize: context.fs(isPrimary ? 12.5 : 11.5),
            fontWeight: isPrimary ? FontWeight.w700 : FontWeight.w600,
            color: opdTextDark,
          ),
        ),
      ],
    );
  }

  /// Stylized Rx Header Line.
  Widget _buildRxLine(BuildContext context) {
    return Row(
      children: [
        Text(
          'Rx',
          style: TextStyle(
            fontSize: context.fs(22),
            fontWeight: FontWeight.w900,
            fontStyle: FontStyle.italic,
            color: opdNavy,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(child: Container(height: 1, color: opdBorder)),
      ],
    );
  }

  /// Structured Medicines Table.
  Widget _buildMedicinesSection(BuildContext context) {
    final validMeds = prescription.medicines
        .where((m) => m.isNotEmpty)
        .toList();
    if (validMeds.isEmpty) return const SizedBox.shrink();

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: opdBorder, width: 0.9),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          // Header Row
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: opdNavy,
            child: Row(
              children: [
                SizedBox(
                  width: 24,
                  child: Text(
                    '#',
                    style: TextStyle(
                      fontSize: context.fs(10),
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
                Expanded(
                  flex: 4,
                  child: Text(
                    'Medicine & Strength',
                    style: TextStyle(
                      fontSize: context.fs(10),
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    'Dosage',
                    style: TextStyle(
                      fontSize: context.fs(10),
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    'Frequency',
                    style: TextStyle(
                      fontSize: context.fs(10),
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    'Duration',
                    style: TextStyle(
                      fontSize: context.fs(10),
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: Text(
                    'Instructions',
                    style: TextStyle(
                      fontSize: context.fs(10),
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Medicine items
          for (var i = 0; i < validMeds.length; i++) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              color: i % 2 == 1 ? opdRowAlt : Colors.white,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 24,
                    child: Text(
                      '${i + 1}.',
                      style: TextStyle(
                        fontSize: context.fs(10.5),
                        fontWeight: FontWeight.w600,
                        color: opdTextMuted,
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 4,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          validMeds[i].name,
                          style: TextStyle(
                            fontSize: context.fs(12),
                            fontWeight: FontWeight.w700,
                            color: opdTextDark,
                          ),
                        ),
                        if (validMeds[i].strength.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            validMeds[i].strength,
                            style: TextStyle(
                              fontSize: context.fs(10),
                              fontWeight: FontWeight.w600,
                              color: opdBlue,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text(
                      validMeds[i].dosage.isEmpty ? '—' : validMeds[i].dosage,
                      style: TextStyle(
                        fontSize: context.fs(11),
                        color: opdTextDark,
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text(
                      validMeds[i].frequency.isEmpty
                          ? '—'
                          : validMeds[i].frequency,
                      style: TextStyle(
                        fontSize: context.fs(11),
                        color: opdTextDark,
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text(
                      validMeds[i].duration.isEmpty
                          ? '—'
                          : validMeds[i].duration,
                      style: TextStyle(
                        fontSize: context.fs(11),
                        color: opdTextDark,
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: Text(
                      validMeds[i].instructions.isEmpty
                          ? '—'
                          : validMeds[i].instructions,
                      style: TextStyle(
                        fontSize: context.fs(11),
                        color: opdTextDark,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (i < validMeds.length - 1)
              const Divider(height: 1, thickness: 0.6, color: opdBorder),
          ],
        ],
      ),
    );
  }

  /// Section container for multiline notes / general advice.
  Widget _buildTextSection({
    required BuildContext context,
    required String title,
    required String content,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: opdRowAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: opdBorder, width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: context.fs(11.5),
              fontWeight: FontWeight.w700,
              color: opdNavy,
            ),
          ),
          const SizedBox(height: 6),
          SelectableText(
            content,
            style: TextStyle(
              fontSize: context.fs(12.5),
              height: 1.6,
              color: opdTextDark,
            ),
          ),
        ],
      ),
    );
  }

  /// Follow-up instructions banner.
  Widget _buildFollowUpBox(BuildContext context, String followUp) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: opdLightBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: opdNavy, width: 1.2),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.event_repeat_rounded, size: 18, color: opdNavy),
          const SizedBox(width: 8),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: TextStyle(fontSize: context.fs(12), color: opdTextDark),
                children: [
                  const TextSpan(
                    text: 'Follow-up Advice: ',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: opdNavy,
                    ),
                  ),
                  TextSpan(text: followUp),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Document Footer.
  /// Strict design rule: NO signature line or section.
  Widget _buildFooter(BuildContext context) {
    return Column(
      children: [
        const Divider(height: 1, thickness: 0.8, color: opdBorder),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'OPD Telemedicine • Ref: ${prescription.reference}',
              style: TextStyle(
                fontSize: context.fs(9.5),
                color: opdTextMuted,
                fontWeight: FontWeight.w500,
              ),
            ),
            Text(
              'Computer Generated Document',
              style: TextStyle(
                fontSize: context.fs(9),
                color: opdTextMuted,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
