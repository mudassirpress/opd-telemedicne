import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/auth/user_controller/doctor_controller.dart';
import 'package:telemedicine/home_screen/chatting_list_widget/chatting_list_widget.dart';
import 'package:telemedicine/home_widget/chat_call/call/call_history_screen.dart';
import 'package:telemedicine/doctor_portal/bottom_nav/doctor_portal_tab_provider.dart';
import 'package:telemedicine/core/theme/app_theme.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/shared/widgets/auth_layout.dart';

class DoctorPortalScreen extends ConsumerStatefulWidget {
  const DoctorPortalScreen({super.key});

  @override
  ConsumerState<DoctorPortalScreen> createState() =>
      _DoctorPortalScreenState();
}

class _DoctorPortalScreenState extends ConsumerState<DoctorPortalScreen> {
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  bool _isLoading = true;
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

  Future<void> _checkAndLoadDoctorProfile() async {
    if (!mounted) return;

    setState(() {
      _isLoading = true;
    });

    try {
      final doctorController = ref.read(doctorControllerProvider);

      if (doctorController.currentDoctor == null) {
        await doctorController.loadDoctorFromLocalStorage();
      }

      if (doctorController.currentDoctor != null) {
        setState(() {
          isOnline = doctorController.isDoctorOnline;
        });
      }

      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    } catch (e) {
      ToastService.instance.showError(
        'Error loading doctor profile: ${e.toString()}',
      );
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() {
      _searchQuery = '';
    });
    ToastService.instance.showInfo('Search cleared');
  }

  bool _isToggling = false;

  Future<void> _toggleOnlineStatus() async {
    if (_isToggling) return;
    _isToggling = true;

    final doctorController = ref.read(doctorControllerProvider);
    final targetStatus = !isOnline;

    final success = await doctorController.toggleDoctorStatus(targetStatus);

    if (mounted) {
      setState(() {
        isOnline = doctorController.isDoctorOnline;
        _isToggling = false;
      });

      if (success) {
        if (targetStatus) {
          ToastService.instance.showSuccess('You are now online and ready for calls');
        } else {
          ToastService.instance.showInfo('You are now offline');
        }
      } else {
        ToastService.instance.showWarning('Failed to update online status. Please check your connection.');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final doctorController = ref.watch(doctorControllerProvider);
    final currentDoctor = doctorController.currentDoctor;

    // Keep toggle visual state bound to central controller
    if (!_isToggling && isOnline != doctorController.isDoctorOnline) {
      isOnline = doctorController.isDoctorOnline;
    }

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
                      GestureDetector(
                        onTap: _toggleOnlineStatus,
                        child: Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: context.rsp(12),
                            vertical: 7,
                          ),
                          decoration: BoxDecoration(
                            color: isOnline
                                ? const Color(0xFF4CAF50)
                                : const Color(0xFFBDBDBD),
                            borderRadius: BorderRadius.circular(20),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(0xFF0F233C)
                                    .withValues(alpha: 0.08),
                                blurRadius: 10,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 7,
                                height: 7,
                                decoration: const BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                isOnline ? 'Online' : 'Offline',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: context.fs(12),
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
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
                          ToastService.instance.showInfo('Opening call history');
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
                  padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 8),
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
              child: ChatingListWidget(
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

  Widget _buildDoctorAvatar(dynamic currentDoctor) {
    return GestureDetector(
      onTap: () {
        ref.read(doctorPortalTabProvider.notifier).state =
            DoctorPortalTab.profile.index;
      },
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: const Color(0xFFDCE6F2), width: 2),
        ),
        child: CircleAvatar(
          radius: 20,
          backgroundColor: const Color(0xFFF0F4FA),
          backgroundImage:
              (currentDoctor?.image != null &&
                      currentDoctor!.image!.isNotEmpty)
                  ? NetworkImage(currentDoctor!.image!)
                  : null,
          child:
              (currentDoctor?.image == null || currentDoctor!.image!.isEmpty)
                  ? Text(
                      (currentDoctor?.fullname ?? 'D')
                              .isNotEmpty
                          ? (currentDoctor!.fullname ?? 'D')[0]
                              .toUpperCase()
                          : 'D',
                      style: TextStyle(
                        color: AppColors.primaryRed,
                        fontSize: context.fs(15),
                        fontWeight: FontWeight.w600,
                      ),
                    )
                  : null,
        ),
      ),
    );
  }
}
