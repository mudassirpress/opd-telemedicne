import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/admin_portal/admin_ui.dart';
import 'package:telemedicine/auth/doctor_profile/doctor_profile_screen.dart';
import 'package:telemedicine/auth/doctor_profile/update_doctor_profile.dart';
import 'package:telemedicine/auth/user_controller/doctor_controller.dart';
import 'package:telemedicine/doctor_portal/appointments/doctor_appointments_screen.dart';
import 'package:telemedicine/doctor_portal/bottom_nav/doctor_portal_tab_provider.dart';
import 'package:telemedicine/doctor_portal/doctor_portal_screen.dart';
import 'package:telemedicine/doctor_portal/shared_reports/doctor_shared_reports_screen.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/shared/widgets/app_states.dart';
import 'package:telemedicine/core/providers/badge_providers.dart';
import 'package:telemedicine/shared/widgets/badge_indicator.dart';

class DoctorPortalWrapper extends ConsumerStatefulWidget {
  const DoctorPortalWrapper({super.key, this.initialTab});

  /// Tab to open on — used by notification taps that must land on the
  /// appointment queue. `null` means the chat tab.
  final DoctorPortalTab? initialTab;

  @override
  ConsumerState<DoctorPortalWrapper> createState() =>
      _DoctorPortalWrapperState();
}

class _DoctorPortalWrapperState extends ConsumerState<DoctorPortalWrapper> {
  final List<Widget> _screens = const [
    DoctorPortalScreen(),
    DoctorAppointmentsScreen(),
    DoctorSharedReportsScreen(),
    DoctorProfileScreen(),
  ];

  /// False until the required `price` / `description` check has passed. The
  /// dashboard stays behind a loading state until then, so an incomplete
  /// profile can never reach the portal — including through notification
  /// deep links that push this screen directly.
  bool _profileCheckPassed = false;

  @override
  void initState() {
    super.initState();
    _applyInitialTab();
    _gateOnRequiredProfileFields();
  }

  /// Re-reads the doctor document and holds the portal back when the
  /// profile still owes a price or a description, sending the doctor to the
  /// existing completion screen instead. A complete profile passes through
  /// untouched, so nothing re-redirects once the fields are saved.
  Future<void> _gateOnRequiredProfileFields() async {
    final doctorController = ref.read(doctorControllerProvider);

    // Without a doctor session there is nothing to verify here; the
    // portal's own loading state keeps handling that case as before.
    if (doctorController.currentDoctor == null) {
      if (mounted) {
        setState(() {
          _profileCheckPassed = true;
        });
      }
      return;
    }

    final needsCompletion = await doctorController.requiresProfileCompletion();
    if (!mounted) return;

    if (needsCompletion) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const UpdateDoctorProfile()),
      );
      return;
    }

    setState(() {
      _profileCheckPassed = true;
    });
  }

  /// Selects [initialTab] without writing a provider from `initState`, which
  /// runs inside the build pass Riverpod rejects with "Tried to modify a
  /// provider while the widget tree was building". Same contract as the
  /// patient shell: the tab already held (chat, the provider's default) is
  /// left untouched, anything else is applied after the current frame. The
  /// seed stays here rather than in `dispose` so an outgoing instance cannot
  /// overwrite the tab a deep-link push just selected.
  void _applyInitialTab() {
    final requestedIndex = (widget.initialTab ?? DoctorPortalTab.chat).index;
    if (ref.read(doctorPortalTabProvider) == requestedIndex) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(doctorPortalTabProvider.notifier).state = requestedIndex;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_profileCheckPassed) {
      return Scaffold(
        backgroundColor: AdminPalette.background,
        body: const AppLoadingIndicator(
          label: 'Checking your doctor profile...',
        ),
      );
    }

    final currentIndex = ref.watch(doctorPortalTabProvider);

    final unreadChats = ref.watch(unreadChatCountProvider).valueOrNull ?? 0;
    final unreadAppointments =
        ref.watch(unreadAppointmentsCountProvider).valueOrNull ?? 0;
    final unreadReports =
        ref.watch(unreadReportsCountProvider).valueOrNull ?? 0;

    return PopScope(
      canPop: currentIndex == DoctorPortalTab.chat.index,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          ref.read(doctorPortalTabProvider.notifier).state =
              DoctorPortalTab.chat.index;
        }
      },
      child: Scaffold(
        backgroundColor: AdminPalette.background,
        body: IndexedStack(
          index: currentIndex,
          children: _screens,
        ),
        bottomNavigationBar: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border(
              top: BorderSide(
                color: AdminPalette.divider.withValues(alpha: 0.4),
              ),
            ),
            boxShadow: [
              BoxShadow(
                color: AdminPalette.cardShadow.withValues(alpha: 0.12),
                blurRadius: 16,
                offset: const Offset(0, -4),
              ),
            ],
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                context.rsp(8),
                6,
                context.rsp(8),
                6,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  Expanded(
                    child: _buildNavItem(
                      DoctorPortalTab.chat,
                      Icons.chat_rounded,
                      'Chat',
                      badgeCount: unreadChats,
                    ),
                  ),
                  Expanded(
                    child: _buildNavItem(
                      DoctorPortalTab.appointments,
                      Icons.calendar_month_rounded,
                      'Appointments',
                      badgeCount: unreadAppointments,
                      onTap: () {
                        markAppointmentsAsViewed(ref);
                        ref.read(doctorPortalTabProvider.notifier).state =
                            DoctorPortalTab.appointments.index;
                      },
                    ),
                  ),
                  Expanded(
                    child: _buildNavItem(
                      DoctorPortalTab.reports,
                      Icons.description_rounded,
                      'Reports',
                      badgeCount: unreadReports,
                      onTap: () {
                        markReportsAsViewed(ref);
                        ref.read(doctorPortalTabProvider.notifier).state =
                            DoctorPortalTab.reports.index;
                      },
                    ),
                  ),
                  Expanded(
                    child: _buildNavItem(
                      DoctorPortalTab.profile,
                      Icons.person_rounded,
                      'Profile',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNavItem(
    DoctorPortalTab tab,
    IconData icon,
    String label, {
    int badgeCount = 0,
    VoidCallback? onTap,
  }) {
    final isSelected = ref.watch(doctorPortalTabProvider) == tab.index;

    return GestureDetector(
      onTap: onTap ??
          () => ref.read(doctorPortalTabProvider.notifier).state = tab.index,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeInOut,
        padding: EdgeInsets.symmetric(horizontal: context.rsp(6), vertical: 6),
        decoration: isSelected
            ? BoxDecoration(
                gradient: AdminPalette.selectedGradient,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: AdminPalette.brandShadow.withValues(alpha: 0.3),
                    blurRadius: 8,
                    offset: const Offset(0, 3),
                  ),
                ],
              )
            : null,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            BadgeIndicator(
              count: badgeCount,
              offset: const Offset(-8, -4),
              child: Icon(
                icon,
                size: 22,
                color: isSelected ? Colors.white : AdminPalette.textMuted,
              ),
            ),
            const SizedBox(height: 3),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: context.fs(11),
                  fontWeight:
                      isSelected ? FontWeight.w600 : FontWeight.normal,
                  color: isSelected ? Colors.white : AdminPalette.textMuted,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
