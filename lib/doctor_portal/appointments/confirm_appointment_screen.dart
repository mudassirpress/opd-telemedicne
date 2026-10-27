import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/auth/auth_provider/user_provider.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/data/models/appointment_model.dart';
import 'package:telemedicine/features/appointment/appointment_controller.dart';
import 'package:telemedicine/features/appointment/appointment_ui.dart';
import 'package:telemedicine/shared/widgets/auth_layout.dart';
import 'package:telemedicine/shared/widgets/opd_design.dart';

/// Where the doctor picks the slot for a requested appointment.
///
/// The same screen doubles as a read-only summary once the appointment is
/// confirmed or completed, so both halves of the queue open one route.
class ConfirmAppointmentScreen extends ConsumerStatefulWidget {
  const ConfirmAppointmentScreen({super.key, required this.appointment});

  final AppointmentModel appointment;

  @override
  ConsumerState<ConfirmAppointmentScreen> createState() =>
      _ConfirmAppointmentScreenState();
}

class _ConfirmAppointmentScreenState
    extends ConsumerState<ConfirmAppointmentScreen> {
  DateTime? _date;
  TimeOfDay? _start;
  TimeOfDay? _end;
  final TextEditingController _note = TextEditingController();
  bool _saving = false;
  String _error = '';

  AppointmentModel get appointment => widget.appointment;

  bool get _readOnly =>
      !appointment.isRequested || appointment.hasSchedule;

  @override
  void initState() {
    super.initState();
    if (appointment.hasSchedule) {
      _date = appointmentDateOnly(appointment.scheduledDate);
      _start = _parseLabel(appointment.scheduledStartTime);
      _end = _parseLabel(appointment.scheduledEndTime);
      _note.text = appointment.doctorResponse;
    }
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  TimeOfDay? _parseLabel(String label) {
    final match =
        RegExp(r'^(\d{1,2}):(\d{2})\s*(AM|PM)?$').firstMatch(label.trim().toUpperCase());
    if (match == null) return null;
    var hour = int.tryParse(match.group(1) ?? '');
    final minute = int.tryParse(match.group(2) ?? '');
    final meridiem = match.group(3);
    if (hour == null || minute == null) return null;
    if (meridiem == 'PM' && hour < 12) hour += 12;
    if (meridiem == 'AM' && hour == 12) hour = 0;
    if (hour > 23 || minute > 59) return null;
    return TimeOfDay(hour: hour, minute: minute);
  }

  String _label(TimeOfDay t) {
    final meridiem = t.hour >= 12 ? 'PM' : 'AM';
    var hour = t.hour % 12;
    if (hour == 0) hour = 12;
    return '$hour:${t.minute.toString().padLeft(2, '0')} $meridiem';
  }

  String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date ?? DateTime.now(),
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (!mounted) return;
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _pickTime({required bool isEnd}) async {
    final initial = isEnd
        ? (_end ?? const TimeOfDay(hour: 17, minute: 0))
        : (_start ?? const TimeOfDay(hour: 10, minute: 0));
    final picked = await showTimePicker(context: context, initialTime: initial);
    if (!mounted) return;
    if (picked == null) return;
    setState(() {
      if (isEnd) {
        _end = picked;
      } else {
        _start = picked;
        // Keep the pair sensible on first pick.
        if (_end == null) {
          _end = TimeOfDay(
            hour: (picked.hour + 1) % 24,
            minute: picked.minute,
          );
        }
      }
    });
  }

  int _minutes(TimeOfDay t) => t.hour * 60 + t.minute;

  Future<void> _confirm() async {
    final user = ref.read(userProvider);
    if (user == null) {
      ToastService.instance.showError('Session expired. Please login again.');
      return;
    }
    if (_date == null || _start == null || _end == null) {
      setState(() => _error = 'Please pick a date, start time and end time.');
      return;
    }
    if (_minutes(_end!) <= _minutes(_start!)) {
      setState(() => _error = 'The end time must be after the start time.');
      return;
    }

    setState(() {
      _saving = true;
      _error = '';
    });

    final error = await ref.read(appointmentControllerProvider).confirmAppointment(
          appointment: appointment,
          actingDoctorId: user.id,
          scheduledDate: _iso(_date!),
          scheduledStartTime: _label(_start!),
          scheduledEndTime: _label(_end!),
          doctorResponse: _note.text,
        );

    if (!mounted) return;
    setState(() => _saving = false);

    if (error != null) {
      setState(() => _error = error);
      ToastService.instance.showError(error);
      return;
    }

    ToastService.instance.showSuccess('Appointment scheduled');
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final pricing = AppointmentPricing(
      consultationFee: appointment.consultationFee,
      discountPercent: appointment.discountPercentage,
      videoWatched: appointment.videoWatched,
    );

    return OpdScreenShell(
      title: _readOnly ? 'Appointment' : 'Schedule Appointment',
      subtitle: _readOnly
          ? appointmentStatusLabel(appointment.appointmentStatus)
          : 'Pick the date and time for ${appointment.patientName}.',
      bottom: _readOnly
          ? null
          : GradientButton(
              text: _saving ? 'Saving...' : 'Confirm Appointment',
              icon: Icons.event_available_rounded,
              isLoading: _saving,
              onPressed: _saving ? null : _confirm,
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _identityCard(),
          const SizedBox(height: 18),
          const OpdSectionLabel('Patient request'),
          OpdCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  appointment.subject.isEmpty
                      ? 'Appointment request'
                      : appointment.subject,
                  style: TextStyle(
                    fontSize: context.fs(14),
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF1F2F44),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  appointment.message,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w400,
                    color: const Color(0xFF657991),
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 18),
          const OpdSectionLabel('Consultation fee'),
          OpdCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Column(
              children: [
                OpdDetailRow(
                  icon: Icons.payments_rounded,
                  label: 'Fee',
                  value: pricing.feeLabel,
                ),
                OpdDetailRow(
                  icon: Icons.ondemand_video_rounded,
                  label: pricing.discountTitle,
                  value: pricing.discountLabel,
                ),
                const Divider(height: 1, color: Color(0xFFDCE6F2)),
                OpdDetailRow(
                  icon: Icons.account_balance_wallet_rounded,
                  label: 'Collected',
                  value: pricing.payableLabel,
                ),
              ],
            ),
          ),

          const SizedBox(height: 18),
          OpdSectionLabel(
            _readOnly ? 'Schedule' : 'Choose date and time',
            trailing: appointment.hasSchedule
                ? AppointmentStatusPill(status: appointment.appointmentStatus)
                : null,
          ),
          OpdCard(
            padding: const EdgeInsets.all(16),
            child: _readOnly ? _buildReadOnlySchedule() : _buildPickers(),
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
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _identityCard() {
    final image = appointment.patientImage;
    final name =
        appointment.patientName.isEmpty ? 'Patient' : appointment.patientName;

    return OpdCard(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          CircleAvatar(
            radius: 26,
            backgroundColor: const Color(0xFFF0F4FA),
            backgroundImage:
                image.isNotEmpty ? CachedNetworkImageProvider(image) : null,
            child: image.isEmpty
                ? Text(
                    name[0].toUpperCase(),
                    style: TextStyle(
                      fontSize: context.fs(16),
                      fontWeight: FontWeight.bold,
                      color: const Color(0xFF062B72),
                    ),
                  )
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
                  style: TextStyle(
                    fontSize: context.fs(14),
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF1F2F44),
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    AppointmentStatusPill(
                      status: appointment.appointmentStatus,
                      fontSize: 10.5,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        'Requested ${appointment.requestedAt != null ? _formatDate(appointment.requestedAt!) : ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: const Color(0xFF7E90A6),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPickers() {
    return Column(
      children: [
        _pickerRow(
          icon: Icons.calendar_month_rounded,
          label: 'Date',
          value: _date == null
              ? 'Not selected'
              : appointmentFormatDisplayDate(_iso(_date!)),
          onTap: _pickDate,
        ),
        const Divider(height: 1, color: Color(0xFFDCE6F2)),
        _pickerRow(
          icon: Icons.schedule_rounded,
          label: 'Start time',
          value: _start == null ? 'Not selected' : _label(_start!),
          onTap: () => _pickTime(isEnd: false),
        ),
        const Divider(height: 1, color: Color(0xFFDCE6F2)),
        _pickerRow(
          icon: Icons.timelapse_rounded,
          label: 'End time',
          value: _end == null ? 'Not selected' : _label(_end!),
          onTap: () => _pickTime(isEnd: true),
        ),
        const SizedBox(height: 16),
        const OpdSectionLabel('Note to patient (optional)'),
        MetallicInput(
          hintText: 'e.g. Please join 5 minutes early',
          icon: Icons.sticky_note_2_rounded,
          controller: _note,
          maxLength: 140,
        ),
      ],
    );
  }

  Widget _buildReadOnlySchedule() {
    if (!appointment.hasSchedule) {
      return const OpdInfoPanel(
        icon: Icons.schedule_rounded,
        title: 'No schedule yet',
        description: 'This appointment has not been given a date and time.',
        accent: Color(0xFF7E90A6),
      );
    }

    return Column(
      children: [
        OpdDetailRow(
          icon: Icons.calendar_month_rounded,
          label: 'Date',
          value: appointmentFormatDisplayDate(appointment.scheduledDate),
        ),
        OpdDetailRow(
          icon: Icons.schedule_rounded,
          label: 'Time',
          value:
              '${appointment.scheduledStartTime} - ${appointment.scheduledEndTime}',
        ),
        if (appointment.doctorResponse.isNotEmpty)
          OpdDetailRow(
            icon: Icons.sticky_note_2_rounded,
            label: 'Note',
            value: appointment.doctorResponse,
          ),
        if (appointment.isCompleted)
          OpdDetailRow(
            icon: Icons.check_circle_rounded,
            label: 'Status',
            value: 'Completed — the chat history is kept',
          ),
        if (appointment.isExpired)
          OpdDetailRow(
            icon: Icons.event_busy_rounded,
            label: 'Status',
            value: 'Expired — this slot has been released',
          ),
      ],
    );
  }

  Widget _pickerRow({
    required IconData icon,
    required String label,
    required String value,
    required VoidCallback onTap,
  }) {
    final unselected = value == 'Not selected';
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: const Color(0xFFF0F4FA),
                borderRadius: BorderRadius.circular(13),
                border: Border.all(color: const Color(0xFFDCE6F2)),
              ),
              child: Icon(icon, size: 20, color: const Color(0xFF0E274D)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                      color: const Color(0xFF7E90A6),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: context.fs(13),
                      fontWeight: FontWeight.w600,
                      color: unselected
                          ? const Color(0xFF7E90A6)
                          : const Color(0xFF1F2F44),
                    ),
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.edit_calendar_rounded,
              size: 18,
              color: Color(0xFF062B72),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime date) =>
      '${date.day}/${date.month}/${date.year}';
}
