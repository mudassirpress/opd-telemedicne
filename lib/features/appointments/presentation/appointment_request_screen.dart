import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/features/auth/presentation/providers/user_provider.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/data/models/appointment_model.dart';
import 'package:telemedicine/features/appointments/presentation/appointment_controller.dart';
import 'package:telemedicine/features/patients/presentation/patient_portal_tab_provider.dart';
import 'package:telemedicine/shared/widgets/auth_layout.dart';
import 'package:telemedicine/shared/widgets/opd_design_system.dart';

/// Step three: the patient describes what they want to discuss. Only reachable
/// once the payment for this doctor has been approved.
class AppointmentRequestScreen extends ConsumerStatefulWidget {
  const AppointmentRequestScreen({
    super.key,
    required this.doctorId,
    required this.payment,
  });

  final String doctorId;
  final AppointmentPaymentModel payment;

  @override
  ConsumerState<AppointmentRequestScreen> createState() =>
      _AppointmentRequestScreenState();
}

class _AppointmentRequestScreenState
    extends ConsumerState<AppointmentRequestScreen> {
  final TextEditingController _subject = TextEditingController();
  final TextEditingController _message = TextEditingController();
  bool _submitting = false;
  String _error = '';

  @override
  void dispose() {
    _subject.dispose();
    _message.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final user = ref.read(userProvider);
    if (user == null) {
      ToastService.instance.showError('Session expired. Please login again.');
      return;
    }

    // The approved payment already carries every doctor field the appointment
    // record needs, so no extra Firestore read is required here.
    final doctor = <String, dynamic>{
      'id': widget.payment.doctorId,
      'fullname': widget.payment.doctorName,
      'imageUrl': widget.payment.doctorImage,
      'specialization': widget.payment.doctorSpecialization,
    };

    if (_subject.text.trim().isEmpty) {
      setState(() => _error = 'Please add a subject.');
      return;
    }
    if (_message.text.trim().isEmpty) {
      setState(() => _error = 'Please describe your concern.');
      return;
    }

    setState(() {
      _submitting = true;
      _error = '';
    });

    // try/finally: any throw from the controller (offline, permission) must
    // still re-enable the button — `_submitting` gates GradientButton's
    // onPressed, so a missing finally left the patient stuck on "Sending…"
    // forever with no way out.
    String? error;
    try {
      error = await ref
          .read(appointmentControllerProvider)
          .sendAppointmentRequest(
            patient: user,
            doctor: doctor,
            payment: widget.payment,
            subject: _subject.text,
            message: _message.text,
          );
    } catch (e) {
      error = 'Could not send the appointment request. Please try again.';
    }

    if (!mounted) return;
    setState(() => _submitting = false);

    if (error != null) {
      final message = error;
      setState(() => _error = message);
      ToastService.instance.showError(message);
      return;
    }

    ToastService.instance.showSuccess('Appointment request sent');
    // Land the patient back on the Appointments tab where the request now
    // appears, instead of leaving them inside the booking stack.
    ref.read(patientPortalTabProvider.notifier).state =
        PatientPortalTab.appointments;
    Navigator.popUntil(context, (route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final doctorName =
        widget.payment.doctorName.isEmpty ? 'your doctor' : widget.payment.doctorName;

    return OpdScreenShell(
      title: 'Appointment Request',
      subtitle: 'Tell Dr. $doctorName what you would like to discuss.',
      bottom: GradientButton(
        text: _submitting ? 'Sending...' : 'Send Appointment Request',
        icon: Icons.send_rounded,
        isLoading: _submitting,
        onPressed: _submitting ? null : _submit,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OpdCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Column(
              children: [
                OpdDetailRow(
                  icon: Icons.medical_services_rounded,
                  label: 'Doctor',
                  value: 'Dr. $doctorName',
                ),
                OpdDetailRow(
                  icon: Icons.payments_rounded,
                  label: 'Payment',
                  value:
                      '${AppointmentDefaults.currency} ${widget.payment.payableAmount.toStringAsFixed(0)} • Approved',
                ),
              ],
            ),
          ),

          const SizedBox(height: 18),
          const OpdSectionLabel('Subject'),
          MetallicInput(
            hintText: 'e.g. Persistent fever for 4 days',
            icon: Icons.subject_rounded,
            controller: _subject,
            maxLength: 80,
          ),

          const SizedBox(height: 16),
          const OpdSectionLabel('Describe your concern'),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [
                  Color(0xFFD4DCE6),
                  Color(0xFFE8EEF5),
                  Color(0xFFC2CDDC),
                ],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0xFFBAC6D5)),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF0F1E32).withValues(alpha: 0.10),
                  blurRadius: 12,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
              ),
              child: TextField(
                controller: _message,
                maxLines: 7,
                minLines: 5,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  border: InputBorder.none,
                  hintText:
                      'Mention symptoms, duration and anything the doctor '
                      'should know before the appointment.',
                  hintStyle: TextStyle(
                    fontSize: 13,
                    color: const Color(0xFF9AACBF),
                  ),
                ),
                style: TextStyle(
                  fontSize: context.fs(13),
                  color: const Color(0xFF1F2F44),
                  height: 1.45,
                ),
              ),
            ),
          ),

          if (_error.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(
              _error,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                color: const Color(0xFFD64545),
              ),
            ),
          ],

          const SizedBox(height: 16),
          const OpdInfoPanel(
            icon: Icons.event_available_rounded,
            title: 'What happens next',
            description:
                'The doctor replies with a date and time, and a pinned '
                'message appears in your chat.',
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
