import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:telemedicine/auth/auth_provider/user_provider.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/data/models/prescription_model.dart';
import 'package:telemedicine/doctor_portal/prescriptions/prescription_controller.dart';
import 'package:telemedicine/doctor_portal/prescriptions/prescription_detail_screen.dart';
import 'package:telemedicine/home_widget/chat_call/chat/chat_controller/chat_controller.dart';
import 'package:telemedicine/shared/widgets/auth_layout.dart';
import 'package:telemedicine/shared/widgets/opd_design.dart';

/// Doctor-side prescriptions for the current chat / patient.
///
/// A prescription is a document plus a `prescription` chat message that links
/// back to it, so both live in one place: the list here, and the card in the
/// chat itself.
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
    setState(() {
      _stream = ref
          .read(prescriptionControllerProvider)
          .streamForChat(widget.chatId);
    });
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
      ToastService.instance.showSuccess('Prescription sent');
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
      subtitle: 'Medication prescribed to ${widget.patientName}.',
      bottom: GradientButton(
        text: 'New Prescription',
        icon: Icons.add_rounded,
        onPressed: _openForm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildList(),
        ],
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
                'Tap "New Prescription" below to write one and send it to the patient.',
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

  /// Friendly, non-fatal error panel with a retry that re-issues the query.
  Widget _buildErrorState(Object error) {
    final (icon, title, message) = _describeError(error);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OpdEmptyState(icon: icon, title: title, subtitle: message),
        const SizedBox(height: 20),
        GradientButton(
          text: 'Retry',
          icon: Icons.refresh_rounded,
          onPressed: _subscribe,
        ),
      ],
    );
  }

  /// Turns a Firestore failure into something the doctor can act on.
  ///
  /// The "index is still building" state is ONLY shown for a genuine missing
  /// composite index - it is never used as a catch-all, so a real problem
  /// (permissions, network) is reported honestly instead of being mislabelled.
  ///
  /// [PrescriptionController.streamForChat] no longer needs a composite index,
  /// so in practice this branch should not appear at all. It is kept so that a
  /// project still holding an ordered query reports the truth.
  (IconData, String, String) _describeError(Object error) {
    final text = error.toString();

    final missingIndex = text.contains('FAILED_PRECONDITION') &&
        (text.contains('missing-indexes') || text.contains('no index'));
    if (missingIndex) {
      return (
        Icons.hourglass_empty_rounded,
        'Preparing prescriptions',
        'A Firestore index for this query is still being built. '
            'This usually finishes within a few minutes - try again shortly.'
      );
    }
    if (text.contains('PERMISSION_DENIED') ||
        text.contains('permission-denied')) {
      return (
        Icons.lock_outline_rounded,
        'Access restricted',
        'You do not have permission to view prescriptions for this patient.'
      );
    }
    if (text.contains('UNAVAILABLE') || text.contains('unavailable')) {
      return (
        Icons.wifi_off_rounded,
        'Connection problem',
        'Could not reach Firestore. Check your connection and try again.'
      );
    }
    return (
      Icons.error_outline_rounded,
      'Could not load prescriptions',
      'Something went wrong while loading. Tap Retry to try again.'
    );
  }
}

/// Composes a prescription: a single multiline note, then **Save & Send**.
///
/// Save & Send (in order):
///   1. stores the prescription document,
///   2. posts a `prescription` message into the existing doctor↔patient chat,
///      which lands in Hive first and then Firestore, so the chat updates
///      live without any reload,
///   3. triggers the FCM notification (tapping it opens that same chat).
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
  final TextEditingController _noteController = TextEditingController();
  final FocusNode _noteFocus = FocusNode();
  bool _sending = false;

  @override
  void dispose() {
    _noteController.dispose();
    _noteFocus.dispose();
    super.dispose();
  }

  Future<void> _saveAndSend() async {
    final note = _noteController.text.trim();
    if (note.isEmpty) {
      ToastService.instance.showWarning('Please write the prescription note');
      _noteFocus.requestFocus();
      return;
    }

    final user = ref.read(userProvider);
    if (user == null) return;

    setState(() => _sending = true);
    try {
      final controller = ref.read(prescriptionControllerProvider);

      // Snapshot the patient's age onto the prescription.
      final patientAge = await controller.fetchPatientAge(widget.patientId);

      // 1) Save the prescription document.
      final prescription = await controller.create(
        chatId: widget.chatId,
        doctorId: user.id,
        doctorName: user.fullname,
        patientId: widget.patientId,
        patientName: widget.patientName,
        patientAge: patientAge,
        note: note,
      );

      // 2) Post the linked message into the existing chat. `sendMessage`
      //    writes to Hive first (instant local state) and then Firestore, and
      //    sends the FCM push — the chat listener picks it up live, so the
      //    conversation is never refetched.
      await ChatController().sendMessage(
        senderId: user.id,
        receiverId: widget.patientId,
        message: 'Prescription available — Tap to view',
        messageType: 'prescription',
        prescriptionId: prescription.prescriptionId,
        // Stored on the message so the card renders the preview instantly and
        // keeps working from the local Hive cache when offline.
        prescriptionNotePreview: _buildNotePreview(note),
        receiverRole: 'patient',
      );

      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _sending = false);
        ToastService.instance.showError('Could not send prescription');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return OpdScreenShell(
      title: 'New Prescription',
      subtitle: 'Write the prescription for ${widget.patientName}.',
      bottom: GradientButton(
        text: 'Save & Send',
        icon: Icons.send_rounded,
        isLoading: _sending,
        onPressed: _sending ? null : _saveAndSend,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OpdInfoPanel(
            icon: Icons.person_rounded,
            title: 'Patient',
            description: '${widget.patientName} • ID ${widget.patientId}',
          ),
          const SizedBox(height: 22),
          const OpdSectionLabel('Note'),
          _buildNoteField(),
          const SizedBox(height: 18),
          const OpdInfoPanel(
            icon: Icons.info_outline_rounded,
            title: 'Sent instantly',
            description:
                'Saving posts the prescription to this chat and notifies the patient. '
                'They can open the full prescription by tapping the card.',
          ),
        ],
      ),
    );
  }

  /// Collapses a multiline note into a short single-line preview for the card.
  static String _buildNotePreview(String note, {int maxLength = 110}) {
    final flat = note.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flat.isEmpty) return '';
    if (flat.length <= maxLength) return flat;
    return '${flat.substring(0, maxLength).trimRight()}...';
  }

  /// Multiline note field using the same metallic treatment as the Sign In
  /// inputs, just taller to allow a full prescription.
  Widget _buildNoteField() {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFE3EAF2), Color(0xFFF5F8FC), Color(0xFFE2E9F2)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFFBAC7D8), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0F233C).withValues(alpha: 0.08),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Container(
        padding: EdgeInsets.fromLTRB(context.rsp(16), 6, context.rsp(16), 12),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFFF3F7FB), Colors.white, Color(0xFFF0F4F9)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
          borderRadius: BorderRadius.circular(21),
        ),
        child: TextField(
          controller: _noteController,
          focusNode: _noteFocus,
          maxLines: 10,
          minLines: 8,
          textCapitalization: TextCapitalization.sentences,
          style: TextStyle(
            fontSize: context.fs(14),
            fontWeight: FontWeight.w500,
            height: 1.6,
            color: const Color(0xFF1E2F44),
          ),
          decoration: InputDecoration(
            border: InputBorder.none,
            isDense: true,
            contentPadding: const EdgeInsets.only(top: 12),
            hintText:
                'Take medicine after breakfast...\nFollow-up after 7 days...',
            hintStyle: TextStyle(
              fontSize: context.fs(13.5),
              height: 1.6,
              color: const Color(0xFF7E90A6),
            ),
          ),
        ),
      ),
    );
  }
}

class _PrescriptionCard extends StatelessWidget {
  final PrescriptionModel prescription;
  final VoidCallback onTap;

  const _PrescriptionCard({required this.prescription, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final note = prescription.note.trim();
    return OpdCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: const Color(0xFF062B72).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: const Icon(
                  Icons.medical_information_rounded,
                  size: 20,
                  color: Color(0xFF062B72),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Dr. ${prescription.doctorName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: context.fs(14.5),
                    fontWeight: FontWeight.w700,
                    color: const Color(0xFF1F2F44),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  DateFormat('dd MMM yyyy').format(prescription.createdAt),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: const Color(0xFF7E90A6),
                  ),
                ),
              ),
            ],
          ),
          if (note.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              note,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: context.fs(13.5),
                height: 1.5,
                color: const Color(0xFF657991),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Flexible(
                child: Text(
                  prescription.reference,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF163B6E),
                  ),
                ),
              ),
              const Spacer(),
              const Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: Color(0xFFBAC6D5),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
