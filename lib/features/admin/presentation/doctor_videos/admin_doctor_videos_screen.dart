import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/features/admin/presentation/admin_design_system.dart';
import 'package:telemedicine/features/auth/presentation/controllers/doctor_controller.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/features/doctor_videos/presentation/doctor_video_controller.dart';

/// Admin → Doctor Videos: assign, update or remove a doctor's introduction
/// video. Built entirely from the existing Admin/OPD design system.
class AdminDoctorVideosScreen extends ConsumerStatefulWidget {
  const AdminDoctorVideosScreen({super.key});

  @override
  ConsumerState<AdminDoctorVideosScreen> createState() =>
      _AdminDoctorVideosScreenState();
}

class _AdminDoctorVideosScreenState
    extends ConsumerState<AdminDoctorVideosScreen> {
  String? _selectedDoctorId;
  Map<String, dynamic>? _selectedDoctor;
  final TextEditingController _urlController = TextEditingController();
  bool _saving = false;

  DoctorController? _doctorController;
  Stream<List<Map<String, dynamic>>>? _doctorStream;

  @override
  void initState() {
    super.initState();
    _doctorController = ref.read(doctorControllerProvider);
    _doctorStream = _doctorController?.streamAllDoctors();
  }

  @override
  void dispose() {
    _doctorController?.disposeDoctorListStream();
    _urlController.dispose();
    super.dispose();
  }

  Map<String, dynamic>? _findDoctor(List<Map<String, dynamic>> doctors, String? id) {
    if (id == null) return null;
    for (final d in doctors) {
      if ((d['id'] ?? '').toString() == id) return d;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return AdminScreen(
      title: 'Doctor Videos',
      subtitle: 'Assign introduction videos to doctors',
      showBack: true,
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: _doctorStream,
        builder: (context, snapshot) {
          // A stream error with nothing cached used to fall through to the
          // "No doctors found" empty state. Only swap in the error state when
          // there is genuinely nothing to render.
          if (snapshot.hasError && snapshot.data == null &&
              (_doctorController?.cachedDoctors ?? const []).isEmpty) {
            return AdminErrorState(
              message: 'Could not load doctors. Check your connection.',
              onRetry: () => setState(() {
                // Balanced with the +1 taken in initState: the shared
                // streamAllDoctors() controller is ref-counted.
                _doctorController?.disposeDoctorListStream();
                _doctorStream = _doctorController?.streamAllDoctors();
              }),
            );
          }
          final doctors = snapshot.data ?? _doctorController?.cachedDoctors ?? const [];
          if (_selectedDoctorId == null && doctors.isNotEmpty) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              setState(() {
                _selectedDoctorId = doctors.first['id'].toString();
                _selectedDoctor = doctors.first;
                _urlController.text =
                    (doctors.first['youtubeVideoUrl'] ?? '').toString();
              });
            });
          }
          _selectedDoctor = _findDoctor(doctors, _selectedDoctorId);

          return SingleChildScrollView(
            padding: EdgeInsets.all(context.rsp(16)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const AdminSectionTitle(
                  icon: Icons.video_library_rounded,
                  title: 'Select a doctor',
                  subtitle: 'Choose which doctor gets an introduction video.',
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 132 * context.textScale,
                  child: doctors.isEmpty
                      ? const AdminEmptyState(
                          icon: Icons.person_off_rounded,
                          title: 'No doctors found',
                        )
                      : ListView.builder(
                          scrollDirection: Axis.horizontal,
                          itemCount: doctors.length,
                          itemBuilder: (context, index) {
                            final doctor = doctors[index];
                            final id = (doctor['id'] ?? '').toString();
                            final selected = id == _selectedDoctorId;
                            final image = (doctor['imageUrl'] ?? '').toString();
                            return GestureDetector(
                              onTap: () => setState(() {
                                _selectedDoctorId = id;
                                _selectedDoctor = doctor;
                                _urlController.text =
                                    (doctor['youtubeVideoUrl'] ?? '').toString();
                              }),
                              child: Container(
                                width: 150,
                                margin: const EdgeInsets.only(right: 12),
                                padding: EdgeInsets.all(context.rsp(12)),
                                decoration: BoxDecoration(
                                  gradient: AdminPalette.cardGradient,
                                  borderRadius: BorderRadius.circular(18),
                                  border: Border.all(
                                    color: selected
                                        ? AdminPalette.brand
                                        : AdminPalette.cardBorder,
                                    width: selected ? 2 : 1,
                                  ),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    CircleAvatar(
                                      radius: 18,
                                      backgroundColor:
                                          AdminPalette.brand.withValues(alpha: 0.1),
                                      backgroundImage: image.isNotEmpty
                                          ? CachedNetworkImageProvider(image)
                                          : null,
                                      child: image.isEmpty
                                          ? Icon(Icons.person,
                                              color: AdminPalette.brand)
                                          : null,
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      (doctor['fullname'] ?? 'Doctor').toString(),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: context.fs(12.5),
                                        fontWeight: FontWeight.w600,
                                        color: selected
                                            ? AdminPalette.brand
                                            : AdminPalette.textPrimary,
                                      ),
                                    ),
                                    Text(
                                      'ID: ${(doctor['doctorId'] ?? 'N/A')}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: AdminTextStyles.small(size: 10),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
                const SizedBox(height: 18),
                if (_selectedDoctor != null) ...[
                  AdminCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            CircleAvatar(
                              radius: 22,
                              backgroundImage: (_selectedDoctor!['imageUrl'] ?? '')
                                      .toString()
                                      .isNotEmpty
                                  ? CachedNetworkImageProvider(
                                      _selectedDoctor!['imageUrl'].toString())
                                  : null,
                              child: (_selectedDoctor!['imageUrl'] ?? '')
                                      .toString()
                                      .isEmpty
                                  ? Icon(Icons.person, color: AdminPalette.brand)
                                  : null,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Dr. ${(_selectedDoctor!['fullname'] ?? '').toString()}',
                                    style: AdminTextStyles.heading(
                                        size: context.fs(14.5)),
                                  ),
                                  Text(
                                    'ID: ${(_selectedDoctor!['doctorId'] ?? 'N/A')} • ${(_selectedDoctor!['highestDegree'] ?? 'General Physician')}',
                                    style: AdminTextStyles.small(size: 11.5),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        AdminInfoRow(
                          icon: Icons.link_rounded,
                          label: 'Current video',
                          value: (_selectedDoctor!['youtubeVideoUrl'] ?? '')
                                  .toString()
                                  .isEmpty
                              ? 'None assigned'
                              : _selectedDoctor!['youtubeVideoUrl'].toString(),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          'YouTube video URL',
                          style: AdminTextStyles.heading(size: context.fs(13)),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                            gradient: AdminPalette.inputOuterGradient,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                                color: AdminPalette.inputOuterBorder,
                                width: 1.5),
                          ),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 10),
                            decoration: BoxDecoration(
                              gradient: AdminPalette.inputInnerGradient,
                              borderRadius: BorderRadius.circular(11),
                            ),
                            child: TextFormField(
                              controller: _urlController,
                              style: TextStyle(
                                fontSize: context.fs(13),
                                color: AdminPalette.textInput,
                              ),
                              decoration: InputDecoration(
                                hintText:
                                    'https://www.youtube.com/watch?v=...',
                                hintStyle: TextStyle(
                                  color: AdminPalette.textMuted,
                                  fontSize: context.fs(12.5),
                                ),
                                border: InputBorder.none,
                                isDense: true,
                                contentPadding: EdgeInsets.zero,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                        AdminPrimaryButton(
                          label: _saving ? 'Saving...' : 'Assign / Update Video',
                          icon: Icons.check_rounded,
                          isLoading: _saving,
                          onPressed: _saving ? null : _save,
                        ),
                        const SizedBox(height: 10),
                        AdminOutlineButton(
                          label: 'Remove Video',
                          icon: Icons.delete_outline_rounded,
                          color: AdminPalette.error,
                          onPressed: _saving ? null : _remove,
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _save() async {
    if (_selectedDoctorId == null) return;
    setState(() => _saving = true);
    final error = await ref.read(doctorVideoControllerProvider).saveVideo(
          doctorId: _selectedDoctorId!,
          youtubeUrl: _urlController.text,
        );
    if (!mounted) return;
    setState(() => _saving = false);
    if (error != null) {
      ToastService.instance.showError(error);
    } else {
      ToastService.instance.showSuccess('Doctor video saved');
    }
  }

  Future<void> _remove() async {
    if (_selectedDoctorId == null) return;
    setState(() => _saving = true);
    final error = await ref
        .read(doctorVideoControllerProvider)
        .removeVideo(_selectedDoctorId!);
    if (!mounted) return;
    setState(() {
      _saving = false;
      _urlController.clear();
    });
    if (error != null) {
      ToastService.instance.showError(error);
    } else {
      ToastService.instance.showSuccess('Doctor video removed');
    }
  }
}
