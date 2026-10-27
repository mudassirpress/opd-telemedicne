import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/features/admin/presentation/admin_design_system.dart';
import 'package:telemedicine/features/admin/presentation/create_doctor_id/create_doctor_id_screen.dart';
import 'package:telemedicine/features/admin/presentation/doctor_online_history/doctor_online_history_screen.dart';
import 'package:telemedicine/features/admin/presentation/notifications/admin_reactivation_screen.dart';
import 'package:telemedicine/features/admin/presentation/notifications/admin_payment_screen.dart';
import 'package:telemedicine/features/admin/presentation/patient_id_management/patient_id_management_screen.dart';
import 'package:telemedicine/features/auth/presentation/providers/user_provider.dart';
import 'package:telemedicine/features/auth/presentation/screens/sign_in_screen.dart';
import 'package:telemedicine/features/auth/presentation/controllers/doctor_controller.dart';
import 'package:telemedicine/core/services/doctor_presence_service.dart';
import 'package:telemedicine/app/theme/app_theme.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/features/chat/presentation/chat_list_widget.dart';

class AdminChatManagementScreen extends ConsumerStatefulWidget {
  /// Document id of a doctor to preselect (used by the dashboard's Recent
  /// Chats rows). When absent the first doctor is auto-selected as before.
  final String? initialDoctorId;

  const AdminChatManagementScreen({super.key, this.initialDoctorId});

  @override
  ConsumerState<AdminChatManagementScreen> createState() => _AdminChatManagementScreenState();
}

class _AdminChatManagementScreenState extends ConsumerState<AdminChatManagementScreen> {
  final TextEditingController _searchController = TextEditingController();

  List<Map<String, dynamic>> _doctorProfiles = [];
  bool _isLoadingProfiles = true;
  String _errorMessage = '';
  String _searchQuery = '';
  String? _selectedDoctorId;
  Map<String, dynamic>? _selectedDoctor;

  /// Subscription to the shared doctor-list stream.
  ///
  /// This is the same broadcast stream the patient-side Doctor List / Grid
  /// subscribe to, so this screen adds no extra Firestore listener.
  StreamSubscription<List<Map<String, dynamic>>>? _doctorProfilesSub;

  /// The shared stream, acquired exactly ONCE in [initState].
  ///
  /// Retries ([_loadDoctorProfiles] → [_subscribeToDoctorProfiles]) resubscribe
  /// to THIS instance. The old code called `streamAllDoctors()` again on every
  /// retry, and that method increments the controller's listener ref-count —
  /// while [dispose] decremented only once, so each retry permanently leaked a
  /// count and kept the Firestore listener alive after the screen closed.
  Stream<List<Map<String, dynamic>>>? _doctorProfilesStream;

  /// Guards the one-time "Loaded N doctors" toast against the stream's
  /// 15-second re-emissions, which would otherwise re-toast while the admin is
  /// working.
  bool _hasAnnouncedInitialLoad = false;

  /// Captured in [initState] so [dispose] can balance the stream ref-count
  /// without touching `ref`, which must not be used once the state is gone.
  DoctorController? _doctorController;

  @override
  void initState() {
    super.initState();
    _doctorController = ref.read(doctorControllerProvider);
    _doctorProfilesStream = _doctorController?.streamAllDoctors();
    _subscribeToDoctorProfiles();
  }

  @override
  void dispose() {
    _doctorProfilesSub?.cancel();
    // Balances the `streamAllDoctors()` call made in initState. The controller
    // tears down the underlying Firestore listener and its 15s refresh timer
    // once the last consumer leaves, so an admin session that is the only
    // subscriber does not keep a query running for the rest of the process.
    _doctorController?.disposeDoctorListStream();
    _searchController.dispose();
    super.dispose();
  }

  /// Attaches to the shared realtime doctor list.
  ///
  /// Replaces the previous one-shot `getAllDoctorProfiles()` read. Every
  /// Firestore event on `telemedicine_doctors` now pushes a new list: a new
  /// doctor appears, a profile edit shows up, and a soft-delete / freeze drops
  /// the doctor out — all without the admin touching the screen. The stream
  /// also re-emits every 15 seconds from a cached snapshot, so a stale
  /// heartbeat flips a doctor to offline even when nobody writes to Firestore.
  void _subscribeToDoctorProfiles() {
    _doctorProfilesSub?.cancel();

    // Paint from the shared stream's cached list straight away. The stream is a
    // broadcast controller and does not replay, so a screen opened after the
    // stream is already running would otherwise sit on the loading state until
    // the next Firestore event or 15-second tick. No extra read is involved —
    // this is the same data the subscription is about to deliver.
    final cached = _doctorController?.cachedDoctors ?? const [];
    if (cached.isNotEmpty && _doctorProfiles.isEmpty) {
      // Own the list: `_deleteDoctor` removes from it in place.
      _doctorProfiles = List<Map<String, dynamic>>.of(cached);
      _isLoadingProfiles = false;
    }

    _doctorProfilesSub = _doctorProfilesStream?.listen(
      (profiles) {
        if (!mounted) return;
        setState(() {
          _doctorProfiles = profiles;
          _isLoadingProfiles = false;
          _errorMessage = '';

          final selectedId = _selectedDoctorId;
          if (selectedId == null) {
            // Nothing selected. Prefer the caller's preselected doctor, then
            // fall back to the first doctor, and announce it only once so the
            // 15-second re-emissions do not re-toast.
            final initialId = widget.initialDoctorId;
            Map<String, dynamic>? target;
            if (initialId != null && initialId.isNotEmpty) {
              target = _findById(profiles, initialId);
            }
            target ??= profiles.isNotEmpty ? profiles.first : null;
            if (target != null) {
              _selectedDoctor = target;
              _selectedDoctorId = target['id'].toString();
              if (!_hasAnnouncedInitialLoad) {
                _hasAnnouncedInitialLoad = true;
                ToastService.instance.showSuccess(
                  'Loaded ${profiles.length} doctors',
                );
              }
            }
            return;
          }

          // Re-resolve the selection against the fresh list.
          //
          // `_selectedDoctor` holds a reference to one of the *previous*
          // emission's maps, so without this the admin would keep reading a
          // stale copy of the doctor's name and degree in the header and
          // subtitle after they edit their profile.
          final refreshed = _findById(profiles, selectedId);
          if (refreshed != null) {
            _selectedDoctor = refreshed;
          } else {
            // The selected doctor was soft-deleted, frozen or deactivated and
            // the shared stream has dropped them from active listings.
            _selectedDoctor = null;
            _selectedDoctorId = null;
          }
        });
      },
      onError: (Object error) {
        if (!mounted) return;
        setState(() {
          _isLoadingProfiles = false;
          // Only surface the error state if nothing has ever loaded; otherwise
          // keep showing the last good list, which is strictly more useful
          // than blanking the admin's screen on a blip.
          if (_doctorProfiles.isEmpty) {
            _errorMessage = 'Unable to load doctor profiles';
          }
        });
      },
    );
  }

  /// Retry hook for the error state.
  ///
  /// Simply re-attaches. There is no extra read to perform: the shared stream
  /// is already live and will push the current list on its next event.
  void _loadDoctorProfiles() => _subscribeToDoctorProfiles();

  static Map<String, dynamic>? _findById(
    List<Map<String, dynamic>> profiles,
    String id,
  ) {
    for (final profile in profiles) {
      if ((profile['id'] ?? '').toString() == id) return profile;
    }
    return null;
  }

  void _selectDoctor(Map<String, dynamic> doctor) {
    setState(() {
      _selectedDoctor = doctor;
      _selectedDoctorId = doctor['id'].toString();
    });
    ToastService.instance.showInfo(
      'Viewing ${doctor['fullname']}\'s conversations',
    );
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() {
      _searchQuery = '';
    });
    ToastService.instance.showInfo('Search cleared');
  }

  Future<void> _logout() async {
    final shouldLogout = await showAdminConfirmDialog(
      context: context,
      title: 'Logout',
      content: 'Are you sure you want to logout?',
      confirmLabel: 'Logout',
      confirmColor: AdminPalette.error,
    );

    if (shouldLogout == true) {
      ToastService.instance.showInfo('Logging out...');

      // Get the controller and call signOut
      final controller = ref.read(patientControllerProvider);
      await controller.signOut();

      if (mounted) {
        ToastService.instance.showSuccess('Logged out successfully');
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => SignInScreen()),
        );
      }
    }
  }

  // Navigate to Doctor Online History Screen
  void _navigateToDoctorOnlineHistory() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => DoctorOnlineHistoryScreen()),
    );
    ToastService.instance.showInfo('Opening online history');
  }

  // Navigate to Create Doctor ID Screen
  void _navigateToCreateDoctorId() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => CreateDoctorIdScreen()),
    );
    ToastService.instance.showInfo('Opening doctor creation form');
  }

  // Navigate to Patient ID Management Screen
  void _navigateToPatientIdManagement() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const PatientIdManagementScreen()),
    );
    ToastService.instance.showInfo('Opening Patient ID management');
  }

  // Navigate to Reactivation Requests Screen
  void _navigateToReactivationRequests() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const AdminReactivationScreen()),
    );
    ToastService.instance.showInfo('Opening reactivation requests');
  }

  /// Search results, ordered online-first.
  ///
  /// The search predicate is unchanged from the previous implementation. The
  /// ordering is the shared [sortDoctorsByPresence] used by the patient-side
  /// Doctor List, fed from the centralized [doctorPresenceProvider] — the SAME
  /// source as the online dot on each row — so the admin's online dot can
  /// never disagree with the list position.
  List<Map<String, dynamic>> get _visibleProfiles {
    final query = _searchQuery.trim().toLowerCase();
    final matched = query.isEmpty
        ? _doctorProfiles
        : _doctorProfiles.where((profile) {
            final fullname = (profile['fullname'] ?? '')
                .toString()
                .toLowerCase();
            final degree = (profile['highestDegree'] ?? '')
                .toString()
                .toLowerCase();
            final doctorId = (profile['doctorId'] ?? '').toString().toLowerCase();
            return fullname.contains(query) ||
                degree.contains(query) ||
                doctorId.contains(query);
          }).toList();

    return sortDoctorsByPresence<Map<String, dynamic>>(
      matched,
      presenceForDoctorList(matched, ref.watch(doctorPresenceProvider)),
      (doctor) => (doctor['id'] ?? '').toString(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AdminScreen(
      title: 'Doctor Chats',
      subtitle:
          _selectedDoctor != null
              ? 'Viewing ${_selectedDoctor!['fullname']}\'s patient chats'
              : 'Select a doctor to view their patient conversations',
      actions: [
        AdminHeaderAction(
          icon: Icons.payment_rounded,
          tooltip: 'Check Payments',
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const AdminPaymentScreen(),
              ),
            );
            ToastService.instance.showInfo('Opening payment requests');
          },
        ),
        const SizedBox(width: 6),
        AdminHeaderAction(
          icon: Icons.logout_rounded,
          tooltip: 'Logout',
          onPressed: _logout,
        ),
      ],
      body: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(context.rsp(16), 18, context.rsp(16), 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildActionGrid(),
                const SizedBox(height: 16),
                AdminSearchField(
                  controller: _searchController,
                  hintText: 'Search doctors by name, degree, or ID...',
                  hasQuery: _searchQuery.isNotEmpty,
                  onChanged: (value) {
                    setState(() {
                      _searchQuery = value;
                    });
                    if (value.isNotEmpty) {
                      ToastService.instance.showInfo('Searching: $value');
                    }
                  },
                  onClear: _clearSearch,
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          SizedBox(
            height: math.min(
              128 * context.textScale,
              math.max(128.0, context.sh * 0.2),
            ),
            child: _buildDoctorProfilesStrip(),
          ),

          const SizedBox(height: 8),

          Expanded(
            child: _selectedDoctor != null
                ? _buildDoctorChats()
                : _buildSelectDoctorPlaceholder(),
          ),
        ],
      ),
    );
  }

  // Sign-in style quick action tiles (2 x 2 grid)
  Widget _buildActionGrid() {
    final actions = [
      (
        'Create Doctor ID',
        Icons.person_add_alt_1_rounded,
        _navigateToCreateDoctorId,
      ),
      ('Patient IDs', Icons.badge_rounded, _navigateToPatientIdManagement),
      ('Online History', Icons.history_rounded, _navigateToDoctorOnlineHistory),
      ('Reactivation', Icons.replay_circle_filled_rounded, _navigateToReactivationRequests),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final itemWidth = (constraints.maxWidth - 12) / 2;
        return Column(
          children: [
            Row(
              children: [
                _buildActionTile(actions[0], itemWidth),
                const SizedBox(width: 12),
                _buildActionTile(actions[1], itemWidth),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _buildActionTile(actions[2], itemWidth),
                const SizedBox(width: 12),
                _buildActionTile(actions[3], itemWidth),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _buildActionTile(
    (String, IconData, VoidCallback) action,
    double width,
  ) {
    return GestureDetector(
      onTap: action.$3,
      child: Container(
        width: width,
        padding: EdgeInsets.symmetric(
          horizontal: context.rsp(14),
          vertical: context.rsp(14),
        ),
        decoration: BoxDecoration(
          gradient: AdminPalette.cardGradient,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AdminPalette.cardBorder),
          boxShadow: [
            BoxShadow(
              color: AdminPalette.cardShadow.withValues(alpha: 0.10),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: AppColors.primaryRed.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(action.$2, color: AppColors.primaryRed, size: 20),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                action.$1,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: context.fs(12.5),
                  fontWeight: FontWeight.w600,
                  color: AdminPalette.textPrimary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDoctorProfilesStrip() {
    if (_isLoadingProfiles) {
      return const AdminLoading();
    }

    if (_errorMessage.isNotEmpty) {
      return AdminErrorState(
        message: _errorMessage,
        onRetry: _loadDoctorProfiles,
      );
    }

    if (_visibleProfiles.isEmpty) {
      return Center(
        child: Text(
          _doctorProfiles.isEmpty
              ? 'No doctor profiles found.\nCreate a doctor profile first.'
              : 'No doctors match your search.',
          textAlign: TextAlign.center,
          style: AdminTextStyles.body(size: 13),
        ),
      );
    }

    return ListView.builder(
      scrollDirection: Axis.horizontal,
      padding: EdgeInsets.symmetric(horizontal: context.rsp(16)),
      itemCount: _visibleProfiles.length,
      itemBuilder: (context, index) {
        final doctor = _visibleProfiles[index];
        final doctorId = (doctor['id'] ?? '').toString();
        final isSelected = _selectedDoctorId == doctorId;
        final doctorName = (doctor['fullname'] ?? 'Doctor').toString();
        final doctorDegree = (doctor['highestDegree'] ?? 'General Physician')
            .toString();
        final doctorIdNumber = (doctor['doctorId'] ?? 'N/A').toString();
        final isOnline = doctor['isOnline'] ?? false;

        return GestureDetector(
          onTap: () => _selectDoctor(doctor),
          onLongPress: () => _showDeleteDoctorDialog(doctor),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 168,
            margin: const EdgeInsets.only(right: 12),
            padding: EdgeInsets.all(context.rsp(12)),
            decoration: BoxDecoration(
              gradient: isSelected
                  ? null
                  : AdminPalette.cardGradient,
              color: isSelected ? null : null,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: isSelected
                    ? AppColors.primaryRed
                    : AdminPalette.cardBorder,
                width: isSelected ? 2 : 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: isSelected
                      ? AppColors.primaryRed.withValues(alpha: 0.14)
                      : AdminPalette.cardShadow.withValues(alpha: 0.10),
                  blurRadius: 14,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Stack(
                      children: [
                        CircleAvatar(
                          radius: 20,
                          backgroundColor: AppColors.primaryRed.withValues(
                            alpha: 0.1,
                          ),
                          backgroundImage:
                              (doctor['imageUrl'] ?? '').toString().isNotEmpty
                              ? NetworkImage(
                                  (doctor['imageUrl'] ?? '').toString(),
                                )
                              : null,
                          child: (doctor['imageUrl'] ?? '').toString().isEmpty
                              ? Icon(
                                  Icons.person,
                                  color: AppColors.primaryRed,
                                  size: 20,
                                )
                              : null,
                        ),
                        Positioned(
                          bottom: 0,
                          right: 0,
                          child: Container(
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: isOnline
                                  ? AdminPalette.success
                                  : AdminPalette.textMuted,
                              border: Border.all(color: Colors.white, width: 2),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            doctorName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: context.fs(12.5),
                              color: isSelected
                                  ? AppColors.primaryRed
                                  : AdminPalette.textPrimary,
                            ),
                          ),
                          Text(
                            'ID: $doctorIdNumber',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AdminTextStyles.small(size: 10),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  doctorDegree,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AdminTextStyles.small(size: 10),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Flexible(child: _doctorStripChip(isSelected)),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: isOnline
                              ? AdminPalette.success.withValues(alpha: 0.12)
                              : AdminPalette.unselectedText.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isOnline
                                ? AdminPalette.success.withValues(alpha: 0.3)
                                : AdminPalette.segmentBorder,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: isOnline
                                    ? AdminPalette.success
                                    : AdminPalette.textMuted,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              isOnline ? 'Online' : 'Offline',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: isOnline
                                    ? AdminPalette.success
                                    : AdminPalette.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _doctorStripChip(bool isSelected) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        gradient: isSelected
            ? AdminPalette.selectedGradient
            : AdminPalette.unselectedSegmentGradient,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isSelected
              ? AdminPalette.brandBorder
              : AdminPalette.segmentBorder,
        ),
      ),
      child: Text(
        isSelected ? 'Viewing' : 'Select',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: isSelected ? Colors.white : AdminPalette.textMuted,
        ),
      ),
    );
  }

  // Add this method to show delete confirmation dialog
  Future<void> _showDeleteDoctorDialog(Map<String, dynamic> doctor) async {
    final doctorName = doctor['fullname'] ?? 'this doctor';
    final doctorIdNumber = doctor['doctorId'] ?? 'N/A';

    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (context) => AdminConfirmDialog(
        title: 'Delete Doctor?',
        content:
            'Are you sure you want to delete this doctor?\n\n'
            'This doctor will be deactivated and removed from active listings. '
            'Their chats, appointments, reports, prescriptions, payment records '
            'and all other history will be preserved, and you can restore this '
            'account later.',
        cancelLabel: 'Cancel',
        confirmLabel: 'Delete',
        confirmColor: AdminPalette.error,
        extraContent: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AdminPalette.infoBg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AdminPalette.infoBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _detailRow(Icons.person_outline, 'Name', doctorName),
              const SizedBox(height: 8),
              _detailRow(Icons.badge_outlined, 'Doctor ID', doctorIdNumber),
              const SizedBox(height: 8),
              _detailRow(
                Icons.medical_information_outlined,
                'Degree',
                doctor['highestDegree'] ?? 'N/A',
              ),
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    size: 16,
                    color: AdminPalette.textSecondary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'This is a soft delete. The doctor profile and all historical records are kept in the database and can be restored at any time.',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: AdminPalette.textSecondary,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    if (shouldDelete == true) {
      await _deleteDoctor(doctor);
    }
  }

  Widget _detailRow(IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, size: 16, color: AdminPalette.textSecondary),
        const SizedBox(width: 8),
        Text(
          '$label: ',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: context.fs(12.5),
            color: AdminPalette.textPrimary,
          ),
        ),
        Expanded(
          child: Text(
            value,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: context.fs(12.5),
              color: AdminPalette.textPrimary,
            ),
          ),
        ),
      ],
    );
  }

  // Soft-deletes a doctor.
  //
  // This is NOT a hard delete: the doctor document, profile, chats, messages,
  // prescriptions, reports, ratings, payment records and history all stay in
  // Firestore. Only the lifecycle flags change, and the admin can restore the
  // account later.
  Future<void> _deleteDoctor(Map<String, dynamic> doctor) async {
    final doctorId = doctor['id']?.toString();
    final doctorName = doctor['fullname'] ?? 'Doctor';

    if (doctorId == null || doctorId.isEmpty) {
      ToastService.instance.showError('Cannot delete doctor: Invalid doctor ID');
      return;
    }

    // Show loading indicator
    ToastService.instance.showInfo('Deleting doctor $doctorName...');

    try {
      final doctorController = ref.read(doctorControllerProvider);
      // Attribute the action to the signed-in admin for the audit trail.
      final adminId = ref.read(userProvider)?.id ?? 'admin';
      final success = await doctorController.deleteDoctorProfile(
        doctorId,
        performedBy: adminId,
      );

      if (!mounted) return;

      if (success) {
        // Remove from the active list shown in this screen. The record itself
        // is untouched and remains visible in Admin → Doctors & Patients →
        // Deleted.
        setState(() {
          _doctorProfiles.removeWhere((d) => d['id'].toString() == doctorId);

          // If the deleted doctor was selected, clear selection
          if (_selectedDoctorId == doctorId) {
            _selectedDoctor = null;
            _selectedDoctorId = null;
          }
        });

        ToastService.instance.showSuccess(
          'Doctor $doctorName deleted. All history has been preserved.',
        );

        // No reload here: the soft-delete write already produced a Firestore
        // event, so the shared stream is about to push the updated list on its
        // own. A manual `getAllDoctorProfiles()` would be a duplicate read of
        // data we are already subscribed to.
      } else {
        ToastService.instance.showError('Failed to delete doctor $doctorName');
      }
    } catch (e) {
      if (!mounted) return;
      ToastService.instance.showError('Error deleting doctor: ${e.toString()}');
    }
  }

  Widget _buildDoctorChats() {
    if (_selectedDoctor == null) {
      return _buildSelectDoctorPlaceholder();
    }

    final adminUser = ref.read(userProvider);

    // Use the updated ChatListWidget with admin mode
    return ChatListWidget(
      searchQuery: _searchQuery,
      adminView: true,
      doctorId: _selectedDoctor!['id'],
      doctorName: _selectedDoctor!['fullname'],
      isAdminMode: true,
      adminId: adminUser?.id ?? 'admin_id',
      adminName: adminUser?.fullname ?? 'Admin',
    );
  }

  Widget _buildSelectDoctorPlaceholder() {
    return AdminEmptyState(
      icon: Icons.medical_services_outlined,
      title: 'No Doctor Selected',
      subtitle:
          'Please select a doctor from the list above to view their patient conversations.\n\nAs an admin, you can monitor all doctors\' chats and check payment statuses.',
    );
  }
}
