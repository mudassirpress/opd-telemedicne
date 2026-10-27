import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The three tabs of the patient bottom navigation.
///
/// [chat] opens the existing `ChatRoomScreen`, [appointments] opens the
/// booking flow and [profile] opens the existing patient profile — nothing
/// else is reachable from the bar.
enum PatientPortalTab {
  chat,
  appointments,
  profile;

  int get navIndex => index;
}

final patientPortalTabProvider = StateProvider<PatientPortalTab>(
  (ref) => PatientPortalTab.chat,
);
