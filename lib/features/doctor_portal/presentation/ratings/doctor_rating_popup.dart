import 'package:flutter/material.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/features/doctor_portal/presentation/ratings/doctor_rating_controller.dart';
import 'package:telemedicine/shared/widgets/opd_design_system.dart';

/// Result of the rating popup.
class RatingPopupResult {
  final int rating;

  const RatingPopupResult.success(this.rating) : failure = null;
  const RatingPopupResult.failed(this.failure) : rating = 0;

  final RatingFailure? failure;

  bool get isSuccess => failure == null;
}

/// Opens the small, centered "Rate Doctor" popup.
///
/// This is a modal dialog on top of the chat — it never navigates to another
/// page and never rebuilds or reloads the conversation. Only the popup's own
/// state changes while the user picks stars.
///
/// The **Submit Rating** button stays disabled until a rating is selected, and
/// shows a small button-level spinner while saving.
Future<RatingPopupResult?> showDoctorRatingPopup({
  required BuildContext context,
  required String doctorName,
}) {
  return showDialog<RatingPopupResult>(
    context: context,
    barrierColor: const Color(0xFF0B2041).withValues(alpha: 0.45),
    builder: (_) => _DoctorRatingDialog(doctorName: doctorName),
  );
}

class _DoctorRatingDialog extends StatefulWidget {
  final String doctorName;

  const _DoctorRatingDialog({required this.doctorName});

  @override
  State<_DoctorRatingDialog> createState() => _DoctorRatingDialogState();
}

class _DoctorRatingDialogState extends State<_DoctorRatingDialog> {
  int _selected = 0;
  bool _saving = false;

  Future<void> _submit() async {
    if (_selected == 0 || _saving) return;
    setState(() => _saving = true);

    // The actual Firestore write is owned by the caller (the chat card), which
    // has the prescription context. Here we just hand the choice back.
    Navigator.of(context).pop(RatingPopupResult.success(_selected));
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: EdgeInsets.symmetric(horizontal: context.rsp(20)),
      child: SingleChildScrollView(
        child: Container(
          padding: EdgeInsets.fromLTRB(
            context.rsp(20),
            22,
            context.rsp(20),
            18,
          ),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(22),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF12263F).withValues(alpha: 0.22),
                blurRadius: 30,
                offset: const Offset(0, 14),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: const BoxDecoration(
                  color: Color(0xFFF0F4FA),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.star_rounded,
                  color: Color(0xFFE9A400),
                  size: 28,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                'Rate Doctor',
                style: TextStyle(
                  fontSize: context.fs(16),
                  fontWeight: FontWeight.bold,
                  color: const Color(0xFF1F2F44),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                widget.doctorName.isEmpty
                    ? 'Your doctor'
                    : 'Dr. ${widget.doctorName}',
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: context.fs(13.5),
                  fontWeight: FontWeight.w500,
                  color: const Color(0xFF657991),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                'How was your experience?',
                style: TextStyle(
                  fontSize: context.fs(13.5),
                  fontWeight: FontWeight.w500,
                  color: const Color(0xFF1F2F44),
                ),
              ),
              const SizedBox(height: 12),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var star = 1; star <= 5; star++)
                      GestureDetector(
                        onTap: () => setState(() => _selected = star),
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: context.rsp(3),
                          ),
                          child: Icon(
                            star <= _selected
                                ? Icons.star_rounded
                                : Icons.star_border_rounded,
                            size: 38,
                            color: star <= _selected
                                ? const Color(0xFFE9A400)
                                : const Color(0xFFBAC6D5),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Text(
                _selected == 0 ? 'Tap a star to rate' : '$_selected of 5',
                style: TextStyle(fontSize: 12, color: const Color(0xFF7E90A6)),
              ),
              const SizedBox(height: 18),
              _SubmitButton(
                enabled: _selected > 0 && !_saving,
                saving: _saving,
                onTap: _submit,
              ),
              const SizedBox(height: 6),
              TextButton(
                onPressed: _saving ? null : () => Navigator.of(context).pop(),
                child: Text(
                  'Cancel',
                  style: TextStyle(
                    fontSize: context.fs(13),
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF6B7B8D),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Submit button with a small button-level loading state (never a full-screen
/// indicator).
class _SubmitButton extends StatelessWidget {
  final bool enabled;
  final bool saving;
  final VoidCallback onTap;

  const _SubmitButton({
    required this.enabled,
    required this.saving,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return OpdCard(
      onTap: enabled ? onTap : null,
      padding: const EdgeInsets.symmetric(vertical: 14),
      radius: 16,
      child: Center(
        child: saving
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2.2,
                  color: Color(0xFF062B72),
                ),
              )
            : Text(
                'Submit Rating',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: context.fs(14),
                  fontWeight: FontWeight.w600,
                  color: enabled
                      ? const Color(0xFF062B72)
                      : const Color(0xFFBAC6D5),
                ),
              ),
      ),
    );
  }
}
