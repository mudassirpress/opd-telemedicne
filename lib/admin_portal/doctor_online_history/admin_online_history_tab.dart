import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/admin_portal/admin_ui.dart';
import 'package:telemedicine/auth/user_controller/doctor_controller.dart';
import 'package:telemedicine/core/utils/responsive.dart';

class AdminOnlineHistoryTab extends ConsumerStatefulWidget {
  const AdminOnlineHistoryTab({super.key});

  @override
  ConsumerState<AdminOnlineHistoryTab> createState() =>
      _AdminOnlineHistoryTabState();
}

class _AdminOnlineHistoryTabState extends ConsumerState<AdminOnlineHistoryTab> {
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  // Created once: calling this in build()/_buildActivityLogList() opened a
  // new Firestore listener on every rebuild (each search keystroke), with
  // StreamBuilder dropping and re-subscribing the old one every time.
  Stream<List<Map<String, dynamic>>>? _activityStream;

  @override
  void initState() {
    super.initState();
    _activityStream =
        ref.read(doctorControllerProvider).getAllDoctorActivityLogs();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AdminScreen(
      title: 'Online History',
      subtitle: 'Doctor login / logout activity',
      body: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              context.rsp(16),
              context.rsp(14),
              context.rsp(16),
              6,
            ),
            child: AdminSearchField(
              controller: _searchController,
              hintText: 'Search by doctor name or ID...',
              hasQuery: _searchQuery.isNotEmpty,
              onChanged: (value) => setState(() => _searchQuery = value),
              onClear: () {
                _searchController.clear();
                setState(() => _searchQuery = '');
              },
            ),
          ),
          const SizedBox(height: 6),
          Expanded(child: _buildActivityLogList()),
        ],
      ),
    );
  }

  Widget _buildActivityLogList() {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _activityStream,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          // A failure used to fall through to `!snapshot.hasData` and render
          // the fake-empty "No activity history yet".
          return AdminErrorState(
            message: 'Could not load activity history. Check your connection.',
            onRetry: () => setState(() {
              _activityStream = ref
                  .read(doctorControllerProvider)
                  .getAllDoctorActivityLogs();
            }),
          );
        }
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const AdminLoading(label: 'Loading activity...');
        }

        if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return const AdminEmptyState(
            icon: Icons.history_rounded,
            title: 'No activity history yet',
            subtitle: 'Doctor login/logout events will appear here',
          );
        }

        final logs = snapshot.data!;
        final filteredLogs = _searchQuery.isEmpty
            ? logs
            : logs.where((log) {
                final name = (log['doctorName'] ?? '').toString().toLowerCase();
                final id = (log['doctorId'] ?? '').toString().toLowerCase();
                final query = _searchQuery.toLowerCase();
                return name.contains(query) || id.contains(query);
              }).toList();

        if (filteredLogs.isEmpty) {
          return Center(
            child: Text(
              'No matching results',
              style: AdminTextStyles.body(size: context.fs(13.5)),
            ),
          );
        }

        // Group logs by date
        final groupedLogs = _groupByDate(filteredLogs);

        return ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: groupedLogs.length,
          itemBuilder: (context, index) {
            final dateKey = groupedLogs.keys.elementAt(index);
            final dayLogs = groupedLogs[dateKey]!;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Date header
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                  child: Text(
                    dateKey,
                    style: AdminTextStyles.label(
                      size: 13,
                      weight: FontWeight.w700,
                      color: AdminPalette.textPrimary,
                    ),
                  ),
                ),
                // Logs for this date
                ...dayLogs.map((log) => _buildActivityCard(log)),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildActivityCard(Map<String, dynamic> log) {
    final event = log['event'] ?? 'unknown';
    final doctorName = log['doctorName'] ?? 'Unknown Doctor';
    final doctorId = log['doctorId'] ?? 'N/A';
    final timestamp = log['timestamp'] as Timestamp?;

    final isLogin = event == 'login';
    final icon = isLogin ? Icons.login_rounded : Icons.logout_rounded;
    final color = isLogin ? AdminPalette.success : AdminPalette.frozen;
    final eventLabel = isLogin ? 'Logged In' : 'Logged Out';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        gradient: AdminPalette.cardGradient,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.25)),
        boxShadow: [
          BoxShadow(
            color: AdminPalette.cardShadow.withValues(alpha: 0.08),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        children: [
          // Event icon
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 12),
          // Doctor info
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  doctorName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AdminTextStyles.heading(size: context.fs(14)),
                ),
                const SizedBox(height: 2),
                Text(
                  'ID: $doctorId',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AdminTextStyles.small(size: 12),
                ),
              ],
            ),
          ),
          // Event details
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: context.sw * 0.4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: color.withValues(alpha: 0.28)),
                  ),
                  child: Text(
                    eventLabel,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: color,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  timestamp != null ? _formatTime(timestamp.toDate()) : '--:--',
                  style: AdminTextStyles.small(size: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Map<String, List<Map<String, dynamic>>> _groupByDate(List<Map<String, dynamic>> logs) {
    final Map<String, List<Map<String, dynamic>>> grouped = {};
    for (final log in logs) {
      final timestamp = log['timestamp'] as Timestamp?;
      final date = timestamp?.toDate() ?? DateTime.now();
      final key = _formatDate(date);
      grouped.putIfAbsent(key, () => []).add(log);
    }
    return grouped;
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    if (date.year == now.year && date.month == now.month && date.day == now.day) {
      return 'Today';
    }
    final yesterday = now.subtract(const Duration(days: 1));
    if (date.year == yesterday.year && date.month == yesterday.month && date.day == yesterday.day) {
      return 'Yesterday';
    }
    return '${date.day}/${date.month}/${date.year}';
  }

  String _formatTime(DateTime time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}