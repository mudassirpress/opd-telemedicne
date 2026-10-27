// lib/features/doctors/presentation/doctor_list_widget.dart
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shimmer/shimmer.dart';
import 'package:telemedicine/features/auth/presentation/providers/user_provider.dart';
import 'package:telemedicine/features/auth/presentation/controllers/doctor_controller.dart';
import 'package:telemedicine/core/services/doctor_list_cache.dart';
import 'package:telemedicine/features/chat/presentation/chat_screen.dart';
import 'package:telemedicine/app/theme/app_theme.dart';
import 'package:telemedicine/core/services/doctor_presence_service.dart';
import 'package:telemedicine/core/services/soft_delete_service.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/features/doctor_portal/presentation/ratings/doctor_rating_controller.dart';
import 'package:telemedicine/core/utils/guest_guard.dart';
import 'package:telemedicine/features/payments/presentation/screens/payment_screen.dart';

class DoctorList extends ConsumerStatefulWidget {
  final String searchQuery;

  const DoctorList({super.key, this.searchQuery = ''});

  @override
  ConsumerState<DoctorList> createState() => _DoctorListState();
}

class _DoctorListState extends ConsumerState<DoctorList> {
  DoctorController? _doctorController;
  Stream<List<Map<String, dynamic>>>? _doctorsStream;

  @override
  void initState() {
    super.initState();
    // Acquired ONCE per State, balanced by disposeDoctorListStream() below.
    // The old code called streamAllDoctors() inside build(): every rebuild
    // incremented the controller's listener count (which nothing ever
    // decremented for this widget), and the ValueKey included the search
    // query, so every keystroke destroyed the State, re-acquired, and
    // resubscribed — flashing the shimmer over a list the user was typing
    // into. Search filtering happens in the builder; the stream is identical.
    _doctorController = ref.read(doctorControllerProvider);
    _doctorsStream = _doctorController?.streamAllDoctors();
  }

  @override
  void dispose() {
    _doctorController?.disposeDoctorListStream();
    super.dispose();
  }

  /// Re-acquires the shared doctor stream. Retry used to call `setState(() {})`
  /// only, which re-subscribed to the *same errored* stream instance — the
  /// list could never recover until the app was restarted. The toast also used
  /// to fire from inside build(), so it re-fired on every rebuild.
  void _retry() {
    setState(() {
      _doctorController?.disposeDoctorListStream();
      _doctorsStream = _doctorController?.streamAllDoctors();
    });
  }

  @override
  Widget build(BuildContext context) {
    // Local-first: the cache provider is Hive-seeded synchronously and kept
    // live by the same shared Firestore stream this widget also watches, so
    // reading it adds no extra network listener. It lets a warm launch (or an
    // offline device) paint the doctor list on the very first frame instead
    // of a shimmer that waits for the first Firestore snapshot.
    final cachedDoctors = ref.watch(doctorListCacheProvider).doctors;

    return StreamBuilder<List<Map<String, dynamic>>>(
      key: const ValueKey('doctor_list_stream'),
      stream: _doctorsStream,
      builder: (context, snapshot) {
        // Stream data wins; the Hive cache covers the frames before the first
        // snapshot arrives AND a stream error on a device that already has
        // doctors cached (offline / Firestore outage) — a cached list must
        // never be replaced by a blank error screen.
        final doctors = snapshot.data ?? cachedDoctors;

        if (snapshot.hasError && doctors.isEmpty) {
          // Never surface the raw Firestore exception to a patient.
          return Container(
            height: 136,
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.error_outline, color: Colors.red, size: 24),
                  const SizedBox(height: 8),
                  Text(
                    'Could not load doctors',
                    style: TextStyle(
                      fontSize: context.fs(12),
                      color: Colors.red,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _retry,
                    child: Text(
                      'Retry',
                      style: TextStyle(color: AppColors.primaryRed),
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        // Genuine first-ever launch with nothing on disk: only then shimmer.
        if (!snapshot.hasData && doctors.isEmpty) {
          return _buildShimmerLoading();
        }

        // Filter doctors based on search query
        final query = widget.searchQuery.trim().toLowerCase();
        final matched = query.isEmpty
            ? doctors
            : doctors.where((doctor) {
                final fullname = (doctor['fullname'] ?? '')
                    .toString()
                    .toLowerCase();
                final degree = (doctor['highestDegree'] ?? '')
                    .toString()
                    .toLowerCase();
                final doctorId = (doctor['doctorId'] ?? '')
                    .toString()
                    .toLowerCase();
                return fullname.contains(query) ||
                    degree.contains(query) ||
                    doctorId.contains(query);
              }).toList();

        // Online doctors first, most recently online at the top. Presence comes
        // from the centralized [DoctorPresence] service — the SAME source as
        // the green dot on each card — so the order and the dot can never
        // disagree, and the order updates the moment a doctor comes online or
        // their heartbeat goes stale instead of a refresh interval later.
        final presence = ref.watch(doctorPresenceProvider);
        final filteredDoctors = sortDoctorsByPresence<Map<String, dynamic>>(
          matched,
          presenceForDoctorList(matched, presence),
          (doctor) => (doctor['id'] ?? '').toString(),
        );

        if (filteredDoctors.isEmpty) {
          return Container(
            height: 136,
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.people_outline, color: Colors.grey[400], size: 32),
                  const SizedBox(height: 8),
                  Text(
                    query.isEmpty
                        ? 'No doctors available'
                        : 'No matching doctors',
                    style: TextStyle(
                      fontSize: context.fs(12),
                      color: Colors.grey[500],
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        return Container(
          // Tall enough for the rating row; the parent SizedBox must match.
          height: 156 + (context.textScale - 1.0) * 64,
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: filteredDoctors.length,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemBuilder: (context, index) {
              final doctor = filteredDoctors[index];
              return _buildDoctorCard(doctor);
            },
          ),
        );
      },
    );
  }

  Widget _buildDoctorCard(Map<String, dynamic> doctor) {
    final fullname = doctor['fullname'] ?? 'Unknown Doctor';
    final degree = doctor['highestDegree'] ?? 'General Physician';
    final imageUrl = doctor['imageUrl'] ?? '';
    final consultations = doctor['consultations'] ?? 0;
    final nameParts = fullname.split(' ');
    final shortName = nameParts.isNotEmpty ? nameParts.first : 'Doctor';
    final doctorId = (doctor['id'] ?? '').toString();

    // Use centralized presence — same source as Chat List and Chat Screen
    final isOnline = ref.watch(doctorOnlineProvider(doctorId));

    // Real-time rating from the single source of truth, gracefully falling back
    // to the cached projected value on the doctor document while loading.
    final ratingAsync = ref.watch(doctorRatingSummaryProvider(doctorId));
    final averageRating =
        ratingAsync.valueOrNull?.average ??
        (doctor['averageRating'] ?? 0.0).toDouble();
    final totalRatings =
        ratingAsync.valueOrNull?.total ?? (doctor['totalRatings'] ?? 0).toInt();

    return Container(
      width: 85,
      margin: const EdgeInsets.only(right: 12),
      child: GestureDetector(
        onTap: () => _navigateToChat(doctor),
        child: Column(
          children: [
            Stack(
              children: [
                Container(
                  width: 65,
                  height: 65,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: isOnline ? AppColors.success : Colors.grey,
                      width: 2,
                    ),
                  ),
                  child: ClipOval(
                    child: imageUrl.isNotEmpty
                        ? CachedNetworkImage(
                            imageUrl: imageUrl,
                            fit: BoxFit.cover,
                            width: 65,
                            height: 65,
                            placeholder: (context, url) => Container(
                              color: Colors.grey[200],
                              child: Center(
                                child: SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: AppColors.primaryRed,
                                  ),
                                ),
                              ),
                            ),
                            errorWidget: (context, url, error) => Container(
                              color: Colors.grey[200],
                              child: Icon(
                                Icons.person,
                                size: 30,
                                color: Colors.grey[400],
                              ),
                            ),
                          )
                        : Container(
                            color: Colors.grey[200],
                            child: Icon(
                              Icons.person,
                              size: 30,
                              color: Colors.grey[400],
                            ),
                          ),
                  ),
                ),
                Positioned(
                  bottom: 0,
                  right: 2,
                  child: Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      color: isOnline ? AppColors.success : Colors.grey,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              shortName,
              style: TextStyle(
                fontSize: context.fs(11),
                fontWeight: FontWeight.w500,
                color: Colors.grey[800],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              degree.length > 15 ? '${degree.substring(0, 12)}...' : degree,
              style: TextStyle(
                fontSize: context.fs(9),
                color: Colors.grey[600],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (consultations > 0)
              Text(
                '$consultations consults',
                style: TextStyle(
                  fontSize: context.fs(8),
                  color: Colors.grey[500],
                ),
              ),
            if (totalRatings > 0)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.star, size: 10, color: Colors.amber),
                  const SizedBox(width: 2),
                  Text(
                    averageRating.toStringAsFixed(1),
                    style: TextStyle(
                      fontSize: context.fs(9),
                      color: Colors.grey[600],
                    ),
                  ),
                  Text(
                    ' ($totalRatings)',
                    style: TextStyle(
                      fontSize: context.fs(9),
                      color: Colors.grey[400],
                    ),
                  ),
                ],
              )
            else
              Text(
                'No ratings yet',
                style: TextStyle(
                  fontSize: context.fs(8),
                  color: Colors.grey[400],
                ),
              ),
            // Online/Offline status text
            AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              child: Text(
                isOnline ? '● Online' : '○ Offline',
                style: TextStyle(
                  fontSize: context.fs(8),
                  fontWeight: FontWeight.w500,
                  color: isOnline ? AppColors.success : Colors.grey[500],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Entry point for starting a NEW chat with a doctor.
  ///
  /// The doctor list is already filtered to active doctors, but that is only a
  /// convenience — the doctor could be deactivated between the list being
  /// rendered and this tap landing, so the live Firestore state is re-checked
  /// here. An already-existing conversation is unaffected and still opens.
  Future<void> _navigateToChat(Map<String, dynamic> doctor) async {
    final currentUser = ref.read(userProvider);

    if (currentUser == null || currentUser.isGuest) {
      GuestGuard.showLoginPrompt(
        context,
        message: 'Please log in to chat with doctors.',
      );
      return;
    }

    final isRestrictedPatient =
        currentUser.role == 'patient' &&
        !currentUser.isPatientIdUser &&
        currentUser.paymentStatus != 'approved' &&
        currentUser.paymentStatus != 'completed';

    if (isRestrictedPatient) {
      _showRestrictedPatientPrompt(context, currentUser.paymentStatus);
      return;
    }

    final doctorId = (doctor['id'] ?? '').toString();
    if (doctorId.isEmpty) return;

    // Re-verify against the database rather than trusting the in-memory card.
    final blockedReason = await SoftDeleteService.newBusinessBlockedReason(
      doctorId,
    );
    if (!mounted) return;
    if (blockedReason != null) {
      ToastService.instance.showError(blockedReason);
      return;
    }

    // Use centralized presence — same source as Chat List and Chat Screen
    final isOnline = ref.read(doctorOnlineProvider(doctorId));
    if (!isOnline) {
      ToastService.instance.showInfo(
        '${doctor['fullname'] ?? 'Doctor'} is offline. They will respond when online.',
      );
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChatScreen(
          otherUserId: doctorId,
          otherUserName: doctor['fullname'] ?? 'Doctor',
          otherUserImage: doctor['imageUrl'] ?? '',
        ),
      ),
    );
  }

  void _showRestrictedPatientPrompt(
    BuildContext context,
    String? paymentStatus,
  ) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.lock_outline_rounded, color: AppColors.primaryRed),
            const SizedBox(width: 8),
            const Text('Account Restricted'),
          ],
        ),
        content: Text(
          paymentStatus == 'pending'
              ? 'Your payment proof is currently under review by administrators. Chat and calls are locked until approval.'
              : 'Payment is required to chat and consult with doctors. Please complete your payment to continue.',
          style: const TextStyle(fontSize: 14, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primaryRed,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const PaymentScreen()),
              );
            },
            child: Text(
              paymentStatus == 'pending' ? 'View Payment' : 'Complete Payment',
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  Widget shimmerBox({double? width, double? height, BorderRadius? radius}) {
    return Shimmer.fromColors(
      baseColor: Colors.grey[300]!,
      highlightColor: Colors.grey[100]!,
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: radius ?? BorderRadius.circular(4),
        ),
      ),
    );
  }

  Widget _buildShimmerLoading() {
    return Container(
      height: 140,
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: 6,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemBuilder: (context, index) {
          return Container(
            width: 85,
            margin: const EdgeInsets.only(right: 12),
            child: Column(
              children: [
                Stack(
                  children: [
                    shimmerBox(
                      width: 65,
                      height: 65,
                      radius: BorderRadius.circular(100),
                    ),
                    Positioned(
                      bottom: 0,
                      right: 2,
                      child: shimmerBox(
                        width: 14,
                        height: 14,
                        radius: BorderRadius.circular(100),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                shimmerBox(width: 50, height: 11),
                const SizedBox(height: 4),
                shimmerBox(width: 60, height: 9),
                const SizedBox(height: 4),
                shimmerBox(width: 40, height: 8),
              ],
            ),
          );
        },
      ),
    );
  }
}

// Doctor Grid View with real-time status
class DoctorGridView extends ConsumerStatefulWidget {
  final String searchQuery;

  const DoctorGridView({super.key, this.searchQuery = ''});

  @override
  ConsumerState<DoctorGridView> createState() => _DoctorGridViewState();
}

class _DoctorGridViewState extends ConsumerState<DoctorGridView> {
  DoctorController? _doctorController;
  Stream<List<Map<String, dynamic>>>? _doctorsStream;

  @override
  void initState() {
    super.initState();
    // Same acquire/release pairing as _DoctorListState: one subscription for
    // the life of this State, released on dispose.
    _doctorController = ref.read(doctorControllerProvider);
    _doctorsStream = _doctorController?.streamAllDoctors();
  }

  @override
  void dispose() {
    _doctorController?.disposeDoctorListStream();
    super.dispose();
  }

  /// See [_DoctorListState._retry]: re-acquires the shared stream so Retry can
  /// actually recover, and keeps the raw exception off the screen.
  void _retry() {
    setState(() {
      _doctorController?.disposeDoctorListStream();
      _doctorsStream = _doctorController?.streamAllDoctors();
    });
  }

  @override
  Widget build(BuildContext context) {
    // Same local-first rule as the horizontal strip above: paint the Hive
    // cache on the first frame instead of a spinner, let the live stream
    // replace it, and keep the cached list visible through a stream error.
    final cachedDoctors = ref.watch(doctorListCacheProvider).doctors;

    return StreamBuilder<List<Map<String, dynamic>>>(
      key: const ValueKey('doctor_grid_stream'),
      stream: _doctorsStream,
      builder: (context, snapshot) {
        final doctors = snapshot.data ?? cachedDoctors;

        if (snapshot.hasError && doctors.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, color: Colors.red, size: 48),
                const SizedBox(height: 16),
                Text(
                  'Could not load doctors',
                  style: TextStyle(fontSize: context.fs(14), color: Colors.red),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: _retry,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primaryRed,
                  ),
                  child: const Text('Retry'),
                ),
              ],
            ),
          );
        }

        if (!snapshot.hasData && doctors.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }

        final query = widget.searchQuery.trim().toLowerCase();
        final matched = query.isEmpty
            ? doctors
            : doctors.where((doctor) {
                final fullname = (doctor['fullname'] ?? '')
                    .toString()
                    .toLowerCase();
                final degree = (doctor['highestDegree'] ?? '')
                    .toString()
                    .toLowerCase();
                final doctorId = (doctor['doctorId'] ?? '')
                    .toString()
                    .toLowerCase();
                return fullname.contains(query) ||
                    degree.contains(query) ||
                    doctorId.contains(query);
              }).toList();

        // Online doctors first, most recently online at the top. Presence comes
        // from the centralized [DoctorPresence] service — the SAME source as
        // the green dot on each card — so the order and the dot can never
        // disagree, and the order updates the moment a doctor comes online or
        // their heartbeat goes stale instead of a refresh interval later.
        final presence = ref.watch(doctorPresenceProvider);
        final filteredDoctors = sortDoctorsByPresence<Map<String, dynamic>>(
          matched,
          presenceForDoctorList(matched, presence),
          (doctor) => (doctor['id'] ?? '').toString(),
        );

        if (filteredDoctors.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.people_outline, size: 64, color: Colors.grey[400]),
                const SizedBox(height: 16),
                Text(
                  query.isEmpty
                      ? 'No doctors available'
                      : 'No matching doctors',
                  style: TextStyle(
                    fontSize: context.fs(14),
                    color: Colors.grey[500],
                  ),
                ),
              ],
            ),
          );
        }

        return GridView.builder(
          padding: const EdgeInsets.all(16),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 240,
            mainAxisExtent: 236,
            crossAxisSpacing: 16,
            mainAxisSpacing: 16,
          ),
          itemCount: filteredDoctors.length,
          itemBuilder: (context, index) {
            final doctor = filteredDoctors[index];
            return _buildDoctorGridCard(doctor);
          },
        );
      },
    );
  }

  Widget _buildDoctorGridCard(Map<String, dynamic> doctor) {
    final fullname = doctor['fullname'] ?? 'Unknown Doctor';
    final degree = doctor['highestDegree'] ?? 'General Physician';
    final imageUrl = doctor['imageUrl'] ?? '';
    final consultations = doctor['consultations'] ?? 0;
    final rating = (doctor['rating'] ?? 0.0).toDouble();
    final specialization = doctor['specialization'] ?? degree;
    final doctorId = (doctor['id'] ?? '').toString();

    // Use centralized presence — same source as Chat List and Chat Screen
    final isOnline = ref.watch(doctorOnlineProvider(doctorId));

    // Real-time rating from the single source of truth, gracefully falling back
    // to the cached projected value on the doctor document while loading.
    final ratingAsync = ref.watch(doctorRatingSummaryProvider(doctorId));
    final averageRating =
        ratingAsync.valueOrNull?.average ??
        (doctor['averageRating'] ?? 0.0).toDouble();
    final totalRatings =
        ratingAsync.valueOrNull?.total ?? (doctor['totalRatings'] ?? 0).toInt();

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        onTap: () => _navigateToChat(doctor),
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Stack(
                children: [
                  Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isOnline ? AppColors.success : Colors.grey,
                        width: 3,
                      ),
                    ),
                    child: ClipOval(
                      child: imageUrl.isNotEmpty
                          ? CachedNetworkImage(
                              imageUrl: imageUrl,
                              fit: BoxFit.cover,
                              width: 80,
                              height: 80,
                              placeholder: (context, url) => Container(
                                color: Colors.grey[200],
                                child: Center(
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: AppColors.primaryRed,
                                  ),
                                ),
                              ),
                              errorWidget: (context, url, error) => Container(
                                color: Colors.grey[200],
                                child: Icon(
                                  Icons.person,
                                  size: 40,
                                  color: Colors.grey[400],
                                ),
                              ),
                            )
                          : Container(
                              color: Colors.grey[200],
                              child: Icon(
                                Icons.person,
                                size: 40,
                                color: Colors.grey[400],
                              ),
                            ),
                    ),
                  ),
                  Positioned(
                    bottom: 2,
                    right: 2,
                    child: Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        color: isOnline ? AppColors.success : Colors.grey,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                fullname,
                style: TextStyle(
                  fontSize: context.fs(14.5),
                  fontWeight: FontWeight.w600,
                  color: Colors.grey[800],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Text(
                specialization.length > 20
                    ? '${specialization.substring(0, 17)}...'
                    : specialization,
                style: TextStyle(
                  fontSize: context.fs(12.5),
                  color: Colors.grey[600],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (consultations > 0)
                    Flexible(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.people_outline,
                            size: 12,
                            color: Colors.grey[500],
                          ),
                          const SizedBox(width: 2),
                          Text(
                            '$consultations',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: context.fs(10),
                              color: Colors.grey[600],
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (consultations > 0 && rating > 0)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Container(
                        width: 1,
                        height: 10,
                        color: Colors.grey[300],
                      ),
                    ),
                  if (totalRatings > 0)
                    Flexible(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.star, size: 12, color: Colors.amber),
                          const SizedBox(width: 2),
                          Text(
                            averageRating.toStringAsFixed(1),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: context.fs(10),
                              color: Colors.grey[600],
                            ),
                          ),
                          Text(
                            ' ($totalRatings)',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: context.fs(10),
                              color: Colors.grey[400],
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (totalRatings == 0)
                    Flexible(
                      child: Text(
                        'No ratings yet',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: context.fs(9),
                          color: Colors.grey[400],
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: isOnline
                      ? AppColors.success.withOpacity(0.1)
                      : Colors.grey.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  isOnline ? '● Online' : '○ Offline',
                  style: TextStyle(
                    fontSize: context.fs(10),
                    fontWeight: FontWeight.w500,
                    color: isOnline ? AppColors.success : Colors.grey[600],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Entry point for starting a NEW chat with a doctor.
  ///
  /// See the identically named method on `DoctorList` — the live Firestore
  /// re-check is what enforces "a deleted doctor cannot receive a new
  /// consultation" rather than merely hiding them from the list.
  Future<void> _navigateToChat(Map<String, dynamic> doctor) async {
    final currentUser = ref.read(userProvider);

    if (currentUser == null || currentUser.isGuest) {
      GuestGuard.showLoginPrompt(
        context,
        message: 'Please log in to chat with doctors.',
      );
      return;
    }

    final doctorId = (doctor['id'] ?? '').toString();
    if (doctorId.isEmpty) return;

    final blockedReason = await SoftDeleteService.newBusinessBlockedReason(
      doctorId,
    );
    if (!mounted) return;
    if (blockedReason != null) {
      ToastService.instance.showError(blockedReason);
      return;
    }

    // Use centralized presence — same source as Chat List and Chat Screen
    final isOnline = ref.read(doctorOnlineProvider(doctorId));
    if (!isOnline) {
      ToastService.instance.showInfo(
        '${doctor['fullname'] ?? 'Doctor'} is offline. They will respond when online.',
      );
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChatScreen(
          otherUserId: doctorId,
          otherUserName: doctor['fullname'] ?? 'Doctor',
          otherUserImage: doctor['imageUrl'] ?? '',
        ),
      ),
    );
  }
}
