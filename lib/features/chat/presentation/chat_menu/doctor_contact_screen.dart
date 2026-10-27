import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/shared/widgets/language_field.dart';
import 'package:telemedicine/shared/widgets/opd_design_system.dart';

/// Minimal read-only card a patient sees for the doctor they are chatting with,
/// reached from the chat overflow menu's "View Contact".
///
/// Deliberately scoped to four facts — image, name, highest degree and
/// languages. It intentionally does NOT reuse `ChatContactScreen` (which is the
/// doctor's view of a patient): that screen renders ratings, phone number,
/// specialisation, gender, age and an account block, all of which the product
/// has ruled out here. Keeping a separate screen also means the patient's
/// lightweight view can never inherit new fields that get added to the
/// clinician-facing card later.
///
/// The profile is read through a Firestore snapshot stream rather than a
/// one-shot `get()`, so a doctor who adds a language while the patient has this
/// screen open sees the change without a restart.
class DoctorContactScreen extends StatelessWidget {
  final String doctorId;
  final String doctorName;
  final String doctorImage;

  const DoctorContactScreen({
    super.key,
    required this.doctorId,
    required this.doctorName,
    required this.doctorImage,
  });

  @override
  Widget build(BuildContext context) {
    return OpdScreenShell(
      title: 'Doctor Contact',
      subtitle: 'Basic details of the doctor you are chatting with.',
      child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection(FirestoreCollections.doctors)
            .doc(doctorId)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const OpdInlineLoader(label: 'Loading doctor details...');
          }

          if (snapshot.hasError) {
            return OpdEmptyState(
              icon: Icons.cloud_off_rounded,
              title: 'Could not load details',
              subtitle:
                  'We could not reach the server. Please check your '
                  'connection and try again.',
            );
          }

          final profile = snapshot.data?.data();
          return _DoctorContactBody(
            doctorId: doctorId,
            profile: profile,
            fallbackName: doctorName,
            fallbackImage: doctorImage,
          );
        },
      ),
    );
  }
}

class _DoctorContactBody extends StatelessWidget {
  final String doctorId;
  final Map<String, dynamic>? profile;
  final String fallbackName;
  final String fallbackImage;

  const _DoctorContactBody({
    required this.doctorId,
    required this.profile,
    required this.fallbackName,
    required this.fallbackImage,
  });

  String _text(dynamic value, {String fallback = ''}) {
    final text = (value ?? '').toString().trim();
    return text.isEmpty ? fallback : text;
  }

  @override
  Widget build(BuildContext context) {
    final name = _text(profile?['fullname'], fallback: fallbackName);
    // The doctor photo is written as `imageUrl` everywhere else in the app
    // (`doctor_list`, `doctor_controller`, admin screens); `UserModel` uses
    // `image`. Read both so the card works whichever field this record carries,
    // and fall back to the URL the chat list already had in hand.
    final image = _text(
      profile?['imageUrl'],
      fallback: _text(profile?['image'], fallback: fallbackImage),
    );
    final degree = _text(profile?['highestDegree'], fallback: 'Not specified');
    // `DoctorLanguages.parse` absorbs the missing-field case, so a doctor who
    // has never declared a language renders an empty list rather than throwing.
    final languages = DoctorLanguages.parse(
      profile?[DoctorLanguages.field] ?? profile?[DoctorLanguages.legacyField],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OpdCard(
          padding: EdgeInsets.symmetric(
            vertical: context.rsp(28),
            horizontal: context.rsp(20),
          ),
          child: Column(
            children: [
              CircleAvatar(
                radius: 46,
                backgroundColor: const Color(0xFFF0F4FA),
                backgroundImage: image.isNotEmpty ? NetworkImage(image) : null,
                onBackgroundImageError: image.isEmpty ? null : (_, __) {},
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
              const SizedBox(height: 16),
              Text(
                name.isEmpty ? 'Doctor' : name,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: context.fs(16.5),
                  fontWeight: FontWeight.bold,
                  color: const Color(0xFF1F2F44),
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: context.rsp(22)),
        const OpdSectionLabel('Highest Degree'),
        OpdCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: OpdDetailRow(
            icon: Icons.school_rounded,
            label: 'Qualification',
            value: degree,
          ),
        ),
        SizedBox(height: context.rsp(22)),
        const OpdSectionLabel('Languages'),
        OpdCard(
          padding: const EdgeInsets.all(16),
          child: DoctorLanguagesView(languages: languages),
        ),
      ],
    );
  }
}
