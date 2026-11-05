import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:telemedicine/features/auth/presentation/providers/user_provider.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/data/models/prescription_model.dart';
import 'package:telemedicine/features/doctor_portal/presentation/prescriptions/prescription_controller.dart';
import 'package:telemedicine/features/doctor_portal/presentation/prescriptions/prescription_detail_screen.dart';
import 'package:telemedicine/features/chat/presentation/controllers/chat_controller.dart';
import 'package:telemedicine/shared/widgets/auth_layout.dart';
import 'package:telemedicine/shared/widgets/opd_design_system.dart';

/// Doctor-side prescriptions for the current chat / patient.
class PrescriptionScreen extends ConsumerStatefulWidget {
  final String chatId;
  final String patientId;
  final String patientName;

  const PrescriptionScreen({
    super.key,
    required this.chatId,
    required this.patientId,
    required this.patientName,
  });

  @override
  ConsumerState<PrescriptionScreen> createState() => _PrescriptionScreenState();
}

class _PrescriptionScreenState extends ConsumerState<PrescriptionScreen> {
  Stream<List<PrescriptionModel>>? _stream;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _subscribe());
  }

  void _subscribe() {
    if (!mounted) return;
    if (ref.read(userProvider) == null) return;
    try {
      setState(() {
        _stream = ref
            .read(prescriptionControllerProvider)
            .streamForChat(widget.chatId);
      });
    } catch (e) {
      debugPrint('[PrescriptionScreen] Subscription error: $e');
    }
  }

  Future<void> _openForm() async {
    final created = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => PrescriptionFormScreen(
          chatId: widget.chatId,
          patientId: widget.patientId,
          patientName: widget.patientName,
        ),
      ),
    );
    if (created == true && mounted) {
      ToastService.instance.showSuccess('Prescription created and sent');
    }
  }

  void _openDetail(PrescriptionModel prescription) {
    final viewer = ref.read(userProvider);
    if (viewer == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PrescriptionDetailScreen(
          prescriptionId: prescription.prescriptionId,
          viewerId: viewer.id,
          expectedDoctorId: prescription.doctorId,
          expectedPatientId: prescription.patientId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return OpdScreenShell(
      title: 'Prescriptions',
      subtitle: 'Official prescriptions issued to ${widget.patientName}.',
      bottom: GradientButton(
        text: 'New Prescription',
        icon: Icons.add_rounded,
        onPressed: _openForm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [_buildList()],
      ),
    );
  }

  Widget _buildList() {
    if (_stream == null) {
      return const OpdInlineLoader(label: 'Loading prescriptions...');
    }

    return StreamBuilder<List<PrescriptionModel>>(
      stream: _stream,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const OpdInlineLoader(label: 'Loading prescriptions...');
        }
        if (snapshot.hasError) {
          return _buildErrorState(snapshot.error!);
        }

        final prescriptions = snapshot.data ?? const [];
        if (prescriptions.isEmpty) {
          return const OpdEmptyState(
            icon: Icons.medical_information_rounded,
            title: 'No prescriptions yet',
            subtitle:
                'Tap "New Prescription" below to write an official branded prescription.',
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            OpdCounterChip(
              '${prescriptions.length} prescription${prescriptions.length == 1 ? '' : 's'}',
            ),
            const SizedBox(height: 16),
            for (final prescription in prescriptions) ...[
              _PrescriptionCard(
                prescription: prescription,
                onTap: () => _openDetail(prescription),
              ),
              const SizedBox(height: 14),
            ],
          ],
        );
      },
    );
  }

  Widget _buildErrorState(Object error) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const OpdEmptyState(
          icon: Icons.error_outline_rounded,
          title: 'Could not load prescriptions',
          subtitle:
              'Something went wrong while loading. Tap Retry to try again.',
        ),
        const SizedBox(height: 20),
        GradientButton(
          text: 'Retry',
          icon: Icons.refresh_rounded,
          onPressed: _subscribe,
        ),
      ],
    );
  }
}

/// Helper model for reactive medicine entry fields in the prescription form.
class _MedicineInputGroup {
  final TextEditingController name = TextEditingController();
  final TextEditingController strength = TextEditingController();
  final TextEditingController dosage = TextEditingController();
  final TextEditingController frequency = TextEditingController();
  final TextEditingController duration = TextEditingController();
  final TextEditingController instructions = TextEditingController();

  void dispose() {
    name.dispose();
    strength.dispose();
    dosage.dispose();
    frequency.dispose();
    duration.dispose();
    instructions.dispose();
  }

  PrescriptionMedicine toMedicine() {
    return PrescriptionMedicine(
      name: name.text.trim(),
      strength: strength.text.trim(),
      dosage: dosage.text.trim(),
      frequency: frequency.text.trim(),
      duration: duration.text.trim(),
      instructions: instructions.text.trim(),
    );
  }
}

/// Official OPD Prescription Composition Screen.
class PrescriptionFormScreen extends ConsumerStatefulWidget {
  final String chatId;
  final String patientId;
  final String patientName;

  const PrescriptionFormScreen({
    super.key,
    required this.chatId,
    required this.patientId,
    required this.patientName,
  });

  @override
  ConsumerState<PrescriptionFormScreen> createState() =>
      _PrescriptionFormScreenState();
}

class _PrescriptionFormScreenState
    extends ConsumerState<PrescriptionFormScreen> {
  final List<_MedicineInputGroup> _medicines = [];
  final TextEditingController _noteController = TextEditingController();
  final TextEditingController _adviceController = TextEditingController();
  final TextEditingController _followUpController = TextEditingController();

  final FocusNode _noteFocus = FocusNode();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    // Start with 1 medicine input row by default
    _addMedicineRow();
  }

  void _addMedicineRow() {
    setState(() {
      _medicines.add(_MedicineInputGroup());
    });
  }

  void _removeMedicineRow(int index) {
    if (_medicines.length <= 1) {
      // Clear instead of removing last row
      _medicines.first.name.clear();
      _medicines.first.strength.clear();
      _medicines.first.dosage.clear();
      _medicines.first.frequency.clear();
      _medicines.first.duration.clear();
      _medicines.first.instructions.clear();
      setState(() {});
      return;
    }
    setState(() {
      final removed = _medicines.removeAt(index);
      removed.dispose();
    });
  }

  @override
  void dispose() {
    for (final med in _medicines) {
      med.dispose();
    }
    _noteController.dispose();
    _adviceController.dispose();
    _followUpController.dispose();
    _noteFocus.dispose();
    super.dispose();
  }

  Future<void> _saveAndSend() async {
    final note = _noteController.text.trim();
    final advice = _adviceController.text.trim();
    final followUp = _followUpController.text.trim();

    final validMedicines = _medicines
        .map((m) => m.toMedicine())
        .where((m) => m.isNotEmpty)
        .toList();

    // Must have at least one medicine OR a written general prescription note
    if (validMedicines.isEmpty && note.isEmpty) {
      ToastService.instance.showWarning(
        'Please add at least one medicine or write a prescription note',
      );
      return;
    }

    final user = ref.read(userProvider);
    if (user == null) return;

    setState(() => _sending = true);
    try {
      final controller = ref.read(prescriptionControllerProvider);

      // Snapshot patient demographic info (age & gender)
      final patientInfo = await controller.fetchPatientInfo(widget.patientId);
      final patientAge = patientInfo['age'] ?? '';
      final patientGender = patientInfo['gender'] ?? '';

      // Snapshot doctor qualifications and specialty
      final doctorInfo = await controller.fetchDoctorInfo(user.id);
      final doctorDegree = (user.highestDegree ?? doctorInfo['degree'] ?? '')
          .trim();
      final doctorSpecialty = (doctorInfo['specialty'] ?? '').trim();

      // 1) Save official prescription document & generate branded PDF
      final prescription = await controller.create(
        chatId: widget.chatId,
        doctorId: user.id,
        doctorName: user.fullname,
        doctorQualification: doctorDegree,
        doctorSpecialty: doctorSpecialty,
        patientId: widget.patientId,
        patientName: widget.patientName,
        patientAge: patientAge,
        patientGender: patientGender,
        note: note,
        medicines: validMedicines,
        advice: advice,
        followUp: followUp,
      );

      // Preview text for chat card
      String previewText;
      if (validMedicines.isNotEmpty) {
        final firstMed = validMedicines.first;
        previewText =
            'Rx: ${firstMed.displayLine}${validMedicines.length > 1 ? ' (+${validMedicines.length - 1} more)' : ''}';
      } else {
        previewText = _buildNotePreview(note);
      }

      // 2) Post prescription message into chat with preview image and PDF URL
      await ChatController().sendMessage(
        senderId: user.id,
        receiverId: widget.patientId,
        message: 'Official Prescription — Tap to view',
        messageType: 'prescription',
        mediaUrl: prescription.previewImageUrl ?? prescription.pdfUrl,
        prescriptionId: prescription.prescriptionId,
        prescriptionNotePreview: previewText,
        pdfUrl: prescription.pdfUrl,
        previewImageUrl: prescription.previewImageUrl,
        prescriptionDate: prescription.createdAt,
        doctorName: user.fullname,
        receiverRole: 'patient',
      );

      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _sending = false);
        ToastService.instance.showError('Could not save prescription: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return OpdScreenShell(
      title: 'New Prescription',
      subtitle: 'Prescribing for ${widget.patientName}.',
      bottom: GradientButton(
        text: 'Save Prescription',
        icon: Icons.check_circle_rounded,
        isLoading: _sending,
        onPressed: _sending ? null : _saveAndSend,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OpdInfoPanel(
            icon: Icons.person_rounded,
            title: 'Patient Information',
            description: '${widget.patientName} • ID: ${widget.patientId}',
          ),
          const SizedBox(height: 20),

          // ── SECTION: STRUCTURED MEDICINES ──
          OpdSectionLabel(
            'Medicines (Rx)',
            trailing: TextButton.icon(
              onPressed: _addMedicineRow,
              icon: const Icon(Icons.add_circle_outline_rounded, size: 18),
              label: const Text('Add Medicine'),
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF062B72),
                textStyle: TextStyle(
                  fontSize: context.fs(12.5),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),

          for (var i = 0; i < _medicines.length; i++) ...[
            _buildMedicineCard(i, _medicines[i]),
            const SizedBox(height: 12),
          ],

          const SizedBox(height: 16),

          // ── SECTION: GENERAL PRESCRIPTION / WRITTEN NOTES ──
          const OpdSectionLabel('General Prescription / Written Notes'),
          const SizedBox(height: 6),
          _buildTextCard(
            controller: _noteController,
            focusNode: _noteFocus,
            hintText:
                'Doctor\'s written directions or general prescription instructions...',
            minLines: 4,
            maxLines: 7,
          ),
          const SizedBox(height: 16),

          // ── SECTION: ADDITIONAL ADVICE ──
          const OpdSectionLabel('Additional Medical Advice'),
          const SizedBox(height: 6),
          _buildTextCard(
            controller: _adviceController,
            hintText: 'e.g. Drink plenty of warm fluids, rest for 3 days...',
            minLines: 2,
            maxLines: 4,
          ),
          const SizedBox(height: 16),

          // ── SECTION: FOLLOW-UP ──
          const OpdSectionLabel('Follow-up Instructions'),
          const SizedBox(height: 6),
          _buildTextCard(
            controller: _followUpController,
            hintText: 'e.g. Review after 7 days, or SOS if symptoms persist',
            minLines: 1,
            maxLines: 2,
          ),
          const SizedBox(height: 20),

          const OpdInfoPanel(
            icon: Icons.verified_rounded,
            title: 'Official Document Generation',
            description:
                'Saving generates an official branded A4 prescription PDF and attaches it directly to the patient record.',
          ),
        ],
      ),
    );
  }

  /// Interactive card for adding a single medicine.
  Widget _buildMedicineCard(int index, _MedicineInputGroup med) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFD6E2EF), width: 1.2),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0F233C).withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header Row with Medicine Number and Delete
          Row(
            children: [
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: const Color(0xFF062B72),
                  borderRadius: BorderRadius.circular(8),
                ),
                alignment: Alignment.center,
                child: Text(
                  '${index + 1}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'Medicine #${index + 1}',
                style: TextStyle(
                  fontSize: context.fs(13),
                  fontWeight: FontWeight.w700,
                  color: const Color(0xFF1F2F44),
                ),
              ),
              const Spacer(),
              if (_medicines.length > 1)
                IconButton(
                  onPressed: () => _removeMedicineRow(index),
                  icon: const Icon(
                    Icons.delete_outline_rounded,
                    color: Colors.redAccent,
                    size: 20,
                  ),
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Remove Medicine',
                ),
            ],
          ),
          const SizedBox(height: 12),

          // Row 1: Name and Strength
          Row(
            children: [
              Expanded(
                flex: 3,
                child: _buildInputField(
                  controller: med.name,
                  label: 'Medicine Name *',
                  hint: 'e.g. Paracetamol / Augmentin',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: _buildInputField(
                  controller: med.strength,
                  label: 'Strength',
                  hint: 'e.g. 500mg, 10ml',
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // Row 2: Dosage, Frequency & Duration
          Row(
            children: [
              Expanded(
                child: _buildInputField(
                  controller: med.dosage,
                  label: 'Dosage',
                  hint: 'e.g. 1 Tab',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildInputField(
                  controller: med.frequency,
                  label: 'Frequency',
                  hint: 'e.g. 1-0-1',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildInputField(
                  controller: med.duration,
                  label: 'Duration',
                  hint: 'e.g. 5 Days',
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // Row 3: Instructions (Food instructions)
          _buildInputField(
            controller: med.instructions,
            label: 'Instructions / Food Directions',
            hint: 'e.g. After meal / Before breakfast / At bedtime',
          ),
        ],
      ),
    );
  }

  Widget _buildInputField({
    required TextEditingController controller,
    required String label,
    required String hint,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: context.fs(11),
            fontWeight: FontWeight.w600,
            color: const Color(0xFF5E7188),
          ),
        ),
        const SizedBox(height: 4),
        Container(
          decoration: BoxDecoration(
            color: const Color(0xFFF7FAFD),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFFD6E2EF)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: TextField(
            controller: controller,
            style: TextStyle(
              fontSize: context.fs(12.5),
              fontWeight: FontWeight.w500,
              color: const Color(0xFF1F2F44),
            ),
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              hintText: hint,
              hintStyle: TextStyle(
                fontSize: context.fs(11.5),
                color: const Color(0xFF96A5B8),
              ),
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTextCard({
    required TextEditingController controller,
    FocusNode? focusNode,
    required String hintText,
    int minLines = 3,
    int maxLines = 6,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFF7FAFD),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFBAC7D8)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        minLines: minLines,
        maxLines: maxLines,
        textCapitalization: TextCapitalization.sentences,
        style: TextStyle(
          fontSize: context.fs(13.5),
          height: 1.5,
          color: const Color(0xFF1E2F44),
        ),
        decoration: InputDecoration(
          border: InputBorder.none,
          isDense: true,
          hintText: hintText,
          hintStyle: TextStyle(
            fontSize: context.fs(12.5),
            color: const Color(0xFF7E90A6),
          ),
        ),
      ),
    );
  }

  static String _buildNotePreview(String note, {int maxLength = 110}) {
    final flat = note.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flat.isEmpty) return '';
    if (flat.length <= maxLength) return flat;
    return '${flat.substring(0, maxLength).trimRight()}...';
  }
}

class _PrescriptionCard extends StatelessWidget {
  final PrescriptionModel prescription;
  final VoidCallback onTap;

  const _PrescriptionCard({required this.prescription, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final hasMeds = prescription.hasMedicines;
    final note = prescription.note.trim();

    return OpdCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 54,
                decoration: BoxDecoration(
                  color: const Color(0xFF062B72).withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFFD6E2EF)),
                ),
                clipBehavior: Clip.antiAlias,
                child: prescription.primaryImageUrl.isNotEmpty
                    ? Image.network(
                        prescription.primaryImageUrl,
                        fit: BoxFit.cover,
                        alignment: Alignment.topCenter,
                        errorBuilder: (_, __, ___) => const Center(
                          child: Icon(
                            Icons.description_rounded,
                            size: 20,
                            color: Color(0xFF062B72),
                          ),
                        ),
                      )
                    : const Center(
                        child: Icon(
                          Icons.description_rounded,
                          size: 20,
                          color: Color(0xFF062B72),
                        ),
                      ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${prescription.doctorName}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: context.fs(14.5),
                        fontWeight: FontWeight.w700,
                        color: const Color(0xFF1F2F44),
                      ),
                    ),
                    if (prescription.doctorQualification.isNotEmpty)
                      Text(
                        prescription.doctorQualification,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: context.fs(11),
                          fontWeight: FontWeight.w600,
                          color: const Color(0xFF163B6E),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                DateFormat('dd MMM yyyy').format(prescription.createdAt),
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF7E90A6),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
