// lib/features/calling/screens/call_history_screen.dart

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:shimmer/shimmer.dart';
import 'package:telemedicine/app/theme/app_theme.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/features/auth/presentation/providers/user_provider.dart';
import 'package:telemedicine/features/calling/controllers/call_controller.dart';
import 'package:telemedicine/features/calling/domain/call_model.dart';
import 'package:telemedicine/features/calling/domain/call_status.dart';
import 'package:telemedicine/features/calling/screens/outgoing_call_screen.dart';
import 'package:telemedicine/features/calling/widgets/call_timer.dart';
import 'package:telemedicine/shared/widgets/auth_layout.dart';
import 'package:telemedicine/shared/widgets/opd_design_system.dart';

class CallHistoryScreen extends ConsumerStatefulWidget {
  const CallHistoryScreen({super.key});

  @override
  ConsumerState<CallHistoryScreen> createState() => _CallHistoryScreenState();
}

class _CallHistoryScreenState extends ConsumerState<CallHistoryScreen> {
  final CallController _callController = CallController.instance;
  String _selectedFilter = 'All'; // 'All', 'Incoming', 'Outgoing', 'Missed', 'Rejected'

  final List<String> _filters = const [
    'All',
    'Incoming',
    'Outgoing',
    'Missed',
    'Rejected',
  ];

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(userProvider);
    if (user == null) {
      return const Scaffold(
        body: Center(child: Text('Please log in to view call history.')),
      );
    }

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
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Header
                Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: context.rsp(16),
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      CircularBackButton(
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Voice Call History',
                          style: TextStyle(
                            fontSize: context.fs(18),
                            fontWeight: FontWeight.bold,
                            color: const Color(0xFF1F2F44),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // Filter Chips Row
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: EdgeInsets.symmetric(
                    horizontal: context.rsp(16),
                    vertical: 6,
                  ),
                  physics: const BouncingScrollPhysics(),
                  child: Row(
                    children: _filters.map((filter) {
                      final isSelected = _selectedFilter == filter;
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(filter),
                          selected: isSelected,
                          onSelected: (val) {
                            if (val) setState(() => _selectedFilter = filter);
                          },
                          labelStyle: TextStyle(
                            fontSize: 12.5,
                            fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                            color: isSelected ? Colors.white : const Color(0xFF4A5568),
                          ),
                          selectedColor: AppColors.primaryRed,
                          backgroundColor: Colors.white,
                          side: BorderSide(
                            color: isSelected
                                ? AppColors.primaryRed
                                : const Color(0xFFDCE6F2),
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
                const SizedBox(height: 6),

                // Call Records List
                Expanded(
                  child: StreamBuilder<List<VoiceCallModel>>(
                    stream: _callController.getCallHistoryStream(user.id),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return _buildLoadingShimmer();
                      }
                      if (snapshot.hasError) {
                        return Center(
                          child: Text(
                            'Error loading call history: ${snapshot.error}',
                            style: const TextStyle(color: Colors.red),
                          ),
                        );
                      }

                      final calls = snapshot.data ?? [];
                      final filteredCalls = _filterCalls(calls, user.id);

                      if (filteredCalls.isEmpty) {
                        return _buildEmptyState();
                      }

                      return ListView.separated(
                        padding: EdgeInsets.symmetric(
                          horizontal: context.rsp(16),
                          vertical: 10,
                        ),
                        physics: const BouncingScrollPhysics(),
                        itemCount: filteredCalls.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (context, index) {
                          return _buildCallCard(filteredCalls[index], user.id);
                        },
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

  List<VoiceCallModel> _filterCalls(List<VoiceCallModel> all, String currentUserId) {
    if (_selectedFilter == 'All') return all;

    return all.where((call) {
      final isOutgoing = call.callerId == currentUserId;
      final isIncoming = !isOutgoing;
      final st = call.status.toLowerCase().trim();

      switch (_selectedFilter) {
        case 'Incoming':
          return isIncoming;
        case 'Outgoing':
          return isOutgoing;
        case 'Missed':
          return call.missedCall || st == CallingStatus.missed;
        case 'Rejected':
          return st == CallingStatus.rejected;
        default:
          return true;
      }
    }).toList();
  }

  Widget _buildCallCard(VoiceCallModel call, String currentUserId) {
    final isOutgoing = call.callerId == currentUserId;
    final otherName = isOutgoing ? call.receiverName : call.callerName;
    final otherImage = isOutgoing ? call.receiverImage : call.callerImage;
    final otherId = isOutgoing ? call.receiverId : call.callerId;
    final otherRole = isOutgoing ? call.receiverRole : call.callerRole;

    final isMissed = call.missedCall || call.status == CallingStatus.missed;
    final isRejected = call.status == CallingStatus.rejected;
    final isConnected = call.duration > 0 || call.status == CallingStatus.ended;

    IconData statusIcon;
    Color statusColor;
    String statusLabel;

    if (isMissed) {
      statusIcon = Icons.call_missed_rounded;
      statusColor = const Color(0xFFE53935);
      statusLabel = 'Missed';
    } else if (isRejected) {
      statusIcon = Icons.call_end_rounded;
      statusColor = const Color(0xFFE53935);
      statusLabel = 'Declined';
    } else if (isOutgoing) {
      statusIcon = Icons.call_made_rounded;
      statusColor = const Color(0xFF1E8E5A);
      statusLabel = isConnected ? 'Outgoing' : 'Unanswered';
    } else {
      statusIcon = Icons.call_received_rounded;
      statusColor = const Color(0xFF2196F3);
      statusLabel = 'Incoming';
    }

    final formattedDate = DateFormat('MMM d, h:mm a').format(call.createdAt.toLocal());

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFDCE6F2)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0F233C).withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          // Profile Avatar
          CircleAvatar(
            radius: 24,
            backgroundColor: const Color(0xFFF0F4FA),
            backgroundImage: (otherImage != null && otherImage.isNotEmpty)
                ? CachedNetworkImageProvider(otherImage)
                : null,
            child: (otherImage == null || otherImage.isEmpty)
                ? Text(
                    otherName.isNotEmpty ? otherName[0].toUpperCase() : '?',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF062B72),
                    ),
                  )
                : null,
          ),
          const SizedBox(width: 12),

          // Name and Details
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  otherName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF1F2F44),
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(statusIcon, size: 14, color: statusColor),
                    const SizedBox(width: 4),
                    Text(
                      statusLabel,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: statusColor,
                      ),
                    ),
                    if (call.duration > 0) ...[
                      const Text(
                        ' • ',
                        style: TextStyle(color: Color(0xFF9AA7B6)),
                      ),
                      Text(
                        CallTimerWidget.formatDuration(call.duration),
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF657991),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  formattedDate,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: Color(0xFF8A9BAE),
                  ),
                ),
              ],
            ),
          ),

          // Call Back Action Button
          IconButton(
            icon: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF11B7A8).withValues(alpha: 0.12),
              ),
              child: const Icon(
                Icons.call_rounded,
                color: Color(0xFF0E9A8E),
                size: 20,
              ),
            ),
            onPressed: () => _callBack(otherId, otherName, otherRole, otherImage),
          ),
        ],
      ),
    );
  }

  void _callBack(String receiverId, String receiverName, String receiverRole, String? receiverImage) async {
    final currentUser = ref.read(userProvider);
    if (currentUser == null) return;

    ToastService.instance.showInfo('Calling $receiverName...');
    final result = await _callController.initiateVoiceCall(
      callerId: currentUser.id,
      callerName: currentUser.fullname,
      callerRole: currentUser.role,
      callerImage: currentUser.image,
      receiverId: receiverId,
      receiverName: receiverName,
      receiverRole: receiverRole,
      receiverImage: receiverImage,
    );

    if (!mounted) return;

    if (result['success'] == true) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => OutgoingCallScreen(
            callId: result['callId'],
            receiverId: receiverId,
            receiverName: receiverName,
            receiverRole: receiverRole,
            receiverImage: receiverImage,
            currentUserId: currentUser.id,
            currentUserName: currentUser.fullname,
          ),
        ),
      );
    } else {
      ToastService.instance.showError(result['error'] ?? 'Could not place call');
    }
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF062B72).withValues(alpha: 0.08),
            ),
            child: const Icon(
              Icons.phone_missed_rounded,
              size: 48,
              color: Color(0xFF062B72),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'No ${_selectedFilter == 'All' ? '' : '$_selectedFilter '}calls found',
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Color(0xFF1F2F44),
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Your voice call history will appear here.',
            style: TextStyle(
              fontSize: 13,
              color: Color(0xFF657991),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingShimmer() {
    return Shimmer.fromColors(
      baseColor: const Color(0xFFE2E8F0),
      highlightColor: const Color(0xFFF8FAFC),
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: 6,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (_, __) => Container(
          height: 72,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
    );
  }
}

