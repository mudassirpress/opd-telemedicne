import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/features/auth/presentation/providers/user_provider.dart';
import 'package:telemedicine/features/auth/presentation/screens/complete_patient_profile_screen.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/shared/widgets/auth_layout.dart';

class PatientIdVerificationScreen extends ConsumerStatefulWidget {
  const PatientIdVerificationScreen({super.key});

  @override
  ConsumerState<PatientIdVerificationScreen> createState() =>
      _PatientIdVerificationScreenState();
}

class _PatientIdVerificationScreenState
    extends ConsumerState<PatientIdVerificationScreen> {
  final TextEditingController _patientIdController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _isLoading = false;

  @override
  void dispose() {
    _patientIdController.dispose();
    super.dispose();
  }

  Future<void> _verifyPatientId() async {
    if (!_formKey.currentState!.validate()) return;

    final patientId = _patientIdController.text.trim();

    if (patientId.length != 12) {
      ToastService.instance.showError('Patient ID must be exactly 12 digits');
      return;
    }

    setState(() => _isLoading = true);

    final controller = ref.read(patientIdControllerProvider);
    final result = await controller.verifyPatientId(patientId);

    if (!mounted) return;

    if (result != null) {
      setState(() {
        _isLoading = false;
      });
      ToastService.instance.showSuccess('Patient ID verified!');

      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => CompletePatientProfileScreen(
              patientIdModel: result,
              isPhoneAuth: false,
            ),
          ),
        );
      }
    } else {
      setState(() => _isLoading = false);
      ToastService.instance.showError(
        controller.errorMessage.isNotEmpty
            ? controller.errorMessage
            : 'Invalid Patient ID',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthScreenLayout(
      title: 'Enter Patient ID',
      subtitle:
          'Enter your 12-digit Patient ID to verify and complete your profile.',
      child: Form(
        key: _formKey,
        child: Column(
          children: [
            MetallicInput(
              hintText: '12-Digit Patient ID',
              icon: Icons.badge_rounded,
              keyboardType: TextInputType.number,
              controller: _patientIdController,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(12),
              ],
              maxLength: 12,
            ),
            SizedBox(height: context.rsp(20)),

            // Verify Button
            GradientButton(
              text: 'Verify Patient ID',
              isLoading: _isLoading,
              onPressed: _verifyPatientId,
              icon: Icons.arrow_forward_rounded,
            ),
          ],
        ),
      ),
    );
  }
}
