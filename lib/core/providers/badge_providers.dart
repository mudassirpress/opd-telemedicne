import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:telemedicine/features/auth/presentation/providers/user_provider.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/data/models/appointment_model.dart';
import 'package:telemedicine/data/models/user_model.dart';
import 'package:telemedicine/features/doctor_portal/presentation/prescriptions/prescription_controller.dart';
import 'package:telemedicine/features/appointments/presentation/appointment_controller.dart';
import 'package:telemedicine/features/complaints/presentation/payment_complaint_service.dart';
import 'package:telemedicine/features/chat/presentation/controllers/chat_controller.dart';
import 'package:telemedicine/features/reports/presentation/report_share_controller/report_share_controller.dart';
import 'package:telemedicine/data/local/offline_chat_service.dart';

// ─────────────────────────────────────────────────────────────
// LOCAL PERSISTENCE KEYS FOR VIEWED TIMESTAMPS
// ─────────────────────────────────────────────────────────────
const String _kLastViewedAppointmentsPrefix = 'last_viewed_appointments_';
const String _kLastViewedReportsPrefix = 'last_viewed_reports_';

/// Local epoch state for viewed appointments to support optimistic badge clearing
final appointmentsViewedEpochProvider =
    StateProvider.autoDispose.family<int, String>((ref, userId) => 0);

/// Local epoch state for viewed reports to support optimistic badge clearing
final reportsViewedEpochProvider =
    StateProvider.autoDispose.family<int, String>((ref, userId) => 0);

/// Set of chat IDs that have been marked read locally/optimistically in the current session.
/// Enables 0ms reactive badge decrement when a conversation is opened.
final locallyReadChatIdsProvider =
    StateProvider.autoDispose<Set<String>>((ref) => <String>{});

/// Immediately clears the badge count for [chatId] optimistically and triggers sync
/// without waiting for a server round-trip or full app restart.
void markChatAsReadLocally(WidgetRef ref, String chatId) {
  if (chatId.isEmpty) return;
  final current = ref.read(locallyReadChatIdsProvider);
  if (!current.contains(chatId)) {
    ref.read(locallyReadChatIdsProvider.notifier).state = {...current, chatId};
  }
}

// ─────────────────────────────────────────────────────────────
// 1. CHAT UNREAD BADGE COUNTER (Doctor & Patient)
// ─────────────────────────────────────────────────────────────

/// Reactive stream of total unread messages across all active conversations.
/// Updates dynamically on incoming messages and decrements/clears immediately
/// when chats are opened and marked as read.
final unreadChatCountProvider = StreamProvider.autoDispose<int>((ref) async* {
  final user = ref.watch(userProvider);
  if (user == null || user.id.isEmpty) {
    yield 0;
    return;
  }

  final locallyRead = ref.watch(locallyReadChatIdsProvider);
  final chatController = ChatController();

  // Fast offline-first emission: check local Hive database so the bottom nav
  // badge responds instantly on app open or when a chat is opened.
  final localList = OfflineChatService.instance.getChatList(user.id);
  if (localList != null) {
    var localTotal = 0;
    for (final chat in localList) {
      final chatId = (chat['chatId'] ?? '').toString();
      if (locallyRead.contains(chatId)) continue;
      final count = ((chat['unreadCount'] as num?) ?? 0).toInt();
      localTotal += count;
    }
    yield localTotal;
  }

  await for (final counts in chatController.streamUnreadCounts(user.id)) {
    var total = 0;
    for (final entry in counts.entries) {
      if (locallyRead.contains(entry.key)) continue;
      total += entry.value;
    }
    yield total;
  }
});

// ─────────────────────────────────────────────────────────────
// 2. APPOINTMENTS UNREAD / PENDING BADGE COUNTER (Doctor & Patient)
// ─────────────────────────────────────────────────────────────

/// Stream of unread / new action appointments for the signed-in user.
/// For Doctor: counts appointments with status 'requested' (awaiting action)
///             or scheduled/created after last view time.
/// For Patient: counts appointments newly scheduled or updated after last view time.
final unreadAppointmentsCountProvider =
    StreamProvider.autoDispose<int>((ref) async* {
  final user = ref.watch(userProvider);
  if (user == null || user.id.isEmpty) {
    yield 0;
    return;
  }

  // Load initial stored timestamp from SharedPreferences
  final prefs = await SharedPreferences.getInstance();
  final storedEpoch = prefs.getInt('$_kLastViewedAppointmentsPrefix${user.id}') ?? 0;
  final localEpoch = ref.watch(appointmentsViewedEpochProvider(user.id));
  final effectiveEpoch = localEpoch > storedEpoch ? localEpoch : storedEpoch;

  final appointmentsAsync = ref.watch(myAppointmentsProvider);
  final appointments = appointmentsAsync.valueOrNull ?? const <AppointmentModel>[];

  if (user.role == UserRoles.doctor) {
    // For doctor: pending appointment requests awaiting confirmation,
    // plus any appointments created after the last view timestamp.
    final pendingActionCount = appointments.where((a) {
      if (a.appointmentStatus == AppointmentStatus.requested) {
        return true;
      }
      final createdEpoch = a.createdAt?.millisecondsSinceEpoch ?? 0;
      return createdEpoch > effectiveEpoch && AppointmentStatus.isOpen(a.appointmentStatus);
    }).length;
    yield pendingActionCount;
  } else {
    // For patient: appointments newly scheduled or created after the last view timestamp.
    final unviewedCount = appointments.where((a) {
      final updatedEpoch = a.updatedAt?.millisecondsSinceEpoch ??
          a.createdAt?.millisecondsSinceEpoch ??
          0;
      return updatedEpoch > effectiveEpoch && AppointmentStatus.isOpen(a.appointmentStatus);
    }).length;
    yield unviewedCount;
  }
});

/// Mark appointments as viewed for the current user and clear the badge optimistically.
Future<void> markAppointmentsAsViewed(WidgetRef ref) async {
  final user = ref.read(userProvider);
  if (user == null || user.id.isEmpty) return;

  final now = DateTime.now().millisecondsSinceEpoch;
  ref.read(appointmentsViewedEpochProvider(user.id).notifier).state = now;

  final prefs = await SharedPreferences.getInstance();
  await prefs.setInt('$_kLastViewedAppointmentsPrefix${user.id}', now);
}

// ─────────────────────────────────────────────────────────────
// 3. REPORTS UNREAD BADGE COUNTER (Doctor & Patient)
// ─────────────────────────────────────────────────────────────

/// Unread badge indicating newly shared diagnostic reports, lab results,
/// or prescription updates.
final unreadReportsCountProvider = StreamProvider.autoDispose<int>((ref) async* {
  final user = ref.watch(userProvider);
  if (user == null || user.id.isEmpty) {
    yield 0;
    return;
  }

  final prefs = await SharedPreferences.getInstance();
  final storedEpoch = prefs.getInt('$_kLastViewedReportsPrefix${user.id}') ?? 0;
  final localEpoch = ref.watch(reportsViewedEpochProvider(user.id));
  final effectiveEpoch = localEpoch > storedEpoch ? localEpoch : storedEpoch;

  if (user.role == UserRoles.doctor) {
    // For doctor: watch active shared reports and count those shared after effectiveEpoch
    final stream = ref.read(reportShareControllerProvider).streamDoctorSharedReports(user.id);
    await for (final reports in stream) {
      final unviewed = reports.where((r) {
        final sharedEpoch = r.sharedAt.millisecondsSinceEpoch;
        return sharedEpoch > effectiveEpoch && r.isShared;
      }).length;
      yield unviewed;
    }
  } else {
    // For patient: watch prescriptions issued to the patient
    final stream = ref.read(prescriptionControllerProvider).streamForPatient(user.id);
    await for (final prescriptions in stream) {
      final unviewed = prescriptions.where((p) {
        final createdEpoch = p.createdAt.millisecondsSinceEpoch;
        return createdEpoch > effectiveEpoch;
      }).length;
      yield unviewed;
    }
  }
});

/// Mark reports as viewed for the current user and clear the badge optimistically.
Future<void> markReportsAsViewed(WidgetRef ref) async {
  final user = ref.read(userProvider);
  if (user == null || user.id.isEmpty) return;

  final now = DateTime.now().millisecondsSinceEpoch;
  ref.read(reportsViewedEpochProvider(user.id).notifier).state = now;

  final prefs = await SharedPreferences.getInstance();
  await prefs.setInt('$_kLastViewedReportsPrefix${user.id}', now);
}

// ─────────────────────────────────────────────────────────────
// 4. ADMIN DASHBOARD & MONITORING BADGES
// ─────────────────────────────────────────────────────────────

/// Total count of unapproved / pending payment receipts and transaction proofs
/// submitted by patients or doctors (both appointment payments & account payments).
final adminPendingPaymentsCountProvider = Provider.autoDispose<int>((ref) {
  final appointmentPayments =
      ref.watch(appointmentPaymentsProvider).valueOrNull ??
          const <AppointmentPaymentModel>[];
  final pendingAppointmentPayments =
      appointmentPayments.where((p) => p.isPending).length;

  final accountPaymentsAsync = ref.watch(_adminPendingAccountPaymentsStreamProvider);
  final pendingAccountPayments = accountPaymentsAsync.valueOrNull?.length ?? 0;

  return pendingAppointmentPayments + pendingAccountPayments;
});

/// Internal stream for pending account payments
final _adminPendingAccountPaymentsStreamProvider =
    StreamProvider.autoDispose<List<UserModel>>((ref) {
  return ref
      .read(patientControllerProvider)
      .getFilteredPaymentRequests(PaymentStatus.pending);
});

/// Total appointments booked that are pending confirmation or currently active/incomplete.
final adminPendingAppointmentsCountProvider = Provider.autoDispose<int>((ref) {
  final appointments =
      ref.watch(allAppointmentsProvider).valueOrNull ??
          const <AppointmentModel>[];
  return appointments
      .where((a) =>
          a.appointmentStatus == AppointmentStatus.requested ||
          AppointmentStatus.isOpen(a.appointmentStatus))
      .length;
});
/// Total reactivation requests awaiting admin sign-off.
final adminPendingReactivationsCountProvider =
    StreamProvider.autoDispose<int>((ref) {
  return ref
      .read(patientControllerProvider)
      .getReactivationRequests()
      .map((requests) =>
          requests.where((r) => (r['status'] ?? '').toString() == 'pending').length);
});

/// Aggregate pending count for Admin "More" tab (payment proofs + reactivations + complaints).
final adminMoreMenuBadgeCountProvider = Provider.autoDispose<int>((ref) {
  final pendingPayments = ref.watch(adminPendingPaymentsCountProvider);
  final pendingReactivations =
      ref.watch(adminPendingReactivationsCountProvider).valueOrNull ?? 0;
  final unreadNotifications =
      ref.watch(adminUnreadNotificationsCountProvider).valueOrNull ?? 0;
  return pendingPayments + pendingReactivations + unreadNotifications;
});

