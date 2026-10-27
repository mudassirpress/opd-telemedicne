import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/data/models/chat_model.dart';
import 'package:telemedicine/features/chat/presentation/doc/document_viewer_helper.dart';
import 'package:telemedicine/shared/widgets/opd_design_system.dart';
import 'package:url_launcher/url_launcher.dart';

enum _MediaTab { media, links, docs }

/// Browses everything shared inside the current conversation, grouped into
/// Media / Links / Docs categories using the same metallic segmented selector
/// as the Sign In role tabs.
///
/// Everything is derived from the in-memory message list the chat screen
/// already holds, so no additional Firestore read is performed.
class ChatMediaScreen extends StatefulWidget {
  final List<ChatMessageModel> messages;
  final String currentUserId;

  const ChatMediaScreen({
    super.key,
    required this.messages,
    required this.currentUserId,
  });

  @override
  State<ChatMediaScreen> createState() => _ChatMediaScreenState();
}

class _ChatMediaScreenState extends State<ChatMediaScreen> {
  _MediaTab _tab = _MediaTab.media;

  static final RegExp _urlPattern = RegExp(
    r'((https?:\/\/|www\.)[^\s<>"“”]+)',
    caseSensitive: false,
  );

  static const Map<_MediaTab, ({String label, IconData icon})> _tabs = {
    _MediaTab.media: (label: 'Media', icon: Icons.photo_library_rounded),
    _MediaTab.links: (label: 'Links', icon: Icons.link_rounded),
    _MediaTab.docs: (label: 'Docs', icon: Icons.insert_drive_file_rounded),
  };

  List<ChatMessageModel> get _media => widget.messages
      .where((m) =>
          !m.isDeleted &&
          (m.mediaUrl ?? '').isNotEmpty &&
          const {'image', 'video', 'audio', 'call_recording'}
              .contains(m.messageType))
      .toList()
    ..sort((a, b) => b.timestamp.compareTo(a.timestamp));

  List<ChatMessageModel> get _docs => widget.messages
      .where((m) =>
          !m.isDeleted &&
          (m.mediaUrl ?? '').isNotEmpty &&
          const {'document', 'forwarded_report'}.contains(m.messageType))
      .toList()
    ..sort((a, b) => b.timestamp.compareTo(a.timestamp));

  List<({String url, ChatMessageModel message})> get _links {
    final results = <({String url, ChatMessageModel message})>[];
    for (final message in widget.messages) {
      if (message.isDeleted) continue;
      for (final match in _urlPattern.allMatches(message.message)) {
        results.add((url: match.group(0)!, message: message));
      }
    }
    results.sort((a, b) => b.message.timestamp.compareTo(a.message.timestamp));
    return results;
  }

  @override
  Widget build(BuildContext context) {
    return OpdScreenShell(
      scrollable: false,
      title: 'Shared Items',
      subtitle: 'Media, links and documents shared in this conversation.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OpdSegmentedSelector<_MediaTab>(
            options: [
              for (final entry in _tabs.entries)
                (
                  value: entry.key,
                  label: entry.value.label,
                  icon: entry.value.icon,
                ),
            ],
            selected: _tab,
            onChanged: (value) => setState(() => _tab = value),
          ),
          SizedBox(height: context.rsp(20)),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              child: switch (_tab) {
                _MediaTab.media => _buildMediaTab(),
                _MediaTab.links => _buildLinksTab(),
                _MediaTab.docs => _buildDocsTab(),
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMediaTab() {
    final media = _media;
    if (media.isEmpty) {
      return const OpdEmptyState(
        key: ValueKey('empty-media'),
        icon: Icons.photo_library_rounded,
        title: 'No media shared',
        subtitle:
            'Photos, videos and voice notes shared in this chat will appear here.',
      );
    }
    final crossAxisCount = (context.sw / 120).floor().clamp(2, 4).toInt();
    return GridView.builder(
      key: const ValueKey('grid-media'),
      physics: const BouncingScrollPhysics(),
      padding: EdgeInsets.zero,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: media.length,
      itemBuilder: (context, index) {
        final message = media[index];
        return _MediaTile(
          message: message,
          onTap: () => _openMedia(message),
        );
      },
    );
  }

  Widget _buildLinksTab() {
    final links = _links;
    if (links.isEmpty) {
      return const OpdEmptyState(
        key: ValueKey('empty-links'),
        icon: Icons.link_rounded,
        title: 'No links shared',
        subtitle: 'Links shared in this conversation will appear here.',
      );
    }
    return ListView.separated(
      key: const ValueKey('list-links'),
      physics: const BouncingScrollPhysics(),
      padding: EdgeInsets.zero,
      itemCount: links.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final link = links[index];
        return _LinkTile(
          url: link.url,
          timestamp: link.message.timestamp,
          onTap: () => _launchUrl(link.url),
        );
      },
    );
  }

  Widget _buildDocsTab() {
    final docs = _docs;
    if (docs.isEmpty) {
      return const OpdEmptyState(
        key: ValueKey('empty-docs'),
        icon: Icons.insert_drive_file_rounded,
        title: 'No documents shared',
        subtitle:
            'Files and medical reports shared in this chat will appear here.',
      );
    }
    return ListView.separated(
      key: const ValueKey('list-docs'),
      physics: const BouncingScrollPhysics(),
      padding: EdgeInsets.zero,
      itemCount: docs.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final message = docs[index];
        return _DocTile(
          fileName: (message.fileName ?? '').isNotEmpty
              ? message.fileName!
              : message.message,
          isReport: message.messageType == 'forwarded_report',
          timestamp: message.timestamp,
          onTap: () => _openDoc(message),
        );
      },
    );
  }

  Future<void> _openMedia(ChatMessageModel message) async {
    final url = message.mediaUrl;
    if (url == null || url.isEmpty) return;

    if (message.messageType != 'image') {
      await _launchUrl(url);
      return;
    }

    await showDialog<void>(
      context: context,
      barrierColor: const Color(0xFF0B2041).withValues(alpha: 0.88),
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: EdgeInsets.zero,
        child: Stack(
          children: [
            Center(
              child: InteractiveViewer(
                child: Image.network(
                  url,
                  errorBuilder: (_, __, ___) => const Icon(
                    Icons.broken_image_rounded,
                    color: Colors.white,
                    size: 48,
                  ),
                ),
              ),
            ),
            Positioned(
              top: 40,
              right: 16,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 28),
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openDoc(ChatMessageModel message) async {
    final url = message.mediaUrl;
    if (url == null || url.isEmpty) return;
    final fileName = (message.fileName ?? '').isNotEmpty
        ? message.fileName!
        : 'shared_document';
    await DocumentViewerHelper.openDocument(
      documentUrl: url,
      fileName: fileName,
      context: context,
    );
  }

  Future<void> _launchUrl(String url) async {
    try {
      final uri = Uri.parse(url.startsWith('http') ? url : 'https://$url');
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        ToastService.instance.showError('Cannot open this link');
      }
    } catch (e) {
      ToastService.instance.showError('Could not open link');
    }
  }
}

class _MediaTile extends StatelessWidget {
  final ChatMessageModel message;
  final VoidCallback onTap;

  const _MediaTile({required this.message, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isImage = message.messageType == 'image';
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: OpdCard(
          padding: EdgeInsets.zero,
          radius: 14,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(13),
            child: isImage
                ? Image.network(
                    message.mediaUrl!,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const Center(
                      child: Icon(
                        Icons.broken_image_rounded,
                        color: Color(0xFF7E90A6),
                      ),
                    ),
                  )
                : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _iconFor(message.messageType),
                        color: const Color(0xFF062B72),
                        size: 24,
                      ),
                      const SizedBox(height: 4),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Text(
                          _labelFor(message.messageType),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: const Color(0xFF062B72),
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  static IconData _iconFor(String type) {
    switch (type) {
      case 'video':
        return Icons.videocam_rounded;
      case 'audio':
        return Icons.mic_rounded;
      case 'call_recording':
        return Icons.graphic_eq_rounded;
      default:
        return Icons.perm_media_rounded;
    }
  }

  static String _labelFor(String type) {
    switch (type) {
      case 'video':
        return 'Video';
      case 'audio':
        return 'Voice';
      case 'call_recording':
        return 'Recording';
      default:
        return 'Media';
    }
  }
}

class _LinkTile extends StatelessWidget {
  final String url;
  final DateTime timestamp;
  final VoidCallback onTap;

  const _LinkTile({
    required this.url,
    required this.timestamp,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return OpdCard(
      onTap: onTap,
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: const Color(0xFFF0F4FA),
              borderRadius: BorderRadius.circular(13),
              border: Border.all(color: const Color(0xFFDCE6F2)),
            ),
            child: const Icon(
              Icons.link_rounded,
              size: 20,
              color: Color(0xFF0E274D),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  url,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: context.fs(13),
                    height: 1.35,
                    color: const Color(0xFF1F2F44),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  DateFormat('dd MMM yyyy • hh:mm a').format(timestamp),
                  style: TextStyle(
                    fontSize: context.fs(11),
                    fontWeight: FontWeight.w500,
                    color: const Color(0xFF7E90A6),
                  ),
                ),
              ],
            ),
          ),
          const Icon(
            Icons.open_in_new_rounded,
            size: 18,
            color: Color(0xFF7E90A6),
          ),
        ],
      ),
    );
  }
}

class _DocTile extends StatelessWidget {
  final String fileName;
  final bool isReport;
  final DateTime timestamp;
  final VoidCallback onTap;

  const _DocTile({
    required this.fileName,
    required this.isReport,
    required this.timestamp,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final accent = isReport ? const Color(0xFFE53935) : const Color(0xFF0E274D);
    return OpdCard(
      onTap: onTap,
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(13),
              border: Border.all(color: const Color(0xFFDCE6F2)),
            ),
            child: Icon(
              isReport
                  ? Icons.medical_information_rounded
                  : Icons.insert_drive_file_rounded,
              size: 22,
              color: accent,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isReport && !fileName.contains('.')
                      ? 'Medical Report'
                      : fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: context.fs(14),
                    fontWeight: FontWeight.w500,
                    color: const Color(0xFF1F2F44),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  DateFormat('dd MMM yyyy • hh:mm a').format(timestamp),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: context.fs(11),
                    fontWeight: FontWeight.w500,
                    color: const Color(0xFF7E90A6),
                  ),
                ),
              ],
            ),
          ),
          const Icon(
            Icons.chevron_right_rounded,
            size: 22,
            color: Color(0xFFBAC6D5),
          ),
        ],
      ),
    );
  }
}
