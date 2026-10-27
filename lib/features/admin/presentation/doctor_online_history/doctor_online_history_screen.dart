import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:syncfusion_flutter_charts/charts.dart';
import 'package:telemedicine/data/models/doctor_online_session.dart';
import 'package:telemedicine/features/admin/presentation/doctor_online_history/doctor_online_services/doctor_online_history_service.dart';
import 'package:telemedicine/features/admin/presentation/admin_design_system.dart';
import 'package:telemedicine/features/auth/presentation/controllers/doctor_controller.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';

class DoctorOnlineHistoryScreen extends ConsumerStatefulWidget {
  const DoctorOnlineHistoryScreen({super.key});

  @override
  ConsumerState<DoctorOnlineHistoryScreen> createState() =>
      _DoctorOnlineHistoryScreenState();
}

class _DoctorOnlineHistoryScreenState
    extends ConsumerState<DoctorOnlineHistoryScreen> {
  final DoctorOnlineHistoryService _historyService =
      DoctorOnlineHistoryService();
  String? _selectedDoctorId;
  String? _selectedDoctorName;
  TimeRange _selectedTimeRange = TimeRange.week;

  List<DoctorDailyStats> _dailyStats = [];
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadDoctorsAndStats();
  }

  Future<void> _loadDoctorsAndStats() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final doctors = await ref
          .read(doctorControllerProvider)
          .getAllDoctorProfiles();

      if (!mounted) return;

      if (doctors.isNotEmpty && _selectedDoctorId == null) {
        _selectedDoctorId = doctors.first['id'].toString();
        _selectedDoctorName = doctors.first['fullname'].toString();
        await _loadStatsForDoctor();
      } else if (_selectedDoctorId != null) {
        await _loadStatsForDoctor();
      }

      setState(() {
        _isLoading = false;
      });

      if (doctors.isEmpty) {
        ToastService.instance.showWarning('No doctors found in the system');
      }
    } catch (e) {
      debugPrint('Failed to load doctors: $e');
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Something went wrong. Please try again.';
        _isLoading = false;
      });
      ToastService.instance.showError('Something went wrong. Please try again.');
    }
  }

  Future<void> _loadStatsForDoctor() async {
    if (_selectedDoctorId == null) return;

    setState(() {
      _isLoading = true;
    });

    try {
      final (startDate, endDate) = _getDateRange();

      final stats = await _getDoctorStatsForDateRange(
        doctorId: _selectedDoctorId!,
        startDate: startDate,
        endDate: endDate,
      );

      if (!mounted) return;

      setState(() {
        _dailyStats = stats;
        _isLoading = false;
      });

      if (stats.isEmpty) {
        ToastService.instance.showInfo(
          'No online history found for this period',
        );
      }
    } catch (e) {
      debugPrint('Failed to load stats: $e');
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Something went wrong. Please try again.';
        _isLoading = false;
      });
      ToastService.instance.showError('Something went wrong. Please try again.');
    }
  }

  Future<List<DoctorDailyStats>> _getDoctorStatsForDateRange({
    required String doctorId,
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    try {
      final snapshot = await _historyService
          .getDoctorDailyStats(
            doctorId: doctorId,
            startDate: startDate,
            endDate: endDate,
          )
          .first;

      return snapshot;
    } catch (e) {
      ToastService.instance.showWarning(
        'Using alternative data loading method',
      );

      final stats = await _historyService.getDoctorDailyStatsAlternative(
        doctorId: doctorId,
        startDate: startDate,
        endDate: endDate,
      );
      return stats;
    }
  }

  (DateTime, DateTime) _getDateRange() {
    final now = DateTime.now();
    DateTime startDate;
    DateTime endDate = now;

    switch (_selectedTimeRange) {
      case TimeRange.day:
        startDate = DateTime(now.year, now.month, now.day);
        break;
      case TimeRange.week:
        startDate = now.subtract(Duration(days: 7));
        break;
      case TimeRange.month:
        startDate = DateTime(now.year, now.month - 1, now.day);
        break;
    }

    return (startDate, endDate);
  }

  Duration _getTotalDuration() {
    return _dailyStats.fold(
      Duration.zero,
      (sum, stat) => sum + stat.totalOnlineDuration,
    );
  }

  int _getTotalSessions() {
    return _dailyStats.fold(0, (sum, stat) => sum + stat.sessionsCount);
  }

  double _getAverageDailyDuration() {
    if (_dailyStats.isEmpty) return 0;
    final totalDuration = _getTotalDuration();
    return totalDuration.inMinutes / _dailyStats.length;
  }

  @override
  Widget build(BuildContext context) {
    return AdminScreen(
      showBack: true,
      title: 'Online History',
      subtitle: _selectedDoctorName ?? 'Pulling stats & sessions',
      body: _isLoading
          ? const AdminLoading(label: 'Loading statistics...')
          : _errorMessage != null
              ? _buildErrorWidget()
              : _buildContent(),
    );
  }

  Widget _buildErrorWidget() {
    return AdminErrorState(
      message: _errorMessage!,
      onRetry: () {
        _loadDoctorsAndStats();
        ToastService.instance.showInfo('Retrying...');
      },
    );
  }

  Widget _buildContent() {
    final totalDuration = _getTotalDuration();
    final totalSessions = _getTotalSessions();
    final avgDailyDuration = _getAverageDailyDuration();

    // SingleChildScrollView + Column keeps the whole page scrollable
    return SingleChildScrollView(
      child: Column(
        children: [
          // Doctor selector and time range filter
          Padding(
            padding: EdgeInsets.fromLTRB(
              context.rsp(16),
              context.rsp(16),
              context.rsp(16),
              0,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AdminSectionLabel(
                  'Select Doctor',
                  padding: const EdgeInsets.only(bottom: 8, left: 4),
                ),
                _buildDoctorSelector(),
                const SizedBox(height: 16),
                AdminSectionLabel(
                  'Time Range',
                  padding: const EdgeInsets.only(bottom: 8, left: 4),
                ),
                AdminSegmentedControl<TimeRange>(
                  value: _selectedTimeRange,
                  onChanged: (range) {
                    setState(() {
                      _selectedTimeRange = range;
                      _loadStatsForDoctor();
                    });
                    ToastService.instance.showInfo('Showing ${_rangeLabel(range)} data');
                  },
                  options: [
                    AdminSegmentOption(TimeRange.day, 'Today', Icons.today_outlined),
                    AdminSegmentOption(TimeRange.week, 'Week', Icons.calendar_view_week_outlined),
                    AdminSegmentOption(TimeRange.month, 'Month', Icons.calendar_month_outlined),
                  ],
                ),
              ],
            ),
          ),

          // Stats Cards
          Padding(
            padding: EdgeInsets.all(context.rsp(16)),
            child: Row(
              children: [
                _buildStatCard(
                  'Total Online Time',
                  _formatDuration(totalDuration),
                  Icons.timer,
                  AdminPalette.brand,
                ),
                SizedBox(width: context.rsp(10)),
                _buildStatCard(
                  'Total Sessions',
                  totalSessions.toString(),
                  Icons.history,
                  AdminPalette.success,
                ),
                SizedBox(width: context.rsp(10)),
                _buildStatCard(
                  'Avg Daily',
                  '${avgDailyDuration.toStringAsFixed(1)} min',
                  Icons.trending_up,
                  AdminPalette.frozen,
                ),
              ],
            ),
          ),

          // Chart
          AdminCard(
            margin: EdgeInsets.symmetric(horizontal: context.rsp(16)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Daily Online Duration',
                  style: AdminTextStyles.heading(size: context.fs(14)),
                ),
                SizedBox(height: context.rsp(16)),
                SizedBox(
                  height: math.min(
                    300.0,
                    math.max(220.0, context.sh * 0.38),
                  ),
                  child: _buildChart(),
                ),
              ],
            ),
          ),

          // Detailed List
          Padding(
            padding: EdgeInsets.all(context.rsp(16)),
            child: _dailyStats.isEmpty
                ? _buildEmptyListWidget()
                : _buildDetailedList(),
          ),

          const SizedBox(height: 20),
        ],
      ),
    );
  }

  String _rangeLabel(TimeRange range) {
    switch (range) {
      case TimeRange.day:
        return 'today';
      case TimeRange.week:
        return 'this week';
      case TimeRange.month:
        return 'this month';
    }
  }

  Widget _buildEmptyListWidget() {
    return AdminEmptyState(
      icon: Icons.history_rounded,
      title: 'No online history available',
      subtitle: 'Doctor needs to log in to start tracking',
      action: AdminSolidButton(
        label: 'Refresh',
        icon: Icons.refresh,
        color: AdminPalette.brand,
        onPressed: _loadStatsForDoctor,
      ),
    );
  }

  Widget _buildDoctorSelector() {
    return Consumer(
      builder: (context, ref, child) {
        final doctorsAsync = ref
            .watch(doctorControllerProvider)
            .getAllDoctorProfiles();

        return FutureBuilder<List<Map<String, dynamic>>>(
          future: doctorsAsync,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              ToastService.instance.showError(
                'Error loading doctors: ${snapshot.error}',
              );
              return AdminInfoBanner(
                icon: Icons.error_outline,
                title: 'Error loading doctors',
                color: AdminPalette.error,
              );
            }

            if (!snapshot.hasData || snapshot.data!.isEmpty) {
              return AdminInfoBanner(
                icon: Icons.medical_services_outlined,
                title: 'No doctors available',
                color: AdminPalette.textMuted,
              );
            }

            final doctors = snapshot.data!;

            // Metallic dropdown styled like the Sign In inputs
            return Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                gradient: AdminPalette.inputOuterGradient,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: AdminPalette.inputOuterBorder,
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF0F233C).withValues(alpha: 0.08),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Container(
                padding: const EdgeInsets.only(left: 4),
                decoration: BoxDecoration(
                  gradient: AdminPalette.inputInnerGradient,
                  borderRadius: BorderRadius.circular(15),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _selectedDoctorId,
                    isExpanded: true,
                    icon: const Icon(
                      Icons.keyboard_arrow_down_rounded,
                      color: AdminPalette.iconSecondary,
                    ),
                    hint: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        'Select Doctor',
                        style: TextStyle(
                          color: AdminPalette.textMuted,
                          fontSize: context.fs(13),
                        ),
                      ),
                    ),
                    items: doctors.map((doctor) {
                      return DropdownMenuItem(
                        value: doctor['id'].toString(),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                              child: Row(
                                children: [
                                  Container(
                                    width: 30,
                                    height: 30,
                                    decoration: BoxDecoration(
                                      color: AdminPalette.brand
                                          .withValues(alpha: 0.1),
                                      borderRadius: BorderRadius.circular(9),
                                    ),
                                    child: const Icon(
                                      Icons.person,
                                      size: 16,
                                      color: AdminPalette.brand,
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Flexible(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          doctor['fullname'] ?? 'Unknown',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: context.fs(13.5),
                                            fontWeight: FontWeight.w500,
                                            color: AdminPalette.textPrimary,
                                          ),
                                        ),
                                        Text(
                                          'ID: ${doctor['doctorId']}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: AdminPalette.textMuted,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                        ),
                      );
                    }).toList(),
                    onChanged: (value) {
                      setState(() {
                        _selectedDoctorId = value;
                        _selectedDoctorName = doctors.firstWhere(
                          (d) => d['id'].toString() == value,
                        )['fullname'];
                        _loadStatsForDoctor();
                      });
                      ToastService.instance.showInfo(
                        'Loading data for selected doctor',
                      );
                    },
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildStatCard(
    String title,
    String value,
    IconData icon,
    Color color,
  ) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          gradient: AdminPalette.cardGradient,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AdminPalette.cardBorder),
          boxShadow: [
            BoxShadow(
              color: AdminPalette.cardShadow.withValues(alpha: 0.08),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(height: 8),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                value,
                maxLines: 1,
                style: TextStyle(
                  fontSize: context.fs(15),
                  fontWeight: FontWeight.bold,
                  color: AdminPalette.textPrimary,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                color: AdminPalette.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChart() {
    if (_dailyStats.isEmpty) {
      return AdminEmptyState(
        icon: Icons.show_chart,
        title: 'No data for this period',
        subtitle: 'Doctor needs to have online sessions to show data',
      );
    }

    final List<ChartData> chartData = _dailyStats.map((stat) {
      return ChartData(
        _formatDate(stat.date),
        stat.totalOnlineDuration.inMinutes.toDouble(),
        stat.sessionsCount,
      );
    }).toList();

    return SfCartesianChart(
      primaryXAxis: CategoryAxis(
        labelStyle: TextStyle(fontSize: 10),
        labelRotation: 45,
      ),
      primaryYAxis: NumericAxis(
        title: AxisTitle(
          text: 'Minutes Online',
          textStyle: TextStyle(fontSize: 12),
        ),
        labelStyle: TextStyle(fontSize: 10),
      ),
      tooltipBehavior: TooltipBehavior(enable: true),
      series: <CartesianSeries<ChartData, String>>[
        ColumnSeries<ChartData, String>(
          dataSource: chartData,
          xValueMapper: (ChartData data, _) => data.date,
          yValueMapper: (ChartData data, _) => data.minutes,
          name: 'Online Duration',
          color: AdminPalette.brand,
          dataLabelSettings: const DataLabelSettings(isVisible: true),
          dataLabelMapper: (ChartData data, _) => '${data.minutes.toInt()} min',
        ),
      ],
    );
  }

  Widget _buildDetailedList() {
    return ListView.builder(
      shrinkWrap: true, // Allows ListView to size itself inside scroll view
      physics: const NeverScrollableScrollPhysics(),
      itemCount: _dailyStats.length,
      itemBuilder: (context, index) {
        final stat = _dailyStats[index];
        return AdminCard(
          margin: const EdgeInsets.only(bottom: 12),
          radius: 16,
          child: Row(
            children: [
              Container(
                width: 50,
                height: 50,
                decoration: BoxDecoration(
                  color: AdminPalette.brand.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(
                  Icons.calendar_today,
                  color: AdminPalette.brand,
                ),
              ),
              SizedBox(width: context.rsp(12)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _formatDate(stat.date),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AdminTextStyles.heading(size: context.fs(14)),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${stat.sessionsCount} sessions',
                      style: AdminTextStyles.small(size: 12),
                    ),
                  ],
                ),
              ),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: context.sw * 0.4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        _formatDuration(stat.totalOnlineDuration),
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: context.fs(15),
                          fontWeight: FontWeight.bold,
                          color: AdminPalette.brand,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: AdminPalette.success.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: AdminPalette.success.withValues(alpha: 0.28),
                        ),
                      ),
                      child: Text(
                        '${stat.totalOnlineDuration.inMinutes} min',
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: 10,
                          color: AdminPalette.success,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    if (date.year == now.year &&
        date.month == now.month &&
        date.day == now.day) {
      return 'Today';
    }

    final yesterday = now.subtract(const Duration(days: 1));
    if (date.year == yesterday.year &&
        date.month == yesterday.month &&
        date.day == yesterday.day) {
      return 'Yesterday';
    }

    return '${date.day}/${date.month}/${date.year}';
  }

  String _formatDuration(Duration duration) {
    if (duration.inDays > 0) {
      return '${duration.inDays}d ${duration.inHours.remainder(24)}h';
    } else if (duration.inHours > 0) {
      return '${duration.inHours}h ${duration.inMinutes.remainder(60)}m';
    } else {
      return '${duration.inMinutes}m';
    }
  }
}

enum TimeRange { day, week, month }

class ChartData {
  final String date;
  final double minutes;
  final int sessions;

  ChartData(this.date, this.minutes, this.sessions);
}