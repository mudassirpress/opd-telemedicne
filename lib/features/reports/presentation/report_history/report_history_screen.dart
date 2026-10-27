import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:telemedicine/features/reports/presentation/report_controller/report_controller.dart';
import 'package:telemedicine/features/reports/presentation/report_history/medical_history_item.dart';
import 'package:telemedicine/features/reports/presentation/share_report_screen/share_report_screen.dart';
import 'package:telemedicine/features/reports/presentation/patient_shared_reports/patient_shared_reports_screen.dart';
import 'package:telemedicine/data/models/prescription_model.dart';
import 'package:telemedicine/features/auth/presentation/providers/user_provider.dart';
import 'package:telemedicine/features/doctor_portal/presentation/prescriptions/prescription_detail_screen.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/shared/widgets/auth_layout.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:open_file/open_file.dart';

class ReportHistoryScreen extends ConsumerStatefulWidget {
  const ReportHistoryScreen({super.key});

  @override
  ConsumerState<ReportHistoryScreen> createState() =>
      _ReportHistoryScreenState();
}

class _ReportHistoryScreenState extends ConsumerState<ReportHistoryScreen> {
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  bool _isDownloading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Loads the merged history (reports + prescriptions).
  ///
  /// The list is driven by a live stream now, so this no longer performs a
  /// one-shot read — a prescription saved by a doctor appears here without the
  /// patient pulling to refresh or reopening the app. It is retained as the
  /// pull-to-refresh callback purely to give the spinner something to await;
  /// the subscription is already current, so there is nothing to re-fetch.
  Future<void> _loadReports() async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }

  Future<void> _viewReport(String fileUrl, String reportType) async {
    try {
      ToastService.instance.showInfo('Opening file...');

      final Uri url = Uri.parse(fileUrl);

      if (fileUrl.startsWith('http://') || fileUrl.startsWith('https://')) {
        if (reportType.toLowerCase().contains('blood') ||
            reportType.toLowerCase().contains('x-ray') ||
            reportType.toLowerCase().contains('mri') ||
            reportType.toLowerCase().contains('ct scan') ||
            reportType.toLowerCase().contains('ultrasound')) {
          if (await canLaunchUrl(url)) {
            await launchUrl(url, mode: LaunchMode.externalApplication);
          } else {
            await _downloadAndOpenFile(fileUrl);
          }
        } else {
          await _downloadAndOpenFile(fileUrl);
        }
      } else {
        if (await canLaunchUrl(url)) {
          await launchUrl(url, mode: LaunchMode.externalApplication);
        } else {
          ToastService.instance.showError('Cannot open this file');
        }
      }
    } catch (e) {
      print('Error opening file: $e');
      ToastService.instance.showError('Error opening file: ${e.toString()}');
    }
  }

  Future<void> _downloadAndOpenFile(String fileUrl) async {
    if (_isDownloading) return;

    setState(() {
      _isDownloading = true;
    });

    try {
      ToastService.instance.showInfo('Downloading file...');

      final Uri url = Uri.parse(fileUrl);
      final response = await http.get(url);

      if (response.statusCode == 200) {
        final Directory tempDir = await getTemporaryDirectory();
        final String timestamp =
            DateTime.now().millisecondsSinceEpoch.toString();

        String fileExtension = 'pdf';
        if (fileUrl.contains('.jpg') || fileUrl.contains('.jpeg')) {
          fileExtension = 'jpg';
        } else if (fileUrl.contains('.png')) {
          fileExtension = 'png';
        } else if (fileUrl.contains('.gif')) {
          fileExtension = 'gif';
        }

        final String filePath =
            '${tempDir.path}/report_$timestamp.$fileExtension';
        final File file = File(filePath);
        await file.writeAsBytes(response.bodyBytes);

        final result = await OpenFile.open(filePath);

        if (result.type != ResultType.done) {
          ToastService.instance.showError('Could not open file');
        } else {
          ToastService.instance.showSuccess('File opened successfully');
        }
      } else {
        ToastService.instance.showError('Failed to download file');
      }
    } catch (e) {
      print('Error downloading file: $e');
      ToastService.instance.showError(
        'Error downloading file: ${e.toString()}',
      );
    } finally {
      if (mounted) {
        setState(() {
          _isDownloading = false;
        });
      }
    }
  }

  Future<void> _deleteReport(
    String reportId,
    ReportController controller,
  ) {
    return showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Text(
            'Delete Report',
            style: TextStyle(
              fontSize: context.fs(15),
              fontWeight: FontWeight.w700,
              color: const Color(0xFF1F2F44),
            ),
          ),
          content: Text(
            'Are you sure you want to delete this report? This action cannot be undone.',
            style: TextStyle(
              fontSize: context.fs(13.5),
              color: const Color(0xFF6B7B8D),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(
                'Cancel',
                style: TextStyle(
                  color: const Color(0xFF6B7B8D),
                ),
              ),
            ),
            TextButton(
              onPressed: () async {
                Navigator.pop(context);
                final success = await controller.deleteReport(reportId);
                if (success && mounted) {
                  ToastService.instance.showSuccess('Report deleted');
                  _loadReports();
                }
              },
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: Text(
                'Delete',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        );
      },
    );
  }

  String _formatDate(DateTime date) {
    return DateFormat('dd MMM yyyy').format(date);
  }

  /// Free-text filter over the merged list.
  ///
  /// Prescriptions are searchable by doctor name and note as well as by their
  /// "Prescription" title, so a patient can find a specific one.
  List<MedicalHistoryItem> _filterItems(List<MedicalHistoryItem> items) {
    return items.where((item) => item.matches(_searchQuery)).toList();
  }

  @override
  Widget build(BuildContext context) {
    final reportController = ref.read(reportControllerProvider);

    return Scaffold(
      backgroundColor: const Color(0xFFEDF2F8),
      body: Stack(
        children: [
          // ECG Watermark - Top Right (matching Sign In)
          Positioned(
            top: 20,
            right: 0,
            child: Opacity(
              opacity: 0.15,
              child: CustomPaint(
                size: const Size(240, 180),
                painter: ECGWatermarkPainter(),
              ),
            ),
          ),

          // Main Content
          SafeArea(
            child: Column(
              children: [
                // Top Bar with Back Button
                Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: context.rsp(18),
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      const CircularBackButton(),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Report History',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: context.fs(16),
                            fontWeight: FontWeight.w700,
                            color: const Color(0xFF1F2F44),
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(
                          Icons.folder_shared_rounded,
                          color: Color(0xFF062B72),
                        ),
                        tooltip: 'Shared Reports',
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) =>
                                const PatientSharedReportsScreen(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // Search Bar
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: context.rsp(18)),
                  child: MetallicInput(
                    hintText: 'Search reports, prescriptions or doctors...',
                    icon: Icons.search_rounded,
                    controller: _searchController,
                    validator: null,
                    // Wired to the merged list so a patient can find a
                    // prescription by doctor name or note text.
                    onChanged: (value) => setState(() => _searchQuery = value),
                  ),
                ),
                const SizedBox(height: 8),

                // Content
                Expanded(
                  child: _buildContent(reportController),
                ),

                
              ],
            ),
          ),

          // Loading overlay for download
          if (_isDownloading)
            Container(
              color: Colors.black.withValues(alpha: 0.5),
              child: const Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(color: Color(0xFF062B72)),
                    SizedBox(height: 16),
                    Text(
                      'Downloading file...',
                      style: TextStyle(color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
  Widget _buildContent(ReportController reportController) {
    // `medicalHistoryProvider` is a StreamProvider, so watching it already
    // yields the current value plus its loading/error state — no StreamBuilder
    // and no manual subscription needed.
    final history = ref.watch(medicalHistoryProvider);

    if (history.hasError && !history.hasValue) {
      return _buildErrorState(history.error.toString());
    }

    // Only show the blocking spinner before the first emission; after that an
    // empty list is a legitimate state, not a loading one.
    final items = history.value;
    if (items == null) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF062B72)),
      );
    }

    if (items.isEmpty) return _buildEmptyState();

    final visible = _filterItems(items);
    if (visible.isEmpty) return _buildNoSearchResults();

    return RefreshIndicator(
      onRefresh: _loadReports,
      color: const Color(0xFF062B72),
      child: ListView.builder(
        physics: const BouncingScrollPhysics(),
        padding: EdgeInsets.symmetric(horizontal: context.rsp(18), vertical: 8),
        itemCount: visible.length,
        itemBuilder: (context, index) =>
            _buildHistoryCard(visible[index], reportController),
      ),
    );
  }

  Widget _buildErrorState([String? message]) {
    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: context.rsp(18)),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.08),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.error_outline_rounded,
                size: 64,
                color: Colors.red.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Error loading reports',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: context.fs(16),
                fontWeight: FontWeight.w700,
                color: const Color(0xFF1F2F44),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message ?? _errorMessage ?? 'Something went wrong.',
              style: TextStyle(
                fontSize: context.fs(13.5),
                color: const Color(0xFF6B7B8D),
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            GradientButton(
              text: 'Retry',
              icon: Icons.refresh_rounded,
              onPressed: _loadReports,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: context.rsp(18)),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: const Color(0xFFD6E4F0).withValues(alpha: 0.4),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.folder_open_rounded,
                size: 80,
                color: const Color(0xFF062B72).withValues(alpha: 0.4),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'No reports or prescriptions yet',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: context.fs(16),
                fontWeight: FontWeight.w700,
                color: const Color(0xFF1F2F44),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Reports you upload and prescriptions your doctors send will '
              'both appear here.',
              style: TextStyle(
                fontSize: context.fs(13.5),
                color: const Color(0xFF6B7B8D),
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNoSearchResults() {
    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: context.rsp(18)),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: const Color(0xFFD6E4F0).withValues(alpha: 0.4),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.search_off_rounded,
                size: 80,
                color: const Color(0xFF062B72).withValues(alpha: 0.4),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'No Matching Reports',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: context.fs(16),
                fontWeight: FontWeight.w700,
                color: const Color(0xFF1F2F44),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Try adjusting your search terms',
              style: TextStyle(
                fontSize: context.fs(13.5),
                color: const Color(0xFF6B7B8D),
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  /// Dispatches to the right card for a merged history entry.
  Widget _buildHistoryCard(
    MedicalHistoryItem item,
    ReportController controller,
  ) {
    return item.isPrescription
        ? _buildPrescriptionCard(item)
        : _buildReportCard(item, controller);
  }

  /// Prescription row.
  ///
  /// Reuses the report card's visual language so the merged list reads as one
  /// surface, but the actions are different by necessity: a prescription has
  /// no file to forward and is a medical record the doctor owns, so it offers
  /// View only. Opening it goes to the same `PrescriptionDetailScreen` the chat
  /// prescription card uses, which re-validates that the viewer is the
  /// prescribing doctor or the patient the prescription was written for.
  Widget _buildPrescriptionCard(MedicalHistoryItem item) {
    final prescription = item.prescription!;
    final note = prescription.note.trim();

    return _buildCardShell(
      onTap: () => _viewPrescription(prescription),
      icon: item.icon,
      title: 'Prescription',
      subtitle: prescription.doctorName.isEmpty
          ? null
          : 'by ${prescription.doctorName}',
      date: prescription.createdAt,
      description: note.isEmpty ? null : note,
      dateLabel: 'Issued',
      trailing: _prescriptionTrailingActions(prescription),
    );
  }

  List<Widget> _prescriptionTrailingActions(PrescriptionModel prescription) {
    return [
      IconButton(
        icon: const Icon(
          Icons.visibility_rounded,
          size: 20,
          color: Color(0xFF062B72),
        ),
        constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
        onPressed: () => _viewPrescription(prescription),
        tooltip: 'View Prescription',
      ),
    ];
  }

  void _viewPrescription(PrescriptionModel prescription) {
    final viewer = ref.read(userProvider);
    if (viewer == null) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PrescriptionDetailScreen(
          prescriptionId: prescription.prescriptionId,
          viewerId: viewer.id,
          expectedDoctorId: prescription.doctorId,
          expectedPatientId: prescription.patientId,
        ),
      ),
    );
  }

  /// Shared visual shell for both card kinds so reports and prescriptions look
  /// like they belong to the same list.
  Widget _buildCardShell({
    required VoidCallback onTap,
    required IconData icon,
    required String title,
    required DateTime date,
    String? subtitle,
    String? description,
    String dateLabel = 'Uploaded',
    required List<Widget> trailing,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [
            Color(0xFFE3EAF2),
            Color(0xFFF5F8FC),
            Color(0xFFE2E9F2),
          ],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFBAC7D8), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0F233C).withValues(alpha: 0.08),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Container(
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [
              Color(0xFFF3F7FB),
              Colors.white,
              Color(0xFFF0F4F9),
            ],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFFD6E4F0).withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(icon, color: const Color(0xFF062B72), size: 24),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: context.fs(14.5),
                                fontWeight: FontWeight.w700,
                                color: const Color(0xFF1F2F44),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              subtitle ?? _formatDate(date),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: context.fs(12),
                                color: const Color(0xFF6B7B8D),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (description != null && description.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      description,
                      style: TextStyle(
                        fontSize: context.fs(13),
                        color: const Color(0xFF6B7B8D),
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const SizedBox(height: 12),
                  Container(height: 1, color: const Color(0xFFDCE6F2)),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Flexible(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              dateLabel == 'Issued'
                                  ? Icons.medical_information_outlined
                                  : Icons.upload_file_rounded,
                              size: 14,
                              color: const Color(0xFF8FA4BD),
                            ),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                _formatDate(date),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: context.fs(11),
                                  color: const Color(0xFF8FA4BD),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: trailing,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildReportCard(
    MedicalHistoryItem item,
    ReportController controller,
  ) {
    final report = item.report!;

    return _buildCardShell(
      onTap: () => _viewReport(report.fileUrl, report.reportType),
      icon: item.icon,
      title: report.reportType,
      subtitle: null,
      date: report.uploadDate,
      description: report.description,
      dateLabel: 'Uploaded',
      trailing: [
        IconButton(
          icon: const Icon(
            Icons.visibility_rounded,
            size: 20,
            color: Color(0xFF062B72),
          ),
          constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
          onPressed: () => _viewReport(report.fileUrl, report.reportType),
          tooltip: 'View Report',
        ),
        IconButton(
          icon: const Icon(
            Icons.reply_rounded,
            size: 22,
            color: Color(0xFF062B72),
          ),
          constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => ShareReportScreen(report: report)),
          ),
          tooltip: 'Forward Report',
        ),
        IconButton(
          icon: Icon(
            Icons.delete_outline_rounded,
            size: 20,
            color: Colors.red[400],
          ),
          constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
          onPressed: () => _deleteReport(report.id, controller),
          tooltip: 'Delete Report',
        ),
      ],
    );
  }
}
