import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/auth/auth_provider/user_provider.dart';
import 'package:telemedicine/admin_portal/admin_ui.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/subscription_calculator.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';

class AdminReactivationScreen extends ConsumerStatefulWidget {
  const AdminReactivationScreen({super.key});

  @override
  ConsumerState<AdminReactivationScreen> createState() =>
      _AdminReactivationScreenState();
}

class _AdminReactivationScreenState
    extends ConsumerState<AdminReactivationScreen> {
  String _selectedFilter = 'pending';
  bool _isProcessing = false;

  // Memoised on the filter value so rebuilds (_isProcessing, selection)
  // reuse the subscription and only a filter-chip change resubscribes.
  Stream<List<Map<String, dynamic>>>? _requestsStream;
  String? _requestsFilter;

  Stream<List<Map<String, dynamic>>> _reactivationStream(
    dynamic patientController,
  ) {
    if (_requestsFilter != _selectedFilter || _requestsStream == null) {
      _requestsFilter = _selectedFilter;
      _requestsStream = patientController.getReactivationRequests(
        statusFilter: _selectedFilter,
      );
    }
    return _requestsStream!;
  }

  @override
  Widget build(BuildContext context) {
    final patientController = ref.read(patientControllerProvider);

    return AdminScreen(
      showBack: true,
      title: 'Reactivation Requests',
      subtitle: 'Review patient account reactivations',
      body: Column(
        children: [
          // Filter chips
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: context.rsp(16),
              vertical: 14,
            ),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _buildFilterChip('Pending', 'pending'),
                _buildFilterChip('Approved', 'approved'),
                _buildFilterChip('Rejected', 'rejected'),
                _buildFilterChip('All', 'all'),
              ],
            ),
          ),
          Expanded(
            child: StreamBuilder<List<Map<String, dynamic>>>(
              stream: _reactivationStream(patientController),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return AdminErrorState(message: 'Error loading requests');
                }

                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const AdminLoading(label: 'Loading requests...');
                }

                final requests = snapshot.data ?? [];

                if (requests.isEmpty) {
                  return const AdminEmptyState(
                    icon: Icons.inbox,
                    title: 'No reactivation requests found',
                  );
                }

                return ListView.builder(
                  padding: const EdgeInsets.only(bottom: 16),
                  itemCount: requests.length,
                  itemBuilder: (context, index) {
                    return _buildRequestCard(requests[index]);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip(String label, String filter) {
    return AdminFilterChip(
      label: label,
      selected: _selectedFilter == filter,
      onTap: () {
        if (_selectedFilter != filter) {
          setState(() => _selectedFilter = filter);
        }
      },
    );
  }

  Widget _buildRequestCard(Map<String, dynamic> request) {
    final status = request['status'] ?? 'pending';
    final statusColor = _getStatusColor(status);
    final submittedAt = request['submittedAt'];
    final previousExpiry = request['previousExpiryDate'];
    final newExpiry = request['newExpiryDate'];
    final plan = SubscriptionPlan.fromPlanId(
      request['subscriptionPlan']?.toString(),
    );

    return AdminCard(
      margin: EdgeInsets.fromLTRB(context.rsp(16), 0, context.rsp(16), 16),
      radius: 18,
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Container(
            padding: EdgeInsets.all(context.rsp(16)),
            decoration: BoxDecoration(
              color: AdminPalette.infoBg,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(18),
                topRight: Radius.circular(18),
              ),
              border: Border(
                bottom: BorderSide(
                  color: AdminPalette.cardBorder.withValues(alpha: 0.6),
                ),
              ),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: statusColor.withValues(alpha: 0.1),
                  child: Icon(
                    _getStatusIcon(status),
                    color: statusColor,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        request['patientName'] ?? 'Unknown',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AdminTextStyles.heading(size: context.fs(14.5)),
                      ),
                      Text(
                        'Patient ID: ${request['patientId'] ?? 'N/A'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AdminTextStyles.small(size: context.fs(12.5)),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: AdminPill(text: status.toUpperCase(), color: statusColor),
                ),
              ],
            ),
          ),

          // Content
          Padding(
            padding: EdgeInsets.all(context.rsp(16)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Dates & Plan info
                _buildInfoRow(
                  'Plan',
                  plan.displayName,
                  Icons.card_membership,
                  plan == SubscriptionPlan.oneYear
                      ? AdminPalette.success
                      : (plan == SubscriptionPlan.oneMonth
                          ? AdminPalette.info
                          : AdminPalette.brand),
                ),
                if (previousExpiry != null)
                  _buildInfoRow(
                    'Previous Expiry',
                    _formatTimestamp(previousExpiry),
                    Icons.event_busy,
                    AdminPalette.frozen,
                  ),
                if (submittedAt != null)
                  _buildInfoRow(
                    'Submitted',
                    _formatTimestamp(submittedAt),
                    Icons.schedule,
                    AdminPalette.info,
                  ),
                if (newExpiry != null)
                  _buildInfoRow(
                    'New Expiry',
                    _formatTimestamp(newExpiry),
                    Icons.event_available,
                    AdminPalette.success,
                  ),

                const SizedBox(height: 12),

                // Payment proof image
                if (request['paymentProofUrl'] != null) ...[
                  Text(
                    'Payment Proof:',
                    style: AdminTextStyles.heading(size: context.fs(13)),
                  ),
                  const SizedBox(height: 8),
                  GestureDetector(
                    onTap: () => _showFullScreenImage(
                      request['paymentProofUrl'],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: CachedNetworkImage(
                        imageUrl: request['paymentProofUrl'],
                        height: 200,
                        width: double.infinity,
                        fit: BoxFit.cover,
                        placeholder: (context, url) => Container(
                          height: 200,
                          color: AdminPalette.background,
                          child: const Center(
                            child: CircularProgressIndicator(
                              color: AdminPalette.brand,
                            ),
                          ),
                        ),
                        errorWidget: (context, url, error) => Container(
                          height: 200,
                          color: AdminPalette.background,
                          child: const Center(
                            child: Icon(
                              Icons.error_outline,
                              color: AdminPalette.error,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],

                // Rejection reason
                if (request['rejectionReason'] != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AdminPalette.error.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: AdminPalette.error.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.error_outline,
                          color: AdminPalette.error,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Reason: ${request['rejectionReason']}',
                            style: TextStyle(
                              fontSize: context.fs(12),
                              color: AdminPalette.error,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                // Action buttons (only for pending)
                if (status == 'pending') ...[
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          minWidth: context.rsp(116) * context.textScale,
                          maxWidth: 260,
                        ),
                        child: AdminOutlineButton(
                          label: 'Reject',
                          icon: Icons.close,
                          color: AdminPalette.error,
                          onPressed: _isProcessing
                              ? null
                              : () => _rejectRequest(request),
                        ),
                      ),
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          minWidth: context.rsp(116) * context.textScale,
                          maxWidth: 260,
                        ),
                        child: AdminSolidButton(
                          label: 'Approve',
                          icon: Icons.check_circle,
                          color: AdminPalette.success,
                          onPressed: _isProcessing
                              ? null
                              : () => _approveRequest(request),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value, IconData icon, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Text(
            '$label: ',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AdminTextStyles.body(size: context.fs(13)),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: context.fs(13),
                fontWeight: FontWeight.w600,
                color: AdminPalette.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _approveRequest(Map<String, dynamic> request) async {
    if (_isProcessing) return;
    setState(() => _isProcessing = true);
    try {
      final plan = SubscriptionPlan.fromPlanId(
        request['subscriptionPlan']?.toString(),
      );
      final confirmed = await showAdminConfirmDialog(
        context: context,
        title: 'Approve Reactivation',
        content:
            "Reactivate patient ${request['patientName']}'s account with ${plan.displayName} renewal?",
        confirmLabel: 'Approve',
        confirmColor: AdminPalette.success,
      );

      if (confirmed == true) {
        ToastService.instance.showInfo('Processing approval...');
        final controller = ref.read(patientControllerProvider);
        final success = await controller.approveReactivationRequest(
          requestId: request['id'],
          patientUserId: request['patientUserId'],
        );
        if (success) {
          ToastService.instance.showSuccess('Reactivation approved!');
        } else {
          ToastService.instance.showError('Failed: ${controller.errorMessage}');
        }
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  void _rejectRequest(Map<String, dynamic> request) {
    if (_isProcessing) return;
    showAdminReasonDialog(
      context: context,
      title: 'Reject Reactivation',
      prompt: 'Reject reactivation for ${request['patientName']}?',
      confirmLabel: 'Reject',
      confirmColor: AdminPalette.error,
      onConfirm: (reason) async {
        setState(() => _isProcessing = true);
        try {
          final controller = ref.read(patientControllerProvider);
          final success = await controller.rejectReactivationRequest(
            requestId: request['id'],
            reason: reason,
          );
          if (success) {
            ToastService.instance.showSuccess('Reactivation rejected');
          } else {
            ToastService.instance.showError(
              'Failed: ${controller.errorMessage}',
            );
          }
        } finally {
          if (mounted) setState(() => _isProcessing = false);
        }
      },
    );
  }

  void _showFullScreenImage(String imageUrl) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            leading: IconButton(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close, color: Colors.white),
            ),
          ),
          body: Center(
            child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 4.0,
              child: CachedNetworkImage(
                imageUrl: imageUrl,
                fit: BoxFit.contain,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Color _getStatusColor(String status) {
    switch (status) {
      case 'pending':
        return AdminPalette.frozen;
      case 'approved':
        return AdminPalette.success;
      case 'rejected':
        return AdminPalette.error;
      default:
        return AdminPalette.textMuted;
    }
  }

  IconData _getStatusIcon(String status) {
    switch (status) {
      case 'pending':
        return Icons.pending;
      case 'approved':
        return Icons.check_circle;
      case 'rejected':
        return Icons.cancel;
      default:
        return Icons.info;
    }
  }

  String _formatTimestamp(dynamic timestamp) {
    if (timestamp == null) return 'N/A';
    DateTime? date;
    if (timestamp is DateTime) {
      date = timestamp;
    } else if (timestamp is String) {
      date = DateTime.tryParse(timestamp);
    }
    if (date == null) return 'N/A';
    return '${date.day}/${date.month}/${date.year} ${date.hour}:${date.minute.toString().padLeft(2, '0')}';
  }
}