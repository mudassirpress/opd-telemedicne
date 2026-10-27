import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:telemedicine/auth/auth_provider/user_provider.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/data/models/report_model.dart';
import 'package:telemedicine/data/models/report_share_model.dart';
import 'package:telemedicine/home_widget/reports/report_share_controller/report_share_controller.dart';
import 'package:telemedicine/shared/widgets/auth_layout.dart';

/// Patient-facing overview of every report shared with doctors, with the
/// ability to revoke access to any of them.
class PatientSharedReportsScreen extends ConsumerStatefulWidget {
  const PatientSharedReportsScreen({super.key});

  @override
  ConsumerState<PatientSharedReportsScreen> createState() =>
      _PatientSharedReportsScreenState();
}

class _PatientSharedReportsScreenState
    extends ConsumerState<PatientSharedReportsScreen> {
  String? _revokingShareId;

  String _formatDate(DateTime date) {
    return DateFormat('dd MMM yyyy').format(date);
  }

  Future<void> _confirmAndRevoke(SharedReportModel share) async {
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
          'Dr. ${share.doctorName} will no longer be able to access this report after you revoke access.',
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

    setState(() => _revokingShareId = share.id);

    final success = await ref
        .read(reportShareControllerProvider)
        .revokeReportAccess(
          reportId: share.reportId,
          doctorId: share.doctorId,
        );

    if (mounted) {
      setState(() => _revokingShareId = null);
    }

    if (success) {
      ToastService.instance.showSuccess(
        'Access revoked for Dr. ${share.doctorName}',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(userProvider);
    final patientId = user?.id ?? '';

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
                              'Reports you have shared with doctors',
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
                Expanded(child: _buildContent(patientId)),
                
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(String patientId) {
    if (patientId.isEmpty) {
      return _buildMessage(
        icon: Icons.folder_shared_outlined,
        title: 'Sign in required',
        subtitle: 'Please sign in to manage your shared reports.',
      );
    }

    return StreamBuilder<List<SharedReportModel>>(
      stream: ref
          .read(reportShareControllerProvider)
          .streamPatientShares(patientId),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
            child: CircularProgressIndicator(color: Color(0xFF062B72)),
          );
        }

        if (snapshot.hasError) {
          return _buildMessage(
            icon: Icons.error_outline_rounded,
            title: 'Error loading shares',
            subtitle: snapshot.error.toString(),
          );
        }

        final shares = snapshot.data ?? const <SharedReportModel>[];

        if (shares.isEmpty) {
          return _buildMessage(
            icon: Icons.folder_shared_outlined,
            title: 'No shared reports',
            subtitle:
                'Share a report from your Report History to give a doctor access to it.',
          );
        }

        return ListView.builder(
          physics: const BouncingScrollPhysics(),
          padding: EdgeInsets.symmetric(horizontal: context.rsp(18), vertical: 8),
          itemCount: shares.length,
          itemBuilder: (context, index) {
            return _buildShareCard(shares[index]);
          },
        );
      },
    );
  }

  Widget _buildMessage({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
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
                icon,
                size: 64,
                color: const Color(0xFF062B72).withValues(alpha: 0.4),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
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
    final isShared = share.isShared;

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
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.local_hospital_rounded,
                              size: 13,
                              color: Color(0xFF657991),
                            ),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                'Dr. ${share.doctorName}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: context.fs(12),
                                  fontWeight: FontWeight.w600,
                                  color: const Color(0xFF1F2F44),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: isShared
                          ? const Color(0xFF4CAF50).withValues(alpha: 0.12)
                          : const Color(0xFFBDBDBD).withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      isShared ? 'Shared' : 'Revoked',
                      style: TextStyle(
                        fontSize: context.fs(11),
                        fontWeight: FontWeight.w600,
                        color: isShared
                            ? const Color(0xFF2E7D32)
                            : const Color(0xFF6B7B8D),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Container(height: 1, color: const Color(0xFFDCE6F2)),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
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
                                  fontSize: context.fs(11),
                                  color: const Color(0xFF8FA4BD),
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (share.revokedAt != null) ...[
                          const SizedBox(height: 4),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.link_off_rounded,
                                size: 13,
                                color: Color(0xFF8FA4BD),
                              ),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  'Revoked ${_formatDate(share.revokedAt!)}',
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
                        ],
                      ],
                    ),
                  ),
                  if (isShared) ...[
                    if (_revokingShareId == share.id)
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
                      TextButton.icon(
                        onPressed: () => _confirmAndRevoke(share),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.redAccent,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                        icon: const Icon(Icons.link_off_rounded, size: 16),
                        label: Text(
                          'Unshare',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}