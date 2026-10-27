import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:telemedicine/auth/auth_provider/user_provider.dart';
import 'package:telemedicine/core/services/app_feedback.dart';
import 'package:telemedicine/core/theme/app_theme.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/data/models/payment_complaint_model.dart';
import 'package:telemedicine/features/complaint/payment_complaint_service.dart';
import 'package:telemedicine/shared/widgets/auth_layout.dart';

class SubmitComplaintScreen extends ConsumerStatefulWidget {
  const SubmitComplaintScreen({super.key});

  @override
  ConsumerState<SubmitComplaintScreen> createState() =>
      _SubmitComplaintScreenState();
}

class _SubmitComplaintScreenState extends ConsumerState<SubmitComplaintScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final TextEditingController _messageController = TextEditingController();
  final TextEditingController _paymentIdController = TextEditingController();
  final TextEditingController _appointmentIdController = TextEditingController();

  static const List<String> _categories = [
    'Account activation payment',
    'Account reactivation payment',
    'Appointment booking payment',
    'Payment proof submitted but approval pending',
    'Payment rejected',
    'Other payment-related issue',
  ];

  String _selectedCategory = _categories[0];
  bool _isSubmitting = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);

    // Auto-fill paymentId if user already has one on record
    final currentUser = ref.read(userProvider);
    if (currentUser?.paymentId != null &&
        currentUser!.paymentId!.trim().isNotEmpty) {
      _paymentIdController.text = currentUser.paymentId!.trim();
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _messageController.dispose();
    _paymentIdController.dispose();
    _appointmentIdController.dispose();
    super.dispose();
  }

  Future<void> _submitComplaint() async {
    final message = _messageController.text.trim();
    if (message.isEmpty) {
      setState(() {
        _errorMessage = 'Please describe your complaint or issue.';
      });
      AppFeedback.showWarning(context, 'Please enter your complaint message.');
      return;
    }

    final currentUser = ref.read(userProvider);
    if (currentUser == null || currentUser.id.isEmpty) {
      AppFeedback.showError(
        context,
        'Your session has expired. Please sign in again.',
      );
      return;
    }

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    try {
      final service = ref.read(paymentComplaintServiceProvider);

      final paymentStatus = (currentUser.paymentStatus != null &&
              currentUser.paymentStatus!.isNotEmpty)
          ? currentUser.paymentStatus!
          : 'not_submitted';

      final enteredPaymentId = _paymentIdController.text.trim().isNotEmpty
          ? _paymentIdController.text.trim()
          : currentUser.paymentId;
      final enteredAppointmentId = _appointmentIdController.text.trim().isNotEmpty
          ? _appointmentIdController.text.trim()
          : null;

      await service.submitComplaint(
        patientUid: currentUser.id,
        patientId: currentUser.patientId,
        patientName: currentUser.fullname.isNotEmpty
            ? currentUser.fullname
            : 'Patient',
        category: _selectedCategory,
        message: message,
        paymentId: enteredPaymentId,
        appointmentId: enteredAppointmentId,
        paymentStatusAtSubmission: paymentStatus,
      );

      if (!mounted) return;

      AppFeedback.showSuccess(
        context,
        'Complaint submitted successfully! Our team will review it shortly.',
      );

      // Clear form inputs and switch to the "My Complaints" tab
      _messageController.clear();
      _tabController.animateTo(1);
    } catch (e) {
      if (!mounted) return;
      final errorMsg =
          e is ArgumentError ? e.message.toString() : 'Failed to submit complaint: $e';
      setState(() {
        _errorMessage = errorMsg;
      });
      AppFeedback.showError(context, errorMsg);
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentUser = ref.watch(userProvider);
    final paymentStatus = (currentUser?.paymentStatus != null &&
            currentUser!.paymentStatus!.isNotEmpty)
        ? currentUser.paymentStatus!.toUpperCase()
        : 'NOT SUBMITTED';

    return Scaffold(
      backgroundColor: const Color(0xFFEDF2F8),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0.5,
        leading: const CircularBackButton(),
        title: Text(
          'Help & Complaints',
          style: TextStyle(
            fontSize: context.fs(18),
            fontWeight: FontWeight.bold,
            color: const Color(0xFF1F2F44),
          ),
        ),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: AppColors.primaryRed,
          indicatorWeight: 3,
          labelColor: AppColors.primaryRed,
          unselectedLabelColor: const Color(0xFF657991),
          labelStyle: TextStyle(
            fontSize: context.fs(13.5),
            fontWeight: FontWeight.w600,
          ),
          tabs: const [
            Tab(text: 'New Complaint'),
            Tab(text: 'My Complaints'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildComplaintForm(paymentStatus),
          _buildMyComplaintsList(currentUser?.id ?? ''),
        ],
      ),
    );
  }

  Widget _buildComplaintForm(String paymentStatus) {
    final nowFormatted = DateFormat('MMM d, yyyy h:mm a').format(DateTime.now());

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: context.contentMaxWidth),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Patient context card
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFDCE6F2)),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF12263F).withValues(alpha: 0.04),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: AppColors.primaryRed.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.support_agent_rounded,
                      color: AppColors.primaryRed,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Payment Assistance & Support',
                          style: TextStyle(
                            fontSize: context.fs(14),
                            fontWeight: FontWeight.bold,
                            color: const Color(0xFF1F2F44),
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          'Current Payment Status: $paymentStatus',
                          style: TextStyle(
                            fontSize: context.fs(12),
                            fontWeight: FontWeight.w600,
                            color: paymentStatus == 'APPROVED'
                                ? Colors.green[700]
                                : (paymentStatus == 'PENDING'
                                    ? Colors.orange[800]
                                    : AppColors.primaryRed),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // Complaint Category
            Text(
              'Complaint Category',
              style: TextStyle(
                fontSize: context.fs(13.5),
                fontWeight: FontWeight.bold,
                color: const Color(0xFF1F2F44),
              ),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFFDCE6F2)),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _selectedCategory,
                  isExpanded: true,
                  icon: const Icon(Icons.arrow_drop_down_rounded,
                      color: Color(0xFF1F2F44)),
                  items: _categories.map((category) {
                    return DropdownMenuItem<String>(
                      value: category,
                      child: Text(
                        category,
                        style: TextStyle(
                          fontSize: context.fs(13),
                          color: const Color(0xFF1F2F44),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    );
                  }).toList(),
                  onChanged: (val) {
                    if (val != null) {
                      setState(() {
                        _selectedCategory = val;
                      });
                    }
                  },
                ),
              ),
            ),

            const SizedBox(height: 18),

            // Related Payment ID (optional)
            Text(
              'Related Payment ID (Optional)',
              style: TextStyle(
                fontSize: context.fs(13.5),
                fontWeight: FontWeight.bold,
                color: const Color(0xFF1F2F44),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _paymentIdController,
              decoration: InputDecoration(
                hintText: 'e.g. Transaction ID or Bank Reference',
                hintStyle: TextStyle(
                  fontSize: context.fs(13),
                  color: const Color(0xFF9AA8BC),
                ),
                filled: true,
                fillColor: Colors.white,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: Color(0xFFDCE6F2)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: Color(0xFFDCE6F2)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(color: AppColors.primaryRed, width: 1.5),
                ),
              ),
            ),

            const SizedBox(height: 18),

            // Related Appointment ID (optional)
            Text(
              'Related Appointment ID (Optional)',
              style: TextStyle(
                fontSize: context.fs(13.5),
                fontWeight: FontWeight.bold,
                color: const Color(0xFF1F2F44),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _appointmentIdController,
              decoration: InputDecoration(
                hintText: 'e.g. Appointment reference if applicable',
                hintStyle: TextStyle(
                  fontSize: context.fs(13),
                  color: const Color(0xFF9AA8BC),
                ),
                filled: true,
                fillColor: Colors.white,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: Color(0xFFDCE6F2)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: Color(0xFFDCE6F2)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(color: AppColors.primaryRed, width: 1.5),
                ),
              ),
            ),

            const SizedBox(height: 18),

            // Complaint message (Required)
            Row(
              children: [
                Text(
                  'Complaint Message',
                  style: TextStyle(
                    fontSize: context.fs(13.5),
                    fontWeight: FontWeight.bold,
                    color: const Color(0xFF1F2F44),
                  ),
                ),
                const SizedBox(width: 4),
                const Text(
                  '*',
                  style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _messageController,
              maxLines: 5,
              maxLength: 1000,
              decoration: InputDecoration(
                hintText:
                    'Explain your issue in detail so our support administrators can help you quickly...',
                hintStyle: TextStyle(
                  fontSize: context.fs(13),
                  color: const Color(0xFF9AA8BC),
                ),
                filled: true,
                fillColor: Colors.white,
                contentPadding: const EdgeInsets.all(16),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: Color(0xFFDCE6F2)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: Color(0xFFDCE6F2)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(color: AppColors.primaryRed, width: 1.5),
                ),
              ),
            ),

            if (_errorMessage != null) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red[50],
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.red[200]!),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline_rounded,
                        color: Colors.red, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _errorMessage!,
                        style: TextStyle(
                          fontSize: context.fs(12.5),
                          color: Colors.red[800],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 12),
            Text(
              'Submission timestamp: $nowFormatted (Server verified)',
              style: TextStyle(
                fontSize: context.fs(11.5),
                color: const Color(0xFF7E90A6),
              ),
            ),

            const SizedBox(height: 24),

            // Submit Button
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton.icon(
                onPressed: _isSubmitting ? null : _submitComplaint,
                icon: _isSubmitting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.send_rounded, size: 20, color: Colors.white),
                label: Text(
                  _isSubmitting ? 'Submitting Complaint...' : 'Submit Complaint',
                  style: TextStyle(
                    fontSize: context.fs(15),
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primaryRed,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  elevation: 2,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMyComplaintsList(String patientUid) {
    if (patientUid.isEmpty) {
      return const Center(child: Text('Please log in to view complaints.'));
    }

    final service = ref.watch(paymentComplaintServiceProvider);

    return StreamBuilder<List<PaymentComplaintModel>>(
      stream: service.streamPatientComplaints(patientUid),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        final complaints = snapshot.data ?? [];
        if (complaints.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.mark_email_read_outlined,
                    size: 56,
                    color: const Color(0xFF9AA8BC),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No Complaints Submitted',
                    style: TextStyle(
                      fontSize: context.fs(16),
                      fontWeight: FontWeight.bold,
                      color: const Color(0xFF1F2F44),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Any help requests or payment complaints you submit will appear here along with responses from the administrators.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: context.fs(13),
                      color: const Color(0xFF657991),
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: complaints.length,
          separatorBuilder: (_, __) => const SizedBox(height: 12),
          itemBuilder: (context, index) {
            final complaint = complaints[index];
            final dateStr = DateFormat('MMM d, yyyy h:mm a').format(complaint.createdAt);

            Color statusColor;
            String statusText;
            switch (complaint.status) {
              case 'resolved':
                statusColor = Colors.green[700]!;
                statusText = 'RESOLVED';
                break;
              case 'in_progress':
                statusColor = Colors.blue[700]!;
                statusText = 'IN PROGRESS';
                break;
              default:
                statusColor = Colors.orange[800]!;
                statusText = 'OPEN';
            }

            return Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFDCE6F2)),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF12263F).withValues(alpha: 0.04),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
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
                          statusText,
                          style: TextStyle(
                            fontSize: context.fs(11),
                            fontWeight: FontWeight.bold,
                            color: statusColor,
                          ),
                        ),
                      ),
                      const Spacer(),
                      Text(
                        dateStr,
                        style: TextStyle(
                          fontSize: context.fs(11.5),
                          color: const Color(0xFF9AA8BC),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    complaint.category,
                    style: TextStyle(
                      fontSize: context.fs(14),
                      fontWeight: FontWeight.bold,
                      color: const Color(0xFF1F2F44),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    complaint.message,
                    style: TextStyle(
                      fontSize: context.fs(13),
                      color: const Color(0xFF4B5E76),
                      height: 1.4,
                    ),
                  ),
                  if (complaint.paymentId != null &&
                      complaint.paymentId!.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Payment Ref: ${complaint.paymentId}',
                      style: TextStyle(
                        fontSize: context.fs(11.5),
                        fontWeight: FontWeight.w500,
                        color: const Color(0xFF7E90A6),
                      ),
                    ),
                  ],
                  if (complaint.adminResponse != null &&
                      complaint.adminResponse!.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF0F7FF),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFC7E0FF)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.admin_panel_settings_rounded,
                                  size: 16, color: Colors.blue[800]),
                              const SizedBox(width: 6),
                              Text(
                                'Admin Response:',
                                style: TextStyle(
                                  fontSize: context.fs(12),
                                  fontWeight: FontWeight.bold,
                                  color: Colors.blue[900],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            complaint.adminResponse!,
                            style: TextStyle(
                              fontSize: context.fs(12.5),
                              color: const Color(0xFF1F2F44),
                              height: 1.35,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        );
      },
    );
  }
}
