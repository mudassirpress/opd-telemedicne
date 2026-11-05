import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:open_file/open_file.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/data/models/prescription_model.dart';
import 'package:telemedicine/features/auth/presentation/providers/user_provider.dart';
import 'package:telemedicine/features/doctor_portal/presentation/prescriptions/prescription_controller.dart';
import 'package:telemedicine/features/doctor_portal/presentation/prescriptions/prescription_detail_screen.dart';
import 'package:telemedicine/features/prescriptions/services/prescription_pdf_service.dart';
import 'package:telemedicine/shared/widgets/auth_layout.dart';
import 'package:telemedicine/shared/widgets/opd_design_system.dart';

/// Patient Prescription History screen.
///
/// Gives patients direct access to all their prescriptions with options to
/// view, download PDF, and share via WhatsApp or other apps.
class PatientPrescriptionsScreen extends ConsumerStatefulWidget {
  const PatientPrescriptionsScreen({super.key});

  @override
  ConsumerState<PatientPrescriptionsScreen> createState() =>
      _PatientPrescriptionsScreenState();
}

class _PatientPrescriptionsScreenState
    extends ConsumerState<PatientPrescriptionsScreen> {
  Stream<List<PrescriptionModel>>? _stream;
  final Set<String> _processingIds = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initStream());
  }

  void _initStream() {
    final user = ref.read(userProvider);
    if (user == null || !mounted) return;
    setState(() {
      _stream = ref
          .read(prescriptionControllerProvider)
          .streamForPatient(user.id);
    });
  }

  void _openDetail(PrescriptionModel prescription) {
    final user = ref.read(userProvider);
    if (user == null) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PrescriptionDetailScreen(
          prescriptionId: prescription.prescriptionId,
          viewerId: user.id,
          expectedDoctorId: prescription.doctorId,
          expectedPatientId: prescription.patientId,
        ),
      ),
    );
  }

  Future<void> _downloadPdf(PrescriptionModel prescription) async {
    final id = prescription.prescriptionId;
    if (_processingIds.contains(id)) return;

    setState(() => _processingIds.add(id));
    try {
      final urls = prescription.pageImageUrls.isNotEmpty
          ? prescription.pageImageUrls
          : (prescription.primaryImageUrl.isNotEmpty
                ? [prescription.primaryImageUrl]
                : <String>[]);
      if (urls.isNotEmpty) {
        final bytes = await PrescriptionPdfService.instance.loadImagesFromUrls(
          urls,
        );
        if (bytes.isNotEmpty) {
          final files = await PrescriptionPdfService.instance
              .savePrescriptionImages(
                imageBytesList: bytes,
                reference: prescription.reference,
                patientName: prescription.patientName,
              );
          if (mounted && files.isNotEmpty) {
            ToastService.instance.showSuccess('Prescription saved to device');
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Saved: ${files.first.uri.pathSegments.last}'),
                action: SnackBarAction(
                  label: 'Open',
                  textColor: Colors.white,
                  onPressed: () => OpenFile.open(files.first.path),
                ),
                duration: const Duration(seconds: 5),
              ),
            );
            return;
          }
        }
      }
      final file = await PrescriptionPdfService.instance.savePdfFile(
        prescription,
      );
      if (!mounted) return;
      ToastService.instance.showSuccess('Prescription saved');

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Saved: ${file.uri.pathSegments.last}'),
          action: SnackBarAction(
            label: 'Open',
            textColor: Colors.white,
            onPressed: () => OpenFile.open(file.path),
          ),
          duration: const Duration(seconds: 5),
        ),
      );
    } catch (e) {
      if (mounted) {
        ToastService.instance.showError('Could not save prescription: $e');
      }
    } finally {
      if (mounted) setState(() => _processingIds.remove(id));
    }
  }

  Future<void> _sharePdf(PrescriptionModel prescription) async {
    final id = prescription.prescriptionId;
    if (_processingIds.contains(id)) return;

    setState(() => _processingIds.add(id));
    try {
      final urls = prescription.pageImageUrls.isNotEmpty
          ? prescription.pageImageUrls
          : (prescription.primaryImageUrl.isNotEmpty
                ? [prescription.primaryImageUrl]
                : <String>[]);
      if (urls.isNotEmpty) {
        final bytes = await PrescriptionPdfService.instance.loadImagesFromUrls(
          urls,
        );
        if (bytes.isNotEmpty) {
          await PrescriptionPdfService.instance.sharePrescriptionImages(
            imageBytesList: bytes,
            reference: prescription.reference,
            patientName: prescription.patientName,
            doctorName: prescription.doctorName,
          );
          return;
        }
      }
      await PrescriptionPdfService.instance.sharePdf(prescription);
    } catch (e) {
      if (mounted) {
        ToastService.instance.showError('Could not share prescription: $e');
      }
    } finally {
      if (mounted) setState(() => _processingIds.remove(id));
    }
  }

  @override
  Widget build(BuildContext context) {
    return OpdScreenShell(
      title: 'My Prescriptions',
      subtitle: 'View, download and share your official prescriptions.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [_buildBody()],
      ),
    );
  }

  Widget _buildBody() {
    if (_stream == null) {
      return const OpdInlineLoader(label: 'Loading prescriptions...');
    }

    return StreamBuilder<List<PrescriptionModel>>(
      stream: _stream,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const OpdInlineLoader(label: 'Loading prescriptions...');
        }
        if (snapshot.hasError) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const OpdEmptyState(
                icon: Icons.error_outline_rounded,
                title: 'Could not load prescriptions',
                subtitle: 'Please check your connection and try again.',
              ),
              const SizedBox(height: 20),
              GradientButton(
                text: 'Retry',
                icon: Icons.refresh_rounded,
                onPressed: _initStream,
              ),
            ],
          );
        }

        final prescriptions = snapshot.data ?? const [];
        if (prescriptions.isEmpty) {
          return const OpdEmptyState(
            icon: Icons.medical_services_outlined,
            title: 'No Prescriptions Yet',
            subtitle:
                'Official prescriptions issued by your doctors during consultations will be available here.',
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            OpdCounterChip(
              '${prescriptions.length} Prescription${prescriptions.length == 1 ? '' : 's'}',
            ),
            const SizedBox(height: 16),
            for (final p in prescriptions) ...[
              _buildPrescriptionCard(p),
              const SizedBox(height: 14),
            ],
          ],
        );
      },
    );
  }

  Widget _buildPrescriptionCard(PrescriptionModel p) {
    final isProcessing = _processingIds.contains(p.prescriptionId);
    final hasMeds = p.hasMedicines;
    final note = p.note.trim();

    return OpdCard(
      onTap: () => _openDetail(p),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 58,
                decoration: BoxDecoration(
                  color: const Color(0xFF062B72).withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFFD6E2EF)),
                ),
                clipBehavior: Clip.antiAlias,
                child: p.primaryImageUrl.isNotEmpty
                    ? Image.network(
                        p.primaryImageUrl,
                        fit: BoxFit.cover,
                        alignment: Alignment.topCenter,
                        errorBuilder: (_, __, ___) => const Center(
                          child: Icon(
                            Icons.description_rounded,
                            color: Color(0xFF062B72),
                            size: 22,
                          ),
                        ),
                      )
                    : const Center(
                        child: Icon(
                          Icons.description_rounded,
                          color: Color(0xFF062B72),
                          size: 22,
                        ),
                      ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Dr. ${p.doctorName}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: context.fs(15),
                        fontWeight: FontWeight.w700,
                        color: const Color(0xFF1F2F44),
                      ),
                    ),
                    if (p.doctorQualification.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        p.doctorQualification,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: context.fs(11.5),
                          fontWeight: FontWeight.w600,
                          color: const Color(0xFF163B6E),
                        ),
                      ),
                    ],
                    if (p.doctorSpecialty.isNotEmpty) ...[
                      const SizedBox(height: 1),
                      Text(
                        p.doctorSpecialty,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: context.fs(11),
                          color: const Color(0xFF7E90A6),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                DateFormat('dd MMM yyyy').format(p.createdAt),
                style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF7E90A6),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Medicines or Note Summary
          if (hasMeds) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: const Color(0xFFF4F8FC),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFDCE6F2)),
              ),
              child: Row(
                children: [
                  const Text(
                    'Rx ',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF062B72),
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      p.medicines.first.displayLine,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: context.fs(12),
                        fontWeight: FontWeight.w500,
                        color: const Color(0xFF1F2F44),
                      ),
                    ),
                  ),
                  if (p.medicines.length > 1)
                    Text(
                      ' +${p.medicines.length - 1} more',
                      style: TextStyle(
                        fontSize: context.fs(11),
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFF062B72),
                      ),
                    ),
                ],
              ),
            ),
          ] else if (note.isNotEmpty) ...[
            Text(
              note,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: context.fs(13),
                height: 1.4,
                color: const Color(0xFF657991),
              ),
            ),
          ],

          const SizedBox(height: 12),
          const Divider(height: 1, color: Color(0xFFE5EDF6)),
          const SizedBox(height: 8),

          // Action row: Ref ID on left, View, Download, Share on right
          Row(
            children: [
              Text(
                p.reference,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF163B6E),
                ),
              ),
              const Spacer(),
              if (isProcessing)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Color(0xFF062B72),
                  ),
                )
              else ...[
                IconButton(
                  onPressed: () => _openDetail(p),
                  icon: const Icon(Icons.visibility_rounded, size: 20),
                  color: const Color(0xFF062B72),
                  tooltip: 'View Prescription',
                  visualDensity: VisualDensity.compact,
                ),
                IconButton(
                  onPressed: () => _downloadPdf(p),
                  icon: const Icon(Icons.download_rounded, size: 20),
                  color: const Color(0xFF062B72),
                  tooltip: 'Download PDF',
                  visualDensity: VisualDensity.compact,
                ),
                IconButton(
                  onPressed: () => _sharePdf(p),
                  icon: const Icon(Icons.share_rounded, size: 20),
                  color: const Color(0xFF062B72),
                  tooltip: 'Share Prescription',
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
