import 'package:flutter_riverpod/flutter_riverpod.dart';

final doctorPortalTabProvider = StateProvider<int>((ref) => 0);

/// Tabs of the doctor bottom navigation, in display order.
enum DoctorPortalTab {
  chat,
  appointments,
  reports,
  profile;
}
