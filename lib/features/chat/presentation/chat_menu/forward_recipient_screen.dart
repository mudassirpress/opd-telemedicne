import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/features/auth/presentation/controllers/doctor_controller.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/core/services/soft_delete_service.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/data/models/chat_model.dart';
import 'package:telemedicine/data/repositories/patient_repository.dart';
import 'package:telemedicine/features/chat/presentation/chat_action/message_action_rules.dart';
import 'package:telemedicine/features/chat/presentation/controllers/chat_controller.dart';
import 'package:telemedicine/shared/widgets/auth_layout.dart';
import 'package:telemedicine/shared/widgets/opd_design_system.dart';

/// Pick who to forward one or more chat messages to.
///
/// A doctor forwards to patients, a patient forwards to doctors — the same
/// direction rules the rest of the app uses. The actual send happens here so
/// the chat screen only has to wait for a yes/no result, and the soft-delete
/// gate runs before anything is queued.
class ForwardRecipientScreen extends ConsumerStatefulWidget {
  const ForwardRecipientScreen({
    super.key,
    required this.currentUserId,
    required this.currentUserRole,
    required this.messages,
  });

  final String currentUserId;
  final String currentUserRole;
  final List<ChatMessageModel> messages;

  @override
  ConsumerState<ForwardRecipientScreen> createState() =>
      _ForwardRecipientScreenState();
}

class _ForwardRecipientScreenState
    extends ConsumerState<ForwardRecipientScreen> {
  List<Map<String, dynamic>> _recipients = const [];
  Map<String, dynamic>? _selected;
  bool _loading = true;
  bool _loadFailed = false;
  bool _isSending = false;

  bool get _isDoctor => widget.currentUserRole == UserRoles.doctor;

  int get _count => widget.messages.length;

  @override
  void initState() {
    super.initState();
    _loadRecipients();
  }

  Future<void> _loadRecipients() async {
    setState(() {
      _loading = true;
      _loadFailed = false;
    });
    try {
      final recipients = _isDoctor
          ? await _loadPatients()
          : await _loadDoctors();
      if (!mounted) return;
      setState(() {
        _recipients = recipients;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadFailed = true;
        _loading = false;
      });
    }
  }

  /// All active patients — the pool a doctor may forward into.
  Future<List<Map<String, dynamic>>> _loadPatients() async {
    final snapshots = await PatientRepository().getAllPatients();
    final recipients = <Map<String, dynamic>>[];
    for (final doc in snapshots) {
      final data = doc.data() as Map<String, dynamic>? ?? const {};
      if (!SoftDeleteService.isActive(data)) continue;
      if (doc.id == widget.currentUserId) continue;
      recipients.add({
        'id': doc.id,
        'name': (data['fullname'] ?? data['name'] ?? 'Patient').toString(),
        'image': (data['imageUrl'] ?? data['image'] ?? '').toString(),
        'role': UserRoles.patient,
      });
    }
    recipients.sort(
      (a, b) => (a['name'] as String).compareTo(b['name'] as String),
    );
    return recipients;
  }

  /// All active doctors — the pool a patient may forward into. Soft-deleted
  /// doctors are already filtered by the shared doctor stream.
  Future<List<Map<String, dynamic>>> _loadDoctors() async {
    final doctors = await ref
        .read(doctorControllerProvider)
        .streamAllDoctors()
        .first
        .timeout(const Duration(seconds: 20));
    final recipients = <Map<String, dynamic>>[];
    for (final data in doctors) {
      final id = (data['id'] ?? '').toString();
      if (id.isEmpty || id == widget.currentUserId) continue;
      recipients.add({
        'id': id,
        'name': (data['fullname'] ?? 'Doctor').toString(),
        'image': (data['imageUrl'] ?? '').toString(),
        'role': UserRoles.doctor,
      });
    }
    recipients.sort(
      (a, b) => (a['name'] as String).compareTo(b['name'] as String),
    );
    return recipients;
  }

  Future<void> _send() async {
    final selected = _selected;
    if (selected == null || _isSending) return;
    final recipientId = (selected['id'] ?? '').toString();

    if (!MessageActionRules.isValidForwardTarget(
      senderId: widget.currentUserId,
      recipientId: recipientId,
    )) {
      ToastService.instance.showError('Choose a different recipient');
      return;
    }

    setState(() => _isSending = true);

    // Re-check the live state: the list was built when this screen opened.
    final blocked = await SoftDeleteService.newBusinessBlockedReason(
      recipientId,
    );
    if (blocked != null) {
      if (!mounted) return;
      ToastService.instance.showError(blocked);
      Navigator.pop(context, false);
      return;
    }

    try {
      await ChatController().forwardMessages(
        senderId: widget.currentUserId,
        receiverId: recipientId,
        messages: widget.messages,
        receiverRole: (selected['role'] ?? '').toString(),
      );
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSending = false);
      ToastService.instance.showError(
        e is ChatNotAvailableException
            ? e.reason
            : 'Could not forward the message',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final roleLabel = _isDoctor ? 'patient' : 'doctor';
    return OpdScreenShell(
      title: 'Forward to',
      subtitle: _count == 1
          ? 'Choose a $roleLabel to forward this message to.'
          : 'Choose a $roleLabel to forward $_count messages to.',
      scrollable: false,
      bottom: GradientButton(
        text: _isSending ? 'Forwarding...' : 'Forward',
        isLoading: _isSending,
        icon: Icons.forward_rounded,
        onPressed: _selected == null || _isSending ? null : _send,
      ),
      child: _buildBody(roleLabel),
    );
  }

  Widget _buildBody(String roleLabel) {
    if (_loading) {
      return const OpdInlineLoader(label: 'Loading recipients...');
    }
    if (_loadFailed) {
      return OpdEmptyState(
        icon: Icons.wifi_off_rounded,
        title: 'Could not load recipients',
        subtitle: 'Check your connection and try again.',
        action: TextButton(
          onPressed: _loadRecipients,
          child: const Text('Retry'),
        ),
      );
    }
    if (_recipients.isEmpty) {
      return OpdEmptyState(
        icon: Icons.people_outline_rounded,
        title: 'No ${roleLabel}s to forward to',
        subtitle: 'Start a conversation with a $roleLabel first.',
      );
    }

    return ListView.separated(
      itemCount: _recipients.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final recipient = _recipients[index];
        final selectedId = _selected?['id'];
        final isSelected = selectedId == recipient['id'];
        return _RecipientTile(
          recipient: recipient,
          isSelected: isSelected,
          onTap: () => setState(() => _selected = recipient),
        );
      },
    );
  }
}

/// One tappable recipient row, ticked when selected.
class _RecipientTile extends StatelessWidget {
  const _RecipientTile({
    required this.recipient,
    required this.isSelected,
    required this.onTap,
  });

  final Map<String, dynamic> recipient;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final name = (recipient['name'] ?? '').toString();
    final image = (recipient['image'] ?? '').toString();
    final isDoctor = recipient['role'] == UserRoles.doctor;

    return OpdCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Row(
          children: [
            CircleAvatar(
              radius: 22,
              backgroundColor: const Color(0xFFD6E4F0),
              backgroundImage: image.isNotEmpty ? NetworkImage(image) : null,
              child: image.isEmpty
                  ? Text(
                      name.isEmpty ? '?' : name[0].toUpperCase(),
                      style: TextStyle(
                        color: const Color(0xFF062B72),
                        fontWeight: FontWeight.w700,
                        fontSize: context.fs(15),
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isDoctor && !name.startsWith('Dr') ? 'Dr. $name' : name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: context.fs(14.5),
                      color: const Color(0xFF1F2F44),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    isDoctor ? 'Doctor' : 'Patient',
                    style: TextStyle(
                      fontSize: context.fs(11.5),
                      color: const Color(0xFF6B7B8D),
                    ),
                  ),
                ],
              ),
            ),
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isSelected ? const Color(0xFF062B72) : Colors.white,
                border: Border.all(
                  color: isSelected
                      ? const Color(0xFF062B72)
                      : const Color(0xFFBAC7D8),
                  width: 1.5,
                ),
              ),
              child: isSelected
                  ? const Icon(
                      Icons.check_rounded,
                      size: 16,
                      color: Colors.white,
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}
