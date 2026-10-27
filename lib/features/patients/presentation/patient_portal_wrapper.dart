import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/features/admin/presentation/admin_design_system.dart';
import 'package:telemedicine/features/patients/presentation/screens/patient_profile_screen.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/features/appointments/presentation/appointment_screen.dart';
import 'package:telemedicine/features/patients/presentation/patient_portal_tab_provider.dart';
import 'package:telemedicine/features/chat/presentation/room_chat_screen.dart';
import 'package:telemedicine/core/providers/badge_providers.dart';
import 'package:telemedicine/shared/widgets/badge_indicator.dart';

/// Patient shell holding exactly three tabs — Chat, Appointments and Profile.
///
/// Visually identical to [DoctorPortalWrapper] and the admin wrapper: a white
/// bar with a gradient pill on the active item, and an `IndexedStack` so each
/// tab keeps its own state when the patient switches away.
class PatientPortalWrapper extends ConsumerStatefulWidget {
  const PatientPortalWrapper({super.key, this.initialTab});

  /// Tab to open on. `null` means Chat — what a fresh sign-in shows.
  final PatientPortalTab? initialTab;

  /// Navigation guard so a notification tap cannot stack a second wrapper.
  static bool isPatientPortalOpen = false;

  @override
  ConsumerState<PatientPortalWrapper> createState() =>
      _PatientPortalWrapperState();
}

class _PatientPortalWrapperState extends ConsumerState<PatientPortalWrapper> {
  static const List<Widget> _screens = <Widget>[
    ChatRoomScreen(),
    AppointmentScreen(),
    PatientProfileScreen(),
  ];

  @override
  void initState() {
    super.initState();
    PatientPortalWrapper.isPatientPortalOpen = true;
    _applyInitialTab();
  }

  /// Selects [initialTab] without touching a provider from inside a
  /// widget life-cycle.
  ///
  /// `initState` runs inside the very build pass Riverpod guards: writing the
  /// tab from here made `_UncontrolledProviderScopeElement.markNeedsBuild`
  /// throw "Tried to modify a provider while the widget tree was building",
  /// which is what stopped Patient Login → Room Chat from opening. The tab the
  /// provider already holds (Chat — its default and what a fresh sign-in asks
  /// for) needs no write at all, so the normal path never defers anything; any
  /// other tab is applied once the current frame has finished building.
  ///
  /// The seed still happens here rather than in `dispose`: a deep-link push
  /// that replaces this route must not have its tab overwritten by the
  /// outgoing instance.
  void _applyInitialTab() {
    final requestedTab = widget.initialTab ?? PatientPortalTab.chat;
    if (ref.read(patientPortalTabProvider) == requestedTab) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(patientPortalTabProvider.notifier).state = requestedTab;
    });
  }

  @override
  void dispose() {
    PatientPortalWrapper.isPatientPortalOpen = false;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentTab = ref.watch(patientPortalTabProvider);

    final unreadChats = ref.watch(unreadChatCountProvider).valueOrNull ?? 0;
    final unreadAppointments =
        ref.watch(unreadAppointmentsCountProvider).valueOrNull ?? 0;

    return PopScope(
      canPop: currentTab == PatientPortalTab.chat,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          ref.read(patientPortalTabProvider.notifier).state =
              PatientPortalTab.chat;
        }
      },
      child: Scaffold(
        backgroundColor: AdminPalette.background,
        body: IndexedStack(
          index: currentTab.navIndex,
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
                      PatientPortalTab.chat,
                      Icons.chat_rounded,
                      'Chat',
                      badgeCount: unreadChats,
                    ),
                  ),
                  Expanded(
                    child: _buildNavItem(
                      PatientPortalTab.appointments,
                      Icons.calendar_month_rounded,
                      'Appointments',
                      badgeCount: unreadAppointments,
                      onTap: () {
                        markAppointmentsAsViewed(ref);
                        ref.read(patientPortalTabProvider.notifier).state =
                            PatientPortalTab.appointments;
                      },
                    ),
                  ),
                  Expanded(
                    child: _buildNavItem(
                      PatientPortalTab.profile,
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
    PatientPortalTab tab,
    IconData icon,
    String label, {
    int badgeCount = 0,
    VoidCallback? onTap,
  }) {
    final isSelected = ref.watch(patientPortalTabProvider) == tab;

    return GestureDetector(
      onTap: onTap ??
          () => ref.read(patientPortalTabProvider.notifier).state = tab,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeInOut,
        padding: EdgeInsets.symmetric(horizontal: context.rsp(8), vertical: 6),
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
