import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:telemedicine/core/services/doctor_list_cache.dart';
import 'package:telemedicine/core/services/doctor_presence_service.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/data/models/report_model.dart';
import 'package:telemedicine/data/models/report_share_model.dart';
import 'package:telemedicine/home_widget/reports/report_share_controller/report_share_controller.dart';
import 'package:telemedicine/doctor_portal/ratings/doctor_rating_controller.dart';
import 'package:telemedicine/shared/widgets/auth_layout.dart';

/// Lets a patient share a specific report with one (or several) doctors and
/// manage/revoke existing shares for that report.
class ShareReportScreen extends ConsumerStatefulWidget {
  final ReportModel report;

  const ShareReportScreen({super.key, required this.report});

  @override
  ConsumerState<ShareReportScreen> createState() => _ShareReportScreenState();
}
 
class _ShareReportScreenState extends ConsumerState<ShareReportScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  /// Doctor currently running a share operation (drives the localized
  /// button spinner instead of a full-screen loader).
  String? _sharingDoctorId;

  /// Doctor currently running a revoke operation.
  String? _revokingDoctorId;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      if (!mounted) return;
      setState(() => _searchQuery = _searchController.text);
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  String _formatDate(DateTime date) {
    return DateFormat('dd MMM yyyy').format(date);
  }

  Widget _sectionTitle(String title) {
    return Text(
      title,
      style: TextStyle(
        fontSize: context.fs(14),
        fontWeight: FontWeight.w700,
        color: const Color(0xFF1F2F44),
      ),
    );
  }

  List<Map<String, dynamic>> _filterDoctors(List<Map<String, dynamic>> doctors) {
    if (_searchQuery.isEmpty) return doctors;
    final q = _searchQuery.toLowerCase();
    return doctors.where((doctor) {
      final name = (doctor['fullname'] ?? '').toString().toLowerCase();
      final degree = (doctor['highestDegree'] ?? '').toString().toLowerCase();
      final doctorId = (doctor['doctorId'] ?? '').toString().toLowerCase();
      return name.contains(q) || degree.contains(q) || doctorId.contains(q);
    }).toList();
  }

  Future<void> _confirmAndShare(
    Map<String, dynamic> doctor,
  ) async {
    final doctorId = doctor['id']?.toString() ?? '';
    final doctorName = doctor['fullname']?.toString() ?? 'Doctor';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        title: Text(
          'Share Report',
          style: TextStyle(
            fontSize: context.fs(15),
            fontWeight: FontWeight.w700,
            color: const Color(0xFF1F2F44),
          ),
        ),
        content: Text(
          'Are you sure you want to share this report with Dr. $doctorName?',
          style: TextStyle(
            fontSize: context.fs(13.5),
            color: const Color(0xFF6B7B8D),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(
              'Cancel',
              style: TextStyle(color: const Color(0xFF6B7B8D)),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(
              'Share',
              style: TextStyle(
                color: const Color(0xFF062B72),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _sharingDoctorId = doctorId);

    final controller = ref.read(reportShareControllerProvider);
    final success = await controller.shareReportWithDoctor(
      report: widget.report,
      doctorId: doctorId,
      doctorName: doctorName,
    );

    if (mounted) {
      setState(() => _sharingDoctorId = null);
    }

    if (success) {
      ToastService.instance.showSuccess(
        'Report shared with Dr. $doctorName',
      );
    }
  }

  Future<void> _confirmAndRevoke(SharedReportModel share) async {
    final doctorName = share.doctorName;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        title: Text(
          'Revoke Access',
          style: TextStyle(
            fontSize: context.fs(15),
            fontWeight: FontWeight.w700,
            color: const Color(0xFF1F2F44),
          ),
        ),
        content: Text(
          'Dr. $doctorName will no longer be able to access this report after you revoke access.',
          style: TextStyle(
            fontSize: context.fs(13.5),
            color: const Color(0xFF6B7B8D),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(
              'Cancel',
              style: TextStyle(color: const Color(0xFF6B7B8D)),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(
              'Revoke',
              style: TextStyle(
                color: Colors.redAccent,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _revokingDoctorId = share.doctorId);

    final controller = ref.read(reportShareControllerProvider);
    final success = await controller.revokeReportAccess(
      reportId: widget.report.id,
      doctorId: share.doctorId,
    );

    if (mounted) {
      setState(() => _revokingDoctorId = null);
    }

    if (success) {
      ToastService.instance.showSuccess(
        'Access revoked for Dr. $doctorName',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final shareStream = ref
        .watch(reportShareControllerProvider)
        .streamActiveSharesForReport(widget.report.id);

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
                    horizontal: context.rsp(18),
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      const CircularBackButton(),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Share Report',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: context.fs(16),
                                fontWeight: FontWeight.w700,
                                color: const Color(0xFF1F2F44),
                              ),
                            ),
                            Text(
                              widget.report.reportType,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: context.fs(11),
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
                  padding: EdgeInsets.symmetric(horizontal: context.rsp(18)),
                  child: MetallicInput(
                    hintText: 'Search doctors by name...',
                    icon: Icons.search_rounded,
                    controller: _searchController,
                    validator: null,
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: StreamBuilder<List<SharedReportModel>>(
                    stream: shareStream,
                    initialData: const <SharedReportModel>[],
                    builder: (context, snapshot) {
                      // A failed shares stream used to fall through
                      // (`initialData` + `snapshot.data ?? []`) and render
                      // "Not shared with any doctor yet" — telling the patient
                      // their sharing state was false when we simply could not
                      // read it.
                      if (snapshot.hasError) {
                        return Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(
                                Icons.error_outline,
                                size: 48,
                                color: Colors.red,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                'Could not load shared doctors.\nCheck your connection.',
                                textAlign: TextAlign.center,
                                style: TextStyle(),
                              ),
                            ],
                          ),
                        );
                      }
                      final activeShares =
                          snapshot.data ?? const <SharedReportModel>[];
                      return ListView(
                        physics: const BouncingScrollPhysics(),
                        padding: EdgeInsets.symmetric(
                          horizontal: context.rsp(18),
                          vertical: 8,
                        ),
                        children: [
                          _sectionTitle('Shared with'),
                          const SizedBox(height: 4),
                          if (activeShares.isEmpty)
                            _buildManagedDoctorEmpty(
                              'Not shared with any doctor yet',
                            )
                          else
                            ...activeShares.map(_buildCurrentShareRow),
                          const SizedBox(height: 16),
                          _sectionTitle('Select a doctor'),
                          const SizedBox(height: 4),
                          _buildDoctorList(activeShares),
                        ],
                      );
                    },
                  ),
                ),
                
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDoctorList(List<SharedReportModel> activeShares) {
    final Map<String, SharedReportModel> shareByDoctorId = {
      for (final share in activeShares) share.doctorId: share,
    };

    // Served from the app-scoped local cache (seeded from Hive, kept current by
    // the background sync started in `main`), so the list paints on the first
    // frame and this screen no longer opens a Firestore listener of its own.
    // The cache is non-nullable and non-empty-or-loading, so there is no
    // `null` branch and no spinner to show.
    final cache = ref.watch(doctorListCacheProvider);
    final doctorList = cache.doctors;

    final doctors = _filterDoctors(doctorList);

    if (doctors.isEmpty) {
      // Show a spinner only when there is genuinely nothing to show yet — a
      // first launch with no cache and no sync. A warm cache must never land
      // here, including when the search matches nothing, so the guard tests for
      // *having data* rather than for having synced.
      final hasSomethingToShow = cache.hasLocalData || cache.hasSynced;
      if (!hasSomethingToShow) {
        return const Padding(
          padding: EdgeInsets.all(24),
          child: Center(
            child: CircularProgressIndicator(color: Color(0xFF062B72)),
          ),
        );
      }
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 24),
        child: Column(
          children: [
            Icon(
              Icons.search_off_rounded,
              size: 48,
              color: const Color(0xFF8FA4BD),
            ),
            const SizedBox(height: 8),
            Text(
              _searchQuery.isEmpty
                  ? 'No doctors available'
                  : 'No doctors match your search',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: context.fs(13),
                color: const Color(0xFF6B7B8D),
              ),
            ),
          ],
        ),
      );
    }

    // Same online-first ordering as the main doctor list, using the SAME
    // centralized presence source as the online dots, so a doctor coming
    // online moves to the top here too without any manual refresh.
    final orderedDoctors = sortDoctorsByPresence<Map<String, dynamic>>(
      doctors,
      presenceForDoctorList(doctors, ref.watch(doctorPresenceProvider)),
      (doctor) => (doctor['id'] ?? '').toString(),
    );

    return Column(
      children: orderedDoctors.map((doctor) {
        final doctorId = doctor['id']?.toString() ?? '';
        final isLoading = _sharingDoctorId == doctorId;
        return _buildDoctorTile(
          doctor,
          share: shareByDoctorId[doctorId],
          isLoading: isLoading,
        );
      }).toList(),
    );
  }

  Widget _buildDoctorTile(
    Map<String, dynamic> doctor, {
    required SharedReportModel? share,
    required bool isLoading,
  }) {
    final doctorName = doctor['fullname']?.toString() ?? 'Doctor';
    final degree = doctor['highestDegree']?.toString() ?? '';
    final imageUrl = doctor['imageUrl']?.toString() ?? '';
    final doctorId = doctor['id']?.toString() ?? '';
    // Aggregated rating projected onto the doctor profile.
    final ratingAsync = ref.watch(doctorRatingSummaryProvider(doctorId));
    final averageRating = ratingAsync.valueOrNull?.average ?? (doctor['averageRating'] ?? 0.0).toDouble();
    final totalRatings = ratingAsync.valueOrNull?.total ?? (doctor['totalRatings'] ?? 0).toInt();
    final bool isShared = share != null;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
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
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isShared ? const Color(0xFF062B72) : const Color(0xFFDCE6F2),
          width: isShared ? 1.5 : 1,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0F233C).withValues(alpha: 0.06),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 24,
            backgroundColor: const Color(0xFF062B72).withValues(alpha: 0.1),
            backgroundImage: imageUrl.isNotEmpty ? NetworkImage(imageUrl) : null,
            child: imageUrl.isEmpty
                ? Text(
                    doctorName.isNotEmpty ? doctorName[0].toUpperCase() : 'D',
                    style: TextStyle(
                      color: const Color(0xFF062B72),
                      fontWeight: FontWeight.w600,
                    ),
                  )
                : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Dr. $doctorName',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: context.fs(14),
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF1F2F44),
                  ),
                ),
                if (degree.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    degree,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: context.fs(12),
                      color: const Color(0xFF657991),
                    ),
                  ),
                ],
                // Aggregated rating, projected onto the doctor profile by the
                // rating system. Read off the doctor document we already have.
                const SizedBox(height: 3),
                Row(
                  children: [
                    Icon(
                      totalRatings > 0 ? Icons.star_rounded : Icons.star_border_rounded,
                      size: 13,
                      color: totalRatings > 0
                          ? const Color(0xFFE9A400)
                          : const Color(0xFFBAC6D5),
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        totalRatings > 0
                            ? '${averageRating.toStringAsFixed(1)} ($totalRatings)'
                            : 'No ratings yet',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: context.fs(11.5),
                          fontWeight: FontWeight.w500,
                          color: totalRatings > 0
                              ? const Color(0xFF163B6E)
                              : const Color(0xFF7E90A6),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (share != null)
            TextButton(
              onPressed:
                  isLoading ? null : () => _confirmAndRevoke(share),
              style: TextButton.styleFrom(
                foregroundColor: Colors.redAccent,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              child: _revokingDoctorId == doctorId
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.redAccent,
                      ),
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.link_off_rounded, size: 16),
                        const SizedBox(width: 4),
                        Text(
                          'Revoke',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
            )
          else
            GradientButton(
              text: 'Share',
              icon: Icons.share_rounded,
              onPressed: isLoading ? null : () => _confirmAndShare(doctor),
              isLoading: isLoading,
            ),
        ],
      ),
    );
  }

  Widget _buildCurrentShareRow(SharedReportModel share) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF062B72).withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF062B72).withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.link_rounded,
            size: 18,
            color: Color(0xFF062B72),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Dr. ${share.doctorName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: context.fs(13.5),
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF1F2F44),
                  ),
                ),
                Text(
                  'Shared ${_formatDate(share.sharedAt)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: context.fs(11),
                    color: const Color(0xFF8FA4BD),
                  ),
                ),
              ],
            ),
          ),
          if (_revokingDoctorId == share.doctorId)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Color(0xFF062B72),
                ),
              ),
            )
          else
            TextButton(
              onPressed: () => _confirmAndRevoke(share),
              style: TextButton.styleFrom(
                foregroundColor: Colors.redAccent,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 32),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.link_off_rounded, size: 16),
                  const SizedBox(width: 4),
                  Text(
                    'Revoke',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildManagedDoctorEmpty(String message) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFD6E4F0).withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: context.fs(13),
          color: const Color(0xFF6B7B8D),
        ),
      ),
    );
  }
}