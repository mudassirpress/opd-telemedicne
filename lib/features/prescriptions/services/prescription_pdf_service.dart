import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';
import 'package:telemedicine/data/models/prescription_model.dart';

/// Professional PDF generator and sharing service for OPD Telemedicine prescriptions.
///
/// Features:
/// - Official branded layout with OPD Telemedicine logo
/// - Dynamic doctor credentials (name, highest degree, specialty)
/// - Patient metadata (name, date, age, gender, reference ID)
/// - Prominent Rx symbol
/// - Structured medicines table and verbatim written notes
/// - Additional medical advice and follow-up instructions
/// - Strict compliance: NO signature section or line
/// - Multi-page support with page numbers and consistent headers
class PrescriptionPdfService {
  PrescriptionPdfService._();
  static final PrescriptionPdfService instance = PrescriptionPdfService._();

  // OPD Brand Colors
  static const PdfColor opdNavy = PdfColor.fromInt(0xFF062B72);
  static const PdfColor opdBlue = PdfColor.fromInt(0xFF163B6E);
  static const PdfColor opdTextDark = PdfColor.fromInt(0xFF1F2F44);
  static const PdfColor opdTextMuted = PdfColor.fromInt(0xFF5B6E85);
  static const PdfColor opdBorder = PdfColor.fromInt(0xFFD6E2EF);
  static const PdfColor opdLightBg = PdfColor.fromInt(0xFFF4F8FC);
  static const PdfColor opdRowAlt = PdfColor.fromInt(0xFFFAFCFE);

  pw.MemoryImage? _cachedLogo;

  Future<pw.MemoryImage?> _loadLogoImage() async {
    if (_cachedLogo != null) return _cachedLogo;
    try {
      final bytes = await rootBundle.load('assets/images/opd online.png');
      _cachedLogo = pw.MemoryImage(bytes.buffer.asUint8List());
      return _cachedLogo;
    } catch (_) {
      try {
        final fallbackBytes = await rootBundle.load('assets/images/logo.jpeg');
        _cachedLogo = pw.MemoryImage(fallbackBytes.buffer.asUint8List());
        return _cachedLogo;
      } catch (_) {
        return null;
      }
    }
  }

  /// Generates a high-quality A4 PDF document for the given [prescription].
  Future<Uint8List> generatePdf(PrescriptionModel prescription) async {
    final pdf = pw.Document(
      title: 'Prescription - ${prescription.patientName}',
      author: 'Dr. ${prescription.doctorName}',
      creator: 'OPD Telemedicine',
      subject: 'Medical Prescription ${prescription.reference}',
    );

    final logo = await _loadLogoImage();
    final dateFormat = DateFormat('dd MMM yyyy');
    final formattedDate = dateFormat.format(prescription.createdAt);

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.symmetric(horizontal: 32, vertical: 32),
        header: (context) => _buildHeader(
          prescription: prescription,
          logo: logo,
          pageNumber: context.pageNumber,
        ),
        footer: (context) => _buildFooter(
          context: context,
          prescription: prescription,
        ),
        build: (context) => [
          pw.SizedBox(height: 12),
          _buildPatientInfoBox(
            prescription: prescription,
            date: formattedDate,
          ),
          pw.SizedBox(height: 16),
          _buildRxHeader(),
          pw.SizedBox(height: 8),

          // Structured medicines (if any)
          if (prescription.hasMedicines) ...[
            _buildMedicinesTable(prescription.medicines),
            pw.SizedBox(height: 14),
          ],

          // Written prescription notes (if any)
          if (prescription.note.trim().isNotEmpty) ...[
            _buildSection(
              title: prescription.hasMedicines
                  ? 'General Prescription / Instructions'
                  : 'Prescription & Directions',
              content: prescription.note.trim(),
            ),
            pw.SizedBox(height: 14),
          ],

          // Additional advice (if any)
          if (prescription.advice.trim().isNotEmpty) ...[
            _buildSection(
              title: 'Additional Medical Advice',
              content: prescription.advice.trim(),
            ),
            pw.SizedBox(height: 14),
          ],

          // Follow-up instructions (if any)
          if (prescription.followUp.trim().isNotEmpty) ...[
            _buildFollowUpBox(prescription.followUp.trim()),
            pw.SizedBox(height: 14),
          ],
        ],
      ),
    );

    return pdf.save();
  }

  /// Top Document Header with OPD Logo and Doctor Credentials.
  pw.Widget _buildHeader({
    required PrescriptionModel prescription,
    required pw.MemoryImage? logo,
    required int pageNumber,
  }) {
    final doctorName = prescription.doctorName.trim();
    final degree = prescription.doctorQualification.trim();
    final specialty = prescription.doctorSpecialty.trim();

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            // Left: OPD Telemedicine Logo & Branding
            pw.Row(
              children: [
                if (logo != null)
                  pw.Container(
                    height: 48,
                    width: 48,
                    margin: const pw.EdgeInsets.only(right: 10),
                    child: pw.Image(logo, fit: pw.BoxFit.contain),
                  ),
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      'OPD TELEMEDICINE',
                      style: pw.TextStyle(
                        fontSize: 14,
                        fontWeight: pw.FontWeight.bold,
                        color: opdNavy,
                        letterSpacing: 0.8,
                      ),
                    ),
                    pw.Text(
                      'Official Medical Consultation',
                      style: const pw.TextStyle(
                        fontSize: 8.5,
                        color: opdTextMuted,
                      ),
                    ),
                  ],
                ),
              ],
            ),

            // Right: Doctor Information Block
            pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.end,
              children: [
                pw.Text(
                  'Dr. $doctorName',
                  style: pw.TextStyle(
                    fontSize: 14,
                    fontWeight: pw.FontWeight.bold,
                    color: opdNavy,
                  ),
                ),
                if (degree.isNotEmpty)
                  pw.Text(
                    degree,
                    style: pw.TextStyle(
                      fontSize: 9.5,
                      fontWeight: pw.FontWeight.bold,
                      color: opdBlue,
                    ),
                  ),
                if (specialty.isNotEmpty)
                  pw.Text(
                    specialty,
                    style: const pw.TextStyle(
                      fontSize: 9,
                      color: opdTextMuted,
                    ),
                  ),
              ],
            ),
          ],
        ),
        pw.SizedBox(height: 8),
        pw.Container(
          height: 2.5,
          decoration: const pw.BoxDecoration(
            color: opdNavy,
            borderRadius: pw.BorderRadius.all(pw.Radius.circular(1.5)),
          ),
        ),
      ],
    );
  }

  /// Patient Information Grid Container.
  pw.Widget _buildPatientInfoBox({
    required PrescriptionModel prescription,
    required String date,
  }) {
    final patientName = prescription.patientName.trim().isEmpty
        ? 'Patient'
        : prescription.patientName.trim();
    final age = prescription.patientAge.trim().isEmpty
        ? '-'
        : '${prescription.patientAge.trim()} Yrs';
    final gender = prescription.patientGender.trim().isEmpty
        ? '-'
        : prescription.patientGender.trim();

    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: pw.BoxDecoration(
        color: opdLightBg,
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
        border: pw.Border.all(color: opdBorder, width: 0.8),
      ),
      child: pw.Row(
        children: [
          // Patient Name
          pw.Expanded(
            flex: 4,
            child: _buildInfoItem('PATIENT NAME', patientName, isPrimary: true),
          ),
          // Date
          pw.Expanded(
            flex: 3,
            child: _buildInfoItem('DATE', date),
          ),
          // Age
          pw.Expanded(
            flex: 2,
            child: _buildInfoItem('AGE', age),
          ),
          // Gender
          pw.Expanded(
            flex: 2,
            child: _buildInfoItem('GENDER', gender),
          ),
          // Ref ID
          pw.Expanded(
            flex: 3,
            child: _buildInfoItem('REF ID', prescription.reference),
          ),
        ],
      ),
    );
  }

  pw.Widget _buildInfoItem(String label, String value, {bool isPrimary = false}) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          label,
          style: pw.TextStyle(
            fontSize: 7.5,
            fontWeight: pw.FontWeight.bold,
            color: opdTextMuted,
            letterSpacing: 0.5,
          ),
        ),
        pw.SizedBox(height: 2),
        pw.Text(
          value,
          maxLines: 1,
          style: pw.TextStyle(
            fontSize: isPrimary ? 10.5 : 9.5,
            fontWeight: isPrimary ? pw.FontWeight.bold : pw.FontWeight.normal,
            color: opdTextDark,
          ),
        ),
      ],
    );
  }

  /// Prominent Rx symbol line.
  pw.Widget _buildRxHeader() {
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.center,
      children: [
        pw.Text(
          'Rx',
          style: pw.TextStyle(
            fontSize: 22,
            fontWeight: pw.FontWeight.bold,
            color: opdNavy,
            fontStyle: pw.FontStyle.italic,
          ),
        ),
        pw.SizedBox(width: 8),
        pw.Expanded(
          child: pw.Container(
            height: 0.8,
            color: opdBorder,
          ),
        ),
      ],
    );
  }

  /// Structured medicines table.
  pw.Widget _buildMedicinesTable(List<PrescriptionMedicine> medicines) {
    final validMeds = medicines.where((m) => m.isNotEmpty).toList();
    if (validMeds.isEmpty) return pw.SizedBox();

    return pw.Container(
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: opdBorder, width: 0.8),
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
      ),
      child: pw.Table(
        border: const pw.TableBorder(
          horizontalInside: pw.BorderSide(color: opdBorder, width: 0.5),
        ),
        columnWidths: const {
          0: pw.FlexColumnWidth(0.8), // S.No
          1: pw.FlexColumnWidth(4.0), // Medicine & Strength
          2: pw.FlexColumnWidth(2.0), // Dosage
          3: pw.FlexColumnWidth(2.2), // Frequency
          4: pw.FlexColumnWidth(2.0), // Duration
          5: pw.FlexColumnWidth(3.0), // Instructions
        },
        children: [
          // Table Header
          pw.TableRow(
            decoration: const pw.BoxDecoration(
              color: opdNavy,
              borderRadius: pw.BorderRadius.vertical(top: pw.Radius.circular(5)),
            ),
            children: [
              _buildTableCell('#', isHeader: true),
              _buildTableCell('Medicine & Strength', isHeader: true),
              _buildTableCell('Dosage', isHeader: true),
              _buildTableCell('Frequency', isHeader: true),
              _buildTableCell('Duration', isHeader: true),
              _buildTableCell('Instructions', isHeader: true),
            ],
          ),
          // Medicine Rows
          for (var i = 0; i < validMeds.length; i++) ...[
            pw.TableRow(
              decoration: pw.BoxDecoration(
                color: i % 2 == 1 ? opdRowAlt : PdfColors.white,
              ),
              children: [
                _buildTableCell('${i + 1}.', isMuted: true),
                pw.Padding(
                  padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(
                        validMeds[i].name,
                        style: pw.TextStyle(
                          fontSize: 9.5,
                          fontWeight: pw.FontWeight.bold,
                          color: opdTextDark,
                        ),
                      ),
                      if (validMeds[i].strength.isNotEmpty)
                        pw.Text(
                          validMeds[i].strength,
                          style: const pw.TextStyle(
                            fontSize: 8,
                            color: opdBlue,
                          ),
                        ),
                    ],
                  ),
                ),
                _buildTableCell(
                  validMeds[i].dosage.isEmpty ? '-' : validMeds[i].dosage,
                ),
                _buildTableCell(
                  validMeds[i].frequency.isEmpty ? '-' : validMeds[i].frequency,
                ),
                _buildTableCell(
                  validMeds[i].duration.isEmpty ? '-' : validMeds[i].duration,
                ),
                _buildTableCell(
                  validMeds[i].instructions.isEmpty ? '-' : validMeds[i].instructions,
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  pw.Widget _buildTableCell(
    String text, {
    bool isHeader = false,
    bool isMuted = false,
  }) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      child: pw.Text(
        text,
        style: pw.TextStyle(
          fontSize: isHeader ? 8.5 : 9,
          fontWeight: isHeader ? pw.FontWeight.bold : pw.FontWeight.normal,
          color: isHeader
              ? PdfColors.white
              : (isMuted ? opdTextMuted : opdTextDark),
        ),
      ),
    );
  }

  /// Clean section block for written prescription notes or advice.
  pw.Widget _buildSection({required String title, required String content}) {
    return pw.Container(
      width: double.infinity,
      padding: const pw.EdgeInsets.all(12),
      decoration: pw.BoxDecoration(
        color: opdRowAlt,
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
        border: pw.Border.all(color: opdBorder, width: 0.8),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            title,
            style: pw.TextStyle(
              fontSize: 10,
              fontWeight: pw.FontWeight.bold,
              color: opdNavy,
            ),
          ),
          pw.SizedBox(height: 6),
          pw.Text(
            content,
            style: const pw.TextStyle(
              fontSize: 9.5,
              lineSpacing: 2,
              color: opdTextDark,
            ),
          ),
        ],
      ),
    );
  }

  /// Follow-up instructions banner.
  pw.Widget _buildFollowUpBox(String followUp) {
    return pw.Container(
      width: double.infinity,
      padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: pw.BoxDecoration(
        color: opdLightBg,
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
        border: pw.Border.all(color: opdNavy, width: 1),
      ),
      child: pw.Row(
        children: [
          pw.Text(
            'Follow-up Advice: ',
            style: pw.TextStyle(
              fontSize: 9.5,
              fontWeight: pw.FontWeight.bold,
              color: opdNavy,
            ),
          ),
          pw.Expanded(
            child: pw.Text(
              followUp,
              style: const pw.TextStyle(
                fontSize: 9.5,
                color: opdTextDark,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Consistent page footer across all pages.
  /// Explicitly contains NO signature section or line.
  pw.Widget _buildFooter({
    required pw.Context context,
    required PrescriptionModel prescription,
  }) {
    return pw.Column(
      children: [
        pw.Container(height: 0.8, color: opdBorder),
        pw.SizedBox(height: 6),
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(
              'OPD Telemedicine | Official Digital Prescription | ${prescription.reference}',
              style: const pw.TextStyle(
                fontSize: 7.5,
                color: opdTextMuted,
              ),
            ),
            pw.Text(
              'Page ${context.pageNumber} of ${context.pagesCount}',
              style: const pw.TextStyle(
                fontSize: 7.5,
                color: opdTextMuted,
              ),
            ),
          ],
        ),
        pw.SizedBox(height: 2),
        pw.Align(
          alignment: pw.Alignment.centerLeft,
          child: pw.Text(
            'This is a computer generated medical document. No physical signature is required.',
            style: const pw.TextStyle(
              fontSize: 7,
              color: opdTextMuted,
            ),
          ),
        ),
      ],
    );
  }

  /// Generates a PNG preview image of the first page of the PDF document.
  Future<Uint8List?> generatePreviewImage(
    Uint8List pdfBytes, {
    double dpi = 144.0,
  }) async {
    try {
      await for (final page in Printing.raster(pdfBytes, pages: [0], dpi: dpi)) {
        return await page.toPng();
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  /// Generates PNG image bytes for every page of the prescription.
  ///
  /// High-resolution A4 rendering at 200 DPI for crystal clear text, viewing, and printing.
  Future<List<Uint8List>> generatePrescriptionPageImages(
    Uint8List pdfBytes, {
    double dpi = 200.0,
  }) async {
    final images = <Uint8List>[];
    try {
      await for (final page in Printing.raster(pdfBytes, dpi: dpi)) {
        final png = await page.toPng();
        images.add(png);
      }
    } catch (e) {
      debugPrint('⚠️ [PrescriptionPdfService] Rasterize pages error: $e');
    }
    return images;
  }

  /// Downloads raw image bytes from a list of URLs (with caching / fallback).
  Future<List<Uint8List>> loadImagesFromUrls(List<String> urls) async {
    final results = <Uint8List>[];
    for (final url in urls) {
      if (url.trim().isEmpty) continue;
      try {
        final response = await http.get(Uri.parse(url));
        if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
          results.add(response.bodyBytes);
        }
      } catch (e) {
        debugPrint('⚠️ [PrescriptionPdfService] Image download error: $e');
      }
    }
    return results;
  }

  /// Generates an A4 PDF directly from the saved prescription image(s), preserving
  /// the exact layout and aspect ratio without re-rendering a separate template.
  Future<Uint8List> generatePdfFromImages(List<Uint8List> imageBytesList) async {
    final pdf = pw.Document();
    for (final imageBytes in imageBytesList) {
      final image = pw.MemoryImage(imageBytes);
      pdf.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          margin: pw.EdgeInsets.zero,
          build: (context) {
            return pw.FullPage(
              ignoreMargins: true,
              child: pw.Center(
                child: pw.Image(image, fit: pw.BoxFit.contain),
              ),
            );
          },
        ),
      );
    }
    return pdf.save();
  }

  /// Saves the prescription image(s) to the local device and returns the saved files.
  Future<List<File>> savePrescriptionImages({
    required List<Uint8List> imageBytesList,
    required String reference,
    required String patientName,
  }) async {
    final dir = await getApplicationDocumentsDirectory();
    final sanitizedPatient = patientName.replaceAll(RegExp(r'\s+'), '_');
    final savedFiles = <File>[];

    for (int i = 0; i < imageBytesList.length; i++) {
      final pageNum = i + 1;
      final filename = imageBytesList.length == 1
          ? 'Prescription_${reference}_$sanitizedPatient.png'
          : 'Prescription_${reference}_${sanitizedPatient}_page_$pageNum.png';
      final file = File('${dir.path}/$filename');
      await file.writeAsBytes(imageBytesList[i], flush: true);
      savedFiles.add(file);
    }
    return savedFiles;
  }

  /// Shares the original saved prescription image(s) via WhatsApp / installed apps.
  Future<void> sharePrescriptionImages({
    required List<Uint8List> imageBytesList,
    required String reference,
    required String patientName,
    required String doctorName,
  }) async {
    final files = await savePrescriptionImages(
      imageBytesList: imageBytesList,
      reference: reference,
      patientName: patientName,
    );

    final xFiles = files.map((f) => XFile(f.path, mimeType: 'image/png')).toList();
    final subject = 'Medical Prescription - Dr. $doctorName';
    final text =
        'Prescription ($reference) for $patientName from Dr. $doctorName via OPD Telemedicine.';

    await Share.shareXFiles(
      xFiles,
      subject: subject,
      text: text,
    );
  }

  /// Prints the original prescription image(s) on A4 paper.
  Future<void> printPrescriptionImages({
    required List<Uint8List> imageBytesList,
    required String reference,
  }) async {
    final pdfBytes = await generatePdfFromImages(imageBytesList);
    await Printing.layoutPdf(
      onLayout: (_) async => pdfBytes,
      name: 'Prescription_$reference',
    );
  }

  /// Saves the PDF to the device's documents or cache directory and returns the File.
  Future<File> savePdfFile(
    PrescriptionModel prescription, [
    Uint8List? prebuiltBytes,
  ]) async {
    final bytes = prebuiltBytes ?? await generatePdf(prescription);
    final dir = await getApplicationDocumentsDirectory();
    final filename =
        'Prescription_${prescription.reference}_${prescription.patientName.replaceAll(RegExp(r'\s+'), '_')}.pdf';
    final file = File('${dir.path}/$filename');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  /// Shares the prescription PDF through WhatsApp, email, or other apps via `share_plus`.
  Future<void> sharePdf(
    PrescriptionModel prescription, [
    Uint8List? prebuiltBytes,
  ]) async {
    final file = await savePdfFile(prescription, prebuiltBytes);
    final subject = 'Medical Prescription - Dr. ${prescription.doctorName}';
    final text =
        'Prescription (${prescription.reference}) for ${prescription.patientName} from Dr. ${prescription.doctorName} via OPD Telemedicine.';

    await Share.shareXFiles(
      [XFile(file.path, mimeType: 'application/pdf', name: file.uri.pathSegments.last)],
      subject: subject,
      text: text,
    );
  }

  /// Opens the native print dialog or print preview.
  Future<void> printPdf(
    PrescriptionModel prescription, [
    Uint8List? prebuiltBytes,
  ]) async {
    final bytes = prebuiltBytes ?? await generatePdf(prescription);
    await Printing.layoutPdf(
      onLayout: (_) async => bytes,
      name: 'Prescription_${prescription.reference}',
    );
  }
}
