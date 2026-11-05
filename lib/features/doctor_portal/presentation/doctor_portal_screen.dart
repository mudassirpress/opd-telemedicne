import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/features/auth/presentation/controllers/doctor_controller.dart';
import 'package:telemedicine/features/chat/presentation/chat_list_widget.dart';
import 'package:telemedicine/features/calls/presentation/call_history_screen.dart';
import 'package:telemedicine/app/theme/app_theme.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/shared/widgets/auth_layout.dart';

class DoctorPortalScreen extends ConsumerStatefulWidget {
  const DoctorPortalScreen({super.key});

  @override
  ConsumerState<DoctorPortalScreen> createState() => _DoctorPortalScreenState();
}

class _DoctorPortalScreenState extends ConsumerState<DoctorPortalScreen> {
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  bool _isLoading = true;
  bool _isUpdatingAvailability = false;
  bool isOnline = false;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      setState(() {
        _searchQuery = _searchController.text.trim().toLowerCase();
      });
    });
    _checkAndLoadDoctorProfile();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _toggleAvailability(bool currentStatus) async {
    if (_isUpdatingAvailability) return;
    setState(() => _isUpdatingAvailability = true);

    final newStatus = !currentStatus;
    try {
      final success = await ref
          .read(doctorControllerProvider)
          .toggleDoctorStatus(newStatus);

      if (success) {
        setState(() {
          isOnline = newStatus;
        });
        if (newStatus) {
          ToastService.instance.showSuccess(
            'You are now Online. Ready to receive voice consultations.',
          );
        } else {
          ToastService.instance.showInfo(
            'You are now Offline. Patients cannot call you.',
          );
        }
      } else {
        ToastService.instance.showError(
          'Failed to update availability. Please try again.',
        );
      }
    } catch (e) {
      ToastService.instance.showError('Unable to update status. Please try again.');
    } finally {
      if (mounted) {
        setState(() => _isUpdatingAvailability = false);
      }
    }
  }

  Future<void> _checkAndLoadDoctorProfile() async {
    if (!mounted) return;

    final doctorController = ref.read(doctorControllerProvider);
    if (doctorController.currentDoctor == null) {
      setState(() {
        _isLoading = true;
      });
    }

    try {
      if (doctorController.currentDoctor == null) {
        await doctorController.loadDoctorFromLocalStorage();
      }

      if (doctorController.currentDoctor != null && mounted) {
        setState(() {
          isOnline = doctorController.isDoctorOnline;
        });
      }
    } catch (e) {
      debugPrint('⚠️ [DoctorPortalScreen] Profile load error: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final doctorController = ref.watch(doctorControllerProvider);
    final currentDoctor = doctorController.currentDoctor;

    // Automated presence state bound directly to central controller
    isOnline = doctorController.isDoctorOnline;

    if (_isLoading) {
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
            const Center(
              child: CircularProgressIndicator(
                color: AppColors.primaryRed,
                strokeWidth: 2.5,
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFFEDF2F8),
      body: SafeArea(
        child: Column(
          children: [
            if (!isOnline)
              Container(
                width: double.infinity,
                color: const Color(0xFFE53935),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 7,
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.wifi_off_rounded,
                      color: Colors.white,
                      size: 16,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Internet connection unstable or package expired. Calls may not connect.',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: context.fs(11),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            Container(
              padding: EdgeInsets.symmetric(
                horizontal: context.rsp(16),
                vertical: 8,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const SizedBox(width: 0),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Telemedicine',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: context.fs(17),
                                fontWeight: FontWeight.bold,
                                color: const Color(0xFF1F2F44),
                                letterSpacing: -0.5,
                              ),
                            ),
                            Text(
                              'Your healthcare dashboard',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: context.fs(12),
                                color: const Color(0xFF657991),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Tooltip(
                        message: isOnline
                            ? 'You are Online. Tap to switch to Offline'
                            : 'You are Offline. Tap to switch to Online',
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: _isUpdatingAvailability
                                ? null
                                : () => _toggleAvailability(isOnline),
                            borderRadius: BorderRadius.circular(20),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 250),
                              padding: EdgeInsets.symmetric(
                                horizontal: context.rsp(12),
                                vertical: 7,
                              ),
                              decoration: BoxDecoration(
                                color: isOnline
                                    ? const Color(0xFF1E8E5A)
                                    : const Color(0xFF78909C),
                                borderRadius: BorderRadius.circular(20),
                                boxShadow: [
                                  BoxShadow(
                                    color: (isOnline
                                            ? const Color(0xFF1E8E5A)
                                            : const Color(0xFF78909C))
                                        .withValues(alpha: 0.28),
                                    blurRadius: 8,
                                    offset: const Offset(0, 3),
                                  ),
                                ],
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (_isUpdatingAvailability) ...[
                                    const SizedBox(
                                      width: 10,
                                      height: 10,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 1.5,
                                        valueColor:
                                            AlwaysStoppedAnimation<Color>(
                                          Colors.white,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                  ] else ...[
                                    AnimatedContainer(
                                      duration:
                                          const Duration(milliseconds: 200),
                                      width: 8,
                                      height: 8,
                                      decoration: const BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: Colors.white,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                  ],
                                  Text(
                                    isOnline ? 'Online' : 'Offline',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: context.fs(12),
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: 0.2,
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  Icon(
                                    isOnline
                                        ? Icons.check_circle_rounded
                                        : Icons.power_settings_new_rounded,
                                    color: Colors.white.withValues(alpha: 0.9),
                                    size: 13,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Color(0xFFE8EDF3),
                          ),
                          child: Icon(
                            Icons.call_rounded,
                            color: AppColors.primaryRed,
                            size: 20,
                          ),
                        ),
                        onPressed: () {
                          ToastService.instance.showInfo(
                            'Opening call history',
                          );
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const CallHistoryScreen(),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 0,
                      vertical: 8,
                    ),
                    child: MetallicInput(
                      hintText: 'Search doctors by name...',
                      icon: Icons.search_rounded,
                      controller: _searchController,
                      validator: null,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ChatListWidget(
                searchQuery: _searchQuery,
                adminView: true,
                doctorId: currentDoctor?.doctorId,
                doctorName: currentDoctor?.fullname,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
