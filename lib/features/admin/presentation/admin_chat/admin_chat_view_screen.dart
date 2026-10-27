// admin_chat_view_screen.dart
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:telemedicine/features/chat/presentation/controllers/chat_controller.dart';
import 'package:telemedicine/data/models/chat_model.dart';
import 'package:intl/intl.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';

class AdminChatViewScreen extends ConsumerStatefulWidget {
  final String patientId;
  final String patientName;
  final String patientImage;
  final String doctorId;
  final String doctorName;
  final String adminId;
  final String adminName;
  final String chatId;

  const AdminChatViewScreen({
    super.key,
    required this.patientId,
    required this.patientName,
    required this.patientImage,
    required this.doctorId,
    required this.doctorName,
    required this.adminId,
    required this.adminName,
    required this.chatId,
  });

  @override
  ConsumerState<AdminChatViewScreen> createState() =>
      _AdminChatViewScreenState();
}

class _AdminChatViewScreenState extends ConsumerState<AdminChatViewScreen> {
  final TextEditingController _messageController = TextEditingController();
  final ChatController _chatController = ChatController();
  final ScrollController _scrollController = ScrollController();
  bool _isSending = false;
  bool _isDownloading = false;

  // Created once: getMessages() opens a Firestore listener per call, and the
  // old code invoked it inside build() — every setState (_isSending,
  // _isDownloading) tore the subscription down and resubscribed.
  late final Stream<List<ChatMessageModel>> _messagesStream;

  @override
  void initState() {
    super.initState();
    _messagesStream = _chatController.getMessages(
      widget.doctorId,
      widget.patientId,
    );
  }

  static const Color _brand = Color(0xFF062B72);
  static const Color _brandLight = Color(0xFF1A3F8A);
  static const List<Color> _brandGradient = [
    Color(0xFF284F85),
    Color(0xFF15386A),
    Color(0xFF0D264E),
    Color(0xFF081938),
  ];

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _sendAdminMessage() async {
    if (_messageController.text.trim().isEmpty || _isSending) return;

    setState(() => _isSending = true);
    final message = _messageController.text.trim();
    _messageController.clear();

    try {
      await _chatController.sendAdminMessage(
        adminId: widget.adminId,
        adminName: widget.adminName,
        doctorId: widget.doctorId,
        patientId: widget.patientId,
        message: message,
        messageType: 'text',
      );
      _scrollToBottom();
      ToastService.instance.showSuccess('Message sent successfully');
    } catch (e) {
      if (mounted) {
        ToastService.instance.showError(
          'Failed to send message: ${e.toString()}',
        );
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _downloadAndOpenFile(String url, String fileName) async {
    if (_isDownloading) return;

    setState(() => _isDownloading = true);

    try {
      ToastService.instance.showInfo('Downloading file...');

      final response = await http.get(Uri.parse(url));

      if (response.statusCode == 200) {
        final directory = await getTemporaryDirectory();
        final filePath = '${directory.path}/$fileName';
        final file = File(filePath);

        if (await file.exists()) {
          await file.delete();
        }

        await file.writeAsBytes(response.bodyBytes);

        if (await file.exists()) {
          ToastService.instance.showSuccess('File downloaded, opening...');
          final result = await OpenFile.open(filePath);

          if (result.type != ResultType.done) {
            if (result.type == ResultType.noAppToOpen) {
              ToastService.instance.showError(
                'No app found to open this file type',
              );
            } else {
              ToastService.instance.showError(
                'Could not open file: ${result.message}',
              );
            }
          }
        }
      } else {
        ToastService.instance.showError(
          'Failed to download file (${response.statusCode})',
        );
      }
    } catch (e) {
      ToastService.instance.showError('Error: ${e.toString()}');
    } finally {
      if (mounted) setState(() => _isDownloading = false);
    }
  }

  void _showFullScreenImage(String imageUrl) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            elevation: 0,
            leading: IconButton(
              icon: const Icon(Icons.close, color: Colors.white),
              onPressed: () => Navigator.pop(context),
            ),
          ),
          body: Center(
            child: InteractiveViewer(child: Image.network(imageUrl)),
          ),
        ),
      ),
    );
  }

  IconData _getDocumentIcon(String fileName) {
    final extension = fileName.split('.').last.toUpperCase();
    switch (extension) {
      case 'PDF':
        return Icons.picture_as_pdf;
      case 'DOC':
      case 'DOCX':
        return Icons.description;
      case 'XLS':
      case 'XLSX':
        return Icons.table_chart;
      case 'TXT':
        return Icons.text_snippet;
      case 'JPG':
      case 'JPEG':
      case 'PNG':
      case 'GIF':
        return Icons.image;
      default:
        return Icons.insert_drive_file;
    }
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final difference = now.difference(time);

    if (difference.inMinutes < 1) return 'Just now';
    if (difference.inHours < 1) return '${difference.inMinutes}m';
    if (difference.inDays < 1) return '${difference.inHours}h';
    return DateFormat('h:mm a').format(time);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEDF2F8),
      appBar: AppBar(
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: _brandGradient,
            ),
          ),
        ),
        title: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${widget.patientName} & ${widget.doctorName}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: context.fs(15),
                    ),
                  ),
                  Text(
                    'Admin Viewing Mode',
                    style: TextStyle(color: Colors.white70, fontSize: 11),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 12),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.admin_panel_settings,
                  size: 16,
                  color: Colors.white,
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    widget.adminName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      body: Container(
        decoration: const BoxDecoration(
          image: DecorationImage(
            image: AssetImage('assets/images/download.jpeg'),
            fit: BoxFit.cover,
            opacity: 0.1,
          ),
        ),
        child: Column(
          children: [
            // Admin info banner
            Container(
              padding: EdgeInsets.symmetric(
                horizontal: context.rsp(16),
                vertical: 8,
              ),
              color: const Color(0xFFFFF3CD),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 16,
                    color: const Color(0xFFB7791F),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'You are viewing as Admin. Your messages will be visible to both ${widget.patientName} and ${widget.doctorName}.',
                      style: TextStyle(
                        fontSize: 11,
                        color: const Color(0xFF74410F),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: StreamBuilder<List<ChatMessageModel>>(
                stream: _messagesStream,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.error_outline,
                            size: 60,
                            color: const Color(0xFF9AA8BC),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'Error loading messages',
                            style: TextStyle(color: const Color(0xFF657991)),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '${snapshot.error}',
                            style: TextStyle(
                              fontSize: 12,
                              color: const Color(0xFF7E90A6),
                            ),
                          ),
                        ],
                      ),
                    );
                  }

                  if (!snapshot.hasData) {
                    return const Center(
                      child: CircularProgressIndicator(color: _brand),
                    );
                  }

                  final messages = snapshot.data!;

                  if (messages.isEmpty) {
                    return const Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.chat_bubble_outline,
                            size: 60,
                            color: Color(0xFF9AA8BC),
                          ),
                          SizedBox(height: 16),
                          Text(
                            'No messages yet',
                            style: TextStyle(color: Color(0xFF657991)),
                          ),
                          Text(
                            'This conversation will appear once they start chatting',
                            style: TextStyle(
                              fontSize: 12,
                              color: Color(0xFF7E90A6),
                            ),
                          ),
                        ],
                      ),
                    );
                  }

                  return ListView.builder(
                    controller: _scrollController,
                    padding: EdgeInsets.symmetric(
                      horizontal: context.rsp(16),
                      vertical: 20,
                    ),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final message = messages[index];
                      final isAdminMessage = message.isAdminMessage == true;
                      final isFromDoctor = message.senderId == widget.doctorId;

                      return _buildMessageBubble(
                        message,
                        isFromDoctor,
                        isAdminMessage,
                      );
                    },
                  );
                },
              ),
            ),
            _buildAdminMessageInput(),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageBubble(
    ChatMessageModel message,
    bool isFromDoctor,
    bool isAdminMessage,
  ) {
    // Handle admin messages
    if (isAdminMessage) {
      return Container(
        margin: const EdgeInsets.only(bottom: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              constraints: BoxConstraints(
                maxWidth: math.min(context.sw * 0.78, 460),
              ),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF8E1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFFFE082)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.admin_panel_settings,
                    size: 16,
                    color: Color(0xFFB7791F),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '👑 Admin ${message.adminName ?? 'Message'}',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: const Color(0xFFB7791F),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          message.message,
                          style: TextStyle(
                            fontSize: context.fs(13.5),
                            color: Colors.black87,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 12, top: 4),
              child: Text(
                _formatTime(message.timestamp),
                style: TextStyle(
                  fontSize: context.fs(10),
                  color: const Color(0xFF7E90A6),
                ),
              ),
            ),
          ],
        ),
      );
    }

    // Handle image messages
    if (message.messageType == 'image' && message.mediaUrl != null) {
      return _buildImageBubble(message, isFromDoctor);
    }

    // Handle document messages
    if (message.messageType == 'document' && message.mediaUrl != null) {
      return _buildDocumentBubble(message, isFromDoctor);
    }

    // Handle call messages
    if (message.messageType == 'audio' || message.messageType == 'video') {
      return _buildCallBubble(message, isFromDoctor);
    }

    // Regular text message
    return Align(
      alignment: isFromDoctor ? Alignment.centerLeft : Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        constraints: BoxConstraints(maxWidth: math.min(context.sw * 0.78, 460)),
        child: Column(
          crossAxisAlignment: isFromDoctor
              ? CrossAxisAlignment.start
              : CrossAxisAlignment.end,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 8, bottom: 2),
              child: Text(
                isFromDoctor ? widget.doctorName : widget.patientName,
                style: TextStyle(
                  fontSize: 10,
                  color: const Color(0xFF657991),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: isFromDoctor ? Colors.white : _brand,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(isFromDoctor ? 0 : 12),
                  topRight: Radius.circular(isFromDoctor ? 12 : 0),
                  bottomLeft: const Radius.circular(12),
                  bottomRight: const Radius.circular(12),
                ),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF12263F).withValues(alpha: 0.08),
                    blurRadius: 8,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    message.message,
                    style: TextStyle(
                      color: isFromDoctor ? Colors.black87 : Colors.white,
                      fontSize: context.fs(13.5),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (message.isEdited)
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: Text(
                            'edited',
                            style: TextStyle(
                              color: isFromDoctor
                                  ? const Color(0xFF7E90A6)
                                  : Colors.white60,
                              fontSize: 9,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ),
                      Text(
                        _formatTime(message.timestamp),
                        style: TextStyle(
                          color: isFromDoctor
                              ? const Color(0xFF7E90A6)
                              : Colors.white70,
                          fontSize: context.fs(10),
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
    );
  }

  Widget _buildImageBubble(ChatMessageModel message, bool isFromDoctor) {
    final double imageSize = math.min(context.sw * 0.5, 200);
    return Align(
      alignment: isFromDoctor ? Alignment.centerLeft : Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        constraints: BoxConstraints(maxWidth: math.min(context.sw * 0.78, 460)),
        child: Column(
          crossAxisAlignment: isFromDoctor
              ? CrossAxisAlignment.start
              : CrossAxisAlignment.end,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 8, bottom: 2),
              child: Text(
                isFromDoctor ? widget.doctorName : widget.patientName,
                style: TextStyle(
                  fontSize: 10,
                  color: const Color(0xFF657991),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            GestureDetector(
              onTap: () => _showFullScreenImage(message.mediaUrl!),
              child: Container(
                margin: const EdgeInsets.only(bottom: 4),
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.1),
                      blurRadius: 4,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Stack(
                    children: [
                      Image.network(
                        message.mediaUrl!,
                        width: imageSize,
                        height: imageSize,
                        fit: BoxFit.cover,
                        loadingBuilder: (context, child, loadingProgress) {
                          if (loadingProgress == null) return child;
                          return Container(
                            width: imageSize,
                            height: imageSize,
                            color: const Color(0xFFDDE5EF),
                            child: const Center(
                              child: CircularProgressIndicator(color: _brand),
                            ),
                          );
                        },
                        errorBuilder: (context, error, stackTrace) {
                          return Container(
                            width: imageSize,
                            height: imageSize,
                            color: const Color(0xFFDDE5EF),
                            child: const Icon(Icons.broken_image, size: 50),
                          );
                        },
                      ),
                      Positioned(
                        bottom: 8,
                        right: 8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.6),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            _formatTime(message.timestamp),
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: context.fs(10),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDocumentBubble(ChatMessageModel message, bool isFromDoctor) {
    final fileName = message.fileName ?? 'Document';
    final double maxW = math.min(context.sw * 0.78, 460);

    return Align(
      alignment: isFromDoctor ? Alignment.centerLeft : Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        constraints: BoxConstraints(maxWidth: maxW),
        child: Column(
          crossAxisAlignment: isFromDoctor
              ? CrossAxisAlignment.start
              : CrossAxisAlignment.end,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 8, bottom: 2),
              child: Text(
                isFromDoctor ? widget.doctorName : widget.patientName,
                style: TextStyle(
                  fontSize: 10,
                  color: const Color(0xFF657991),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            GestureDetector(
              onTap: () => _downloadAndOpenFile(message.mediaUrl!, fileName),
              child: Container(
                margin: const EdgeInsets.only(bottom: 4),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: isFromDoctor
                      ? Colors.white
                      : _brandLight.withValues(alpha: 0.95),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.1),
                      blurRadius: 4,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: isFromDoctor
                            ? const Color(0xFFE8EEF5)
                            : Colors.white.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        _getDocumentIcon(fileName),
                        color: isFromDoctor ? _brand : Colors.white,
                        size: 32,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: math.max(90, maxW - 116),
                          ),
                          child: Text(
                            fileName.length > 20
                                ? '${fileName.substring(0, 20)}...'
                                : fileName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: context.fs(13),
                              fontWeight: FontWeight.w500,
                              color: isFromDoctor
                                  ? Colors.black87
                                  : Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                    Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: isFromDoctor
                            ? const Color(0xFFE8EEF5)
                            : Colors.white.withValues(alpha: 0.2),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.download,
                        size: 16,
                        color: isFromDoctor ? _brand : Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCallBubble(ChatMessageModel message, bool isFromDoctor) {
    final isCall =
        message.messageType == 'audio' || message.messageType == 'video';

    return Align(
      alignment: isFromDoctor ? Alignment.centerLeft : Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        constraints: BoxConstraints(maxWidth: math.min(context.sw * 0.78, 460)),
        child: Column(
          crossAxisAlignment: isFromDoctor
              ? CrossAxisAlignment.start
              : CrossAxisAlignment.end,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 8, bottom: 2),
              child: Text(
                isFromDoctor ? widget.doctorName : widget.patientName,
                style: TextStyle(
                  fontSize: 10,
                  color: const Color(0xFF657991),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: isFromDoctor ? Colors.white : _brand,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF12263F).withValues(alpha: 0.08),
                    blurRadius: 8,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isCall ? Icons.call : Icons.videocam,
                    size: 20,
                    color: isFromDoctor
                        ? const Color(0xFF657991)
                        : Colors.white70,
                  ),
                  const SizedBox(width: 8),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: math.min(context.sw * 0.78, 460) - 52,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          message.message,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: context.fs(13.5),
                            color: isFromDoctor ? Colors.black87 : Colors.white,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _formatTime(message.timestamp),
                          style: TextStyle(
                            fontSize: context.fs(10),
                            color: isFromDoctor
                                ? const Color(0xFF7E90A6)
                                : Colors.white70,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAdminMessageInput() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, -5),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: context.rsp(16),
            vertical: 8,
          ),
          child: Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Color(0xFFE3EAF2),
                        Color(0xFFF5F8FC),
                        Color(0xFFE2E9F2),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(
                      color: const Color(0xFFBAC7D8),
                      width: 1.5,
                    ),
                  ),
                  child: Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: context.rsp(12),
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Color(0xFFF3F7FB),
                          Colors.white,
                          Color(0xFFF0F4F9),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(25),
                    ),
                    child: TextFormField(
                      controller: _messageController,
                      textInputAction: TextInputAction.send,
                      onFieldSubmitted: (_) => _sendAdminMessage(),
                      maxLines: 5,
                      minLines: 1,
                      style: TextStyle(
                        fontSize: context.fs(13.5),
                        color: const Color(0xFF1E2F44),
                      ),
                      decoration: InputDecoration(
                        hintText: 'Send admin message to both...',
                        border: InputBorder.none,
                        isDense: true,
                        hintMaxLines: 1,
                        contentPadding: EdgeInsets.zero,
                        hintStyle: TextStyle(
                          color: const Color(0xFF7E90A6),
                          fontSize: context.fs(13.5),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(width: context.rsp(12)),
              GestureDetector(
                onTap: _isSending ? null : _sendAdminMessage,
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: _brandGradient,
                    ),
                    shape: BoxShape.circle,
                    border: Border.all(color: const Color(0xFF132D56)),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF0B2041).withValues(alpha: 0.32),
                        blurRadius: 12,
                        offset: const Offset(0, 5),
                      ),
                    ],
                  ),
                  alignment: Alignment.center,
                  child: _isSending
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.send, color: Colors.white, size: 20),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
