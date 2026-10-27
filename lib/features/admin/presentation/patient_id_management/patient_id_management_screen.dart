import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:syncfusion_flutter_xlsio/xlsio.dart' as xlsio;
import 'package:telemedicine/features/auth/presentation/providers/user_provider.dart';
import 'package:telemedicine/features/admin/presentation/admin_design_system.dart';
import 'package:telemedicine/features/auth/presentation/controllers/patient_id_controller.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/subscription_calculator.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';

class PatientIdManagementScreen extends ConsumerStatefulWidget {
  const PatientIdManagementScreen({super.key});

  @override
  ConsumerState<PatientIdManagementScreen> createState() =>
      _PatientIdManagementScreenState();
}

class _PatientIdManagementScreenState
    extends ConsumerState<PatientIdManagementScreen> {
  final TextEditingController _quantityController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _isGenerating = false;
  bool _isDownloading = false;
  Map<String, int> _stats = {
    'total': 0,
    'available': 0,
    'assigned': 0,
    'blocked': 0,
  };
  List<Map<String, dynamic>> _batches = [];
  bool _isLoadingStats = true;
  bool _statsFailed = false;
  String? _selectedBatchNumber;
  SubscriptionPlan _selectedPlan = SubscriptionPlan.sixMonths;

  // Progress tracking
  GenerationProgress? _currentProgress;
  String? _lastGeneratedBatchNumber;
  List<Map<String, dynamic>> _failedDocs = [];
  int _failedCount = 0;

  @override
  void initState() {
    super.initState();
    _loadStats();
    _loadBatches();
  }

  @override
  void dispose() {
    _quantityController.dispose();
    super.dispose();
  }

  Future<void> _loadStats() async {
    setState(() {
      _isLoadingStats = true;
      _statsFailed = false;
    });
    final controller = ref.read(patientIdControllerProvider);
    try {
      final stats = await controller.getIdStats();
      if (mounted) {
        setState(() {
          _stats = stats;
          _isLoadingStats = false;
        });
      }
    } catch (e) {
      // `getIdStats` used to return an all-zero map on failure, so an offline
      // admin saw a plausible-looking 0/0/0/0 dashboard as if the ID database
      // were empty. Flag it instead of faking data.
      if (mounted) {
        setState(() {
          _statsFailed = true;
          _isLoadingStats = false;
        });
      }
    }
  }

  Future<void> _loadBatches() async {
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('patient_ids')
          .where('isActive', isEqualTo: true)
          .get();

      final Map<String, Map<String, dynamic>> batchMap = {};
      for (final doc in snapshot.docs) {
        final batchNumber = doc.data()['batchNumber'] ?? 'Unknown';
        if (!batchMap.containsKey(batchNumber)) {
          batchMap[batchNumber] = {
            'batchNumber': batchNumber,
            'total': 0,
            'available': 0,
            'assigned': 0,
            'blocked': 0,
            'generatedAt': doc.data()['generatedAt'],
            'subscriptionPlan': doc.data()['subscriptionPlan'],
            'durationMonths': doc.data()['durationMonths'],
          };
        }
        batchMap[batchNumber]!['total'] =
            (batchMap[batchNumber]!['total'] as int) + 1;
        final status = doc.data()['status'] ?? 'Available';
        if (status == 'Available') {
          batchMap[batchNumber]!['available'] =
              (batchMap[batchNumber]!['available'] as int) + 1;
        } else if (status == 'Assigned') {
          batchMap[batchNumber]!['assigned'] =
              (batchMap[batchNumber]!['assigned'] as int) + 1;
        } else if (status == 'Blocked') {
          batchMap[batchNumber]!['blocked'] =
              (batchMap[batchNumber]!['blocked'] as int) + 1;
        }
      }

      final batchList = batchMap.values.toList();
      batchList.sort((a, b) {
        final aTime = a['generatedAt'];
        final bTime = b['generatedAt'];
        if (aTime == null && bTime == null) return 0;
        if (aTime == null) return 1;
        if (bTime == null) return -1;
        final aDate = aTime is Timestamp ? aTime.toDate() : DateTime.now();
        final bDate = bTime is Timestamp ? bTime.toDate() : DateTime.now();
        return bDate.compareTo(aDate);
      });

      if (mounted) {
        setState(() => _batches = batchList);
      }
    } catch (e) {
      print('Error loading batches: $e');
    }
  }

  Future<void> _generateIds() async {
    if (!_formKey.currentState!.validate()) return;

    final quantity = int.tryParse(_quantityController.text.trim());
    if (quantity == null || quantity <= 0) {
      ToastService.instance.showError('Please enter a valid quantity');
      return;
    }

    if (quantity > 10000) {
      ToastService.instance.showError('Maximum 10,000 IDs per batch');
      return;
    }

    final controller = ref.read(patientIdControllerProvider);
    if (controller.isGenerating) {
      ToastService.instance.showWarning('Generation already in progress');
      return;
    }

    setState(() {
      _isGenerating = true;
      _currentProgress = null;
      _failedDocs = [];
      _failedCount = 0;
    });

    final batchNumber = controller.generateBatchNumber();
    _lastGeneratedBatchNumber = batchNumber;

    final result = await controller.generateBatchOptimized(
      quantity: quantity,
      batchNumber: batchNumber,
      plan: _selectedPlan,
      onProgress: (progress) {
        if (mounted) {
          setState(() => _currentProgress = progress);
        }
      },
    );

    if (mounted) {
      setState(() {
        _currentProgress = result;
        _isGenerating = false;
        _failedCount = result.failed;
      });

      if (result.failed == 0) {
        ToastService.instance.showSuccess(
          '${result.generated} Patient IDs generated successfully!',
        );
        _quantityController.clear();
      } else {
        ToastService.instance.showWarning(
          '${result.successCount} created, ${result.failed} failed. Tap Retry to retry failed records.',
        );
      }

      await _loadStats();
      await _loadBatches();
    }
  }

  Future<void> _retryFailed() async {
    if (_failedDocs.isEmpty || _lastGeneratedBatchNumber == null) return;

    final controller = ref.read(patientIdControllerProvider);
    setState(() => _isGenerating = true);

    final result = await controller.retryFailedIds(
      failedDocs: _failedDocs,
      batchNumber: _lastGeneratedBatchNumber!,
      onProgress: (progress) {
        if (mounted) {
          setState(() => _currentProgress = progress);
        }
      },
    );

    if (mounted) {
      setState(() {
        _currentProgress = result;
        _isGenerating = false;
        _failedCount = result.failed;
      });

      if (result.failed == 0) {
        _failedDocs.clear();
        ToastService.instance.showSuccess(
          'All ${result.generated} failed records retried successfully!',
        );
      } else {
        ToastService.instance.showWarning(
          '${result.successCount} recovered, ${result.failed} still failed.',
        );
      }

      await _loadStats();
      await _loadBatches();
    }
  }

  Future<void> _downloadExcel(String batchNumber) async {
    setState(() => _isDownloading = true);

    try {
      final controller = ref.read(patientIdControllerProvider);
      final batchIds = await controller.getPatientIdsByBatch(batchNumber);

      if (batchIds.isEmpty) {
        final errorMsg = controller.errorMessage.isNotEmpty
            ? controller.errorMessage
            : 'No Patient IDs found for batch $batchNumber';
        ToastService.instance.showWarning(errorMsg);
        if (mounted) setState(() => _isDownloading = false);
        return;
      }

      final workbook = xlsio.Workbook();
      final sheet = workbook.worksheets[0];

      // Headers
      sheet.getRangeByIndex(1, 1).setText('#');
      sheet.getRangeByIndex(1, 2).setText('Batch Number');
      sheet.getRangeByIndex(1, 3).setText('Patient ID');
      sheet.getRangeByIndex(1, 4).setText('Plan');
      sheet.getRangeByIndex(1, 5).setText('Duration (Months)');
      sheet.getRangeByIndex(1, 6).setText('Status');
      sheet.getRangeByIndex(1, 7).setText('Created Date');

      // Apply header style
      final headerStyle = workbook.styles.add('HeaderStyle');
      headerStyle.bold = true;
      headerStyle.fontSize = 12;
      headerStyle.fontColor = '#FFFFFF';
      headerStyle.backColor = '#D32F2F';

      for (int col = 1; col <= 7; col++) {
        sheet.getRangeByIndex(1, col).cellStyle = headerStyle;
      }

      // Column widths
      sheet.getRangeByIndex(1, 1).columnWidth = 8;
      sheet.getRangeByIndex(1, 2).columnWidth = 32;
      sheet.getRangeByIndex(1, 3).columnWidth = 20;
      sheet.getRangeByIndex(1, 4).columnWidth = 16;
      sheet.getRangeByIndex(1, 5).columnWidth = 18;
      sheet.getRangeByIndex(1, 6).columnWidth = 15;
      sheet.getRangeByIndex(1, 7).columnWidth = 22;

      // Data rows
      for (int i = 0; i < batchIds.length; i++) {
        final id = batchIds[i];
        sheet.getRangeByIndex(i + 2, 1).setNumber((i + 1).toDouble());
        sheet.getRangeByIndex(i + 2, 2).setText(id.batchNumber);
        sheet.getRangeByIndex(i + 2, 3).setText(id.patientId);
        sheet.getRangeByIndex(i + 2, 4).setText(id.plan.displayName);
        sheet.getRangeByIndex(i + 2, 5).setNumber(id.durationMonths.toDouble());
        sheet.getRangeByIndex(i + 2, 6).setText(id.status);
        sheet
            .getRangeByIndex(i + 2, 7)
            .setText(
              '${id.generatedAt.day.toString().padLeft(2, '0')}/${id.generatedAt.month.toString().padLeft(2, '0')}/${id.generatedAt.year} ${id.generatedAt.hour.toString().padLeft(2, '0')}:${id.generatedAt.minute.toString().padLeft(2, '0')}',
            );
      }

      final List<int> bytes = workbook.saveSync();
      workbook.dispose();

      final directory = await getApplicationDocumentsDirectory();
      final filePath = '${directory.path}/patient_ids_$batchNumber.xlsx';
      final file = File(filePath);
      await file.writeAsBytes(bytes);

      ToastService.instance.showSuccess('Excel file generated!');

      await Share.shareXFiles(
        [XFile(filePath)],
        text: 'Patient IDs - $batchNumber',
        subject: 'Patient ID List - $batchNumber',
      );
    } catch (e) {
      print('Error generating Excel: $e');
      ToastService.instance.showError('Failed to generate Excel: $e');
    } finally {
      if (mounted) setState(() => _isDownloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AdminScreen(
      showBack: true,
      title: 'Patient IDs',
      subtitle: 'Generate and export patient ID batches',
      body: SingleChildScrollView(
        padding: EdgeInsets.all(context.rsp(16)),
        child: CenteredContent(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildStatsCards(),
              SizedBox(height: context.rsp(16)),
              _buildGenerateCard(),
              if (_isGenerating && _currentProgress != null) ...[
                SizedBox(height: context.rsp(16)),
                _buildProgressCard(),
              ],
              if (_failedCount > 0 && !_isGenerating) ...[
                SizedBox(height: context.rsp(14)),
                _buildRetryCard(),
              ],
              if (!_isGenerating &&
                  _currentProgress != null &&
                  _currentProgress!.isComplete) ...[
                SizedBox(height: context.rsp(14)),
                _buildSummaryCard(),
              ],
              SizedBox(height: context.rsp(16)),
              _buildBatchesSection(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatsCards() {
    return AdminCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AdminSectionTitle(icon: Icons.analytics, title: 'ID Statistics'),
          const SizedBox(height: 16),
          if (_isLoadingStats)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: AdminLoading(label: 'Loading stats...'),
            )
          else if (_statsFailed)
            AdminErrorState(
              message: 'Could not load ID statistics. Check your connection.',
              onRetry: _loadStats,
            )
          else
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 1.45,
              children: [
                _buildStatCard(
                  'Total',
                  _stats['total']!.toString(),
                  Icons.inventory_2,
                  AdminPalette.info,
                ),
                _buildStatCard(
                  'Available',
                  _stats['available']!.toString(),
                  Icons.check_circle,
                  AdminPalette.success,
                ),
                _buildStatCard(
                  'Assigned',
                  _stats['assigned']!.toString(),
                  Icons.person,
                  AdminPalette.frozen,
                ),
                _buildStatCard(
                  'Blocked',
                  _stats['blocked']!.toString(),
                  Icons.block,
                  AdminPalette.error,
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildStatCard(
    String title,
    String value,
    IconData icon,
    Color color,
  ) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 18),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              maxLines: 1,
              style: TextStyle(
                fontSize: context.fs(17),
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGenerateCard() {
    return AdminCard(
      padding: EdgeInsets.all(context.rsp(16)),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AdminSectionTitle(
              icon: Icons.add_circle,
              title: 'Generate Patient IDs',
            ),
            const SizedBox(height: 8),
            Text(
              'Generate unique 12-digit Patient IDs. Supports up to 10,000 per request.',
              style: AdminTextStyles.body(size: context.fs(13)),
            ),
            SizedBox(height: context.rsp(16)),
            MetallicInput(
              controller: _quantityController,
              hintText: 'e.g., 1000',
              labelText: 'Quantity (1 – 10,000)',
              showLabel: true,
              icon: Icons.numbers,
              keyboardType: TextInputType.number,
              enabled: !_isGenerating,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return 'Please enter quantity';
                }
                final num = int.tryParse(value);
                if (num == null || num <= 0) {
                  return 'Please enter a valid number';
                }
                if (num > 10000) {
                  return 'Maximum 10,000 IDs per batch';
                }
                return null;
              },
            ),
            SizedBox(height: context.rsp(16)),
            Text(
              'Subscription Plan',
              style: AdminTextStyles.heading(size: context.fs(13)),
            ),
            const SizedBox(height: 6),
            Text(
              'Select the card validity duration for this batch of Patient IDs.',
              style: AdminTextStyles.small(size: context.fs(12)),
            ),
            const SizedBox(height: 10),
            _buildPlanSelector(),
            SizedBox(height: context.rsp(16)),
            AdminPrimaryButton(
              label: _isGenerating ? 'Generating...' : 'Generate Patient IDs',
              leadingIcon: _isGenerating ? null : Icons.auto_awesome,
              isLoading: _isGenerating,
              onPressed: _generateIds,
              height: context.rsp(48),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProgressCard() {
    final progress = _currentProgress!;
    final pct = progress.percentage.clamp(0, 100);

    return Container(
      padding: EdgeInsets.all(context.rsp(16)),
      decoration: BoxDecoration(
        gradient: AdminPalette.cardGradient,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: AdminPalette.brand.withValues(alpha: 0.12),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
        border: Border.all(color: AdminPalette.brand.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  value: pct / 100,
                  color: AdminPalette.brand,
                  backgroundColor: AdminPalette.segmentBorder,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Generating Patient IDs',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AdminTextStyles.heading(size: context.fs(14)),
                ),
              ),
            ],
          ),
          SizedBox(height: context.rsp(14)),

          // Progress bar
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: pct / 100,
              minHeight: 10,
              backgroundColor: AdminPalette.segmentBorder,
              valueColor: AlwaysStoppedAnimation<Color>(
                pct >= 100 ? AdminPalette.success : AdminPalette.brand,
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Stats row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Text(
                  '${_formatNumber(progress.generated)} / ${_formatNumber(progress.totalRequested)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AdminTextStyles.heading(size: context.fs(13.5)),
                ),
              ),
              Text(
                '${pct.toStringAsFixed(0)}%',
                style: TextStyle(
                  fontSize: context.fs(13.5),
                  fontWeight: FontWeight.bold,
                  color: AdminPalette.brand,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // Batch info
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Text(
                  'Batch ${progress.currentBatch} / ${progress.totalBatches}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AdminTextStyles.small(size: 12),
                ),
              ),
              if (progress.failed > 0)
                Text(
                  '${progress.failed} failed',
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 12,
                    color: AdminPalette.error,
                    fontWeight: FontWeight.w500,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Batch: ${progress.batchNumber}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AdminTextStyles.small(size: 11),
          ),
        ],
      ),
    );
  }

  Widget _buildRetryCard() {
    return Container(
      padding: EdgeInsets.all(context.rsp(14)),
      decoration: BoxDecoration(
        color: AdminPalette.frozen.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AdminPalette.frozen.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(
            Icons.warning_amber_rounded,
            color: AdminPalette.frozen,
            size: 28,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$_failedCount records failed',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: context.fs(13.5),
                    color: AdminPalette.frozen,
                  ),
                ),
                Text(
                  'Tap retry to attempt saving the failed records.',
                  style: TextStyle(fontSize: 12, color: AdminPalette.frozen),
                ),
              ],
            ),
          ),
          AdminSolidButton(
            label: 'Retry',
            color: AdminPalette.frozen,
            height: 40,
            onPressed: _isGenerating ? null : _retryFailed,
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryCard() {
    final progress = _currentProgress!;
    final allSuccess = progress.failed == 0;

    final color = allSuccess ? AdminPalette.success : AdminPalette.frozen;

    return Container(
      padding: EdgeInsets.all(context.rsp(16)),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                allSuccess ? Icons.check_circle : Icons.info_outline,
                color: color,
                size: 24,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Generation Complete',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AdminTextStyles.heading(
                    size: context.fs(14),
                    color: color,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _summaryRow('Requested', _formatNumber(progress.totalRequested)),
          _summaryRow('Created', _formatNumber(progress.successCount)),
          _summaryRow('Plan', _selectedPlan.displayName),
          if (progress.failed > 0)
            _summaryRow('Failed', '${progress.failed}', isRed: true),
          _summaryRow('Batch', progress.batchNumber),
        ],
      ),
    );
  }

  Widget _summaryRow(String label, String value, {bool isRed = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Text('$label: ', style: AdminTextStyles.body(size: context.fs(13))),
          Flexible(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: context.fs(13),
                fontWeight: FontWeight.w600,
                color: isRed ? AdminPalette.error : AdminPalette.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatNumber(int n) {
    return n.toString().replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
      (Match m) => '${m[1]},',
    );
  }

  Widget _buildBatchesSection() {
    return AdminCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AdminSectionTitle(icon: Icons.queue, title: 'Generated Batches'),
          const SizedBox(height: 16),
          _batches.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'No batches generated yet.\nEnter a quantity and click Generate.',
                      textAlign: TextAlign.center,
                      style: AdminTextStyles.body(size: context.fs(13.5)),
                    ),
                  ),
                )
              : ListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: _batches.length,
                  itemBuilder: (context, index) {
                    final batch = _batches[index];
                    return _buildBatchCard(batch);
                  },
                ),
        ],
      ),
    );
  }

  Widget _buildBatchCard(Map<String, dynamic> batch) {
    final batchNumber = batch['batchNumber'] ?? 'Unknown';
    final isSelected = _selectedBatchNumber == batchNumber;

    return GestureDetector(
      onTap: () {
        setState(() {
          _selectedBatchNumber = isSelected ? null : batchNumber;
        });
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isSelected
              ? AdminPalette.brand.withValues(alpha: 0.05)
              : AdminPalette.infoBg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSelected ? AdminPalette.brand : AdminPalette.cardBorder,
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isSelected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: isSelected
                      ? AdminPalette.brand
                      : AdminPalette.textMuted,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        batchNumber,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AdminTextStyles.heading(size: context.fs(13.5)),
                      ),
                      const SizedBox(height: 2),
                      AdminPill(
                        text: SubscriptionPlan.fromPlanId(
                          batch['subscriptionPlan']?.toString(),
                        ).displayName,
                        color: _getPlanColor(
                          SubscriptionPlan.fromPlanId(
                            batch['subscriptionPlan']?.toString(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  height: 32,
                  child: ElevatedButton.icon(
                    onPressed: _isDownloading
                        ? null
                        : () => _downloadExcel(batchNumber),
                    icon: _isDownloading
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.download, size: 16),
                    label: Text(
                      _isDownloading ? '' : 'Excel',
                      style: TextStyle(fontSize: 12),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AdminPalette.brand,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                _buildBatchStat('Total', batch['total'], AdminPalette.info),
                SizedBox(width: context.rsp(8)),
                _buildBatchStat(
                  'Available',
                  batch['available'],
                  AdminPalette.success,
                ),
                SizedBox(width: context.rsp(8)),
                _buildBatchStat(
                  'Assigned',
                  batch['assigned'],
                  AdminPalette.frozen,
                ),
                SizedBox(width: context.rsp(8)),
                _buildBatchStat(
                  'Blocked',
                  batch['blocked'],
                  AdminPalette.error,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBatchStat(String label, int count, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                count.toString(),
                maxLines: 1,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: context.fs(13.5),
                  color: color,
                ),
              ),
            ),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                label,
                maxLines: 1,
                style: TextStyle(fontSize: 10, color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlanSelector() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 420;
        final children = [
          _buildPlanOption(
            plan: SubscriptionPlan.oneMonth,
            title: '1 Month',
            subtitle: '1 Month',
            icon: Icons.calendar_view_month,
          ),
          SizedBox(width: isNarrow ? 0 : 8, height: isNarrow ? 8 : 0),
          _buildPlanOption(
            plan: SubscriptionPlan.sixMonths,
            title: '6 Months',
            subtitle: 'Default',
            icon: Icons.calendar_month,
          ),
          SizedBox(width: isNarrow ? 0 : 8, height: isNarrow ? 8 : 0),
          _buildPlanOption(
            plan: SubscriptionPlan.oneYear,
            title: '1 Year',
            subtitle: '12 Months',
            icon: Icons.verified,
          ),
        ];

        return isNarrow
            ? Column(children: children)
            : Row(
                children: children
                    .map((w) => w is SizedBox ? w : Expanded(child: w))
                    .toList(),
              );
      },
    );
  }

  Widget _buildPlanOption({
    required SubscriptionPlan plan,
    required String title,
    required String subtitle,
    required IconData icon,
  }) {
    final isSelected = _selectedPlan == plan;
    final color = _getPlanColor(plan);

    return InkWell(
      onTap: _isGenerating
          ? null
          : () {
              setState(() => _selectedPlan = plan);
            },
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected
              ? color.withValues(alpha: 0.12)
              : AdminPalette.infoBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? color : AdminPalette.cardBorder,
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              isSelected ? Icons.check_circle : icon,
              size: 20,
              color: isSelected ? color : AdminPalette.textMuted,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: context.fs(12.5),
                      fontWeight: isSelected
                          ? FontWeight.bold
                          : FontWeight.w600,
                      color: isSelected ? color : AdminPalette.textPrimary,
                    ),
                  ),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10.5,
                      color: isSelected
                          ? color.withValues(alpha: 0.8)
                          : AdminPalette.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _getPlanColor(SubscriptionPlan plan) {
    switch (plan) {
      case SubscriptionPlan.oneMonth:
        return AdminPalette.info;
      case SubscriptionPlan.sixMonths:
        return AdminPalette.brand;
      case SubscriptionPlan.oneYear:
        return AdminPalette.success;
    }
  }
}
