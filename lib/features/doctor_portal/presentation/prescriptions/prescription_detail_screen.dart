import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_file/open_file.dart';
import 'package:telemedicine/core/services/firebase_storage_service.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/data/models/prescription_model.dart';
import 'package:telemedicine/features/doctor_portal/presentation/prescriptions/prescription_controller.dart';
import 'package:telemedicine/features/prescriptions/services/prescription_pdf_service.dart';
import 'package:telemedicine/shared/widgets/auth_layout.dart';
import 'package:telemedicine/shared/widgets/opd_design_system.dart';

/// Full-page professional prescription document viewer.
///
/// Single Source of Truth: Always displays the original high-resolution PNG image
/// generated at the time of prescription creation and stored in Firebase Storage.
/// Reachable from chat messages, consultation records, and prescription history.
class PrescriptionDetailScreen extends ConsumerStatefulWidget {
  final String prescriptionId;

  /// The signed-in user.
  final String viewerId;

  /// Fallback ids used to authorise the viewer when the stored record does not
  /// carry them.
  final String? expectedDoctorId;
  final String? expectedPatientId;

  const PrescriptionDetailScreen({
    super.key,
    required this.prescriptionId,
    required this.viewerId,
    this.expectedDoctorId,
    this.expectedPatientId,
  });

  @override
  ConsumerState<PrescriptionDetailScreen> createState() =>
      _PrescriptionDetailScreenState();
}

class _PrescriptionDetailScreenState
    extends ConsumerState<PrescriptionDetailScreen> {
  Object? _error;
  bool _loading = true;
  bool _isProcessing = false;
  PrescriptionModel? _prescription;
  int _currentPage = 0;
  late final PageController _pageController;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _load();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      var prescription = await ref
          .read(prescriptionControllerProvider)
          .fetchById(widget.prescriptionId);

      // If opening a legacy prescription that did not have page images saved yet,
      // generate and upload the permanent page PNG image(s) once so it is permanently
      // preserved as the image single source of truth.
      if (prescription != null &&
          prescription.pageImageUrls.isEmpty &&
          prescription.primaryImageUrl.isEmpty) {
        try {
          final pdfBytes = await PrescriptionPdfService.instance.generatePdf(
            prescription,
          );
          var pages = await PrescriptionPdfService.instance
              .generatePrescriptionPageImages(pdfBytes);
          if (pages.isEmpty) {
            final single = await PrescriptionPdfService.instance
                .generatePreviewImage(pdfBytes);
            if (single != null) pages = [single];
          }
          final pageUrls = <String>[];
          final paths = <String>[];
          for (int i = 0; i < pages.length; i++) {
            final res = await FirebaseStorageService.instance
                .uploadPrescriptionPageImage(
                  patientId: prescription.patientId,
                  prescriptionId: prescription.prescriptionId,
                  pageIndex: i,
                  pngBytes: pages[i],
                );
            if (res.downloadUrl.isNotEmpty) {
              pageUrls.add(res.downloadUrl);
              paths.add(res.storagePath);
            }
          }
          if (pageUrls.isNotEmpty) {
            await FirebaseFirestore.instance
                .collection('prescriptions')
                .doc(prescription.prescriptionId)
                .update({
                  'pageImageUrls': pageUrls,
                  'imageStoragePaths': paths,
                  'previewImageUrl': pageUrls.first,
                  'imageUrl': pageUrls.first,
                  'pageCount': pages.length,
                  'updatedAt': Timestamp.now(),
                });
            prescription = prescription.copyWith(
              pageImageUrls: pageUrls,
              imageStoragePaths: paths,
              previewImageUrl: pageUrls.first,
              pageCount: pages.length,
            );
          }
        } catch (e) {
          debugPrint(
            '⚠️ [PrescriptionDetailScreen] Auto-upgrade legacy image error: $e',
          );
        }
      }

      if (!mounted) return;
      setState(() {
        _prescription = prescription;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  /// Loads image bytes for the saved prescription images.
  Future<List<Uint8List>> _getPrescriptionImageBytes(
    PrescriptionModel p,
  ) async {
    final urls = p.pageImageUrls.isNotEmpty
        ? p.pageImageUrls
        : (p.primaryImageUrl.isNotEmpty ? [p.primaryImageUrl] : <String>[]);
    if (urls.isNotEmpty) {
      final downloaded = await PrescriptionPdfService.instance
          .loadImagesFromUrls(urls);
      if (downloaded.isNotEmpty) return downloaded;
    }
    // Fallback if network was interrupted: rasterize from original template
    final pdfBytes = await PrescriptionPdfService.instance.generatePdf(p);
    final raster = await PrescriptionPdfService.instance
        .generatePrescriptionPageImages(pdfBytes);
    if (raster.isNotEmpty) return raster;
    final single = await PrescriptionPdfService.instance.generatePreviewImage(
      pdfBytes,
    );
    return single != null ? [single] : <Uint8List>[];
  }

  /// Downloads the original saved PNG prescription image(s) to the device.
  Future<void> _downloadImage() async {
    final p = _prescription;
    if (p == null || _isProcessing) return;

    setState(() => _isProcessing = true);
    try {
      ToastService.instance.showInfo('Saving prescription image to device...');
      final bytesList = await _getPrescriptionImageBytes(p);
      if (bytesList.isEmpty) {
        throw Exception('Image bytes unavailable');
      }
      final files = await PrescriptionPdfService.instance
          .savePrescriptionImages(
            imageBytesList: bytesList,
            reference: p.reference,
            patientName: p.patientName,
          );
      if (!mounted) return;
      ToastService.instance.showSuccess('Prescription saved to device');

      if (files.isNotEmpty) {
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
      }
    } catch (e) {
      if (mounted) {
        ToastService.instance.showError(
          'Could not save prescription image: $e',
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  /// Shares the original saved PNG image(s) through WhatsApp / other apps.
  Future<void> _shareImage() async {
    final p = _prescription;
    if (p == null || _isProcessing) return;

    setState(() => _isProcessing = true);
    try {
      final bytesList = await _getPrescriptionImageBytes(p);
      if (bytesList.isEmpty) throw Exception('Image bytes unavailable');
      await PrescriptionPdfService.instance.sharePrescriptionImages(
        imageBytesList: bytesList,
        reference: p.reference,
        patientName: p.patientName,
        doctorName: p.doctorName,
      );
    } catch (e) {
      if (mounted) {
        ToastService.instance.showError('Could not share prescription: $e');
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  /// Prints the original prescription image on A4 paper preserving aspect ratio.
  Future<void> _printImage() async {
    final p = _prescription;
    if (p == null || _isProcessing) return;

    setState(() => _isProcessing = true);
    try {
      final bytesList = await _getPrescriptionImageBytes(p);
      if (bytesList.isEmpty) throw Exception('Image bytes unavailable');
      await PrescriptionPdfService.instance.printPrescriptionImages(
        imageBytesList: bytesList,
        reference: p.reference,
      );
    } catch (e) {
      if (mounted) {
        ToastService.instance.showError('Print error: $e');
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return OpdScreenShell(
      title: 'Prescription',
      subtitle: 'Official OPD Telemedicine Medical Document',
      showLogo: true,
      bottom: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _isProcessing ? null : _shareImage,
              icon: const Icon(Icons.share_rounded, size: 18),
              label: const Text('Share'),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF062B72),
                side: const BorderSide(color: Color(0xFF062B72), width: 1.5),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: GradientButton(
              text: 'Download PNG',
              icon: Icons.download_rounded,
              isLoading: _isProcessing,
              onPressed: _isProcessing ? null : _downloadImage,
            ),
          ),
        ],
      ),
      child: _buildContent(),
    );
  }

  Widget _buildContent() {
    if (_loading) {
      return const OpdInlineLoader(label: 'Loading prescription document...');
    }

    if (_error != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const OpdEmptyState(
            icon: Icons.error_outline_rounded,
            title: 'Could not load prescription',
            subtitle: 'Please check your connection and try again.',
          ),
          const SizedBox(height: 20),
          GradientButton(
            text: 'Retry',
            icon: Icons.refresh_rounded,
            onPressed: _load,
          ),
        ],
      );
    }

    final prescription = _prescription;
    if (prescription == null) {
      return const OpdEmptyState(
        icon: Icons.description_outlined,
        title: 'Prescription not found',
        subtitle: 'This prescription is no longer available.',
      );
    }

    if (!_isAuthorised(prescription)) {
      return const OpdEmptyState(
        icon: Icons.lock_outline_rounded,
        title: 'Access restricted',
        subtitle:
            'This prescription belongs to a different consultation and is not available to you.',
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Permanent Image Surface: Displays the exact saved PNG from Firebase Storage
        _buildPrescriptionImageDisplay(prescription),
        const SizedBox(height: 24),
      ],
    );
  }

  /// Displays the exact original stored PNG image(s) from Firebase Storage.
  Widget _buildPrescriptionImageDisplay(PrescriptionModel p) {
    final imageUrls = p.pageImageUrls.isNotEmpty
        ? p.pageImageUrls
        : (p.primaryImageUrl.isNotEmpty ? [p.primaryImageUrl] : <String>[]);

    if (imageUrls.isEmpty) {
      return Container(
        height: 480,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFD6E2EF)),
        ),
        child: const OpdInlineLoader(
          label: 'Loading prescription document image...',
        ),
      );
    }

    final totalPages = imageUrls.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Multi-page navigation bar if prescription has more than 1 page
        if (totalPages > 1) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFD6E2EF)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back_ios_rounded, size: 16),
                  color: _currentPage > 0
                      ? const Color(0xFF062B72)
                      : Colors.grey,
                  onPressed: _currentPage > 0
                      ? () => _pageController.previousPage(
                          duration: const Duration(milliseconds: 250),
                          curve: Curves.easeInOut,
                        )
                      : null,
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF062B72).withOpacity(0.08),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    'Page ${_currentPage + 1} of $totalPages',
                    style: TextStyle(
                      fontSize: context.fs(12.5),
                      fontWeight: FontWeight.w700,
                      color: const Color(0xFF062B72),
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.arrow_forward_ios_rounded, size: 16),
                  color: _currentPage < totalPages - 1
                      ? const Color(0xFF062B72)
                      : Colors.grey,
                  onPressed: _currentPage < totalPages - 1
                      ? () => _pageController.nextPage(
                          duration: const Duration(milliseconds: 250),
                          curve: Curves.easeInOut,
                        )
                      : null,
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
        ],

        // Zoom helper badge
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFFF1F5F9),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.pinch_rounded, size: 15, color: Color(0xFF64748B)),
              SizedBox(width: 6),
              Text(
                'Pinch to zoom in or out on document',
                style: TextStyle(
                  fontSize: 11,
                  color: Color(0xFF64748B),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // Permanent Image Surface
        if (totalPages > 1)
          SizedBox(
            height: context.sh * 0.72,
            child: PageView.builder(
              controller: _pageController,
              itemCount: totalPages,
              onPageChanged: (idx) => setState(() => _currentPage = idx),
              itemBuilder: (context, index) {
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: _buildSinglePageImage(imageUrls[index], index + 1),
                );
              },
            ),
          )
        else
          _buildSinglePageImage(imageUrls[0], 1),
      ],
    );
  }

  Widget _buildSinglePageImage(String imageUrl, int pageNum) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFD6E2EF), width: 1.2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.06),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: InteractiveViewer(
        minScale: 0.8,
        maxScale: 4.0,
        clipBehavior: Clip.none,
        child: Image.network(
          imageUrl,
          fit: BoxFit.contain,
          alignment: Alignment.topCenter,
          loadingBuilder: (context, child, progress) {
            if (progress == null) return child;
            return Container(
              height: 480,
              color: Colors.white,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(strokeWidth: 2.5),
                    const SizedBox(height: 12),
                    Text(
                      'Loading prescription page $pageNum...',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF64748B),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
          errorBuilder: (context, error, stackTrace) {
            return Container(
              height: 400,
              color: const Color(0xFFF8FAFC),
              padding: const EdgeInsets.all(20),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.broken_image_rounded,
                      size: 48,
                      color: Colors.grey,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Could not load stored image.',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1E293B),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Please check your internet connection.',
                      style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// Only the prescribing doctor or the prescribed patient may open it.
  bool _isAuthorised(PrescriptionModel prescription) {
    final doctorId =
        (prescription.doctorId.isNotEmpty
                ? prescription.doctorId
                : (widget.expectedDoctorId ?? ''))
            .toString();
    final patientId =
        (prescription.patientId.isNotEmpty
                ? prescription.patientId
                : (widget.expectedPatientId ?? ''))
            .toString();
    if (doctorId.isEmpty && patientId.isEmpty) return false;
    return widget.viewerId == doctorId || widget.viewerId == patientId;
  }
}
