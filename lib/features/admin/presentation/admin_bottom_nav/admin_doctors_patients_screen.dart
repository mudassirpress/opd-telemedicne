import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/features/admin/presentation/admin_design_system.dart';
import 'package:telemedicine/features/auth/presentation/providers/user_provider.dart';
import 'package:telemedicine/features/auth/presentation/controllers/doctor_controller.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/core/services/doctor_presence_service.dart';
import 'package:telemedicine/core/services/soft_delete_service.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/core/utils/responsive.dart';

class AdminDoctorsPatientsScreen extends ConsumerStatefulWidget {
  const AdminDoctorsPatientsScreen({super.key});

  @override
  ConsumerState<AdminDoctorsPatientsScreen> createState() =>
      _AdminDoctorsPatientsScreenState();
}

class _AdminDoctorsPatientsScreenState
    extends ConsumerState<AdminDoctorsPatientsScreen> {
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  // 'doctors' or 'patients' (styled as the Sign In segmented selector)
  String _section = 'doctors';

  /// Soft-delete lifecycle filter applied on top of the (unfiltered) admin
  /// streams: 'active' | 'deleted' | 'all'.
  ///
  /// The underlying queries deliberately return deleted records too — this is
  /// where the admin decides what to show, so a deleted doctor/patient stays
  /// one tap away with their complete preserved record intact.
  String _lifecycleFilter = 'active';

  static const Map<String, String> _lifecycleLabels = {
    'active': 'Active',
    'deleted': 'Deleted',
    'all': 'All',
  };

  // Cached once in initState. Creating these in build() opened a fresh
  // Firestore listener on every rebuild — every search keystroke called
  // setState, so StreamBuilder tore down the previous subscription and
  // resubscribed to a brand new query per character typed.
  Stream<List<Map<String, dynamic>>>? _doctorsStream;
  Stream<List<Map<String, dynamic>>>? _patientsStream;

  @override
  void initState() {
    super.initState();
    _reloadStreams();
  }

  /// Re-acquires both tab streams. Used by initState and by the Retry buttons
  /// in the tabs' error states — a `setState(() {})` alone re-subscribes to the
  /// *same errored* stream instance, so Retry could never recover.
  void _reloadStreams() {
    _doctorsStream = ref
        .read(doctorControllerProvider)
        .streamAllDoctorsWithStatus();
    _patientsStream = ref
        .read(patientControllerProvider)
        .streamAllPatientsWithStatus();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AdminScreen(
      title: 'Doctors & Patients',
      subtitle: 'Manage accounts, status and access',
      bottom: Padding(
        padding: EdgeInsets.fromLTRB(context.rsp(16), 4, context.rsp(16), 4),
        child: AdminSegmentedControl<String>(
          value: _section,
          onChanged: (value) => setState(() => _section = value),
          options: const [
            AdminSegmentOption(
              'doctors',
              'Doctors',
              Icons.medical_services_outlined,
            ),
            AdminSegmentOption('patients', 'Patients', Icons.people_outline),
          ],
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              context.rsp(16),
              14,
              context.rsp(16),
              6,
            ),
            child: AdminSearchField(
              controller: _searchController,
              hintText: 'Search by name, ID, or mobile...',
              hasQuery: _searchQuery.isNotEmpty,
              onChanged: (value) => setState(() => _searchQuery = value),
              onClear: () {
                _searchController.clear();
                setState(() => _searchQuery = '');
              },
            ),
          ),
          // Active / Deleted / All — the admin's view into the soft-delete
          // lifecycle. Defaulting to 'active' matches the patient-facing
          // world; 'deleted' surfaces the archived records.
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: context.rsp(16),
              vertical: 4,
            ),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final entry in _lifecycleLabels.entries)
                  AdminFilterChip(
                    label: entry.value,
                    selected: _lifecycleFilter == entry.key,
                    onTap: () => setState(() => _lifecycleFilter = entry.key),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: _section == 'doctors'
                ? _buildDoctorsTab()
                : _buildPatientsTab(),
          ),
        ],
      ),
    );
  }

  /// Applies the lifecycle filter to a materialised admin list.
  ///
  /// Filtering happens here rather than in Firestore so that records which
  /// predate the soft-delete migration (no `isDeleted` field at all) are
  /// correctly treated as active instead of vanishing from the admin's view.
  List<Map<String, dynamic>> _applyLifecycleFilter(
    List<Map<String, dynamic>> records,
  ) {
    switch (_lifecycleFilter) {
      case 'active':
        return SoftDeleteService.activeOnly(records, (record) => record);
      case 'deleted':
        return records
            .where((record) => SoftDeleteService.isDeleted(record))
            .toList();
      default:
        return records;
    }
  }

  // ── Doctors Tab ────────────────────────────────────────────────────────
  Widget _buildDoctorsTab() {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _doctorsStream,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          // Without this branch a Firestore/permission failure fell through
          // to the empty state and read exactly like an empty clinic roster.
          return AdminErrorState(
            message: 'Could not load doctors. Check your connection.',
            onRetry: () => setState(_reloadStreams),
          );
        }
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const AdminLoading(label: 'Loading doctors...');
        }
        if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return AdminEmptyState(
            icon: Icons.medical_services_outlined,
            title: 'No doctors found',
          );
        }

        var doctors = _applyLifecycleFilter(snapshot.data!);
        if (_searchQuery.isNotEmpty) {
          final q = _searchQuery.toLowerCase();
          doctors = doctors.where((d) {
            final name = (d['fullname'] ?? '').toString().toLowerCase();
            final id = (d['doctorId'] ?? '').toString().toLowerCase();
            final mobile = (d['phoneNumber'] ?? '').toString().toLowerCase();
            return name.contains(q) || id.contains(q) || mobile.contains(q);
          }).toList();
        }

        if (doctors.isEmpty) {
          return AdminEmptyState(
            icon: _lifecycleFilter == 'deleted'
                ? Icons.delete_outline
                : Icons.search_off,
            title: _searchQuery.isNotEmpty
                ? 'No matching doctors'
                : _lifecycleFilter == 'deleted'
                ? 'No deleted doctors'
                : 'No active doctors',
          );
        }

        return ListView.builder(
          padding: EdgeInsets.all(context.rsp(12)),
          itemCount: doctors.length,
          itemBuilder: (context, index) => _buildDoctorCard(doctors[index]),
        );
      },
    );
  }

  Widget _buildDoctorCard(Map<String, dynamic> doctor) {
    final name = doctor['fullname'] ?? 'N/A';
    final doctorId = doctor['doctorId'] ?? 'N/A';
    final degree = doctor['highestDegree'] ?? 'N/A';
    final mobile = doctor['phoneNumber'] ?? 'N/A';
    final accountStatus = doctor['accountStatus'] ?? 'Active';
    final loginStatus = doctor['loginStatus'] ?? 'Offline';
    final docId = (doctor['id'] ?? '').toString();
    final isOnline = ref.watch(doctorOnlineProvider(docId));
    final presenceData = ref.watch(doctorPresenceDataProvider(docId));
    final lastLogin = doctor['lastLogin'] as Timestamp?;
    final lastLogout = doctor['lastLogout'] as Timestamp?;
    final lastSeen = doctor['lastSeen'] as Timestamp?;
    final createdAt = doctor['createdAt'] as Timestamp?;
    final isDeleted = SoftDeleteService.isDeleted(doctor);

    return AdminCard(
      margin: const EdgeInsets.only(bottom: 10),
      radius: 16,
      // Ring a deleted record so it is visually distinct in the 'all' view.
      borderColor: isDeleted ? AdminPalette.error.withValues(alpha: 0.5) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isDeleted) _buildDeletedBanner(doctor, 'Doctor'),
          Row(
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: AdminPalette.brand.withValues(alpha: 0.1),
                backgroundImage:
                    (doctor['imageUrl'] ?? '').toString().isNotEmpty
                    ? NetworkImage((doctor['imageUrl'] ?? '').toString())
                    : null,
                child: (doctor['imageUrl'] ?? '').toString().isEmpty
                    ? Icon(Icons.person, color: AdminPalette.brand, size: 22)
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AdminTextStyles.heading(size: context.fs(14)),
                    ),
                    Text(
                      'ID: $doctorId',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AdminTextStyles.small(size: context.fs(12)),
                    ),
                  ],
                ),
              ),
              _buildStatusChip(accountStatus),
              const SizedBox(width: 6),
              _buildOnlineIndicator(isOnline),
              const SizedBox(width: 4),
              _buildMenuButton(doctor, 'doctor'),
            ],
          ),
          const SizedBox(height: 10),
          AdminInfoRow(
            icon: Icons.school_outlined,
            label: 'Degree',
            value: degree,
            color: AdminPalette.textMuted,
          ),
          AdminInfoRow(
            icon: Icons.phone_outlined,
            label: 'Mobile',
            value: mobile,
            color: AdminPalette.textMuted,
          ),
          AdminInfoRow(
            icon: isOnline ? Icons.circle : Icons.circle_outlined,
            label: 'Availability',
            value: isOnline
                ? 'ONLINE (Available)'
                : (presenceData?.manualAvailability == true
                      ? 'OFFLINE (Stale Heartbeat)'
                      : 'OFFLINE (Manual OFF)'),
            color: isOnline ? AdminPalette.success : AdminPalette.textMuted,
            valueColor: isOnline
                ? AdminPalette.success
                : AdminPalette.textMuted,
          ),
          AdminInfoRow(
            icon: Icons.access_time,
            label: 'Last Seen',
            value: lastSeen != null
                ? _formatDateTime(lastSeen.toDate())
                : 'Never',
            color: AdminPalette.textMuted,
          ),
          AdminInfoRow(
            icon: Icons.login,
            label: 'Last Login',
            value: lastLogin != null
                ? _formatDateTime(lastLogin.toDate())
                : 'Never',
            color: AdminPalette.textMuted,
          ),
          AdminInfoRow(
            icon: Icons.logout,
            label: 'Last Logout',
            value: lastLogout != null
                ? _formatDateTime(lastLogout.toDate())
                : 'Never',
            color: AdminPalette.textMuted,
          ),
          AdminInfoRow(
            icon: Icons.calendar_today,
            label: 'Created',
            value: createdAt != null
                ? _formatDateTime(createdAt.toDate())
                : 'Unknown',
            color: AdminPalette.textMuted,
          ),
          ..._deletionInfoRows(doctor),
        ],
      ),
    );
  }

  // ── Patients Tab ──────────────────────────────────────────────────────
  Widget _buildPatientsTab() {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _patientsStream,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return AdminErrorState(
            message: 'Could not load patients. Check your connection.',
            onRetry: () => setState(_reloadStreams),
          );
        }
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const AdminLoading(label: 'Loading patients...');
        }
        if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return AdminEmptyState(
            icon: Icons.people_outline,
            title: 'No patients found',
          );
        }

        var patients = _applyLifecycleFilter(snapshot.data!);
        if (_searchQuery.isNotEmpty) {
          final q = _searchQuery.toLowerCase();
          patients = patients.where((p) {
            final name = (p['fullname'] ?? '').toString().toLowerCase();
            final id = (p['patientId'] ?? '').toString().toLowerCase();
            final mobile = (p['phoneNumber'] ?? '').toString().toLowerCase();
            return name.contains(q) || id.contains(q) || mobile.contains(q);
          }).toList();
        }

        if (patients.isEmpty) {
          return AdminEmptyState(
            icon: _lifecycleFilter == 'deleted'
                ? Icons.delete_outline
                : Icons.search_off,
            title: _searchQuery.isNotEmpty
                ? 'No matching patients'
                : _lifecycleFilter == 'deleted'
                ? 'No deleted patients'
                : 'No active patients',
          );
        }

        return ListView.builder(
          padding: EdgeInsets.all(context.rsp(12)),
          itemCount: patients.length,
          itemBuilder: (context, index) => _buildPatientCard(patients[index]),
        );
      },
    );
  }

  Widget _buildPatientCard(Map<String, dynamic> patient) {
    final name = patient['fullname'] ?? 'N/A';
    final patientId = patient['patientId'] ?? 'N/A';
    final mobile = patient['phoneNumber'] ?? 'N/A';
    final gender = patient['gender'] ?? 'N/A';
    final age = patient['age']?.toString() ?? 'N/A';
    final accountStatus = patient['accountStatus'] ?? 'Active';
    final loginStatus = patient['loginStatus'] ?? 'Offline';
    final isOnline = patient['isOnline'] ?? false;
    final lastLogin = patient['lastLogin'] as Timestamp?;
    final lastLogout = patient['lastLogout'] as Timestamp?;
    final lastSeen = patient['lastSeen'] as Timestamp?;
    final createdAt = patient['createdAt'] as Timestamp?;
    final isDeleted = SoftDeleteService.isDeleted(patient);

    return AdminCard(
      margin: const EdgeInsets.only(bottom: 10),
      radius: 16,
      borderColor: isDeleted ? AdminPalette.error.withValues(alpha: 0.5) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isDeleted) _buildDeletedBanner(patient, 'Patient'),
          Row(
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: AdminPalette.brand.withValues(alpha: 0.1),
                backgroundImage: (patient['image'] ?? '').toString().isNotEmpty
                    ? NetworkImage((patient['image'] ?? '').toString())
                    : null,
                child: (patient['image'] ?? '').toString().isEmpty
                    ? Icon(Icons.person, color: AdminPalette.brand, size: 22)
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AdminTextStyles.heading(size: context.fs(14)),
                    ),
                    Text(
                      'ID: $patientId',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AdminTextStyles.small(size: context.fs(12)),
                    ),
                  ],
                ),
              ),
              _buildStatusChip(accountStatus),
              const SizedBox(width: 6),
              _buildOnlineIndicator(isOnline),
              const SizedBox(width: 4),
              _buildMenuButton(patient, 'patient'),
            ],
          ),
          const SizedBox(height: 10),
          AdminInfoRow(
            icon: Icons.phone_outlined,
            label: 'Mobile',
            value: mobile,
            color: AdminPalette.textMuted,
          ),
          AdminInfoRow(
            icon: Icons.person_outline,
            label: 'Gender',
            value: gender,
            color: AdminPalette.textMuted,
          ),
          AdminInfoRow(
            icon: Icons.cake_outlined,
            label: 'Age',
            value: age,
            color: AdminPalette.textMuted,
          ),
          AdminInfoRow(
            icon: isOnline ? Icons.circle : Icons.circle_outlined,
            label: 'Login Status',
            value: isOnline ? 'Online' : loginStatus,
            color: isOnline ? AdminPalette.success : AdminPalette.textMuted,
            valueColor: isOnline
                ? AdminPalette.success
                : AdminPalette.textMuted,
          ),
          AdminInfoRow(
            icon: Icons.access_time,
            label: 'Last Seen',
            value: lastSeen != null
                ? _formatDateTime(lastSeen.toDate())
                : 'Never',
            color: AdminPalette.textMuted,
          ),
          AdminInfoRow(
            icon: Icons.login,
            label: 'Last Login',
            value: lastLogin != null
                ? _formatDateTime(lastLogin.toDate())
                : 'Never',
            color: AdminPalette.textMuted,
          ),
          AdminInfoRow(
            icon: Icons.logout,
            label: 'Last Logout',
            value: lastLogout != null
                ? _formatDateTime(lastLogout.toDate())
                : 'Never',
            color: AdminPalette.textMuted,
          ),
          AdminInfoRow(
            icon: Icons.calendar_today,
            label: 'Created',
            value: createdAt != null
                ? _formatDateTime(createdAt.toDate())
                : 'Unknown',
            color: AdminPalette.textMuted,
          ),
          ..._deletionInfoRows(patient),
        ],
      ),
    );
  }

  /// The "Deleted" strip shown at the top of a soft-deleted record.
  ///
  /// The rest of the card is deliberately left fully intact: the admin is
  /// looking at the *complete preserved record*, which is the whole point of
  /// soft-deleting rather than removing the document.
  Widget _buildDeletedBanner(Map<String, dynamic> record, String label) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AdminPalette.error.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AdminPalette.error.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.delete_outline, size: 16, color: AdminPalette.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$label deleted — record and all history preserved',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: context.fs(11.5),
                fontWeight: FontWeight.w600,
                color: AdminPalette.error,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Deleted At / Deleted By / Reason rows, shown only for soft-deleted
  /// records. `deletedAt` is a server timestamp, so the displayed time is
  /// trustworthy regardless of any device clock.
  List<Widget> _deletionInfoRows(Map<String, dynamic> record) {
    if (!SoftDeleteService.isDeleted(record)) return const [];

    final deletedAt = record[SoftDeleteFields.deletedAt];
    final deletedBy = (record[SoftDeleteFields.deletedBy] ?? '').toString();
    final reason = (record[SoftDeleteFields.deletedReason] ?? '').toString();

    // `deletedAt` is written as a serverTimestamp, but the legacy
    // self-service delete path used an ISO string, so accept both.
    final DateTime? deletedAtDate = switch (deletedAt) {
      Timestamp ts => ts.toDate(),
      String s => DateTime.tryParse(s),
      DateTime d => d,
      _ => null,
    };

    return [
      AdminInfoRow(
        icon: Icons.event_busy,
        label: 'Deleted At',
        value: deletedAtDate != null
            ? _formatDateTime(deletedAtDate)
            : 'Unknown',
        color: AdminPalette.error,
        valueColor: AdminPalette.error,
      ),
      AdminInfoRow(
        icon: Icons.person_outline,
        label: 'Deleted By',
        value: deletedBy.isEmpty ? 'Unknown' : deletedBy,
        color: AdminPalette.textMuted,
      ),
      if (reason.isNotEmpty)
        AdminInfoRow(
          icon: Icons.notes,
          label: 'Reason',
          value: reason,
          color: AdminPalette.textMuted,
        ),
    ];
  }

  Widget _buildStatusChip(String status) {
    Color color;
    switch (status) {
      case 'Blocked':
        color = AdminPalette.error;
        break;
      case 'Frozen':
        color = AdminPalette.frozen;
        break;
      case 'Deleted':
        color = AdminPalette.textMuted;
        break;
      default:
        color = AdminPalette.success;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Text(
        status,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  Widget _buildOnlineIndicator(bool isOnline) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isOnline ? AdminPalette.success : AdminPalette.textMuted,
        border: Border.all(color: Colors.white, width: 2),
      ),
    );
  }

  // ── Menu / More Button ───────────────────────────────────────────────
  Widget _buildMenuButton(Map<String, dynamic> user, String userType) {
    return PopupMenuButton<String>(
      onSelected: (action) => _handleMenuAction(action, user, userType),
      icon: Icon(Icons.more_vert, color: AdminPalette.textSecondary, size: 20),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: Colors.white,
      itemBuilder: (context) {
        final currentStatus = user['accountStatus'] ?? 'Active';
        final isDeleted = SoftDeleteService.isDeleted(user);
        final label = userType == 'doctor' ? 'Doctor' : 'Patient';
        final items = <PopupMenuEntry<String>>[];

        // A soft-deleted record is restored in place, so the status actions
        // that only make sense for a live account are not offered.
        if (!isDeleted) {
          if (currentStatus == 'Active') {
            items.add(
              _buildMenuItem('block', Icons.block, 'Block', AdminPalette.error),
            );
            items.add(
              _buildMenuItem(
                'freeze',
                Icons.lock_clock,
                'Freeze ID',
                AdminPalette.frozen,
              ),
            );
          } else {
            items.add(
              _buildMenuItem(
                'activate',
                Icons.check_circle_outline,
                'Activate / Unblock',
                AdminPalette.success,
              ),
            );
          }

          items.add(const PopupMenuDivider());
          items.add(
            _buildMenuItem(
              'delete',
              Icons.delete_outline,
              'Delete $label',
              AdminPalette.error,
            ),
          );
        } else {
          items.add(
            _buildMenuItem(
              'restore',
              Icons.restore,
              'Restore $label',
              AdminPalette.success,
            ),
          );
        }

        return items;
      },
    );
  }

  PopupMenuItem<String> _buildMenuItem(
    String value,
    IconData icon,
    String label,
    Color color,
  ) {
    return PopupMenuItem(
      value: value,
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Text(
            label,
            style: TextStyle(fontSize: context.fs(13), color: color),
          ),
        ],
      ),
    );
  }

  // ── Menu Action Handler ──────────────────────────────────────────────
  void _handleMenuAction(
    String action,
    Map<String, dynamic> user,
    String userType,
  ) {
    final label = userType == 'doctor' ? 'Doctor' : 'Patient';
    final name = (user['fullname'] ?? 'this $label').toString();

    switch (action) {
      case 'block':
        _showConfirmDialog(
          title: 'Block $label',
          content:
              'Are you sure you want to block this $userType? They will not be able to log in.',
          confirmText: 'Block',
          confirmColor: AdminPalette.error,
          onConfirm: () => _updateStatus(user, userType, 'Blocked'),
        );
        break;
      case 'freeze':
        _showConfirmDialog(
          title: 'Freeze ${userType == 'doctor' ? 'Doctor ID' : 'Patient ID'}',
          content:
              'Are you sure you want to freeze this ID? The ID cannot be used to access the application.',
          confirmText: 'Freeze',
          confirmColor: AdminPalette.frozen,
          onConfirm: () => _updateStatus(user, userType, 'Frozen'),
        );
        break;
      case 'activate':
        _updateStatus(user, userType, 'Active');
        break;
      case 'delete':
        // Copy deliberately avoids "permanently deleted": the record and all
        // of its history are kept, and the action can be undone via Restore.
        _showConfirmDialog(
          title: 'Delete $label?',
          content:
              'This $userType will be deactivated and removed from active '
              'listings.\n\n'
              'Their chats, appointments, reports, prescriptions, payment '
              'records and all other history will be preserved, and you can '
              'restore this account later.',
          confirmText: 'Delete',
          confirmColor: AdminPalette.error,
          onConfirm: () => _softDeleteUser(user, userType, name),
        );
        break;
      case 'restore':
        _showConfirmDialog(
          title: 'Restore $label?',
          content:
              '$name will be reactivated and appear in active listings again.\n\n'
              'This restores the original record — no duplicate account is '
              'created — and all preserved history remains intact.',
          confirmText: 'Restore',
          confirmColor: AdminPalette.success,
          onConfirm: () => _restoreUser(user, userType, name),
        );
        break;
    }
  }

  /// Soft-deletes a doctor or patient.
  ///
  /// Nothing is removed from Firestore: the record, its chats, messages,
  /// prescriptions, reports, payment records and history are all preserved and
  /// only the lifecycle flags change. The action is reversible through Restore.
  Future<void> _softDeleteUser(
    Map<String, dynamic> user,
    String userType,
    String name,
  ) async {
    final userId = user['id']?.toString() ?? '';
    if (userId.isEmpty) {
      ToastService.instance.showError('Invalid user ID');
      return;
    }

    final adminId = ref.read(userProvider)?.id ?? 'admin';
    final label = userType == 'doctor' ? 'Doctor' : 'Patient';

    ToastService.instance.showInfo('Deleting $label $name...');

    final bool success;
    if (userType == 'doctor') {
      success = await ref
          .read(doctorControllerProvider)
          .deleteDoctorProfile(userId, performedBy: adminId);
    } else {
      success = await ref
          .read(patientControllerProvider)
          .softDeletePatient(userId, performedBy: adminId);
    }

    if (!mounted) return;

    if (success) {
      // Switch the view to Deleted so the admin immediately sees the result.
      setState(() => _lifecycleFilter = 'deleted');
      ToastService.instance.showSuccess(
        '$label $name deleted. All history has been preserved.',
      );
    } else {
      ToastService.instance.showError('Failed to delete $label $name');
    }
  }

  /// Restores a soft-deleted doctor or patient **in place** — the original
  /// document id is reused, so no duplicate record can be created.
  Future<void> _restoreUser(
    Map<String, dynamic> user,
    String userType,
    String name,
  ) async {
    final userId = user['id']?.toString() ?? '';
    if (userId.isEmpty) {
      ToastService.instance.showError('Invalid user ID');
      return;
    }

    final adminId = ref.read(userProvider)?.id ?? 'admin';
    final label = userType == 'doctor' ? 'Doctor' : 'Patient';

    ToastService.instance.showInfo('Restoring $label $name...');

    final bool success;
    if (userType == 'doctor') {
      success = await ref
          .read(doctorControllerProvider)
          .restoreDoctorProfile(userId, performedBy: adminId);
    } else {
      success = await ref
          .read(patientControllerProvider)
          .restorePatient(userId, performedBy: adminId);
    }

    if (!mounted) return;

    if (success) {
      setState(() => _lifecycleFilter = 'active');
      ToastService.instance.showSuccess('$label $name restored successfully');
    } else {
      ToastService.instance.showError('Failed to restore $label $name');
    }
  }

  Future<void> _updateStatus(
    Map<String, dynamic> user,
    String userType,
    String status,
  ) async {
    final userId = user['id']?.toString() ?? '';
    if (userId.isEmpty) {
      ToastService.instance.showError('Invalid user ID');
      return;
    }

    bool success;
    if (userType == 'doctor') {
      success = await ref
          .read(doctorControllerProvider)
          .updateDoctorAccountStatus(userId, status);
    } else {
      success = await ref
          .read(patientControllerProvider)
          .updatePatientAccountStatus(userId, status);
    }

    if (success) {
      final label = status == 'Active'
          ? 'Activated'
          : status == 'Blocked'
          ? 'Blocked'
          : status == 'Frozen'
          ? 'Frozen'
          : 'Deleted';
      ToastService.instance.showSuccess('Account $label successfully');
    } else {
      ToastService.instance.showError('Failed to update account status');
    }
  }

  void _showConfirmDialog({
    required String title,
    required String content,
    required String confirmText,
    required Color confirmColor,
    required VoidCallback onConfirm,
  }) {
    showDialog(
      context: context,
      builder: (context) => AdminConfirmDialog(
        title: title,
        content: content,
        confirmLabel: confirmText,
        cancelLabel: 'Cancel',
        confirmColor: confirmColor,
      ),
    ).then((confirmed) {
      if (confirmed == true) {
        onConfirm();
      }
    });
  }

  String _formatDateTime(DateTime dt) {
    final day = dt.day.toString().padLeft(2, '0');
    final month = dt.month.toString().padLeft(2, '0');
    final year = dt.year;
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    return '$day/$month/$year $hour:$minute';
  }
}
