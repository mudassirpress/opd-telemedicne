import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/data/models/patient_id_model.dart';
import 'package:telemedicine/data/models/user_model.dart';
import 'package:telemedicine/features/auth/presentation/providers/user_provider.dart';
import 'package:telemedicine/features/auth/presentation/screens/sign_in_screen.dart';
import 'package:telemedicine/core/services/auth_routing_service.dart';
import 'package:telemedicine/features/patients/presentation/patient_portal_wrapper.dart';
import 'package:telemedicine/app/theme/app_theme.dart';
import 'package:telemedicine/core/utils/phone_utils.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/errors/auth_error_handler.dart';
import 'package:telemedicine/core/services/app_feedback.dart';
import 'package:telemedicine/shared/widgets/auth_layout.dart';
import 'package:telemedicine/shared/widgets/international_phone_input.dart';

class CompletePatientProfileScreen extends ConsumerStatefulWidget {
  final PatientIdModel? patientIdModel;
  final String? prefilledPhone;
  final String? verifiedPhone;
  final String? patientUid;
  final bool? isPhoneAuth;

  const CompletePatientProfileScreen({
    super.key,
    this.patientIdModel,
    this.prefilledPhone,
    this.verifiedPhone,
    this.patientUid,
    this.isPhoneAuth,
  });

  @override
  ConsumerState<CompletePatientProfileScreen> createState() =>
      _CompletePatientProfileScreenState();
}

class _CompletePatientProfileScreenState
    extends ConsumerState<CompletePatientProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _mobileController = TextEditingController();

  String _selectedGender = '';
  final _ageController = TextEditingController();
  bool _isLoading = false;

  InternationalPhoneValue? _phoneValue;
  String _selectedDialCode = '+92';
  String _selectedIsoCode = 'PK';

  /// Detects whether the patient authenticated via Phone Auth.
  bool get _isPhoneAuth {
    if (widget.isPhoneAuth != null) {
      return widget.isPhoneAuth!;
    }
    // Patient ID card flows are non-phone credentials at profile completion time
    if (widget.patientIdModel != null) {
      return false;
    }
    // Check active Firebase Auth user
    final authUser = FirebaseAuth.instance.currentUser;
    if (authUser != null) {
      if (authUser.phoneNumber != null && authUser.phoneNumber!.isNotEmpty) {
        return true;
      }
      if (authUser.providerData.any((p) => p.providerId == 'phone')) {
        return true;
      }
    }
    // Check controller user loginType
    final currentPatient = ref.read(patientControllerProvider).currentUser;
    if (currentPatient != null && currentPatient.loginType == 'phone') {
      return true;
    }
    if (widget.verifiedPhone != null && widget.verifiedPhone!.isNotEmpty) {
      return true;
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    _initSessionAndPhone();
  }

  void _initSessionAndPhone() {
    // 1. Resolve phone number
    final initialPhone =
        widget.verifiedPhone ??
        widget.prefilledPhone ??
        FirebaseAuth.instance.currentUser?.phoneNumber ??
        ref.read(patientControllerProvider).currentUser?.phoneNumber;

    if (initialPhone != null && initialPhone.trim().isNotEmpty) {
      _mobileController.text = initialPhone.trim();
    }

    // 2. Resolve active UID and debug log session state
    final resolvedUid = _resolveActiveUid();
    debugPrint('🔍 [CompleteProfile.initState] Session Status:');
    debugPrint('   - widget.patientUid: ${widget.patientUid}');
    debugPrint(
      '   - FirebaseAuth.currentUser: ${FirebaseAuth.instance.currentUser?.uid}',
    );
    debugPrint(
      '   - Controller currentUser: ${ref.read(patientControllerProvider).currentUser?.id}',
    );
    debugPrint('   - Resolved UID: $resolvedUid');
    debugPrint('   - isPhoneAuth: $_isPhoneAuth');
    debugPrint('   - Initial Phone: $initialPhone');

    // 3. Hydrate patientController if it lacks currentUser
    if (ref.read(patientControllerProvider).currentUser == null &&
        resolvedUid != null &&
        resolvedUid.isNotEmpty) {
      _hydrateSession(resolvedUid);
    }
  }

  /// Resolves the active patient session ID/UID reliably across all available states
  String? _resolveActiveUid() {
    if (widget.patientUid != null && widget.patientUid!.trim().isNotEmpty) {
      return widget.patientUid!.trim();
    }
    final controllerUser = ref.read(patientControllerProvider).currentUser;
    if (controllerUser != null && controllerUser.id.isNotEmpty) {
      return controllerUser.id;
    }
    final authUser = FirebaseAuth.instance.currentUser;
    if (authUser != null && authUser.uid.isNotEmpty) {
      return authUser.uid;
    }
    if (widget.patientIdModel?.patientUserId != null &&
        widget.patientIdModel!.patientUserId!.isNotEmpty) {
      return widget.patientIdModel!.patientUserId!;
    }
    return null;
  }

  Future<void> _hydrateSession(String uid) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('telemedicine_patient')
          .doc(uid)
          .get();
      if (doc.exists && mounted) {
        final user = UserModel.fromMap({...doc.data()!, 'id': doc.id});
        ref.read(patientControllerProvider).setCurrentUser(user);
        debugPrint(
          '✅ [CompleteProfile] Hydrated patient session for UID: $uid',
        );
      }
    } catch (e) {
      debugPrint('⚠️ [CompleteProfile] Hydrate session notice: $e');
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _mobileController.dispose();
    _ageController.dispose();
    super.dispose();
  }

  Future<void> _submitProfile() async {
    if (!_formKey.currentState!.validate()) return;

    if (_nameController.text.trim().isEmpty) {
      AppFeedback.showError(context, 'Please enter your full name');
      return;
    }

    if (_selectedGender.isEmpty) {
      AppFeedback.showError(context, 'Please select your gender');
      return;
    }

    String phoneToSave = '';
    if (_isPhoneAuth) {
      // Case A (Phone Auth): Use authenticated phone number, field is hidden
      phoneToSave =
          widget.verifiedPhone ??
          widget.prefilledPhone ??
          FirebaseAuth.instance.currentUser?.phoneNumber ??
          ref.read(patientControllerProvider).currentUser?.phoneNumber ??
          _mobileController.text.trim();

      if (phoneToSave.isEmpty) {
        AppFeedback.showError(
          context,
          'No verified phone number found for session.',
        );
        return;
      }
    } else {
      // Case B (Email / Patient ID Auth): Validate format of entered phone number (digits check)
      final rawPhone = _mobileController.text.trim();
      if (rawPhone.isEmpty) {
        AppFeedback.showError(context, 'Please enter your mobile number');
        return;
      }
      final digitsOnly = rawPhone.replaceAll(RegExp(r'\D'), '');
      if (digitsOnly.length < 7 || digitsOnly.length > 15) {
        AppFeedback.showError(context, 'Please enter a valid mobile number');
        return;
      }
      phoneToSave =
          _phoneValue?.isValid == true &&
              (_phoneValue?.e164.isNotEmpty ?? false)
          ? _phoneValue!.e164
          : PhoneUtils.normalizePhone(
                  rawPhone,
                  defaultDialCode: _selectedDialCode,
                ) ??
                rawPhone;
    }

    final resolvedUid = _resolveActiveUid();
    debugPrint(
      '🚀 [CompleteProfile._submitProfile] Executing registration completion:',
    );
    debugPrint('   - resolvedUid: $resolvedUid');
    debugPrint('   - isPhoneAuth: $_isPhoneAuth');
    debugPrint('   - phoneToSave: $phoneToSave');
    debugPrint('   - patientId: ${widget.patientIdModel?.patientId}');

    // Null session check
    if (widget.patientIdModel == null &&
        (resolvedUid == null || resolvedUid.isEmpty)) {
      debugPrint(
        '❌ [CompleteProfile._submitProfile] Auth session check failed: No active patient session found.',
      );
      AppFeedback.showError(
        context,
        'No active patient session found. Please log in again.',
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      final patientController = ref.read(patientControllerProvider);
      final updatedUser = await patientController.completePatientProfile(
        explicitUid: resolvedUid,
        fullname: _nameController.text.trim(),
        gender: _selectedGender,
        age: int.tryParse(_ageController.text.trim()),
        phoneNumber: phoneToSave,
        patientIdModel: widget.patientIdModel,
      );

      if (!mounted) return;

      AppFeedback.showSuccess(context, 'Profile completed successfully!');

      if (widget.patientIdModel != null) {
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (context) => const PatientPortalWrapper()),
          (Route<dynamic> route) => false,
        );
      } else {
        AuthRoutingService.navigatePatientPostLogin(
          context,
          user: updatedUser,
          clearStack: true,
        );
      }
    } catch (e, st) {
      final authError = AuthErrorHandler.handle(
        e,
        st,
        'CompletePatientProfileScreen',
      );
      if (mounted) {
        setState(() => _isLoading = false);
        AppFeedback.showAuthError(context, authError);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEDF2F8),
      body: Stack(
        children: [
          // Background ECG Watermark
          Positioned(
            top: 20,
            right: 0,
            child: Opacity(
              opacity: 0.15,
              child: CustomPaint(
                size: const Size(240, 180),
                painter: ECGWatermarkPainter(),
              ),
            ),
          ),

          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: EdgeInsets.symmetric(
                  horizontal: context.rsp(20),
                  vertical: 16,
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: Column(
                    children: [
                      const SizedBox(height: 8),
                      const LogoCard(),
                      SizedBox(height: context.rsp(20)),

                      // Patient ID Display Card
                      if (widget.patientIdModel != null)
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(18),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF0F4FA),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(color: const Color(0xFFDCE6F2)),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(
                                  0xFF12263F,
                                ).withValues(alpha: 0.06),
                                blurRadius: 12,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: Column(
                            children: [
                              Icon(
                                Icons.badge_rounded,
                                color: AppColors.primaryRed,
                                size: 32,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Your Patient ID',
                                style: TextStyle(
                                  fontSize: context.fs(13),
                                  fontWeight: FontWeight.w500,
                                  color: const Color(0xFF657991),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                widget.patientIdModel!.patientId,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: context.fs(18),
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.primaryRed,
                                  letterSpacing: 2,
                                ),
                              ),
                            ],
                          ),
                        ),
                      SizedBox(height: context.rsp(20)),

                      // Title
                      Text(
                        'Complete Your Profile',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: context.fs(20),
                          fontWeight: FontWeight.bold,
                          color: const Color(0xFF1F2F44),
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Text(
                          'Please fill in your details to complete registration.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: context.fs(13),
                            fontWeight: FontWeight.w500,
                            color: const Color(0xFF657991),
                            height: 1.4,
                          ),
                        ),
                      ),
                      SizedBox(height: context.rsp(20)),

                      // Form
                      Form(
                        key: _formKey,
                        child: Column(
                          children: [
                            // Name
                            MetallicInput(
                              hintText: 'Full Name',
                              icon: Icons.person_rounded,
                              controller: _nameController,
                              validator: (val) =>
                                  (val == null || val.trim().isEmpty)
                                  ? 'Please enter your full name'
                                  : null,
                            ),
                            const SizedBox(height: 16),

                            // Gender Dropdown
                            GenderDropdownField(
                              value: _selectedGender.isNotEmpty
                                  ? _selectedGender
                                  : null,
                              showLabel: true,
                              labelText: 'Gender *',
                              onChanged: (val) {
                                setState(() {
                                  _selectedGender = val ?? '';
                                });
                              },
                              validator: (val) => (val == null || val.isEmpty)
                                  ? 'Please select your gender'
                                  : null,
                            ),
                            const SizedBox(height: 16),

                            // Age
                            MetallicInput(
                              hintText: 'Age',
                              icon: Icons.cake_rounded,
                              keyboardType: TextInputType.number,
                              controller: _ageController,
                            ),
                            const SizedBox(height: 16),

                            // Mobile Number (Shown only for Email / Patient ID Auth; hidden for Phone Auth)
                            if (!_isPhoneAuth) ...[
                              InternationalPhoneInput(
                                controller: _mobileController,
                                initialIsoCode: _selectedIsoCode,
                                hintText: 'Mobile Number',
                                enabled: !_isLoading,
                                onChanged: (val) {
                                  _phoneValue = val;
                                  _selectedDialCode = val.dialCode;
                                  _selectedIsoCode = val.isoCode;
                                },
                              ),
                              const SizedBox(height: 16),
                            ],

                            SizedBox(height: context.rsp(20)),

                            // Submit Button
                            GradientButton(
                              text: 'Complete Registration',
                              isLoading: _isLoading,
                              onPressed: _submitProfile,
                              icon: Icons.arrow_forward_rounded,
                            ),

                            SizedBox(height: context.rsp(16)),

                            // Back to login
                            Wrap(
                              alignment: WrapAlignment.center,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Text(
                                  'Back to',
                                  style: TextStyle(
                                    fontSize: context.fs(13.5),
                                    fontWeight: FontWeight.w500,
                                    color: const Color(0xFF556980),
                                  ),
                                ),
                                GestureDetector(
                                  onTap: () {
                                    Navigator.pushAndRemoveUntil(
                                      context,
                                      MaterialPageRoute(
                                        builder: (context) =>
                                            const SignInScreen(),
                                      ),
                                      (route) => false,
                                    );
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                    ),
                                    child: Text(
                                      'Sign In',
                                      style: TextStyle(
                                        fontSize: context.fs(13.5),
                                        fontWeight: FontWeight.bold,
                                        color: AppColors.primaryRed,
                                      ),
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
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGenderOption(String gender, IconData icon) {
    final isSelected = _selectedGender == gender;
    return GestureDetector(
      onTap: () {
        setState(() => _selectedGender = gender);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          gradient: isSelected
              ? const LinearGradient(
                  colors: [
                    Color(0xFF183359),
                    Color(0xFF0F2445),
                    Color(0xFF08162D),
                  ],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                )
              : const LinearGradient(
                  colors: [
                    Color(0xFFE9EFF6),
                    Color(0xFFDBE4EF),
                    Color(0xFFCAD6E4),
                  ],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
          borderRadius: BorderRadius.circular(14),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: const Color(0xFF0A192D).withValues(alpha: 0.3),
                    blurRadius: 5,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Column(
          children: [
            Icon(
              icon,
              color: isSelected ? Colors.white : const Color(0xFF384C66),
              size: 28,
            ),
            const SizedBox(height: 4),
            Text(
              gender,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                color: isSelected ? Colors.white : const Color(0xFF384C66),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
