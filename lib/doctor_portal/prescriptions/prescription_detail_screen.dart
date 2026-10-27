import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:telemedicine/data/models/prescription_model.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/doctor_portal/prescriptions/prescription_controller.dart';
import 'package:telemedicine/shared/widgets/auth_layout.dart';
import 'package:telemedicine/shared/widgets/opd_design.dart';

/// Read-only, print-style prescription page.
///
/// Reachable from the prescription card in the chat. Both the prescribing
/// doctor and the patient can open it; anyone else is refused, so a
/// prescription belonging to a different patient can never be displayed.
class PrescriptionDetailScreen extends ConsumerStatefulWidget {
  final String prescriptionId;

  /// The signed-in user.
  final String viewerId;

  /// Fallback ids used to authorise the viewer when the stored record does not
  /// carry them (e.g. a very old document).
  final String? expectedDoctorId;
  final String? expectedPatientId;

  const PrescriptionDetailScreen({
    super.key,
    required this.prescriptionId,
    required this.viewerId,
    this.expectedDoctorId,
    this.expectedPatientId,
  });

  @override
  ConsumerState<PrescriptionDetailScreen> createState() =>
      _PrescriptionDetailScreenState();
}

class _PrescriptionDetailScreenState
    extends ConsumerState<PrescriptionDetailScreen> {
  Object? _error;
  bool _loading = true;
  PrescriptionModel? _prescription;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final prescription = await ref
          .read(prescriptionControllerProvider)
          .fetchById(widget.prescriptionId);
      if (!mounted) return;
      setState(() {
        _prescription = prescription;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return OpdScreenShell(
      title: 'Prescription',
      subtitle: 'Issued through OPD Telemedicine.',
      showLogo: true,
      bottom: GradientButton(
        text: 'Done',
        icon: Icons.check_rounded,
        onPressed: () => Navigator.maybePop(context),
      ),
      child: _buildContent(),
    );
  }

  Widget _buildContent() {
    if (_loading) {
      return const OpdInlineLoader(label: 'Loading prescription...');
    }

    if (_error != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const OpdEmptyState(
            icon: Icons.error_outline_rounded,
            title: 'Could not load prescription',
            subtitle: 'Please check your connection and try again.',
          ),
          const SizedBox(height: 20),
          GradientButton(
            text: 'Retry',
            icon: Icons.refresh_rounded,
            onPressed: _load,
          ),
        ],
      );
    }

    final prescription = _prescription;
    if (prescription == null) {
      return const OpdEmptyState(
        icon: Icons.description_outlined,
        title: 'Prescription not found',
        subtitle: 'This prescription is no longer available.',
      );
    }

    if (!_isAuthorised(prescription)) {
      return const OpdEmptyState(
        icon: Icons.lock_outline_rounded,
        title: 'Access restricted',
        subtitle:
            'This prescription belongs to a different consultation and is not available to you.',
      );
    }

    return _buildPrescriptionPaper(prescription);
  }

  /// Only the prescribing doctor or the prescribed patient may open it.
  bool _isAuthorised(PrescriptionModel prescription) {
    final doctorId =
        (prescription.doctorId.isNotEmpty
                ? prescription.doctorId
                : (widget.expectedDoctorId ?? ''))
            .toString();
    final patientId =
        (prescription.patientId.isNotEmpty
                ? prescription.patientId
                : (widget.expectedPatientId ?? ''))
            .toString();
    if (doctorId.isEmpty && patientId.isEmpty) return false;
    return widget.viewerId == doctorId || widget.viewerId == patientId;
  }

  Widget _buildPrescriptionPaper(PrescriptionModel p) {
    final doctorName = p.doctorName.toString();
    final patientName = p.patientName.toString();
    final age = p.patientAge.toString();
    final date = DateFormat('dd MMM yyyy').format(p.createdAt);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 22),

        // ── The prescription "paper" ──
        OpdCard(
          padding: EdgeInsets.fromLTRB(
            context.rsp(20),
            22,
            context.rsp(20),
            20,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildField(label: 'Doctor', value: 'Dr. $doctorName'),
              const SizedBox(height: 14),
              _buildField(label: 'Patient', value: patientName),
              const SizedBox(height: 14),
              _buildField(
                label: 'Age',
                value: age.isEmpty ? 'Not recorded' : '$age Years',
              ),
              const SizedBox(height: 14),
              _buildField(label: 'Date', value: date),

              const SizedBox(height: 20),
              const Divider(height: 1, color: Color(0xFFDCE6F2)),
              const SizedBox(height: 18),

              Text(
                'Prescription / Instructions',
                style: TextStyle(
                  fontSize: context.fs(13),
                  fontWeight: FontWeight.w600,
                  color: const Color(0xFF162B72),
                ),
              ),
              const SizedBox(height: 12),
              // The doctor's complete, multiline note is shown verbatim.
              SelectableText(
                p.note.toString().trim().isEmpty
                    ? 'No instructions were provided.'
                    : p.note.toString().trim(),
                style: TextStyle(
                  fontSize: context.fs(14),
                  height: 1.65,
                  color: const Color(0xFF1F2F44),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 18),

        // ── Footer: reference id + brand ──
        OpdCard(
          padding: EdgeInsets.symmetric(
            horizontal: context.rsp(16),
            vertical: 14,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Prescription ID',
                      style: TextStyle(
                        fontSize: context.fs(11.5),
                        color: const Color(0xFF7E90A6),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      p.reference.toString(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: context.fs(13),
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFF163B6E),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  'OPD Telemedicine',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    fontSize: context.fs(13),
                    fontWeight: FontWeight.w700,
                    color: const Color(0xFF162B72),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildField({required String label, required String value}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: context.fs(11.5),
            fontWeight: FontWeight.w500,
            color: const Color(0xFF7E90A6),
          ),
        ),
        const SizedBox(height: 3),
        Text(
          value,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: context.fs(14),
            fontWeight: FontWeight.w600,
            color: const Color(0xFF1F2F44),
          ),
        ),
      ],
    );
  }
}
