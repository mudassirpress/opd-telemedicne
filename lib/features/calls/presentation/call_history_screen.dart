// lib/features/calls/presentation/call_history_screen.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shimmer/shimmer.dart';
import 'package:telemedicine/features/auth/presentation/providers/user_provider.dart';
import 'package:telemedicine/features/calls/presentation/controllers/call_controller.dart';
import 'package:telemedicine/data/models/call_model.dart';
import 'package:telemedicine/features/calls/presentation/call_screen.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/shared/widgets/auth_layout.dart';

class CallHistoryScreen extends ConsumerStatefulWidget {
  const CallHistoryScreen({super.key});
  @override
  ConsumerState<CallHistoryScreen> createState() => _CallHistoryScreenState();
}

class _CallHistoryScreenState extends ConsumerState<CallHistoryScreen> {
  final CallController _callController = CallController();
  bool _isInitializing = false;
  @override
  void initState() {
    super.initState();
    _initializeCallController();
  }

  Future<void> _initializeCallController() async {
    if (_isInitializing) return;
    _isInitializing = true;
    try {
      await _callController.initializeZego(enableVideo: false);
    } catch (e) {
      debugPrint('Error pre-initializing call controller: $e');
    } finally {
      _isInitializing = false;
    }
  }

  @override
  void dispose() {
    // NOT dispose(): the CallController is an app-wide singleton; closing the
    // history screen must not tear down live call timers/state.
    _callController.resetForScreen();
    super.dispose();
  }

  Future<void> _refreshCallHistory() async {
    await Future.delayed(const Duration(milliseconds: 500));
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(userProvider);
    if (user == null) {
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
                      horizontal: context.rsp(20),
                      vertical: 12,
                    ),
                    child: Row(
                      children: [
                        const CircularBackButton(),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Call History',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: context.fs(16),
                              fontWeight: FontWeight.w700,
                              color: const Color(0xFF1F2F44),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(20),
                            decoration: BoxDecoration(
                              color: const Color(0xFFD6E4F0).withValues(alpha: 0.4),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              Icons.person_off_outlined,
                              size: 64,
                              color: const Color(0xFF062B72).withValues(alpha: 0.4),
                            ),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'Please sign in to view call history',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: context.fs(14),
                              fontWeight: FontWeight.w600,
                              color: const Color(0xFF1F2F44),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  
                ],
              ),
            ),
          ],
        ),
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
              children: [
                Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: context.rsp(20),
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      const CircularBackButton(),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Call History',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: context.fs(16),
                            fontWeight: FontWeight.w700,
                            color: const Color(0xFF1F2F44),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: _refreshCallHistory,
                    color: const Color(0xFF062B72),
                    backgroundColor: Colors.white,
                    strokeWidth: 2.5,
                    displacement: 40,
                    child: StreamBuilder<List<CallModel>>(
                      key: ValueKey('call_history_${user.id}'),
                      stream: _callController.getCallHistory(user.id),
                      builder: (context, snapshot) {
                        if (snapshot.connectionState == ConnectionState.waiting) {
                          return _buildShimmerLoading();
                        }
                        if (snapshot.hasError) {
                          return _buildErrorState(snapshot.error.toString());
                        }
                        if (!snapshot.hasData || snapshot.data!.isEmpty) {
                          return _buildEmptyState();
                        }
                        final calls = snapshot.data!;
                        return ListView.separated(
                          physics: const BouncingScrollPhysics(),
                          padding: EdgeInsets.symmetric(
                            horizontal: context.rsp(20),
                            vertical: 8,
                          ),
                          itemCount: calls.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 12),
                          itemBuilder: (context, index) {
                            return _buildCallTile(calls[index], user.id);
                          },
                        );
                      },
                    ),
                  ),
                ),
                
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState(String error) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
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
              'Error loading call history',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: context.fs(16),
                fontWeight: FontWeight.w700,
                color: const Color(0xFF1F2F44),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              error,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: context.fs(13),
                color: const Color(0xFF6B7B8D),
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            GradientButton(
              text: 'Retry',
              icon: Icons.refresh_rounded,
              onPressed: _refreshCallHistory,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildShimmerLoading() {
    return ListView.builder(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      itemCount: 8,
      itemBuilder: (context, index) {
        return Shimmer.fromColors(
          baseColor: const Color(0xFFD6E4F0),
          highlightColor: const Color(0xFFF5F8FC),
          period: const Duration(milliseconds: 1500),
          child: Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(3),
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
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
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
              child: Row(
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: double.infinity,
                          height: 16,
                          color: Colors.white,
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Container(width: 14, height: 14, color: Colors.white),
                            const SizedBox(width: 4),
                            Container(width: 60, height: 12, color: Colors.white),
                            const SizedBox(width: 8),
                            Container(width: 50, height: 12, color: Colors.white),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Container(width: 22, height: 22, color: Colors.white),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildEmptyState() {
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
                Icons.call_outlined,
                size: 80,
                color: const Color(0xFF062B72).withValues(alpha: 0.4),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'No call history',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: context.fs(16),
                fontWeight: FontWeight.w700,
                color: const Color(0xFF1F2F44),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Your calls will appear here',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: context.fs(13),
                color: const Color(0xFF6B7B8D),
              ),
            ),
            const SizedBox(height: 24),
            InfoCard(
              title: 'Make a call',
              description: 'Start a call to see it appear here.',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCallTile(CallModel call, String currentUserId) {
    final isCaller = call.callerId == currentUserId;
    final otherName = isCaller ? call.receiverName : call.callerName;
    final otherImage = isCaller ? call.receiverImage : call.callerImage;
    final isVideo = call.callType == 'video';
    final isMissed = call.callStatus == 'missed';
    final isRejected = call.callStatus == 'rejected';
    final user = ref.read(userProvider);
    final isDoctor = user?.role == 'doctor';
    final canCallBack = !isDoctor;

    Color statusColor;
    IconData statusIcon;
    String statusText;
    if (isMissed) {
      statusColor = const Color(0xFFDC3545);
      statusIcon = isCaller ? Icons.call_made_rounded : Icons.call_received_rounded;
      statusText = 'Missed';
    } else if (isRejected) {
      statusColor = const Color(0xFFE8890C);
      statusIcon = Icons.call_end_rounded;
      statusText = 'Rejected';
    } else {
      statusColor = const Color(0xFF28A745);
      statusIcon = isCaller ? Icons.call_made_rounded : Icons.call_received_rounded;
      statusText = call.duration != null && call.duration! > 0
          ? _formatDuration(call.duration!)
          : 'Completed';
    }

    return Dismissible(
      key: Key(call.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Colors.red.withValues(alpha: 0.8),
              Colors.red,
            ],
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
          ),
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Icon(Icons.delete_rounded, color: Colors.white),
      ),
      confirmDismiss: (direction) async {
        return await showDialog(
          context: context,
          builder: (BuildContext context) {
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              title: Text(
                'Delete Call History',
                style: TextStyle(
                  fontSize: context.fs(15),
                  fontWeight: FontWeight.w700,
                  color: const Color(0xFF1F2F44),
                ),
              ),
              content: Text(
                'Are you sure you want to delete this call history?',
                style: TextStyle(
                  fontSize: context.fs(13),
                  color: const Color(0xFF6B7B8D),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text(
                    'Cancel',
                    style: TextStyle(
                      color: const Color(0xFF6B7B8D),
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(true),
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
      },
      onDismissed: (direction) async {
        await _callController.deleteCallHistory(call.id);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Call history deleted',
                style: TextStyle(),
              ),
              backgroundColor: const Color(0xFF062B72),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          );
        }
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(3),
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
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
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
          child: Opacity(
            opacity: isDoctor ? 0.6 : 1.0,
            child: Row(
              children: [
                // Avatar
                CircleAvatar(
                  radius: 26,
                  backgroundColor: const Color(0xFFD6E4F0).withValues(alpha: 0.4),
                  backgroundImage: otherImage != null && otherImage.isNotEmpty
                      ? NetworkImage(otherImage)
                      : null,
                  child: otherImage == null || otherImage.isEmpty
                      ? Text(
                          otherName.isNotEmpty ? otherName[0].toUpperCase() : '?',
                          style: TextStyle(
                            color: const Color(0xFF062B72),
                            fontWeight: FontWeight.w700,
                            fontSize: 18,
                          ),
                        )
                      : null,
                ),
                const SizedBox(width: 12),

                // Name + Status
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        otherName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: context.fs(14),
                          color: isMissed
                              ? const Color(0xFFDC3545)
                              : const Color(0xFF1F2F44),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(statusIcon, size: 14, color: statusColor),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              statusText,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: context.fs(12),
                                color: statusColor,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              _formatTimeAgo(call.startTime),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: context.fs(11),
                                color: const Color(0xFF8FA4BD),
                              ),
                            ),
                          ),
                          if (isDoctor) ...[
                            const SizedBox(width: 8),
                            Icon(
                              Icons.lock_rounded,
                              size: 12,
                              color: const Color(0xFF8FA4BD),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),

                // Call Type Icon
                GestureDetector(
                  onTap: canCallBack
                      ? () => _callBack(call, currentUserId, isCaller)
                      : null,
                  child: Container(
                    width: 40,
                    height: 40,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: canCallBack
                          ? const Color(0xFF062B72).withValues(alpha: 0.1)
                          : const Color(0xFFD6E4F0).withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      isVideo ? Icons.videocam_rounded : Icons.call_rounded,
                      color: canCallBack
                          ? const Color(0xFF062B72)
                          : const Color(0xFF8FA4BD),
                      size: 20,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _callBack(
    CallModel call,
    String currentUserId,
    bool wasCaller,
  ) async {
    final otherUserId = wasCaller ? call.receiverId : call.callerId;
    final otherName = wasCaller ? call.receiverName : call.callerName;
    final otherImage = wasCaller ? call.receiverImage : call.callerImage;
    final user = ref.read(userProvider);
    if (user == null) {
      ToastService.instance.showError('User not logged in');
      return;
    }
    ToastService.instance.showInfo('Initializing call...');
    final channelId =
        '${user.id}_${otherUserId}_${DateTime.now().millisecondsSinceEpoch}';
    final otherUserType = await _determineUserType(otherUserId);
    final currentUserRole = user.role;
    final result = await _callController.startCallWithCheck(
      channelId: channelId,
      callerId: user.id,
      receiverId: otherUserId,
      callerName: user.fullname,
      receiverName: otherName,
      callerImage: user.image,
      receiverImage: otherImage,
      callType: call.callType,
      receiverType: otherUserType,
      callerType: currentUserRole,
    );
    if (!mounted) return;
    if (!result['success']) {
      ToastService.instance.showError(
        result['error'] ?? 'Failed to start call',
      );
      return;
    }
    final callId = result['callId'];
    if (callId == null) {
      ToastService.instance.showError('Failed to start call');
      return;
    }
    ToastService.instance.showSuccess('Calling $otherName...');
    if (!_callController.isInitialized) {
      final initialized = await _callController.initializeZego(
        enableVideo: call.callType == 'video',
      );
      if (!initialized && mounted) {
        ToastService.instance.showError('Failed to initialize call engine');
        return;
      }
    }
    final joined = await _callController.joinRoom(
      roomId: channelId,
      uid: user.id,
      userName: user.fullname.isNotEmpty ? user.fullname : 'User',
      isVideo: call.callType == 'video',
    );
    if (!joined && mounted) {
      ToastService.instance.showError('Failed to join call');
      return;
    }
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => CallScreen(
          channelId: channelId,
          callId: callId,
          callType: call.callType,
          otherUserName: otherName,
          otherUserImage: otherImage ?? '',
          currentUserId: user.id,
          otherUserId: otherUserId,
          otherUserType: otherUserType,
          isCaller: true,
        ),
      ),
    );
  }

  Future<String> _determineUserType(String userId) async {
    try {
      final firestore = FirebaseFirestore.instance;
      final doctorDoc = await firestore
          .collection('telemedicine_doctors')
          .doc(userId)
          .get();
      if (doctorDoc.exists) {
        return 'doctor';
      }
      final patientDoc = await firestore
          .collection('telemedicine_patient')
          .doc(userId)
          .get();
      if (patientDoc.exists) {
        return 'patient';
      }
      return 'patient';
    } catch (e) {
      debugPrint('Error determining user type: $e');
      return 'patient';
    }
  }

  String _formatDuration(int seconds) {
    if (seconds < 60) return '${seconds}s';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    if (m < 60) return '${m}m ${s}s';
    final h = m ~/ 60;
    final remainingM = m % 60;
    return '${h}h ${remainingM}m';
  }

  String _formatTimeAgo(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    if (diff.inDays < 30) return '${(diff.inDays / 7).floor()}w ago';
    return '${time.day}/${time.month}/${time.year}';
  }
}
