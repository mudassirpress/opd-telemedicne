import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/shared/widgets/opd_design_system.dart';
import 'package:telemedicine/features/doctor_portal/presentation/ratings/doctor_rating_controller.dart';

/// Read-only contact / profile details of the other participant in a chat.
///
/// The content adapts to the role of the person being viewed: a doctor sees
/// clinical credentials, a patient sees demographic details such as age and
/// gender. Data is read straight from the participant's profile document.
///
/// Styled to match the Sign In screen (logo, watermark, typography, cards).
class ChatContactScreen extends StatefulWidget {
  final String userId;
  final String userName;
  final String userImage;
  final String userRole;

  const ChatContactScreen({
    super.key,
    required this.userId,
    required this.userName,
    required this.userImage,
    required this.userRole,
  });

  @override
  State<ChatContactScreen> createState() => _ChatContactScreenState();
}

class _ChatContactScreenState extends State<ChatContactScreen> {
  Map<String, dynamic>? _profile;
  bool _loading = true;
  bool _loadFailed = false;

  bool get _isDoctor => widget.userRole == UserRoles.doctor;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    setState(() {
      _loading = true;
      _loadFailed = false;
    });
    try {
      final collection = _isDoctor
          ? FirestoreCollections.doctors
          : FirestoreCollections.patients;
      final doc = await FirebaseFirestore.instance
          .collection(collection)
          .doc(widget.userId)
          .get();
      if (!mounted) return;
      setState(() {
        _profile = doc.exists ? doc.data() : null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      // A failed read used to silently fall through to the normal layout,
      // where every field rendered "Not available" — as if this person had no
      // profile data at all.
      setState(() {
        _loadFailed = true;
        _loading = false;
      });
    }
  }

  String _text(dynamic value, {String fallback = 'Not available'}) {
    final text = (value ?? '').toString().trim();
    return text.isEmpty ? fallback : text;
  }

  String get _roleLabel => _isDoctor ? 'Doctor' : 'Patient';

  @override
  Widget build(BuildContext context) {
    return OpdScreenShell(
      title: 'Contact Info',
      subtitle: _isDoctor
          ? 'Profile and contact details of the doctor you are chatting with.'
          : 'Profile and contact details of the patient you are chatting with.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_loading)
            const OpdInlineLoader(label: 'Loading contact details...')
          else if (_loadFailed)
            OpdEmptyState(
              icon: Icons.wifi_off_rounded,
              title: 'Could not load contact details',
              subtitle: 'Check your connection and try again.',
              action: TextButton(
                onPressed: _loadProfile,
                child: const Text('Retry'),
              ),
            )
          else ...[
            _buildIdentityCard(context),
            SizedBox(height: context.rsp(14)),
            if (_isDoctor) ...[
              _DoctorRatingSummary(profile: _profile),
              SizedBox(height: context.rsp(14)),
            ],
            OpdSectionLabel(
              _isDoctor ? 'Professional Details' : 'Patient Details',
            ),
            OpdCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Column(
                children: [
                  for (final row in (_isDoctor ? _doctorRows() : _patientRows()))
                    row,
                ],
              ),
            ),
            SizedBox(height: context.rsp(22)),
            const OpdSectionLabel('Account'),
            OpdCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Column(
                children: [
                  OpdDetailRow(
                    icon: Icons.badge_rounded,
                    label: _isDoctor ? 'Doctor ID' : 'Patient ID',
                    value: _text(
                      _profile?[_isDoctor ? 'doctorId' : 'patientId'],
                    ),
                  ),
                  OpdDetailRow(
                    icon: Icons.login_rounded,
                    label: 'Login Type',
                    value: _text(
                      _profile?['loginType'],
                      fallback: 'Phone number',
                    ),
                  ),
                  OpdDetailRow(
                    icon: Icons.verified_user_rounded,
                    label: 'Role',
                    value: _roleLabel,
                  ),
                ],
              ),
            ),
            SizedBox(height: context.rsp(22)),
            OpdInfoPanel(
              icon: Icons.privacy_tip_outlined,
              title: 'Your contact details stay private',
              description:
                  'Only you and your OPD care team can view this information.',
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildIdentityCard(BuildContext context) {
    final image = _text(_profile?['image'], fallback: widget.userImage);
    final name = _text(_profile?['fullname'], fallback: widget.userName);

    return OpdCard(
      padding: EdgeInsets.symmetric(
        vertical: context.rsp(24),
        horizontal: context.rsp(20),
      ),
      child: Column(
        children: [
          CircleAvatar(
            radius: 44,
            backgroundColor: const Color(0xFFF0F4FA),
            backgroundImage: image.isNotEmpty ? NetworkImage(image) : null,
            child: image.isEmpty
                ? Text(
                    name.isNotEmpty ? name[0].toUpperCase() : '?',
                    style: TextStyle(
                      fontSize: context.fs(20),
                      fontWeight: FontWeight.bold,
                      color: const Color(0xFF062B72),
                    ),
                  )
                : null,
          ),
          const SizedBox(height: 14),
          Text(
            name,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: context.fs(16),
              fontWeight: FontWeight.bold,
              color: const Color(0xFF1F2F44),
            ),
          ),
          const SizedBox(height: 10),
          OpdPill(
            icon: _isDoctor
                ? Icons.medical_services_rounded
                : Icons.person_rounded,
            label: _badgeLabel,
          ),
        ],
      ),
    );
  }

  String get _badgeLabel {
    if (_isDoctor) {
      return _text(
        _profile?['specialization'],
        fallback: _text(_profile?['highestDegree'], fallback: 'Doctor'),
      );
    }
    final gender = ( _profile?['gender'] ?? '').toString().trim();
    return gender.isEmpty ? 'Patient' : 'Patient • $gender';
  }

  List<Widget> _doctorRows() {
    return [
      OpdDetailRow(
        icon: Icons.phone_rounded,
        label: 'Phone Number',
        value: _text(_profile?['phoneNumber']),
      ),
      OpdDetailRow(
        icon: Icons.school_rounded,
        label: 'Qualification',
        value: _text(_profile?['highestDegree']),
      ),
      OpdDetailRow(
        icon: Icons.medical_information_rounded,
        label: 'Specialization',
        value: _text(
          _profile?['specialization'],
          fallback: _text(_profile?['highestDegree']),
        ),
      ),
      OpdDetailRow(
        icon: Icons.wc_rounded,
        label: 'Gender',
        value: _text(_profile?['gender']),
      ),
      OpdDetailRow(
        icon: Icons.cake_rounded,
        label: 'Age',
        value: _text(_profile?['age']),
      ),
    ];
  }

  List<Widget> _patientRows() {
    return [
      OpdDetailRow(
        icon: Icons.phone_rounded,
        label: 'Phone Number',
        value: _text(_profile?['phoneNumber']),
      ),
      OpdDetailRow(
        icon: Icons.cake_rounded,
        label: 'Age',
        value: _text(_profile?['age']),
      ),
      OpdDetailRow(
        icon: Icons.wc_rounded,
        label: 'Gender',
        value: _text(_profile?['gender']),
      ),
      OpdDetailRow(
        icon: Icons.local_hospital_rounded,
        label: 'Blood Group',
        value: _text(_profile?['bloodGroup']),
      ),
    ];
  }
}

/// Doctor's average rating and total count, e.g. "⭐ 4.8  •  125 Ratings".
///
/// Reads the values already projected onto the doctor profile, so it costs no
/// additional query.
class _DoctorRatingSummary extends ConsumerWidget {
  final Map<String, dynamic>? profile;

  const _DoctorRatingSummary({required this.profile});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final doctorId = profile?['id']?.toString() ?? '';
    final ratingAsync = ref.watch(doctorRatingSummaryProvider(doctorId));
    final total = ratingAsync.valueOrNull?.total ?? (profile?['totalRatings'] ?? 0).toInt();
    final average = ratingAsync.valueOrNull?.average ?? (profile?['averageRating'] ?? 0.0).toDouble();
    final hasRatings = total > 0;

    return OpdCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Icon(
            hasRatings ? Icons.star_rounded : Icons.star_border_rounded,
            size: hasRatings ? 24 : 20,
            color: hasRatings ? const Color(0xFFE9A400) : const Color(0xFFBAC6D5),
          ),
          const SizedBox(width: 10),
          if (hasRatings) ...[
            Text(
              average.toStringAsFixed(1),
              style: TextStyle(
                fontSize: context.fs(16),
                fontWeight: FontWeight.bold,
                color: const Color(0xFF1F2F44),
              ),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                '$total Rating${total == 1 ? '' : 's'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: context.fs(13),
                  fontWeight: FontWeight.w500,
                  color: const Color(0xFF657991),
                ),
              ),
            ),
          ] else
            Text(
              'No ratings yet',
              style: TextStyle(
                fontSize: context.fs(13),
                fontWeight: FontWeight.w500,
                color: const Color(0xFF7E90A6),
              ),
            ),
        ],
      ),
    );
  }
}
