import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:telemedicine/features/auth/presentation/controllers/doctor_controller.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/data/models/report_model.dart';
import 'package:telemedicine/data/models/report_share_model.dart';
import 'package:telemedicine/features/reports/presentation/report_share_controller/report_share_controller.dart';
import 'package:telemedicine/shared/widgets/auth_layout.dart';

class DoctorSharedReportsScreen extends ConsumerStatefulWidget {
  const DoctorSharedReportsScreen({super.key});

  @override
  ConsumerState<DoctorSharedReportsScreen> createState() =>
      _DoctorSharedReportsScreenState();
}

class _DoctorSharedReportsScreenState
    extends ConsumerState<DoctorSharedReportsScreen> {
  bool _isDownloading = false;
  Stream<List<SharedReportModel>>? _sharesStream;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _sharesStream = null;
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _reload({
    required String doctorId,
    required bool showToast,
  }) async {
    if (showToast) {
      ToastService.instance.showInfo('Refreshing shared reports...');
    }
    setState(() {
      _sharesStream = ref
          .read(reportShareControllerProvider)
          .streamDoctorSharedReports(doctorId);
    });
  }

  Future<void> _openReport(SharedReportModel share) async {
    try {
      ToastService.instance.showInfo('Opening report...');

      final Uri url = Uri.parse(share.reportUrl);

      if (share.reportUrl.startsWith('http://') ||
          share.reportUrl.startsWith('https://')) {
        if (share.reportName.toLowerCase().contains('blood') ||
            share.reportName.toLowerCase().contains('x-ray') ||
            share.reportName.toLowerCase().contains('mri') ||
            share.reportName.toLowerCase().contains('ct scan') ||
            share.reportName.toLowerCase().contains('ultrasound')) {
          if (await canLaunchUrl(url)) {
            await launchUrl(url, mode: LaunchMode.externalApplication);
          } else {
            await _downloadAndOpenFile(share.reportUrl);
          }
        } else {
          await _downloadAndOpenFile(share.reportUrl);
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

    setState(() => _isDownloading = true);

    try {
      ToastService.instance.showInfo('Downloading report...');

      final Uri url = Uri.parse(fileUrl);
      final response = await http.get(url);

      if (response.statusCode == 200) {
        final Directory tempDir = await getTemporaryDirectory();
        final String timestamp = DateTime.now().millisecondsSinceEpoch
            .toString();

        String fileExtension = 'pdf';
        if (fileUrl.contains('.jpg') || fileUrl.contains('.jpeg')) {
          fileExtension = 'jpg';
        } else if (fileUrl.contains('.png')) {
          fileExtension = 'png';
        } else if (fileUrl.contains('.gif')) {
          fileExtension = 'gif';
        }

        final String filePath =
            '${tempDir.path}/shared_report_$timestamp.$fileExtension';
        final File file = File(filePath);
        await file.writeAsBytes(response.bodyBytes);

        final result = await OpenFile.open(filePath);

        if (result.type != ResultType.done) {
          ToastService.instance.showError('Could not open file');
        } else {
          ToastService.instance.showSuccess('Report opened successfully');
        }
      } else {
        ToastService.instance.showError('Failed to download report');
      }
    } catch (e) {
      print('Error downloading file: $e');
      ToastService.instance.showError(
        'Error downloading file: ${e.toString()}',
      );
    } finally {
      if (mounted) {
        setState(() => _isDownloading = false);
      }
    }
  }

  String _formatDate(DateTime date) {
    return DateFormat('dd MMM yyyy').format(date);
  }

  @override
  Widget build(BuildContext context) {
    final doctorController = ref.watch(doctorControllerProvider);
    final currentDoctor = doctorController.currentDoctor;
    final doctorId = currentDoctor?.id ?? '';

    return Scaffold(
      backgroundColor: const Color(0xFFEDF2F8),
      body: Stack(
        children: [
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
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: context.rsp(16),
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Shared Reports',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: context.fs(16),
                                fontWeight: FontWeight.w700,
                                color: const Color(0xFF1F2F44),
                              ),
                            ),
                            Text(
                              'Medical reports patients shared with you',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                color: const Color(0xFF657991),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: context.rsp(16)),
                  child: MetallicInput(
                    hintText: 'Search doctors by name...',
                    icon: Icons.search_rounded,
                    controller: _searchController,
                    validator: null,
                  ),
                ),
                const SizedBox(height: 4),
                Expanded(child: _buildContent(doctorId)),
              ],
            ),
          ),
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
                      'Downloading report...',
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

  Widget _buildContent(String doctorId) {
    if (doctorId.isEmpty) {
      return _buildMessage(
        icon: Icons.medical_information_outlined,
        title: 'Doctor sign-in required',
        subtitle: 'Please sign in as a doctor to view reports shared with you.',
        action: null,
      );
    }

    final stream =
        _sharesStream ??
        ref
            .read(reportShareControllerProvider)
            .streamDoctorSharedReports(doctorId);

    return StreamBuilder<List<SharedReportModel>>(
      stream: stream,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
            child: CircularProgressIndicator(color: Color(0xFF062B72)),
          );
        }

        if (snapshot.hasError) {
          return _buildMessage(
            icon: Icons.error_outline_rounded,
            title: 'Error loading shared reports',
            subtitle: snapshot.error.toString(),
            action: () => _reload(doctorId: doctorId, showToast: true),
          );
        }

        final shares = snapshot.data ?? const <SharedReportModel>[];

        final query = _searchQuery.toLowerCase();
        final filtered = query.isEmpty
            ? shares
            : shares.where((s) {
                final name = s.reportName.toLowerCase();
                final patient = s.patientName.toLowerCase();
                return name.contains(query) || patient.contains(query);
              }).toList();

        if (filtered.isEmpty) {
          return _buildMessage(
            icon: query.isEmpty
                ? Icons.folder_shared_outlined
                : Icons.search_off_rounded,
            title: query.isEmpty ? 'No shared reports yet' : 'No results found',
            subtitle: query.isEmpty
                ? 'Reports that patients share with you will appear here.'
                : 'No reports match your search for "$_searchQuery".',
            action: query.isEmpty
                ? () => _reload(doctorId: doctorId, showToast: true)
                : () {
                    _searchController.clear();
                    setState(() => _searchQuery = '');
                  },
          );
        }

        return RefreshIndicator(
          onRefresh: () => _reload(doctorId: doctorId, showToast: false),
          color: const Color(0xFF062B72),
          child: ListView.builder(
            physics: const BouncingScrollPhysics(),
            padding: EdgeInsets.symmetric(
              horizontal: context.rsp(20),
              vertical: 8,
            ),
            itemCount: filtered.length,
            itemBuilder: (context, index) {
              return _buildShareCard(filtered[index]);
            },
          ),
        );
      },
    );
  }

  Widget _buildMessage({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback? action,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
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
                icon,
                size: 64,
                color: const Color(0xFF062B72).withValues(alpha: 0.4),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: context.fs(15),
                fontWeight: FontWeight.w700,
                color: const Color(0xFF1F2F44),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: context.fs(13),
                color: const Color(0xFF6B7B8D),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildShareCard(SharedReportModel share) {
    final reportType = ReportType.fromString(share.reportName);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFE3EAF2), Color(0xFFF5F8FC), Color(0xFFE2E9F2)],
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
            colors: [Color(0xFFF3F7FB), Colors.white, Color(0xFFF0F4F9)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Padding(
          padding: EdgeInsets.all(context.rsp(16)),
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
                    child: Icon(
                      reportType.icon,
                      color: const Color(0xFF062B72),
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          share.reportName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: context.fs(14),
                            fontWeight: FontWeight.w700,
                            color: const Color(0xFF1F2F44),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _formatDate(share.reportDate),
                          style: TextStyle(
                            fontSize: 12,
                            color: const Color(0xFF6B7B8D),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Icon(
                    Icons.person_outline_rounded,
                    size: 14,
                    color: Color(0xFF062B72),
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      share.patientName,
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: context.fs(13),
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFF1F2F44),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              if (share.description.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  share.description,
                  style: TextStyle(
                    fontSize: 13,
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
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.upload_file_rounded,
                              size: 13,
                              color: Color(0xFF8FA4BD),
                            ),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                'Uploaded ${_formatDate(share.reportUploadDate)}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: const Color(0xFF8FA4BD),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            const Icon(
                              Icons.share_rounded,
                              size: 13,
                              color: Color(0xFF8FA4BD),
                            ),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                'Shared ${_formatDate(share.sharedAt)}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: const Color(0xFF8FA4BD),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(
                          Icons.visibility_rounded,
                          size: 20,
                          color: Color(0xFF062B72),
                        ),
                        onPressed: () => _openReport(share),
                        tooltip: 'View Report',
                      ),
                      IconButton(
                        icon: const Icon(
                          Icons.download_rounded,
                          size: 20,
                          color: Color(0xFF062B72),
                        ),
                        onPressed: () => _openReport(share),
                        tooltip: 'Download / Open',
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
