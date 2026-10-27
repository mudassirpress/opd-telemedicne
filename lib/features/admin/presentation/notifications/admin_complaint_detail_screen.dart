import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:telemedicine/features/admin/presentation/admin_design_system.dart';
import 'package:telemedicine/features/admin/presentation/notifications/admin_payment_screen.dart';
import 'package:telemedicine/core/services/app_feedback.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/data/models/admin_notification_model.dart';
import 'package:telemedicine/data/models/payment_complaint_model.dart';
import 'package:telemedicine/features/complaints/presentation/payment_complaint_service.dart';

class AdminComplaintDetailScreen extends ConsumerStatefulWidget {
  final String complaintId;
  final AdminNotificationModel? initialNotification;

  const AdminComplaintDetailScreen({
    super.key,
    required this.complaintId,
    this.initialNotification,
  });

  @override
  ConsumerState<AdminComplaintDetailScreen> createState() =>
      _AdminComplaintDetailScreenState();
}

class _AdminComplaintDetailScreenState
    extends ConsumerState<AdminComplaintDetailScreen> {
  final TextEditingController _responseController = TextEditingController();
  bool _isSaving = false;
  PaymentComplaintModel? _complaint;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadComplaint();
  }

  @override
  void dispose() {
    _responseController.dispose();
    super.dispose();
  }

  Future<void> _loadComplaint() async {
    final service = ref.read(paymentComplaintServiceProvider);
    final data = await service.getComplaintById(widget.complaintId);
    if (!mounted) return;

    setState(() {
      _complaint = data;
      _isLoading = false;
      if (data?.adminResponse != null) {
        _responseController.text = data!.adminResponse!;
      }
    });
  }

  Future<void> _updateStatus(String newStatus) async {
    if (_complaint == null) return;
    setState(() => _isSaving = true);

    try {
      final service = ref.read(paymentComplaintServiceProvider);
      await service.updateComplaintStatus(
        complaintId: widget.complaintId,
        status: newStatus,
        adminResponse: _responseController.text.trim().isNotEmpty
            ? _responseController.text.trim()
            : null,
      );

      if (!mounted) return;
      AppFeedback.showSuccess(context, 'Status updated to ${newStatus.toUpperCase()}');
      await _loadComplaint();
    } catch (e) {
      if (!mounted) return;
      AppFeedback.showError(context, 'Failed to update status: $e');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _saveAdminResponse() async {
    final text = _responseController.text.trim();
    if (text.isEmpty) {
      AppFeedback.showWarning(context, 'Please enter a response message.');
      return;
    }

    setState(() => _isSaving = true);
    try {
      final service = ref.read(paymentComplaintServiceProvider);
      final currentStatus = _complaint?.status == 'open'
          ? 'in_progress'
          : (_complaint?.status ?? 'in_progress');

      await service.updateComplaintStatus(
        complaintId: widget.complaintId,
        status: currentStatus,
        adminResponse: text,
      );

      if (!mounted) return;
      AppFeedback.showSuccess(
        context,
        'Response sent and visible to the patient.',
      );
      await _loadComplaint();
    } catch (e) {
      if (!mounted) return;
      AppFeedback.showError(context, 'Failed to save response: $e');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const AdminScreen(
        title: 'Complaint Details',
        subtitle: 'Loading complaint information...',
        body: AdminLoading(label: 'Loading complaint...'),
      );
    }

    final complaint = _complaint;
    if (complaint == null) {
      return AdminScreen(
        title: 'Complaint Details',
        subtitle: 'Not found',
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline_rounded,
                  size: 48, color: AdminPalette.error),
              const SizedBox(height: 12),
              const Text('Complaint record could not be loaded.'),
              const SizedBox(height: 16),
              AdminSolidButton(
                label: 'Go Back',
                icon: Icons.arrow_back_rounded,
                color: AdminPalette.brand,
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
        ),
      );
    }

    final dateFormatted =
        DateFormat('MMM d, yyyy  •  h:mm a').format(complaint.createdAt);

    Color statusColor;
    String statusLabel;
    switch (complaint.status) {
      case 'resolved':
        statusColor = Colors.green[700]!;
        statusLabel = 'RESOLVED';
        break;
      case 'in_progress':
        statusColor = Colors.blue[700]!;
        statusLabel = 'IN PROGRESS';
        break;
      default:
        statusColor = Colors.orange[800]!;
        statusLabel = 'OPEN';
    }

    return AdminScreen(
      title: 'Complaint Details',
      subtitle: 'ID: ${complaint.complaintId}',
      body: SingleChildScrollView(
        padding: EdgeInsets.all(context.rsp(16)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Status and Date Header Card
            AdminCard(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: statusColor.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                              color: statusColor.withValues(alpha: 0.3)),
                        ),
                        child: Text(
                          statusLabel,
                          style: TextStyle(
                            fontSize: context.fs(11.5),
                            fontWeight: FontWeight.bold,
                            color: statusColor,
                          ),
                        ),
                      ),
                      const Spacer(),
                      Text(
                        dateFormatted,
                        style: TextStyle(
                          fontSize: context.fs(11.5),
                          color: AdminPalette.textMuted,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text(
                    complaint.category,
                    style: TextStyle(
                      fontSize: context.fs(16),
                      fontWeight: FontWeight.bold,
                      color: AdminPalette.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF7F9FC),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFE2EAF4)),
                    ),
                    child: Text(
                      complaint.message,
                      style: TextStyle(
                        fontSize: context.fs(13.5),
                        color: AdminPalette.textPrimary,
                        height: 1.45,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // Patient Info Card
            AdminCard(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.person_rounded,
                          size: 20, color: AdminPalette.brand),
                      const SizedBox(width: 8),
                      Text(
                        'Patient Information',
                        style: TextStyle(
                          fontSize: context.fs(14),
                          fontWeight: FontWeight.bold,
                          color: AdminPalette.textPrimary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _buildDetailRow('Patient Name', complaint.patientName),
                  _buildDetailRow('Patient UID', complaint.patientUid),
                  if (complaint.patientId != null &&
                      complaint.patientId!.isNotEmpty)
                    _buildDetailRow('Patient ID', complaint.patientId!),
                  _buildDetailRow(
                    'Payment Status at Filing',
                    complaint.paymentStatusAtSubmission.toUpperCase(),
                  ),
                  if (complaint.appointmentId != null &&
                      complaint.appointmentId!.isNotEmpty)
                    _buildDetailRow('Appointment Reference', complaint.appointmentId!),
                  if (complaint.paymentId != null &&
                      complaint.paymentId!.isNotEmpty) ...[
                    _buildDetailRow('Payment Reference', complaint.paymentId!),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.payment_rounded, size: 18),
                        label: const Text('Review Payment in Payment Screen'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AdminPalette.brand,
                          side: const BorderSide(color: AdminPalette.brand),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        onPressed: () {
                          final isAppt = complaint.category.toLowerCase().contains('appointment');
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => AdminPaymentScreen(
                                focusPatientId: complaint.patientUid,
                                focusPaymentId: complaint.paymentId,
                                initialSegment: isAppt
                                    ? AdminPaymentSegment.appointment
                                    : AdminPaymentSegment.account,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ],
              ),
            ),

            const SizedBox(height: 16),

            // Status Actions Card
            AdminCard(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Change Complaint Status',
                    style: TextStyle(
                      fontSize: context.fs(13.5),
                      fontWeight: FontWeight.bold,
                      color: AdminPalette.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _buildStatusButton(
                          label: 'Open',
                          isActive: complaint.status == 'open',
                          color: Colors.orange[800]!,
                          onTap: () => _updateStatus('open'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildStatusButton(
                          label: 'In Progress',
                          isActive: complaint.status == 'in_progress',
                          color: Colors.blue[700]!,
                          onTap: () => _updateStatus('in_progress'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildStatusButton(
                          label: 'Resolved',
                          isActive: complaint.status == 'resolved',
                          color: Colors.green[700]!,
                          onTap: () => _updateStatus('resolved'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // Admin Response Card
            AdminCard(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.reply_rounded,
                          size: 20, color: AdminPalette.brand),
                      const SizedBox(width: 8),
                      Text(
                        'Admin Response',
                        style: TextStyle(
                          fontSize: context.fs(14),
                          fontWeight: FontWeight.bold,
                          color: AdminPalette.textPrimary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'This response will be visible to the patient on their "My Complaints" tab.',
                    style: TextStyle(
                      fontSize: context.fs(12),
                      color: AdminPalette.textMuted,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _responseController,
                    maxLines: 4,
                    decoration: InputDecoration(
                      hintText: 'Enter response to the patient...',
                      hintStyle: TextStyle(
                        fontSize: context.fs(13),
                        color: AdminPalette.textMuted,
                      ),
                      filled: true,
                      fillColor: const Color(0xFFF7F9FC),
                      contentPadding: const EdgeInsets.all(14),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Color(0xFFDCE6F4)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Color(0xFFDCE6F4)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide:
                            BorderSide(color: AdminPalette.brand, width: 1.5),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    height: 46,
                    child: ElevatedButton.icon(
                      onPressed: _isSaving ? null : _saveAdminResponse,
                      icon: _isSaving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.send_rounded,
                              size: 18, color: Colors.white),
                      label: Text(
                        _isSaving ? 'Saving...' : 'Send Response',
                        style: TextStyle(
                          fontSize: context.fs(13.5),
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AdminPalette.brand,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusButton({
    required String label,
    required bool isActive,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: _isSaving ? null : onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: isActive ? color : color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isActive ? color : color.withValues(alpha: 0.3),
            width: isActive ? 1.5 : 1,
          ),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: isActive ? Colors.white : color,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: AdminPalette.textMuted,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 12.5,
                color: AdminPalette.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
