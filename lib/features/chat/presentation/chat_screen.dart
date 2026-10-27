import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:telemedicine/features/auth/presentation/providers/user_provider.dart';
import 'package:telemedicine/features/auth/presentation/controllers/doctor_controller.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/data/models/appointment_model.dart';
import 'package:telemedicine/features/appointments/presentation/appointment_controller.dart';
import 'package:telemedicine/features/appointments/presentation/appointment_status_widgets.dart';
import 'package:telemedicine/features/calls/presentation/controllers/call_controller.dart';
import 'package:telemedicine/features/calls/presentation/call_screen.dart';
import 'package:telemedicine/features/chat/presentation/chat_status/message_status_indicator.dart';
import 'package:telemedicine/features/chat/presentation/chat_action/chat_image_download_service.dart';
import 'package:telemedicine/features/chat/presentation/chat_action/message_action_rules.dart';
import 'package:telemedicine/features/chat/presentation/chat_action/swipe_to_reply_wrapper.dart';
import 'package:telemedicine/features/chat/presentation/controllers/chat_controller.dart';
import 'package:telemedicine/features/chat/presentation/chat_menu/chat_overflow_menu.dart';
import 'package:telemedicine/features/chat/presentation/chat_menu/forward_recipient_screen.dart';
import 'package:telemedicine/features/chat/presentation/voice/voice_message_player.dart';
import 'package:telemedicine/features/chat/presentation/voice/voice_manager/voice_message_manager.dart';
import 'package:record/record.dart';
import 'package:just_audio/just_audio.dart';
import 'package:telemedicine/data/models/chat_model.dart';
import 'package:telemedicine/features/doctor_portal/presentation/prescriptions/prescription_detail_screen.dart';
import 'package:telemedicine/features/doctor_portal/presentation/ratings/doctor_rating_controller.dart';
import 'package:telemedicine/features/doctor_portal/presentation/ratings/doctor_rating_popup.dart';
import 'package:telemedicine/features/reports/presentation/report_history/report_history_screen.dart';
import 'package:telemedicine/data/local/offline_chat_service.dart';
import 'package:telemedicine/data/local/offline_converters.dart';
import 'package:telemedicine/core/providers/badge_providers.dart';
import 'package:telemedicine/core/services/doctor_presence_service.dart';
import 'package:telemedicine/core/services/notification_service.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/shared/widgets/auth_layout.dart';
import 'package:telemedicine/shared/widgets/opd_design_system.dart';
import 'package:file_picker/file_picker.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;

/// A single highlighted occurrence of a search term inside a chat message.
class _SearchMatch {
  final String messageId;
  final int start;

  const _SearchMatch({required this.messageId, required this.start});
}

/// Which horizontal edge a message row must be pinned to.
///
/// Ownership is decided exclusively by [MessageActionRules.isOwnMessage] —
/// the authenticated user's id against the `senderId` stored on the message —
/// so a patient and a doctor each see their own messages on their own side,
/// and the side is the same whether the message came from the Firestore
/// stream or from the offline Hive cache.
///
/// Public so the alignment decision can be unit-tested without a Firebase
/// project, a Hive box or a pump of the whole screen.
Alignment chatMessageRowAlignment(
  ChatMessageModel message,
  String currentUserId,
) => MessageActionRules.isOwnMessage(message, currentUserId)
    ? Alignment.centerRight
    : Alignment.centerLeft;

class ChatScreen extends ConsumerStatefulWidget {
  final String otherUserId;
  final String otherUserName;
  final String otherUserImage;
  final String? currentUserRole;
  final String? otherUserType;
  final String? otherUserRole;
  const ChatScreen({
    Key? key,
    required this.otherUserId,
    required this.otherUserName,
    required this.otherUserImage,
    this.currentUserRole,
    this.otherUserType,
    this.otherUserRole,
  }) : super(key: key);
  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  final TextEditingController _messageController = TextEditingController();
  final ChatController _chatController = ChatController();
  final CallController _callController = CallController();
  final ScrollController _scrollController = ScrollController();
  final ImagePicker _imagePicker = ImagePicker();
  // Voice message recording & preview state
  AudioRecorder? _audioRecorder;
  bool _isRecording = false;
  int _recordingSeconds = 0;
  Timer? _recordingTimer;
  String? _recordedVoicePath;
  bool _isPreviewingVoice = false;
  AudioPlayer? _previewPlayer;
  bool _isPreviewPlaying = false;
  Duration _previewPosition = Duration.zero;
  Duration _previewDuration = Duration.zero;
  StreamSubscription<Duration>? _previewPosSub;
  StreamSubscription<PlayerState>? _previewStateSub;
  bool _isUploadingVoice = false;
  // Typing status
  Timer? _typingTimer;
  int _lastMessageCount = 0;
  bool _isFirstLoad = true;
  bool _hasScrolledToBottom = false;
  // Sticky header
  String _currentDateHeader = '';
  String _lastDateHeader = '';
  double _scrollOffset = 0;
  bool _showStickyHeader = false;
  bool _isNearBottom = true;

  /// Set when the local user has just sent something, so the next stream
  /// growth scrolls to it even if they were reading history at the time.
  ///
  /// Without it, sending from a scrolled-up position depended entirely on
  /// [_isNearBottom] being true at the exact frame the stream re-emitted —
  /// the user's own message could land off-screen.
  bool _pendingScrollToBottom = false;

  // ==================== Older-message pagination ====================
  /// True while a previous page of history is being fetched — drives the
  /// small top-of-list indicator.
  bool _isLoadingOlder = false;

  /// Set once [ChatController.loadOlderMessages] reports the beginning of
  /// history, so scrolling near the top does not re-query Firestore on every
  /// scroll tick. Reset whenever the messages stream is (re)created.
  bool _olderMessagesExhausted = false;

  late AnimationController _fadeAnimationController;
  late Animation<double> _fadeAnimation;
  // Doctor profile
  Map<String, dynamic>? _doctorProfile;
  bool _isLoadingProfile = false;
  bool _isCallInitiating = false;
  // Message actions
  ChatMessageModel? _selectedMessage;
  ReplyData? _replyToMessage;
  // Edit message
  bool _isEditingMessage = false;
  String? _editingMessageId;
  String? _originalEditText;

  // ==================== Multi-select (WhatsApp style) ====================
  /// Ids of the messages currently ticked. Non-empty ⇔ selection mode is on
  /// and the header is swapped for the selection toolbar.
  final Set<String> _selectedMessageIds = <String>{};

  /// True while the forward recipient picker is open, so a double tap cannot
  /// queue two identical forwards.
  bool _isForwarding = false;

  /// True while an image is being downloaded into the gallery.
  bool _isDownloadingImage = false;

  /// Bubble currently flashed after tapping a reply preview.
  String? _highlightedMessageId;

  /// Key requested for a jump but not yet attached to a built bubble.
  String? _pendingJumpMessageId;

  Timer? _highlightTimer;

  /// Keys for bubbles that need `Scrollable.ensureVisible` (reply jumps).
  /// Separate from `_searchMessageKeys` so clearing search cannot drop a
  /// key that a jump is still animating to.
  final Map<String, GlobalKey> _messageKeys = {};

  /// Message ids already marked read by this screen instance.
  ///
  /// Without it every emission of the message stream would re-scan and
  /// re-issue a read for the same backlog. Bounded because it only ever grows
  /// for the duration of one open conversation.
  final Set<String> _readMarkedIds = <String>{};

  /// Blue for the "read" receipt on the dark outgoing bubbles.
  ///
  /// Named rather than inlined because `Colors.blue[300]` is a `Color?` and
  /// the same value is needed at six call sites.
  static const Color _readTickOnDark = Color(0xFF53BDEB);

  /// Muted tick colour for the call/recording bubble, which is light-filled on
  /// both sides of the conversation.
  static const Color _tickOnLightBubble = Color(0xFF657991);

  /// Whether *this* conversation is the one currently on screen.
  ///
  /// Read state may only advance while the conversation is genuinely being
  /// viewed (§5). `NotificationService.activeChatId` is the app-wide marker for
  /// that, and it is cleared in [dispose], so a write that was queued just
  /// before the user navigated away can detect it lost the race and abort.
  bool get isCurrentUserChatOpen {
    if (!mounted) return false;
    final user = ref.read(userProvider);
    if (user == null) return false;
    final chatId = _chatController.getChatId(user.id, widget.otherUserId);
    return NotificationService.activeChatId == chatId;
  }

  TextEditingController? _editController;
  Stream<List<ChatMessageModel>>? _messagesStream;

  /// Header profile listener, created once in initState (see there).
  late final Stream<DocumentSnapshot> _otherUserDocStream;

  /// Latest messages already held in memory. Shared with the header overflow
  /// menu (Search / Media, Links & Docs) so opening a menu screen never
  /// re-reads the conversation from Firebase.
  List<ChatMessageModel> _latestMessages = const [];

  /// Anchors the floating overflow popup to the 3-dot button.
  final LayerLink _menuAnchorLink = LayerLink();
  final GlobalKey _menuAnchorKey = GlobalKey();

  bool _isChatMenuOpen = false;

  // ==================== In-chat search (WhatsApp style) ====================
  // Search runs entirely on the messages already held in memory. Entering or
  // leaving search mode never touches `_messagesStream`, so the Firebase
  // listener is never restarted and the chat is never reloaded.
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  bool _isSearching = false;
  String _searchQuery = '';
  List<_SearchMatch> _searchMatches = const [];
  int _activeMatchIndex = 0;
  String _searchMatchSignature = '';

  /// Lazily creates (and reuses) a key for a matched message so stepping
  /// through results can scroll straight to it. Only matches are keyed.
  GlobalKey _keyForMessage(String messageId) =>
      _searchMessageKeys.putIfAbsent(messageId, GlobalKey.new);
  final Map<String, GlobalKey> _searchMessageKeys = {};

  void _openSearchMode() {
    if (_isSearching) return;
    setState(() {
      _isSearching = true;
      _searchQuery = '';
      _searchMatches = const [];
      _activeMatchIndex = 0;
      _searchMatchSignature = '';
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocusNode.requestFocus();
    });
  }

  void _closeSearchMode() {
    if (!_isSearching) return;
    _searchController.clear();
    _searchFocusNode.unfocus();
    setState(() {
      _isSearching = false;
      _searchQuery = '';
      _searchMatches = const [];
      _activeMatchIndex = 0;
      _searchMatchSignature = '';
    });
    _searchMessageKeys.clear();
  }

  void _onSearchChanged(String value) {
    final matches = _computeSearchMatches(_latestMessages, value);
    setState(() {
      _searchQuery = value;
      _searchMatches = matches;
      // Matches are newest-first, so the first hit is the most recent one.
      _activeMatchIndex = 0;
    });
    _searchMessageKeys.clear();
    if (matches.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToActiveMatch(),
      );
    }
  }

  /// Keeps search in sync when a realtime message arrives, without rebuilding
  /// on every stream tick.
  void _syncSearchWithStream() {
    if (!_isSearching) return;
    final matches = _computeSearchMatches(_latestMessages, _searchQuery);
    final signature = matches.map((m) => '${m.messageId}@${m.start}').join('|');
    if (signature == _searchMatchSignature) return;
    _searchMatchSignature = signature;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _searchMatches = matches;
        if (_activeMatchIndex >= matches.length) {
          _activeMatchIndex = 0;
        }
      });
    });
  }

  /// Scans the current conversation only and returns every occurrence.
  ///
  /// Results are ordered newest-first, so index 0 is the most recent match —
  /// the header can show "1 of 5" and the up arrow walks back in time.
  static List<_SearchMatch> _computeSearchMatches(
    List<ChatMessageModel> messages,
    String query,
  ) {
    final term = query.trim().toLowerCase();
    if (term.isEmpty) return const [];

    final matches = <_SearchMatch>[];
    for (final message in messages) {
      if (message.isDeleted) continue;
      final haystack = message.message.toLowerCase();
      var from = 0;
      while (true) {
        final index = haystack.indexOf(term, from);
        if (index < 0) break;
        matches.add(_SearchMatch(messageId: message.id, start: index));
        from = index + term.length;
      }
    }
    return matches.reversed.toList();
  }

  void _stepSearchMatch(int delta) {
    if (_searchMatches.isEmpty) return;
    setState(() {
      final count = _searchMatches.length;
      _activeMatchIndex = (_activeMatchIndex + delta) % count;
      if (_activeMatchIndex < 0) _activeMatchIndex += count;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToActiveMatch());
  }

  void _scrollToActiveMatch() {
    if (_searchMatches.isEmpty) return;
    final match = _searchMatches[_activeMatchIndex];
    final target = _searchMessageKeys[match.messageId]?.currentContext;
    if (target == null) return;
    Scrollable.ensureVisible(
      target,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeInOutCubic,
      alignment: 0.35,
    );
  }

  /// Builds message text with every match highlighted, using the OPD palette.
  Widget _buildHighlightedText(
    String text,
    String messageId, {
    required bool isMine,
    required double fontSize,
    int? maxLines,
    TextOverflow overflow = TextOverflow.clip,
  }) {
    final baseStyle = TextStyle(
      color: isMine ? Colors.white : Colors.black87,
      fontSize: fontSize,
      fontWeight: fontSize <= 13 ? FontWeight.w500 : FontWeight.normal,
    );
    final term = _searchQuery.trim().toLowerCase();
    if (term.isEmpty || !_isSearching) {
      return Text(
        text,
        style: baseStyle,
        maxLines: maxLines,
        overflow: overflow,
      );
    }

    final haystack = text.toLowerCase();
    final active = _searchMatches.isEmpty
        ? null
        : _searchMatches[_activeMatchIndex.clamp(0, _searchMatches.length - 1)];
    final spans = <InlineSpan>[];
    var cursor = 0;
    while (true) {
      final index = haystack.indexOf(term, cursor);
      if (index < 0) break;
      if (index > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, index)));
      }
      final isActive =
          active != null &&
          active.messageId == messageId &&
          active.start == index;
      spans.add(
        TextSpan(
          text: text.substring(index, index + term.length),
          style: TextStyle(
            color: isMine ? const Color(0xFF081938) : const Color(0xFF1F2F44),
            backgroundColor: isActive
                ? const Color(0xFFFFC107)
                : const Color(0xFFFFE082),
            fontWeight: FontWeight.w700,
          ),
        ),
      );
      cursor = index + term.length;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }

    return Text.rich(
      TextSpan(style: baseStyle, children: spans),
      maxLines: maxLines,
      overflow: overflow,
    );
  }

  @override
  void initState() {
    super.initState();
    _fadeAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeAnimationController,
      curve: Curves.easeInOut,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final user = ref.read(userProvider);
      if (user != null) {
        final chatId = _chatController.getChatId(user.id, widget.otherUserId);
        NotificationService.activeChatId = chatId;

        // 1. Immediately decrement bottom navigation badge listener optimistically
        markChatAsReadLocally(ref, chatId);

        // 2. Immediately mark local Hive rows to is_read: true upon viewing
        OfflineChatService.instance.markChatAsRead(chatId, user.id);
        OfflineChatService.instance.setCachedChatUnreadCount(
          userId: user.id,
          chatId: chatId,
          count: 0,
        );
        _chatController.invalidateUnreadMemo(user.id, chatId);

        // 3. Trigger bulk update on mount to mark all unread messages as read
        _chatController.markMessagesRead(
          messageIds: null,
          userId: user.id,
          otherUserId: widget.otherUserId,
        );
        // This device can now vouch that anything already in its inbox reached
        // the sender, so those messages advance to the double tick.
        _acknowledgeInboundDelivery();
        _messagesStream = _chatController.getMessagesOfflineFirst(
          user.id,
          widget.otherUserId,
        );
        _olderMessagesExhausted = false;
        if (mounted) setState(() {});
      }
    });
    _scrollController.addListener(_onScroll);
    // Needed so `didChangeAppLifecycleState` can re-assert read state on
    // resume while this conversation is on screen.
    WidgetsBinding.instance.addObserver(this);
    if (widget.otherUserRole == 'doctor') {
      _loadDoctorProfile();
    }
    // Header stream, created once. It was inline in build(): every rebuild
    // (each keystroke in the composer, every message emission, every search
    // toggle) constructed a fresh `.snapshots()`, and StreamBuilder treats a
    // new stream instance as a new subscription — dropping and re-listening to
    // Firestore each time.
    _otherUserDocStream = FirebaseFirestore.instance
        .collection(
          widget.otherUserRole == 'doctor'
              ? FirestoreCollections.doctors
              : FirestoreCollections.patients,
        )
        .doc(widget.otherUserId)
        .snapshots();
    _requestPermissions();
  }

  Stream<Map<String, dynamic>>? _chatMetadataStream;
  String? _chatMetadataUserId;

  /// Memoized on the current user id: [userProvider] can still be null on the
  /// first initState (session restore runs in a post-frame callback), so the
  /// metadata stream is built on the first build that has a signed-in user and
  /// then reused. `getChatId` sorts its arguments, so argument order is stable.
  Stream<Map<String, dynamic>> _chatMetadataStreamFor(String currentUserId) {
    if (_chatMetadataStream == null || _chatMetadataUserId != currentUserId) {
      _chatMetadataUserId = currentUserId;
      _chatMetadataStream = _chatController.getChatMetadata(
        currentUserId,
        widget.otherUserId,
      );
    }
    return _chatMetadataStream!;
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.microphone,
      Permission.storage,
      Permission.photos,
    ].request();
  }

  Future<void> _loadDoctorProfile() async {
    setState(() {
      _isLoadingProfile = true;
    });
    try {
      final doctorController = ref.read(doctorControllerProvider);
      final profile = await doctorController.getDoctorProfile(
        widget.otherUserId,
      );
      if (mounted) {
        setState(() {
          _doctorProfile = profile;
          _isLoadingProfile = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingProfile = false;
        });
      }
    }
  }

  /// Marks incoming messages as read *because this conversation is currently on
  /// screen* — the only condition under which a message may become read
  /// (§5: not merely because the app is open, the list is visible, or a push
  /// arrived).
  ///
  /// Runs on every emission of the message stream, so a message that arrives
  /// while the user is already inside the chat is picked up immediately and
  /// becomes read without leaving and reopening.
  ///
  /// One batched call for all newly-unread messages rather than a
  /// read-then-write per message, and it reconciles the list badge in the same
  /// operation — the previous per-message path left the counter untouched, so
  /// the badge stayed stuck at 1 for a message that had visibly been read.
  /// Acknowledges **delivery** of everything addressed to the current user, so
  /// the sender's single tick becomes a double tick.
  ///
  /// Separate from [_markMessagesAsSeen] because the two transitions have
  /// different meanings and different triggers: delivery is proven by this
  /// device being reachable, whereas read additionally requires the chat to be
  /// on screen. Before this existed, nothing ever acknowledged delivery, so a
  /// message stayed at one tick unless the receiver happened to be online at
  /// the instant of sending.
  ///
  /// Runs on open, on resume, and on every emission. The Firestore query only
  /// matches still-undelivered messages, so repeat calls are cheap no-op reads
  /// rather than redundant writes.
  Future<void> _acknowledgeInboundDelivery() async {
    final user = ref.read(userProvider);
    if (user == null) return;
    if (!mounted || !isCurrentUserChatOpen) return;

    await _chatController.markIncomingMessagesDelivered(
      userId: user.id,
      otherUserId: widget.otherUserId,
    );
  }

  Future<void> _markMessagesAsSeen(List<ChatMessageModel> messages) async {
    final user = ref.read(userProvider);
    if (user == null) return;

    // Guard on the conversation still being open: an async gap between the
    // stream emission and this write must not mark messages read after the
    // user has navigated away (§8, quick open/close/reopen).
    if (!mounted || !isCurrentUserChatOpen) return;

    final unreadIds = messages
        .where(
          (msg) =>
              msg.receiverId == user.id &&
              msg.senderId != user.id &&
              !msg.isRead,
        )
        .map((msg) => msg.id)
        .toList();
    if (unreadIds.isEmpty) return;

    // Nothing to redo for ids already handled on a previous emission.
    unreadIds.removeWhere(_readMarkedIds.contains);
    if (unreadIds.isEmpty) return;

    // Recorded ONLY after a successful write. The controller swallows errors
    // and returns 0, so a transient failure (offline, timeout) used to leave
    // the ids permanently in `_readMarkedIds` and the message stayed unread
    // on the sender's side until the chat was closed and reopened.
    final marked = await _chatController.markMessagesRead(
      userId: user.id,
      otherUserId: widget.otherUserId,
      messageIds: unreadIds,
    );
    if (marked > 0) {
      _readMarkedIds.addAll(unreadIds);
      final chatId = _chatController.getChatId(user.id, widget.otherUserId);
      markChatAsReadLocally(ref, chatId);
      await OfflineChatService.instance.markChatAsRead(chatId, user.id);
      await OfflineChatService.instance.setCachedChatUnreadCount(
        userId: user.id,
        chatId: chatId,
        count: 0,
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    NotificationService.activeChatId = null;
    _sendTypingStatus(false);
    _messageController.dispose();
    _scrollController.dispose();
    _typingTimer?.cancel();
    // NOT dispose(): the CallController is an app-wide singleton and a full
    // dispose here would kill a ring-timeout timer for a live incoming call.
    _callController.resetForScreen();
    _fadeAnimationController.dispose();
    _editController?.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _searchMessageKeys.clear();
    _highlightTimer?.cancel();
    _messageKeys.clear();
    _recordingTimer?.cancel();
    _previewPosSub?.cancel();
    _previewStateSub?.cancel();
    _previewPlayer?.dispose();
    _audioRecorder?.dispose();
    VoiceMessageManager.stopAllAudio();
    super.dispose();
  }

  /// Re-asserts read state when the app comes back to the foreground while
  /// this conversation is on screen (§9).
  ///
  /// A message that arrived while the app was backgrounded stays unread the
  /// whole time it is not being viewed. The stream re-emits on reconnect and
  /// `_markMessagesAsSeen` handles it, but doing it explicitly here means the
  /// badge clears on resume even if Firestore delivered no metadata change
  /// (for example the message arrived while the listener was detached and the
  /// snapshot was served from its local cache).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      if (_isRecording) {
        _cancelVoiceRecording();
      }
      _stopPreview();
    }
    if (state != AppLifecycleState.resumed) return;
    if (!isCurrentUserChatOpen) return;

    final messages = _latestMessages;
    if (messages.isEmpty) return;
    final user = ref.read(userProvider);
    if (user != null) {
      final chatId = _chatController.getChatId(user.id, widget.otherUserId);
      markChatAsReadLocally(ref, chatId);
      OfflineChatService.instance.markChatAsRead(chatId, user.id);
      OfflineChatService.instance.setCachedChatUnreadCount(
        userId: user.id,
        chatId: chatId,
        count: 0,
      );
      _chatController.invalidateUnreadMemo(user.id, chatId);
      _chatController.markMessagesRead(
        userId: user.id,
        otherUserId: widget.otherUserId,
        messageIds: null,
      );
    }
    _markMessagesAsSeen(messages);
    // Messages may have landed in the inbox while the app was backgrounded.
    _acknowledgeInboundDelivery();
  }

  /// Keeps the newest message visible when the viewport resizes (keyboard
  /// opening or closing).
  ///
  /// The cached [_isNearBottom] still holds the pre-resize truth here, which
  /// is exactly what is needed: a user who was at the bottom stays at the
  /// bottom once the keyboard pushes the viewport up. A live check would
  /// already see the new, larger `maxScrollExtent` and bail out.
  @override
  void didChangeMetrics() {
    if (!_isNearBottom) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scrollController.hasClients) {
        _scrollToBottom();
      }
    });
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final threshold = position.maxScrollExtent - 120;
    final nearBottom = position.pixels >= threshold;
    final shouldShowHeader = position.pixels > 60;

    if (nearBottom != _isNearBottom || shouldShowHeader != _showStickyHeader) {
      setState(() {
        _isNearBottom = nearBottom;
        _showStickyHeader = shouldShowHeader;
      });
    }

    if (_showStickyHeader && !_fadeAnimationController.isCompleted) {
      _fadeAnimationController.forward();
    } else if (!_showStickyHeader && _fadeAnimationController.isCompleted) {
      _fadeAnimationController.reverse();
    }

    // Pagination: the live listener only covers the most recent window of
    // messages, so reaching the top of the list fetches the previous page of
    // history into Hive. The merged stream picks the rows up automatically.
    if (position.pixels < 200) {
      _maybeLoadOlderMessages();
    }
  }

  /// Fetches the previous page of message history when the user scrolls near
  /// the top of the conversation, keeping the visual anchor in place while
  /// content is inserted above the viewport.
  Future<void> _maybeLoadOlderMessages() async {
    if (_isLoadingOlder ||
        _olderMessagesExhausted ||
        _isSearching ||
        !mounted) {
      return;
    }
    final user = ref.read(userProvider);
    if (user == null || !_scrollController.hasClients) return;

    _isLoadingOlder = true;
    setState(() {});
    final beforePixels = _scrollController.position.pixels;
    final beforeMax = _scrollController.position.maxScrollExtent;

    final fetched = await _chatController.loadOlderMessages(
      user.id,
      widget.otherUserId,
    );

    if (!mounted) return;
    _isLoadingOlder = false;
    if (fetched == 0) {
      _olderMessagesExhausted = true;
    } else {
      // Content grew above the viewport — shift the offset by exactly the
      // growth of maxScrollExtent so the messages the user was reading stay
      // put. A message arriving at the bottom at the same instant nudges the
      // view by that bubble's height at worst; a one-off, imperceptible
      // trade-off against losing the anchor entirely.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients) return;
        final delta = _scrollController.position.maxScrollExtent - beforeMax;
        if (delta > 0) {
          _scrollController.jumpTo(beforePixels + delta);
        }
      });
    }
    if (mounted) setState(() {});
  }

  /// Live near-bottom check.
  ///
  /// [_isNearBottom] only refreshes when a scroll event fires, so it can be
  /// stale after the content shrinks (a delete) or the viewport resizes —
  /// both of which silently disabled auto-scroll for every later message even
  /// though the newest one was already on screen.
  bool get _nearBottomNow {
    if (!_scrollController.hasClients) return _isNearBottom;
    final position = _scrollController.position;
    return position.pixels >= position.maxScrollExtent - 120;
  }

  bool _isTypingFlag = false;

  void _handleTyping(String text) {
    if (text.trim().isEmpty) {
      _typingTimer?.cancel();
      if (_isTypingFlag) {
        _isTypingFlag = false;
        _sendTypingStatus(false);
      }
      return;
    }

    if (!_isTypingFlag) {
      _isTypingFlag = true;
      _sendTypingStatus(true);
    }

    _typingTimer?.cancel();
    _typingTimer = Timer(const Duration(seconds: 2), () {
      _isTypingFlag = false;
      _sendTypingStatus(false);
    });
  }

  Future<void> _sendTypingStatus(bool isTyping) async {
    final user = ref.read(userProvider);
    if (user == null) return;
    try {
      await _chatController.updateTypingStatus(
        userId: user.id,
        otherUserId: widget.otherUserId,
        isTyping: isTyping,
      );
    } catch (_) {}
  }

  void _showMessageActions(ChatMessageModel message, Offset tapPosition) {
    final user = ref.read(userProvider);
    if (user == null) return;
    final isMe = MessageActionRules.isOwnMessage(message, user.id);
    final isDeleted = message.isDeleted;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      enableDrag: true,
      useSafeArea: true,
      builder: (context) {
        return TweenAnimationBuilder(
          tween: Tween<double>(begin: 0, end: 1),
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
          builder: (context, value, child) {
            return Transform.translate(
              offset: Offset(0, (1 - value) * 100),
              child: Opacity(
                opacity: value,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.85,
                  ),
                  child: SingleChildScrollView(child: child),
                ),
              ),
            );
          },
          child: Container(
            margin: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF12263F).withValues(alpha: 0.15),
                  blurRadius: 30,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: Material(
                color: Colors.transparent,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      margin: const EdgeInsets.only(top: 16),
                      width: 50,
                      height: 5,
                      decoration: BoxDecoration(
                        color: const Color(0xFFD6E4F0),
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    const SizedBox(height: 12),
                    _buildMessageInfoHeader(message, isMe),
                    const Divider(
                      height: 24,
                      thickness: 1,
                      color: Color(0xFFDCE6F2),
                    ),
                    Column(
                      children: [
                        _buildActionButton(
                          icon: Icons.reply_outlined,
                          label: 'Reply',
                          color: const Color(0xFF2196F3),
                          onTap: () {
                            Navigator.pop(context);
                            _setReplyToMessage(message);
                          },
                        ),
                        if (!isDeleted)
                          _buildActionButton(
                            icon: Icons.copy_outlined,
                            label: 'Copy',
                            color: const Color(0xFF4CAF50),
                            onTap: () {
                              Navigator.pop(context);
                              _copyMessageText(message);
                            },
                          ),
                        if (!isDeleted)
                          _buildActionButton(
                            icon: Icons.delete_outline,
                            label: 'Delete for me',
                            color: const Color(0xFFFF5722),
                            onTap: () {
                              Navigator.pop(context);
                              _confirmDeleteForMe(message);
                            },
                          ),
                        if (isMe && !isDeleted)
                          _buildActionButton(
                            icon: Icons.delete_forever,
                            label: 'Delete for everyone',
                            color: const Color(0xFFE53935),
                            isDestructive: true,
                            onTap: () {
                              Navigator.pop(context);
                              _confirmDeleteForEveryone(message);
                            },
                          ),
                        if (!isMe && !isDeleted)
                          _buildActionButton(
                            icon: Icons.report_outlined,
                            label: 'Report',
                            color: const Color(0xFF9E9E9E),
                            isDestructive: true,
                            onTap: () {
                              Navigator.pop(context);
                              _reportMessage(message);
                            },
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      child: SizedBox(
                        width: double.infinity,
                        child: TextButton(
                          onPressed: () => Navigator.pop(context),
                          style: TextButton.styleFrom(
                            backgroundColor: const Color(0xFFF5F8FC),
                            foregroundColor: const Color(0xFF6B7B8D),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20),
                              side: const BorderSide(color: Color(0xFFDCE6F2)),
                            ),
                          ),
                          child: Text(
                            'Cancel',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: context.fs(14.5),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDivider({double vertical = 4}) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: vertical),
      child: Divider(
        height: 1,
        thickness: 0.5,
        color: Colors.grey.shade200,
        indent: 20,
        endIndent: 20,
      ),
    );
  }

  void _reportMessage(ChatMessageModel message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.report, color: Colors.red),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'Report Message',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        content: Text(
          'This message will be reported to the admin for review. Do you want to continue?',
          style: TextStyle(fontSize: context.fs(13.5), height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              ToastService.instance.showSuccess(
                'Message reported successfully',
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text('Report'),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageInfoHeader(ChatMessageModel message, bool isMe) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: context.rsp(16), vertical: 8),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: isMe
                    ? [const Color(0xFF062B72), const Color(0xFF0B3A8A)]
                    : [const Color(0xFF2196F3), const Color(0xFF1976D2)],
              ),
              borderRadius: BorderRadius.circular(22),
              boxShadow: [
                BoxShadow(
                  color:
                      (isMe ? const Color(0xFF062B72) : const Color(0xFF2196F3))
                          .withOpacity(0.3),
                  blurRadius: 8,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Center(
              child: Icon(
                isMe ? Icons.person : Icons.person_outline,
                color: Colors.white,
                size: 24,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isMe ? 'You' : widget.otherUserName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: context.fs(15),
                    color: const Color(0xFF1F2F44),
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(
                      message.messageType == 'text'
                          ? Icons.text_fields
                          : message.messageType == 'image'
                          ? Icons.image
                          : message.messageType == 'document'
                          ? Icons.insert_drive_file
                          : Icons.chat_bubble,
                      size: 12,
                      color: const Color(0xFF6B7B8D),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        message.getDisplayMessage().length > 40
                            ? '${message.getDisplayMessage().substring(0, 40)}...'
                            : message.getDisplayMessage(),
                        style: TextStyle(
                          fontSize: context.fs(12),
                          color: const Color(0xFF6B7B8D),
                          fontStyle: FontStyle.italic,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFFEDF2F8),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              _formatTime(message.timestamp),
              style: TextStyle(
                fontSize: context.fs(10),
                color: const Color(0xFF6B7B8D),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    required Color color,
    bool isDestructive = false,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: 16,
          vertical: context.rsp(10),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: isDestructive
                    ? color.withOpacity(0.08)
                    : const Color(0xFFEDF2F8),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(
                icon,
                color: isDestructive ? Colors.red : const Color(0xFF062B72),
                size: 24,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: context.fs(14),
                  fontWeight: FontWeight.w500,
                  color: isDestructive ? Colors.red : const Color(0xFF1F2F44),
                ),
              ),
            ),
            Icon(Icons.chevron_right, color: const Color(0xFF8FA4BD), size: 20),
          ],
        ),
      ),
    );
  }

  void _setReplyToMessage(ChatMessageModel message) {
    final user = ref.read(userProvider);
    if (user == null) return;
    // A composer holding a half-finished *edit* must not keep that text when
    // the user switches to replying; a fresh draft is left alone.
    final wasEditing = _isEditingMessage;
    setState(() {
      _selectedMessageIds.clear();
      _isEditingMessage = false;
      _editingMessageId = null;
      _originalEditText = null;
      if (wasEditing) _messageController.clear();
      _replyToMessage = ReplyData(
        messageId: message.id,
        message: message.getDisplayMessage(),
        senderName: MessageActionRules.isOwnMessage(message, user.id)
            ? 'You'
            : widget.otherUserName,
        messageType: message.messageType,
        mediaUrl: message.mediaUrl,
      );
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      FocusScope.of(context).requestFocus();
    });
  }

  void _cancelReply() {
    setState(() {
      _replyToMessage = null;
    });
  }

  void _copyMessageText(ChatMessageModel message) {
    Clipboard.setData(ClipboardData(text: message.message));
    ToastService.instance.showSuccess('Message copied');
  }

  Future<void> _confirmDeleteForMe(ChatMessageModel message) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete for me'),
        content: const Text('This message will be deleted only for you.'),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _deleteMessageForMe(message);
    }
  }

  Future<void> _deleteMessageForMe(ChatMessageModel message) async {
    final user = ref.read(userProvider);
    if (user == null) return;
    final chatId = _chatController.getChatId(user.id, widget.otherUserId);
    try {
      await _chatController.deleteMessageForMe(
        chatId: chatId,
        messageId: message.id,
        userId: user.id,
      );
      _exitSelectionMode();
      ToastService.instance.showSuccess('Message deleted');
    } catch (e) {
      ToastService.instance.showError('Failed to delete message');
    }
  }

  Future<void> _confirmDeleteForEveryone(ChatMessageModel message) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete for everyone'),
        content: const Text(
          'This message will be deleted for everyone. This action cannot be undone.',
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: const Text('Delete for everyone'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _deleteMessageForEveryone(message);
    }
  }

  Future<void> _deleteMessageForEveryone(ChatMessageModel message) async {
    final user = ref.read(userProvider);
    if (user == null) return;
    final chatId = _chatController.getChatId(user.id, widget.otherUserId);
    try {
      await _chatController.deleteMessageForEveryone(
        chatId: chatId,
        messageId: message.id,
        deletedByUserId: user.id,
      );
      _exitSelectionMode();
      ToastService.instance.showSuccess('Message deleted for everyone');
    } catch (e) {
      ToastService.instance.showError('Failed to delete message');
    }
  }

  // ==================== MULTI-SELECT / SELECTION TOOLBAR ====================

  /// Selection mode is simply "at least one message is ticked".
  bool get _isSelectionMode => _selectedMessageIds.isNotEmpty;

  /// The ticked messages, in conversation order, restricted to ids that are
  /// still on screen (a message deleted or hidden in another emission drops
  /// out of the selection instead of dangling).
  List<ChatMessageModel> get _selectedMessages =>
      _latestMessages.where((m) => _selectedMessageIds.contains(m.id)).toList();

  /// Actions the toolbar should offer right now — derived from the same pure
  /// rules the tests exercise.
  ChatToolbarActions get _selectionActions {
    final user = ref.read(userProvider);
    if (user == null) return ChatToolbarActions.none;
    return MessageActionRules.resolveForSelection(_selectedMessages, user.id);
  }

  void _enterSelectionMode(ChatMessageModel message) {
    setState(() {
      _selectedMessageIds
        ..clear()
        ..add(message.id);
    });
  }

  void _toggleSelection(ChatMessageModel message) {
    setState(() {
      if (!_selectedMessageIds.remove(message.id)) {
        _selectedMessageIds.add(message.id);
      }
    });
  }

  void _exitSelectionMode() {
    if (_selectedMessageIds.isEmpty) return;
    setState(_selectedMessageIds.clear);
  }

  /// Long press decides between "start selecting" and "legacy action sheet".
  ///
  /// Outside selection a long press on a normal message ticks it and swaps the
  /// header for the toolbar; inside selection it opens the familiar sheet for
  /// that one message (Copy / Report live only there). Deleted messages and
  /// rich cards (prescription / appointment) never enter selection.
  void _handleMessageLongPress(ChatMessageModel message) {
    final user = ref.read(userProvider);
    if (user == null || message.isDeleted) return;
    if (!MessageActionRules.isSelectable(message, user.id)) {
      _showMessageActions(message, Offset.zero);
      return;
    }
    if (_isSelectionMode) {
      _showMessageActions(message, Offset.zero);
      return;
    }
    _enterSelectionMode(message);
  }

  void _onSelectionReply() {
    final selected = _selectedMessages;
    if (selected.length != 1) return;
    final message = selected.first;
    _exitSelectionMode();
    _setReplyToMessage(message);
  }

  void _onSelectionForward() {
    final actions = _selectionActions;
    if (!actions.canForward) return;
    _forwardSelectedMessages();
  }

  void _onSelectionEdit() {
    final selected = _selectedMessages;
    if (selected.length != 1) return;
    final user = ref.read(userProvider);
    if (user == null || !MessageActionRules.canEdit(selected.first, user.id)) {
      return;
    }
    _exitSelectionMode();
    _startEditingMessage(selected.first);
  }

  void _onSelectionDelete() {
    final actions = _selectionActions;
    if (!actions.canDeleteForMe) return;
    _showDeleteOptionsDialog();
  }

  Future<void> _onSelectionDownload() async {
    if (_isDownloadingImage) return;
    final selected = _selectedMessages;
    if (selected.length != 1) return;
    final message = selected.first;
    if (!MessageActionRules.canDownload(message)) return;
    setState(() => _isDownloadingImage = true);
    try {
      await ChatImageDownloadService.saveImageToGallery(
        imageUrl: message.mediaUrl ?? '',
        messageId: message.id,
      );
    } finally {
      if (mounted) setState(() => _isDownloadingImage = false);
    }
  }

  // ==================== DELETE (3 OPTIONS) ====================

  /// The single dialog behind the toolbar's delete button. "Delete for
  /// Everyone" only appears when *every* ticked message is your own and not
  /// already deleted — otherwise only the two account-scoped options show.
  Future<void> _showDeleteOptionsDialog() async {
    final user = ref.read(userProvider);
    if (user == null) return;
    final selected = _selectedMessages;
    if (selected.isEmpty) return;
    final canEveryone = selected.every(
      (m) => MessageActionRules.canDeleteForEveryone(m, user.id),
    );
    final count = selected.length;

    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(count == 1 ? 'Delete message?' : 'Delete $count messages?'),
        content: Text(
          count == 1
              ? 'Choose whether to delete this message only for you or for everyone.'
              : 'Choose whether to delete these messages only for you or for everyone.',
          style: TextStyle(fontSize: context.fs(13.5), height: 1.4),
        ),
        actions: [
          if (canEveryone)
            TextButton(
              onPressed: () => Navigator.pop(context, 'everyone'),
              child: const Text(
                'Delete for Everyone',
                style: TextStyle(color: Colors.red),
              ),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'me'),
            child: const Text(
              'Delete for Me',
              style: TextStyle(color: Colors.red),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'cancel'),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );

    switch (choice) {
      case 'everyone':
        await _deleteSelectionForEveryone();
        break;
      case 'me':
        await _deleteSelectionForMe();
        break;
      default:
        break;
    }
  }

  Future<void> _deleteSelectionForMe() async {
    final user = ref.read(userProvider);
    if (user == null) return;
    final selected = _selectedMessages
        .where((m) => MessageActionRules.canDeleteForMe(m))
        .toList();
    if (selected.isEmpty) return;
    final chatId = _chatController.getChatId(user.id, widget.otherUserId);
    try {
      await _chatController.deleteMessagesForMe(
        chatId: chatId,
        messageIds: [for (final m in selected) m.id],
        userId: user.id,
      );
      _exitSelectionMode();
      ToastService.instance.showSuccess(
        selected.length == 1 ? 'Message deleted' : 'Messages deleted',
      );
    } catch (e) {
      ToastService.instance.showError('Failed to delete message');
    }
  }

  Future<void> _deleteSelectionForEveryone() async {
    final user = ref.read(userProvider);
    if (user == null) return;
    final selected = _selectedMessages
        .where((m) => MessageActionRules.canDeleteForEveryone(m, user.id))
        .toList();
    if (selected.isEmpty) return;
    final chatId = _chatController.getChatId(user.id, widget.otherUserId);
    try {
      await _chatController.deleteMessagesForEveryone(
        chatId: chatId,
        messageIds: [for (final m in selected) m.id],
        deletedByUserId: user.id,
      );
      _exitSelectionMode();
      ToastService.instance.showSuccess('Message deleted for everyone');
    } catch (e) {
      ToastService.instance.showError('Failed to delete message');
    }
  }

  // ==================== EDIT ====================

  void _startEditingMessage(ChatMessageModel message) {
    final user = ref.read(userProvider);
    if (user == null || !MessageActionRules.canEdit(message, user.id)) return;
    setState(() {
      _isEditingMessage = true;
      _editingMessageId = message.id;
      _originalEditText = message.message;
      _replyToMessage = null;
      _messageController.text = message.message;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) FocusScope.of(context).requestFocus();
    });
  }

  void _cancelEditing() {
    if (!_isEditingMessage) return;
    setState(() {
      _isEditingMessage = false;
      _editingMessageId = null;
      _originalEditText = null;
      _messageController.clear();
    });
  }

  Future<void> _submitEdit(String newText) async {
    final user = ref.read(userProvider);
    final messageId = _editingMessageId;
    if (user == null || messageId == null) {
      _cancelEditing();
      return;
    }

    final text = newText.trim();
    if (text.isEmpty) {
      ToastService.instance.showError('Message cannot be empty');
      return;
    }

    ChatMessageModel? target;
    for (final m in _latestMessages) {
      if (m.id == messageId) {
        target = m;
        break;
      }
    }
    if (target == null || !MessageActionRules.canEdit(target, user.id)) {
      ToastService.instance.showError('This message can no longer be edited');
      _cancelEditing();
      return;
    }
    if (text == target.message) {
      // Nothing changed — leave the composer as it was.
      _cancelEditing();
      return;
    }

    final chatId = _chatController.getChatId(user.id, widget.otherUserId);
    try {
      await _chatController.editMessage(
        chatId: chatId,
        messageId: messageId,
        newMessage: text,
        editorId: user.id,
      );
      if (!mounted) return;
      _cancelEditing();
      ToastService.instance.showSuccess('Message updated');
    } catch (e) {
      // Keep the composer open so the typed text is not lost.
      if (!mounted) return;
      ToastService.instance.showError('Could not update the message');
    }
  }

  // ==================== FORWARD ====================

  Future<void> _forwardSelectedMessages() async {
    if (_isForwarding) return;
    final user = ref.read(userProvider);
    if (user == null) return;
    final selected = _selectedMessages;
    if (selected.isEmpty) return;

    setState(() => _isForwarding = true);
    try {
      final sent = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (_) => ForwardRecipientScreen(
            currentUserId: user.id,
            currentUserRole: user.role,
            messages: selected,
          ),
        ),
      );
      if (!mounted) return;
      if (sent == true) {
        _exitSelectionMode();
        ToastService.instance.showSuccess('Message forwarded');
      }
    } finally {
      if (mounted) setState(() => _isForwarding = false);
    }
  }

  // ==================== REPLY JUMP ====================

  GlobalKey _keyForJump(String messageId) =>
      _messageKeys.putIfAbsent(messageId, GlobalKey.new);

  /// Scrolls a tapped reply preview to the message it quotes and flashes it.
  ///
  /// When the quoted message is gone (deleted for me, outside the loaded
  /// window) the preview says so instead of scrolling to nothing.
  Future<void> _jumpToOriginalMessage(String messageId) async {
    ChatMessageModel? original;
    var originalIndex = -1;
    for (var i = 0; i < _latestMessages.length; i++) {
      if (_latestMessages[i].id == messageId) {
        original = _latestMessages[i];
        originalIndex = i;
        break;
      }
    }
    if (original == null) {
      ToastService.instance.showInfo('Original message is no longer available');
      return;
    }

    setState(() {
      _pendingJumpMessageId = messageId;
      _highlightedMessageId = messageId;
    });

    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(milliseconds: 2400), () {
      if (!mounted) return;
      setState(() {
        _highlightedMessageId = null;
        _pendingJumpMessageId = null;
      });
      // Keys are only needed for the flash, so drop them afterwards rather
      // than letting the map grow with the whole conversation.
      _messageKeys.clear();
    });

    await WidgetsBinding.instance.endOfFrame;

    // Lazy lists only build what is on screen, so a message far up the
    // history has no context yet: scroll roughly to it first, then refine.
    BuildContext? target = _messageKeys[messageId]?.currentContext;
    for (var attempt = 0; target == null && attempt < 3; attempt++) {
      if (!_scrollController.hasClients) break;
      final position = _scrollController.position;
      final estimate = (originalIndex * 96.0).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if ((position.pixels - estimate).abs() < 4) break;
      await _scrollController.animateTo(
        estimate,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeInOutCubic,
      );
      if (!mounted) return;
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      target = _messageKeys[messageId]?.currentContext;
    }

    if (!mounted) return;
    if (target != null) {
      await Scrollable.ensureVisible(
        target,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeInOutCubic,
        alignment: 0.4,
      );
    }
    if (mounted && _pendingJumpMessageId == messageId) {
      setState(() => _pendingJumpMessageId = null);
    }
  }

  // ==================== SEND MESSAGE ====================
  void _sendMessage() {
    if (_isEditingMessage) {
      _submitEdit(_messageController.text);
      return;
    }
    if (_messageController.text.trim().isEmpty) return;
    final user = ref.read(userProvider);
    if (user == null) return;
    final message = _messageController.text.trim();
    _messageController.clear();

    if (_isTypingFlag) {
      _isTypingFlag = false;
      _sendTypingStatus(false); // fire and forget
    }
    _typingTimer?.cancel();

    final reply = _replyToMessage;
    setState(() {
      _replyToMessage = null;
    });

    _executeSend(user.id, message, reply);
  }

  Future<void> _executeSend(
    String senderId,
    String message,
    ReplyData? reply,
  ) async {
    // The user's own message must land on screen even when they were reading
    // history when they pressed send; consumed by the stream-growth scroll.
    _pendingScrollToBottom = true;
    try {
      if (reply != null) {
        await _chatController.sendMessageWithReply(
          senderId: senderId,
          receiverId: widget.otherUserId,
          message: message,
          messageType: 'text',
          replyTo: reply,
          receiverRole: widget.otherUserRole,
        );
      } else {
        await _chatController.sendMessage(
          senderId: senderId,
          receiverId: widget.otherUserId,
          message: message,
          messageType: 'text',
          receiverRole: widget.otherUserRole,
        );
      }
      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
      ToastService.instance.showError(
        'Failed to send message: ${e.toString()}',
      );
    }
  }

  Future<void> _pickAndSendImage(ImageSource source) async {
    final user = ref.read(userProvider);
    if (user == null) return;
    try {
      final XFile? pickedFile = await _imagePicker.pickImage(
        source: source,
        imageQuality: 80,
      );
      if (pickedFile != null) {
        ToastService.instance.showInfo('Uploading image...');
        _pendingScrollToBottom = true;
        await _chatController.sendImageMessage(
          senderId: user.id,
          receiverId: widget.otherUserId,
          imageFile: File(pickedFile.path),
          folder: widget.otherUserRole == 'doctor' ? 'doctor' : 'patient',
          receiverRole: widget.otherUserRole,
        );
        ToastService.instance.showSuccess('Image sent successfully');
        _scrollToBottom();
      }
    } catch (e) {
      ToastService.instance.showError('Failed to send image: ${e.toString()}');
    }
  }

  // ==================== DOCUMENT SENDING ====================
  Future<void> _pickAndSendDocument() async {
    final user = ref.read(userProvider);
    if (user == null) return;
    try {
      FilePickerResult? result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: [
          'pdf',
          'doc',
          'docx',
          'xls',
          'xlsx',
          'txt',
          'jpg',
          'png',
        ],
      );
      if (result != null && result.files.single.path != null) {
        final file = File(result.files.single.path!);
        final fileSize = await file.length();
        // Check file size (limit to 10MB)
        if (fileSize > 10 * 1024 * 1024) {
          ToastService.instance.showError('File size should be less than 10MB');
          return;
        }
        ToastService.instance.showInfo('Uploading document...');
        _pendingScrollToBottom = true;
        await _chatController.sendDocumentMessage(
          senderId: user.id,
          receiverId: widget.otherUserId,
          documentFile: file,
          fileName: result.files.single.name,
          folder: widget.otherUserRole == 'doctor' ? 'doctor' : 'patient',
          receiverRole: widget.otherUserRole,
        );
        ToastService.instance.showSuccess('Document sent successfully');
        _scrollToBottom();
      }
    } catch (e) {
      ToastService.instance.showError(
        'Failed to send document: ${e.toString()}',
      );
    }
  }

  /// Opens the WhatsApp-style overflow menu for this conversation as a popup
  /// anchored directly beneath the 3-dot button.
  ///
  /// Entries are driven by the actually logged-in role so a patient never
  /// sees Prescription and a doctor never sees the Favourites toggle.
  Future<void> _openChatMenu() async {
    final user = ref.read(userProvider);
    if (user == null) return;
    if (_isChatMenuOpen) return;

    final currentUserRole = user.role;
    final otherUserRole =
        widget.otherUserRole ??
        widget.otherUserType ??
        (currentUserRole == 'doctor' ? 'patient' : 'doctor');

    final chatId = _chatController.getChatId(user.id, widget.otherUserId);

    setState(() => _isChatMenuOpen = true);
    await showChatMenu(
      context: context,
      ref: ref,
      anchorKey: _menuAnchorKey,
      anchorLink: _menuAnchorLink,
      onSearch: _openSearchMode,
      currentUserId: user.id,
      currentUserRole: currentUserRole,
      otherUserId: widget.otherUserId,
      otherUserName: widget.otherUserName,
      otherUserImage: widget.otherUserImage,
      otherUserRole: otherUserRole,
      chatId: chatId,
      messages: _latestMessages,
    );
    if (mounted) setState(() => _isChatMenuOpen = false);
  }

  void _showAttachmentOptions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          boxShadow: [
            BoxShadow(
              color: Color(0xFF12263F),
              blurRadius: 20,
              offset: Offset(0, -5),
            ),
          ],
        ),
        child: SafeArea(
          child: Padding(
            padding: EdgeInsets.all(context.rsp(16)),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0xFFD6E4F0),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: _buildOption(
                        icon: Icons.camera_alt,
                        label: "Camera",
                        onTap: () {
                          Navigator.pop(context);
                          _pickAndSendImage(ImageSource.camera);
                        },
                      ),
                    ),
                    Expanded(
                      child: _buildOption(
                        icon: Icons.photo,
                        label: "Gallery",
                        onTap: () {
                          Navigator.pop(context);
                          _pickAndSendImage(ImageSource.gallery);
                        },
                      ),
                    ),
                    Expanded(
                      child: _buildOption(
                        icon: Icons.insert_drive_file,
                        label: "Document",
                        onTap: () {
                          Navigator.pop(context);
                          _pickAndSendDocument();
                        },
                      ),
                    ),
                    if (ref.read(userProvider)?.role == 'patient')
                      Expanded(
                        child: _buildOption(
                          icon: Icons.folder_shared,
                          label: "Reports",
                          onTap: () {
                            Navigator.pop(context);
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => const ReportHistoryScreen(),
                              ),
                            );
                          },
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildOption({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            height: context.rsp(60),
            width: context.rsp(60),
            decoration: BoxDecoration(
              color: const Color(0xFFEDF2F8),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0xFFD6E4F0), width: 1.5),
            ),
            child: Icon(icon, color: const Color(0xFF062B72), size: 28),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: context.fs(13),
              color: const Color(0xFF1F2F44),
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  // ==================== CALL METHODS ====================
  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients &&
          _scrollController.position.maxScrollExtent > 0) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _scrollToBottomImmediately() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _snapToBottom(0));
  }

  /// Jumps to the bottom and re-snaps over the next couple of frames.
  ///
  /// `ListView.maxScrollExtent` is an estimate until every child has been
  /// laid out, so a single jump on first load routinely landed a long
  /// conversation part-way up the list instead of on the newest message.
  /// Re-snapping until the extent stops moving is what actually lands at the
  /// bottom; the attempt bound stops it fighting the user if they scroll up
  /// immediately.
  void _snapToBottom(int attempt) {
    if (!mounted || !_scrollController.hasClients) return;
    final position = _scrollController.position;
    final target = position.maxScrollExtent;
    if (position.pixels != target) {
      _scrollController.jumpTo(target);
    }
    if (attempt < 2) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _snapToBottom(attempt + 1),
      );
    }
  }

  Future<void> _startAudioCall() async {
    final user = ref.read(userProvider);
    if (user == null) {
      ToastService.instance.showError('Please login to make calls');
      return;
    }
    final isDoctorOnline = ref.read(doctorOnlineProvider(widget.otherUserId));
    if (widget.otherUserRole == 'doctor' && !isDoctorOnline) {
      ToastService.instance.showWarning(
        'Doctor is offline. Please try again later.',
      );
      _showOfflineDialog();
      return;
    }
    ToastService.instance.showInfo(
      'Initiating call to ${widget.otherUserName}...',
    );
    final channelId = 'call_${DateTime.now().millisecondsSinceEpoch}';
    try {
      final result = await _callController.startCallWithCheck(
        channelId: channelId,
        callerId: user.id,
        receiverId: widget.otherUserId,
        callerName: user.fullname,
        receiverName: widget.otherUserName,
        receiverType: widget.otherUserType ?? 'doctor',
        callerImage: user.image,
        receiverImage: widget.otherUserImage,
        callType: 'audio',
        callerType: user.role,
      );
      if (!mounted) return;
      if (result['success'] == true) {
        ToastService.instance.showSuccess('Call connected');
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => CallScreen(
              channelId: channelId,
              callId: result['callId'],
              callType: 'audio',
              otherUserName: widget.otherUserName,
              otherUserImage: widget.otherUserImage,
              currentUserId: user.id,
              otherUserId: widget.otherUserId,
              otherUserType: widget.otherUserType ?? 'doctor',
              isCaller: true,
            ),
          ),
        );
      } else {
        ToastService.instance.showError(
          result['error'] ?? 'Failed to start call',
        );
      }
    } catch (e) {
      if (!mounted) return;
      ToastService.instance.showError('Error starting call: ${e.toString()}');
    }
  }

  void _showOfflineDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Doctor Offline'),
        content: const Text(
          'The doctor is currently offline. Please try again later or send a message.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final difference = now.difference(time);
    if (difference.inMinutes < 1) return 'Just now';
    if (difference.inHours < 1) return _formatTimeWithSeconds(time);
    if (difference.inDays < 1) return _formatTimeWithSeconds(time);
    return DateFormat('h:mm a').format(time);
  }

  String _formatLastSeen(DateTime? lastSeen) {
    if (lastSeen == null) return '';
    final now = DateTime.now();
    final diff = now.difference(lastSeen);
    if (diff.inMinutes < 1) return 'last seen just now';
    if (diff.inHours < 1) return 'last seen ${diff.inMinutes}m ago';
    if (diff.inDays < 1)
      return 'last seen today at ${DateFormat('h:mm a').format(lastSeen)}';
    if (diff.inDays == 1)
      return 'last seen yesterday at ${DateFormat('h:mm a').format(lastSeen)}';
    return 'last seen ${DateFormat('MMM d, h:mm a').format(lastSeen)}';
  }

  String _formatTimeWithSeconds(DateTime time) {
    return DateFormat('h:mm a').format(time);
  }

  String _getDateSeparator(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final messageDate = DateTime(date.year, date.month, date.day);
    if (messageDate == today) {
      return 'Today';
    } else if (messageDate == yesterday) {
      return 'Yesterday';
    } else {
      return DateFormat('EEEE, MMMM d, yyyy').format(date);
    }
  }

  String _getHeaderForScrollPosition(List<ChatMessageModel> messages) {
    if (messages.isEmpty) return '';
    if (_scrollController.hasClients &&
        _scrollController.position.hasContentDimensions) {
      final firstVisibleIndex =
          (_scrollController.position.pixels /
                  (_scrollController.position.viewportDimension /
                      messages.length))
              .floor();
      final safeIndex = firstVisibleIndex.clamp(0, messages.length - 1);
      if (safeIndex < messages.length) {
        return _getDateSeparator(messages[safeIndex].timestamp);
      }
    }
    return _getDateSeparator(messages.last.timestamp);
  }

  List<Map<String, dynamic>> _groupMessagesWithHeaders(
    List<ChatMessageModel> messages,
  ) {
    final List<Map<String, dynamic>> items = [];
    if (messages.isEmpty) return items;
    DateTime? lastDate;
    for (var message in messages) {
      final messageDate = DateTime(
        message.timestamp.year,
        message.timestamp.month,
        message.timestamp.day,
      );
      if (lastDate == null || messageDate != lastDate) {
        items.add({
          'type': 'header',
          'date': message.timestamp,
          'dateSeparator': _getDateSeparator(message.timestamp),
        });
        lastDate = messageDate;
      }
      items.add({'type': 'message', 'message': message});
    }
    return items;
  }

  // ==================== BUILD METHODS ====================
  @override
  Widget build(BuildContext context) {
    final user = ref.watch(userProvider);
    if (user == null) {
      return const Scaffold(
        body: Center(child: Text('Please sign in to continue chatting.')),
      );
    }

    // Centralized doctor presence — same source as Doctor List and Chat List
    final isDoctorOnline = widget.otherUserRole == 'doctor'
        ? ref.watch(doctorOnlineProvider(widget.otherUserId))
        : false;
    final otherUserLastSeen = widget.otherUserRole == 'doctor'
        ? ref.watch(doctorLastSeenProvider(widget.otherUserId))
        : null;

    return Scaffold(
      backgroundColor: const Color(0xFFEDF2F8),
      body: Container(
        decoration: const BoxDecoration(
          image: DecorationImage(
            image: AssetImage('assets/images/download.jpeg'),
            fit: BoxFit.contain,
            opacity: 0.1,
          ),
        ),
        child: Stack(
          children: [
            SafeArea(
              bottom: false,
              child: Column(
                children: [
                  // Custom Chat Header — swapped for the in-chat search header
                  // while searching, without touching the message list.
                  AnimatedSize(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.topCenter,
                    child: _isSelectionMode
                        ? _buildSelectionHeader(currentUserId: user.id)
                        : _isSearching
                        ? _buildSearchHeader()
                        : _buildNormalHeader(
                            isDoctorOnline: isDoctorOnline,
                            otherUserLastSeen: otherUserLastSeen,
                            currentUserId: user.id,
                          ),
                  ),
                  // Chat messages + input
                  Expanded(
                    child: GestureDetector(
                      onTap: () => FocusScope.of(context).unfocus(),
                      child: Column(
                        children: [
                          Expanded(
                            child: StreamBuilder<List<ChatMessageModel>>(
                              stream: _messagesStream,
                              initialData: OfflineChatService.instance
                                  .getMessagesForChat(
                                    _chatController.getChatId(
                                      user.id,
                                      widget.otherUserId,
                                    ),
                                  )
                                  .map((m) => OfflineConverters.toDomain(m))
                                  .toList(),
                              builder: (context, snapshot) {
                                final messages =
                                    snapshot.data ?? _latestMessages;
                                // Offline-first stream: cached messages are still the
                                // right thing to show on a live-read failure, so only an
                                // error with nothing cached replaces the conversation.
                                // The old branch dumped the raw exception string (e.g.
                                // the full `[cloud_firestore/permission-denied]` text)
                                // over the whole chat, even though initialData was
                                // seeded from OfflineChatService.
                                if (snapshot.hasError && messages.isEmpty) {
                                  return Center(
                                    child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        const Icon(
                                          Icons.error_outline,
                                          size: 48,
                                          color: Colors.red,
                                        ),
                                        const SizedBox(height: 12),
                                        Text(
                                          'Could not load messages.\nCheck your connection.',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(),
                                        ),
                                        const SizedBox(height: 16),
                                        ElevatedButton(
                                          onPressed: () => setState(() {
                                            final user = ref.read(userProvider);
                                            if (user != null) {
                                              _messagesStream = _chatController
                                                  .getMessagesOfflineFirst(
                                                    user.id,
                                                    widget.otherUserId,
                                                  );
                                              _olderMessagesExhausted = false;
                                            }
                                          }),
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: const Color(
                                              0xFF062B72,
                                            ),
                                          ),
                                          child: const Text('Retry'),
                                        ),
                                      ],
                                    ),
                                  );
                                }
                                // Keep an in-memory copy for the header overflow menu so
                                // Search / Media screens can reuse it without refetching.
                                _latestMessages = messages;
                                // Realtime arrivals stay searchable without a reload.
                                _syncSearchWithStream();
                                WidgetsBinding.instance.addPostFrameCallback((
                                  _,
                                ) {
                                  _markMessagesAsSeen(messages);
                                  // A message that just arrived is already on this
                                  // device, so the sender's tick advances to delivered.
                                  _acknowledgeInboundDelivery();
                                });
                                if (messages.length != _lastMessageCount) {
                                  final wasEmpty = _lastMessageCount == 0;
                                  final grew =
                                      messages.length > _lastMessageCount;
                                  _lastMessageCount = messages.length;
                                  // Only auto-scroll for a newly appended message, and
                                  // only when the user is already near the bottom — never
                                  // yank the viewport away from history they are reading.
                                  // A just-sent message always scrolls, whatever the
                                  // user was looking at before they pressed send.
                                  if (grew &&
                                      !wasEmpty &&
                                      mounted &&
                                      !_isSearching &&
                                      (_isNearBottom ||
                                          _nearBottomNow ||
                                          _pendingScrollToBottom)) {
                                    _pendingScrollToBottom = false;
                                    _scrollToBottom();
                                  }
                                }
                                if (_isFirstLoad &&
                                    messages.isNotEmpty &&
                                    mounted) {
                                  _isFirstLoad = false;
                                  WidgetsBinding.instance.addPostFrameCallback((
                                    _,
                                  ) {
                                    _scrollToBottomImmediately();
                                  });
                                }
                                if (messages.isEmpty) {
                                  return _buildEmptyState();
                                }
                                final groupedItems = _groupMessagesWithHeaders(
                                  messages,
                                );
                                final currentHeader =
                                    _getHeaderForScrollPosition(messages);
                                if (_currentDateHeader != currentHeader) {
                                  WidgetsBinding.instance.addPostFrameCallback((
                                    _,
                                  ) {
                                    if (mounted) {
                                      setState(() {
                                        _currentDateHeader = currentHeader;
                                        _lastDateHeader = currentHeader;
                                      });
                                    }
                                  });
                                }
                                final pinnedAppointment = messages
                                    .where(
                                      (m) =>
                                          m.isPinned && m.isAppointmentMessage,
                                    )
                                    .toList();
                                return Column(
                                  children: [
                                    if (pinnedAppointment.isNotEmpty)
                                      _buildPinnedAppointmentBanner(
                                        pinnedAppointment.last,
                                      ),
                                    Expanded(
                                      child: Stack(
                                        children: [
                                          ListView.builder(
                                            controller: _scrollController,
                                            padding: EdgeInsets.symmetric(
                                              horizontal: context.rsp(16),
                                              vertical: 16,
                                            ),
                                            itemCount: groupedItems.length,
                                            itemBuilder: (context, index) {
                                              final item = groupedItems[index];
                                              if (item['type'] == 'header') {
                                                return Column(
                                                  children: [
                                                    const SizedBox(height: 8),
                                                    _buildDateSeparator(
                                                      item['dateSeparator'],
                                                    ),
                                                    const SizedBox(height: 8),
                                                  ],
                                                );
                                              } else {
                                                final message =
                                                    item['message']
                                                        as ChatMessageModel;
                                                // Ownership is decided only by comparing the
                                                // authenticated user's id with the senderId
                                                // stored on the message — never by colour,
                                                // position or a patient/doctor assumption —
                                                // so it is identical for patient→doctor and
                                                // doctor→patient chats, and identical for
                                                // messages decoded from Firestore and from the
                                                // offline Hive cache.
                                                final isMe =
                                                    MessageActionRules.isOwnMessage(
                                                      message,
                                                      user.id,
                                                    );
                                                var bubble =
                                                    _buildMessageBubble(
                                                      message,
                                                      isMe,
                                                    );
                                                // Swipe-to-reply, tap-to-select and the flash
                                                // overlay. The appointment card returns early
                                                // from _buildMessageBubble and stays plain.
                                                if (!message
                                                    .isAppointmentMessage) {
                                                  bubble =
                                                      _wrapBubbleForInteraction(
                                                        message: message,
                                                        isMe: isMe,
                                                        child: bubble,
                                                      );
                                                }
                                                // Place the row on its side explicitly.
                                                // _buildMessageBubble only signals the side
                                                // through CrossAxisAlignment.end/start, which
                                                // works solely while the row keeps the full
                                                // width the ListView hands out. The interaction
                                                // layers above lay the bubble out inside a
                                                // Stack, and a Stack passes its child *loose*
                                                // constraints — the Column then shrink-wraps
                                                // and every message, sender or not, falls back
                                                // to the left edge. An Align pins the side
                                                // independently of any wrapper above it.
                                                bubble = Align(
                                                  alignment:
                                                      chatMessageRowAlignment(
                                                        message,
                                                        user.id,
                                                      ),
                                                  child: bubble,
                                                );
                                                // Matched / jumped-to messages get a key, so
                                                // stepping through results (or tapping a reply
                                                // preview) can scroll straight to them.
                                                final isMatch =
                                                    _isSearching &&
                                                    _searchMatches.any(
                                                      (m) =>
                                                          m.messageId ==
                                                          message.id,
                                                    );
                                                final needsJump =
                                                    _pendingJumpMessageId ==
                                                        message.id ||
                                                    _highlightedMessageId ==
                                                        message.id;
                                                if (!isMatch && !needsJump)
                                                  return bubble;
                                                return KeyedSubtree(
                                                  key: isMatch
                                                      ? _keyForMessage(
                                                          message.id,
                                                        )
                                                      : _keyForJump(message.id),
                                                  child: bubble,
                                                );
                                              }
                                            },
                                          ),
                                          if (_showStickyHeader &&
                                              _currentDateHeader.isNotEmpty)
                                            Positioned(
                                              top: 0,
                                              left: 0,
                                              right: 0,
                                              child: FadeTransition(
                                                opacity: _fadeAnimation,
                                                child: Container(
                                                  color: const Color(
                                                    0xFFEDF2F8,
                                                  ).withOpacity(0.95),
                                                  child: Center(
                                                    child: AnimatedContainer(
                                                      duration: const Duration(
                                                        milliseconds: 200,
                                                      ),
                                                      margin:
                                                          EdgeInsets.symmetric(
                                                            vertical: 12,
                                                            horizontal:
                                                                _scrollOffset >
                                                                    100
                                                                ? 0
                                                                : 16,
                                                          ),
                                                      padding:
                                                          const EdgeInsets.symmetric(
                                                            horizontal: 16,
                                                            vertical: 6,
                                                          ),
                                                      decoration: BoxDecoration(
                                                        color: const Color(
                                                          0xFFD6E4F0,
                                                        ).withOpacity(0.9),
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              20,
                                                            ),
                                                        boxShadow: [
                                                          BoxShadow(
                                                            color: const Color(
                                                              0xFF12263F,
                                                            ).withOpacity(0.06),
                                                            blurRadius: 4,
                                                            offset:
                                                                const Offset(
                                                                  0,
                                                                  1,
                                                                ),
                                                          ),
                                                        ],
                                                      ),
                                                      child: Text(
                                                        _currentDateHeader,
                                                        style: TextStyle(
                                                          fontSize: context.fs(
                                                            12,
                                                          ),
                                                          fontWeight:
                                                              FontWeight.w600,
                                                          color: const Color(
                                                            0xFF1F2F44,
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          if (_isLoadingOlder)
                                            Positioned(
                                              top: 8,
                                              left: 0,
                                              right: 0,
                                              child: Center(
                                                child: Container(
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 14,
                                                        vertical: 8,
                                                      ),
                                                  decoration: BoxDecoration(
                                                    color: const Color(
                                                      0xFF12263F,
                                                    ).withOpacity(0.7),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          20,
                                                        ),
                                                  ),
                                                  child: const SizedBox(
                                                    width: 14,
                                                    height: 14,
                                                    child:
                                                        CircularProgressIndicator(
                                                          strokeWidth: 2,
                                                          color: Colors.white,
                                                        ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ],
                                );
                              },
                            ),
                          ),
                          _buildMessageInput(),
                        ],
                      ),
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

  /// WhatsApp-style in-chat search header, shown in place of the normal header
  /// while search mode is active. Keeping it as a header swap means the chat
  /// list underneath is never rebuilt, reloaded or cleared.
  Widget _buildSearchHeader() {
    final total = _searchMatches.length;
    final hasQuery = _searchQuery.trim().isNotEmpty;
    final position = hasQuery && total > 0
        ? '${_activeMatchIndex + 1} of $total'
        : '';

    return Container(
      padding: EdgeInsets.symmetric(horizontal: context.rsp(6), vertical: 8),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [
            Color(0xFF284F85),
            Color(0xFF15386A),
            Color(0xFF0D264E),
            Color(0xFF081938),
          ],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0B2041).withValues(alpha: 0.32),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          // Close search — returns to the normal chat header instantly.
          GestureDetector(
            onTap: _closeSearchMode,
            child: Container(
              padding: const EdgeInsets.all(9),
              child: const Icon(
                Icons.arrow_back_rounded,
                color: Colors.white,
                size: 22,
              ),
            ),
          ),
          SizedBox(width: context.rsp(4)),
          // Search field, styled with the OPD metallic inner gradient.
          Expanded(
            child: Container(
              constraints: BoxConstraints(minHeight: context.rsp(42)),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFFF3F7FB), Colors.white, Color(0xFFF0F4F9)],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
                borderRadius: BorderRadius.circular(21),
                border: Border.all(color: const Color(0xFFBAC7D8), width: 1.5),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.search_rounded,
                    size: 18,
                    color: Color(0xFF0E274D),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      focusNode: _searchFocusNode,
                      onChanged: _onSearchChanged,
                      textInputAction: TextInputAction.search,
                      style: TextStyle(
                        fontSize: context.fs(13.5),
                        fontWeight: FontWeight.w500,
                        color: const Color(0xFF1E2F44),
                      ),
                      cursorColor: const Color(0xFF062B72),
                      decoration: InputDecoration(
                        hintText: 'Search messages...',
                        hintStyle: TextStyle(
                          fontSize: context.fs(13.5),
                          color: const Color(0xFF7E90A6),
                        ),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ),
                  if (hasQuery)
                    GestureDetector(
                      onTap: () {
                        _searchController.clear();
                        _onSearchChanged('');
                        _searchFocusNode.requestFocus();
                      },
                      child: const Padding(
                        padding: EdgeInsets.all(11),
                        child: Icon(
                          Icons.close_rounded,
                          size: 18,
                          color: Color(0xFF647890),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          SizedBox(width: context.rsp(4)),
          // Result counter
          if (position.isNotEmpty)
            Flexible(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Text(
                  position,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
            )
          else if (hasQuery)
            Flexible(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Text(
                  'No results',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: Colors.white70),
                ),
              ),
            ),
          // Previous / next result
          _buildSearchNavButton(
            icon: Icons.keyboard_arrow_up_rounded,
            enabled: hasQuery && total > 0,
            onTap: () => _stepSearchMatch(-1),
          ),
          _buildSearchNavButton(
            icon: Icons.keyboard_arrow_down_rounded,
            enabled: hasQuery && total > 0,
            onTap: () => _stepSearchMatch(1),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchNavButton({
    required IconData icon,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Container(
        margin: const EdgeInsets.only(left: 2),
        padding: const EdgeInsets.all(9),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: enabled ? 0.15 : 0.06),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(
          icon,
          color: enabled ? Colors.white : Colors.white38,
          size: 22,
        ),
      ),
    );
  }

  /// Header shown while messages are ticked: the count plus exactly the
  /// actions `MessageActionRules` allows for this selection.
  Widget _buildSelectionHeader({required String currentUserId}) {
    final actions = _selectionActions;
    final count = _selectedMessages.length;

    return Container(
      constraints: BoxConstraints(maxWidth: context.contentMaxWidth),
      padding: EdgeInsets.symmetric(horizontal: context.rsp(12), vertical: 10),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [
            Color(0xFF284F85),
            Color(0xFF15386A),
            Color(0xFF0D264E),
            Color(0xFF081938),
          ],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0B2041).withValues(alpha: 0.32),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: _exitSelectionMode,
            behavior: HitTestBehavior.opaque,
            child: Container(
              padding: const EdgeInsets.all(9),
              child: const Icon(
                Icons.close_rounded,
                color: Colors.white,
                size: 22,
              ),
            ),
          ),
          SizedBox(width: context.rsp(8)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '$count',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: context.fs(15),
                  ),
                ),
                Text(
                  count == 1 ? 'message selected' : 'messages selected',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: context.fs(11),
                  ),
                ),
              ],
            ),
          ),
          if (actions.canReply)
            _selectionAction(
              icon: Icons.reply_rounded,
              tooltip: 'Reply',
              onTap: _onSelectionReply,
            ),
          if (actions.canEdit)
            _selectionAction(
              icon: Icons.edit_outlined,
              tooltip: 'Edit',
              onTap: _onSelectionEdit,
            ),
          if (actions.canDownload)
            _selectionAction(
              icon: Icons.download_rounded,
              tooltip: 'Save to gallery',
              onTap: _onSelectionDownload,
              busy: _isDownloadingImage,
            ),
          if (actions.canForward)
            _selectionAction(
              icon: Icons.forward_rounded,
              tooltip: 'Forward',
              onTap: _onSelectionForward,
              busy: _isForwarding,
            ),
          if (actions.canDeleteForMe)
            _selectionAction(
              icon: Icons.delete_outline_rounded,
              tooltip: 'Delete',
              onTap: _onSelectionDelete,
              color: const Color(0xFFFFC7C2),
            ),
        ],
      ),
    );
  }

  /// One icon button in the selection toolbar.
  Widget _selectionAction({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    Color color = Colors.white,
    bool busy = false,
  }) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: busy ? null : onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          margin: const EdgeInsets.only(left: 6),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: busy ? 0.08 : 0.15),
            borderRadius: BorderRadius.circular(12),
          ),
          child: busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : Icon(icon, color: color, size: 20),
        ),
      ),
    );
  }

  /// The normal chat header: back, avatar + presence, name, call, menu.
  Widget _buildNormalHeader({
    required bool isDoctorOnline,
    required DateTime? otherUserLastSeen,
    required String currentUserId,
  }) {
    return Container(
      constraints: BoxConstraints(maxWidth: context.contentMaxWidth),
      padding: EdgeInsets.symmetric(horizontal: context.rsp(12), vertical: 10),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [
            Color(0xFF284F85),
            Color(0xFF15386A),
            Color(0xFF0D264E),
            Color(0xFF081938),
          ],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0B2041).withValues(alpha: 0.32),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          CircularBackButton(onPressed: () => Navigator.pop(context)),
          SizedBox(width: context.rsp(6)),
          // Avatar with online dot
          Stack(
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: const Color(0xFFD6E4F0).withValues(alpha: 0.3),
                backgroundImage: widget.otherUserImage.isNotEmpty
                    ? NetworkImage(widget.otherUserImage)
                    : null,
                child: widget.otherUserImage.isEmpty
                    ? Text(
                        widget.otherUserName.isNotEmpty
                            ? widget.otherUserName[0].toUpperCase()
                            : '?',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: context.fs(14),
                        ),
                      )
                    : null,
              ),
              if (widget.otherUserRole == 'doctor')
                Positioned(
                  bottom: 0,
                  right: 0,
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isDoctorOnline
                          ? const Color(0xFF28A745)
                          : Colors.grey,
                      border: Border.all(
                        color: const Color(0xFF0D264E),
                        width: 2,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          SizedBox(width: context.rsp(8)),
          // Name + Status
          Expanded(
            child: StreamBuilder<DocumentSnapshot>(
              // Hoisted to initState — see `_otherUserDocStream`.
              stream: _otherUserDocStream,
              builder: (context, userSnapshot) {
                final userData =
                    userSnapshot.data?.data() as Map<String, dynamic>?;
                final String? loginType = userData?['loginType'];
                final String? patientId = userData?['patientId'];
                final bool isPatientIdUser =
                    loginType == 'patientId' ||
                    (patientId != null && patientId.isNotEmpty);

                return StreamBuilder<Map<String, dynamic>>(
                  // Memoized on currentUserId — see _chatMetadataStreamFor.
                  // Built fresh per build() before, which re-subscribed the
                  // typing listener on every rebuild of this header.
                  stream: _chatMetadataStreamFor(currentUserId),
                  builder: (context, snapshot) {
                    final chatMetadata =
                        snapshot.data ?? const <String, dynamic>{};
                    final isOtherUserTyping =
                        chatMetadata['typing_${widget.otherUserId}'] == true;
                    return Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                widget.otherUserName,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                  fontSize: context.fs(15),
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (widget.otherUserRole == 'patient') ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.15),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  isPatientIdUser ? 'Patient Card' : 'Online',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        if (isOtherUserTyping)
                          Text(
                            'typing...',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: context.fs(11),
                            ),
                          )
                        else if (isDoctorOnline)
                          Text(
                            'Online',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: const Color(0xFF4ADE80),
                              fontSize: context.fs(11),
                            ),
                          )
                        else if (otherUserLastSeen != null)
                          Text(
                            _formatLastSeen(otherUserLastSeen),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: context.fs(11),
                            ),
                          ),
                      ],
                    );
                  },
                );
              },
            ),
          ),

          // Call button
          GestureDetector(
            onTap: _startAudioCall,
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.call_rounded,
                color: Colors.white,
                size: 20,
              ),
            ),
          ),
          SizedBox(width: context.rsp(6)),
          // Overflow menu (role aware) — floating popup anchor
          CompositedTransformTarget(
            key: _menuAnchorKey,
            link: _menuAnchorLink,
            child: GestureDetector(
              onTap: _openChatMenu,
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: AnimatedRotation(
                  turns: _isChatMenuOpen ? 0.5 : 0.0,
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutCubic,
                  child: const Icon(
                    Icons.more_vert_rounded,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDateSeparator(String dateText) {
    return Center(
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: context.rsp(14), vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFFD6E4F0).withOpacity(0.9),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF12263F).withOpacity(0.06),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Text(
          dateText,
          style: TextStyle(
            fontSize: context.fs(12),
            fontWeight: FontWeight.w600,
            color: const Color(0xFF1F2F44),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: const Color(0xFFD6E4F0).withOpacity(0.4),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.chat_bubble_outline,
              size: 60,
              color: const Color(0xFF062B72).withOpacity(0.4),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'No messages yet',
            style: TextStyle(
              color: const Color(0xFF1F2F44),
              fontSize: context.fs(16),
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Start a conversation',
            style: TextStyle(
              fontSize: context.fs(12),
              color: const Color(0xFF6B7B8D),
            ),
          ),
        ],
      ),
    );
  }

  /// Pinned appointment notice pinned above the message list so both sides
  /// keep seeing the schedule while it is active. It disappears from here at
  /// the same moment `isPinned` flips to false.
  ///
  /// While the slot is actually running this turns into a *live* banner: the
  /// appointment document is watched, the phase pill keeps counting down and
  /// a Join button appears the moment this side is expected — so the Join
  /// action exists exactly where the conversation already is.
  Widget _buildPinnedAppointmentBanner(ChatMessageModel message) {
    final appointmentId = message.appointmentId ?? '';
    final appointment = appointmentId.isEmpty
        ? null
        : ref.watch(appointmentProvider(appointmentId)).valueOrNull;

    final phase = appointment == null
        ? ''
        : appointmentDisplayPhase(appointment, now: DateTime.now());
    final phaseColor = phase.isEmpty
        ? const Color(0xFF062B72)
        : appointmentPhaseColor(phase);

    final user = ref.watch(userProvider);
    final asDoctor = user?.role == UserRoles.doctor;
    final canAct =
        appointment != null &&
        user != null &&
        user.role != UserRoles.admin &&
        (asDoctor
            ? user.id == appointment.doctorId
            : user.id == appointment.patientId);
    final joinable =
        canAct && showAppointmentJoinAction(appointment, asDoctor: asDoctor);

    // Live phase sentence while the slot runs, the pinned schedule text
    // otherwise — the banner never shows an empty line.
    var bannerText = phase.isNotEmpty ? appointmentPhaseHint(phase) : '';
    if (bannerText.isEmpty) bannerText = _appointmentBody(message.message);

    return Container(
      margin: EdgeInsets.fromLTRB(context.rsp(16), 8, context.rsp(16), 0),
      padding: EdgeInsets.symmetric(horizontal: context.rsp(12), vertical: 10),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFEAF2FF), Color(0xFFF6F9FF)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFB8CBE4)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF12263F).withValues(alpha: 0.06),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                phase.isEmpty
                    ? Icons.event_available_rounded
                    : appointmentPhaseIcon(phase),
                size: 18,
                color: phaseColor,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  bannerText,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: context.fs(12.5),
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF1F2F44),
                    height: 1.35,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              const Icon(
                Icons.push_pin_rounded,
                size: 14,
                color: Color(0xFF7E90A6),
              ),
            ],
          ),
          if (phase.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                AppointmentPhasePill(phase: phase, fontSize: 10.5),
                const Spacer(),
                if (joinable)
                  FilledButton.icon(
                    onPressed: () => _joinFromBanner(appointment),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF0E7C86),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 7,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    icon: const Icon(Icons.video_call_rounded, size: 15),
                    label: Text(
                      'Join',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// Marks this side as joined, then says so once — the counterpart is told
  /// by the controller's push, the timeline by its event.
  Future<void> _joinFromBanner(AppointmentModel appointment) async {
    final user = ref.read(userProvider);
    if (user == null) return;

    final asDoctor = user.role == UserRoles.doctor;
    final error = await ref
        .read(appointmentControllerProvider)
        .markAppointmentJoined(
          appointment: appointment,
          actorId: user.id,
          asDoctor: asDoctor,
        );
    if (error != null) {
      ToastService.instance.showError(error);
      return;
    }
    ToastService.instance.showSuccess('You have joined the appointment.');
  }

  /// Full-width system card for an appointment message inside the list —
  /// deliberately not a left/right speech bubble.
  Widget _buildAppointmentBubble(ChatMessageModel message) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.all(context.rsp(12)),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFFFFFFFF), Color(0xFFF3F7FD)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0xFFB8CBE4)),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF12263F).withValues(alpha: 0.07),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: const Color(0xFFE4EDFB),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.event_available_rounded,
                    size: 17,
                    color: Color(0xFF062B72),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Appointment Scheduled',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: context.fs(13.5),
                      fontWeight: FontWeight.w700,
                      color: const Color(0xFF1F2F44),
                    ),
                  ),
                ),
                if (message.isPinned)
                  const Icon(
                    Icons.push_pin_rounded,
                    size: 15,
                    color: Color(0xFF062B72),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              _appointmentBody(message.message),
              style: TextStyle(
                fontSize: context.fs(13.5),
                fontWeight: FontWeight.w500,
                color: const Color(0xFF384C66),
                height: 1.45,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The controller writes the headline into the message body so the chat list
  /// preview reads correctly; the cards render their own headline instead.
  String _appointmentBody(String body) {
    const headline = '📌 Appointment Scheduled';
    var value = body.trim();
    if (value.startsWith(headline)) {
      value = value.substring(headline.length).trim();
    }
    return value;
  }

  /// Adds the interaction layers around a finished bubble:
  ///
  ///  * swipe-to-reply (either direction) while selection mode is off;
  ///  * tap-to-tick while selection mode is on — the child's own taps are
  ///    absorbed so a tick can never open the image/document instead;
  ///  * the tick + dimming for a selected bubble;
  ///  * the flash used after jumping to a quoted message.
  Widget _wrapBubbleForInteraction({
    required ChatMessageModel message,
    required bool isMe,
    required Widget child,
  }) {
    final user = ref.read(userProvider);
    final selectable =
        user != null && MessageActionRules.isSelectable(message, user.id);
    final selected = _selectedMessageIds.contains(message.id);

    Widget content = child;

    if (selected) {
      content = Stack(
        clipBehavior: Clip.none,
        children: [
          Opacity(opacity: 0.55, child: content),
          Positioned(
            top: 0,
            left: isMe ? null : 4,
            right: isMe ? 4 : null,
            child: Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: const Color(0xFF062B72),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.25),
                    blurRadius: 4,
                    offset: const Offset(0, 1),
                  ),
                ],
              ),
              child: const Icon(
                Icons.check_rounded,
                size: 14,
                color: Colors.white,
              ),
            ),
          ),
        ],
      );
    }

    if (_isSelectionMode) {
      content = GestureDetector(
        behavior: HitTestBehavior.deferToChild,
        onTap: selectable ? () => _toggleSelection(message) : null,
        child: AbsorbPointer(child: content),
      );
    } else {
      content = SwipeToReplyWrapper(
        enabled:
            user != null &&
            !message.isDeleted &&
            MessageActionRules.canReply(message, user.id),
        onReply: () => _setReplyToMessage(message),
        child: content,
      );
    }

    if (_highlightedMessageId == message.id) {
      content = Container(
        decoration: BoxDecoration(
          color: const Color(0xFFFFC107).withValues(alpha: 0.22),
          borderRadius: BorderRadius.circular(16),
        ),
        child: content,
      );
    }

    return content;
  }

  Widget _buildMessageBubble(ChatMessageModel message, bool isMe) {
    final isVoiceMessage =
        message.messageType == 'voice' ||
        (message.messageType == 'audio' &&
            message.mediaUrl != null &&
            message.mediaUrl!.isNotEmpty);
    final isCallMessage =
        !isVoiceMessage &&
        (message.messageType == 'audio' ||
            message.messageType == 'video' ||
            message.messageType == 'call_recording');
    final bool isLongMessage = message.message.length > 35;
    // A prescription is a rich card, not a speech bubble, so it renders on its
    // own white surface with a full-width tappable area.
    final bool isPrescriptionCard = message.isPrescription;
    // So is the pinned appointment notice the doctor's confirmation writes.
    if (message.isAppointmentMessage) {
      return _buildAppointmentBubble(message);
    }
    return GestureDetector(
      onLongPressStart: (LongPressStartDetails details) {
        _handleMessageLongPress(message);
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        constraints: BoxConstraints(
          maxWidth: isVoiceMessage
              ? math.min(context.sw * 0.85, 320)
              : math.min(context.sw * 0.78, 460),
        ),
        child: Column(
          crossAxisAlignment: isMe
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            if (message.isForwarded && !message.isDeleted)
              _buildForwardedLabel(isMe),
            if (message.replyTo != null)
              _buildReplyPreview(message, message.replyTo!, isMe),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: isVoiceMessage
                    ? math.min(context.sw * 0.85, 320)
                    : isCallMessage
                    ? math.min(context.sw * 0.72, 250)
                    : (isLongMessage
                          ? math.min(context.sw * 0.78, 460)
                          : double.infinity),
              ),
              child: Container(
                decoration: (isPrescriptionCard || isVoiceMessage)
                    ? null
                    : BoxDecoration(
                        gradient: isMe
                            ? const LinearGradient(
                                colors: [
                                  Color(0xFF284F85),
                                  Color(0xFF15386A),
                                  Color(0xFF0D264E),
                                ],
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                              )
                            : null,
                        color: isMe ? null : Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: isMe
                            ? Border.all(
                                color: const Color(0xFF132D56),
                                width: 0.5,
                              )
                            : Border.all(
                                color: const Color(0xFFDCE6F2),
                                width: 0.5,
                              ),
                        boxShadow: [
                          BoxShadow(
                            color:
                                (isMe
                                        ? const Color(0xFF0B2041)
                                        : const Color(0xFF0F233C))
                                    .withValues(alpha: isMe ? 0.2 : 0.06),
                            blurRadius: isMe ? 10 : 6,
                            offset: Offset(0, isMe ? 3 : 2),
                          ),
                        ],
                      ),
                child: isVoiceMessage
                    ? _buildVoiceMessageBubble(message, isMe)
                    : isCallMessage
                    ? _buildCallOrRecordingBubble(message, isMe)
                    : message.isPrescription
                    ? _buildPrescriptionBubble(message, isMe)
                    : message.messageType == 'image'
                    ? _buildImageBubble(message, isMe)
                    : message.messageType == 'document'
                    ? _buildDocumentBubble(message, isMe)
                    : message.messageType == 'forwarded_report'
                    ? _buildForwardedReportBubble(message, isMe)
                    : _buildTextBubble(message, isMe),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVoiceMessageBubble(ChatMessageModel message, bool isMe) {
    final currentUser = ref.read(userProvider);
    final senderAvatarUrl = isMe
        ? (currentUser?.image ?? '')
        : widget.otherUserImage;

    return VoiceMessageBubble(
      messageId: message.id,
      audioUrl: message.mediaUrl ?? '',
      duration: message.duration ?? 0,
      isMe: isMe,
      timestamp: message.timestamp,
      isRead: message.isRead,
      isDelivered: message.isDelivered,
      deliveryStatus: message.deliveryStatus,
      isListened: message.isListened,
      senderAvatarUrl: senderAvatarUrl,
      onListened: () {
        if (!isMe && currentUser != null) {
          _chatController.markVoiceMessageAsListened(
            messageId: message.id,
            senderId: message.senderId,
            receiverId: currentUser.id,
          );
        }
      },
    );
  }

  /// The small "Forwarded" caption above a bubble that came from another
  /// conversation, matching the double-arrow treatment of WhatsApp.
  Widget _buildForwardedLabel(bool isMe) {
    final color = isMe ? Colors.white70 : const Color(0xFF8FA4BD);
    return Padding(
      padding: EdgeInsets.only(
        left: isMe ? 0 : 4,
        right: isMe ? 4 : 0,
        bottom: 2,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.forward_rounded, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            'Forwarded',
            style: TextStyle(
              fontSize: 11,
              fontStyle: FontStyle.italic,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  /// Prescription card shown in place of a text message. Tapping it opens the
  /// dedicated Prescription Detail page for the linked document.
  Widget _buildPrescriptionBubble(ChatMessageModel message, bool isMe) {
    return OpdCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Accent header
          Container(
            padding: EdgeInsets.symmetric(
              horizontal: 14,
              vertical: context.rsp(8),
            ),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF284F85), Color(0xFF15386A)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(17),
                topRight: Radius.circular(17),
              ),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.medical_information_rounded,
                  color: Colors.white,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Prescription',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: context.fs(14),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _formatTime(message.timestamp),
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: context.fs(10),
                      ),
                    ),
                    if (isMe) ...[
                      const SizedBox(width: 4),
                      MessageStatusIndicator.forOutgoing(
                        message,
                        color: Colors.white70,
                        readColor: _readTickOnDark,
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 11, 14, 0),
            child: Text(
              isMe ? 'You' : 'Dr. ${widget.otherUserName}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: context.fs(13.5),
                fontWeight: FontWeight.w700,
                color: const Color(0xFF062B72),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
            child: Text(
              (message.prescriptionNotePreview ?? '').trim().isEmpty
                  ? message.getDisplayMessage()
                  : message.prescriptionNotePreview!.trim(),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: context.fs(12.5),
                height: 1.45,
                fontWeight: FontWeight.w500,
                color: const Color(0xFF1F2F44),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
            child: _buildPrescriptionActions(message, isMe),
          ),
        ],
      ),
    );
  }

  /// "View Prescription" + the rate / your-rating row for a prescription card.
  Widget _buildPrescriptionActions(ChatMessageModel message, bool isMe) {
    final user = ref.read(userProvider);
    final prescriptionId = message.prescriptionId ?? '';

    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          child: _PrescriptionActionButton(
            icon: Icons.description_rounded,
            label: 'View Prescription',
            onTap: user == null
                ? null
                : () => _openPrescriptionDetail(
                    prescriptionId: prescriptionId,
                    viewerId: user.id,
                    doctorId: isMe ? user.id : null,
                    patientId: isMe ? null : user.id,
                  ),
          ),
        ),
        const SizedBox(height: 8),
        // Only the recipient of the prescription may rate the doctor.
        if (!isMe && user != null && prescriptionId.isNotEmpty)
          _DoctorRatingRow(
            doctorId: message.senderId,
            doctorName: widget.otherUserName,
            patientId: user.id,
            patientName: user.fullname,
            prescriptionId: prescriptionId,
          ),
      ],
    );
  }

  void _openPrescriptionDetail({
    required String prescriptionId,
    required String viewerId,
    String? doctorId,
    String? patientId,
  }) {
    if (prescriptionId.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PrescriptionDetailScreen(
          prescriptionId: prescriptionId,
          viewerId: viewerId,
          expectedDoctorId: doctorId,
          expectedPatientId: patientId,
        ),
      ),
    );
  }

  Widget _buildReplyPreview(
    ChatMessageModel message,
    ReplyData replyTo,
    bool isMe,
  ) {
    final isCallMessage =
        message.messageType == 'audio' ||
        message.messageType == 'video' ||
        message.messageType == 'call_recording';
    final bool isLongMessage = message.message.length > 35;

    // Prefer the live copy of the quoted message so an edit or a delete shows
    // up here too; fall back to what was captured when the reply was made.
    ChatMessageModel? original;
    for (final m in _latestMessages) {
      if (m.id == replyTo.messageId) {
        original = m;
        break;
      }
    }
    final gone = original == null;
    final quotedDeleted = original?.isDeleted ?? false;
    final previewText = gone
        ? 'Original message unavailable'
        : quotedDeleted
        ? 'This message was deleted'
        : original!.getDisplayMessage();
    final previewType = gone ? replyTo.messageType : original!.messageType;

    return GestureDetector(
      onTap: () => _jumpToOriginalMessage(replyTo.messageId),
      behavior: HitTestBehavior.opaque,
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: isMe
              ? const Color(0xFF062B72).withOpacity(0.08)
              : const Color(0xFFEDF2F8),
          borderRadius: BorderRadius.circular(8),
          border: Border(
            left: BorderSide(color: const Color(0xFF062B72), width: 3),
          ),
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: isCallMessage
                ? math.min(context.sw * 0.72, 250)
                : (isLongMessage
                      ? math.min(context.sw * 0.78, 460)
                      : double.infinity),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                replyTo.senderName,
                style: TextStyle(
                  fontSize: 11,
                  color: const Color(0xFF062B72),
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  if (previewType == 'image')
                    const Icon(Icons.image, size: 12, color: Colors.grey),
                  if (previewType == 'document')
                    const Icon(
                      Icons.insert_drive_file,
                      size: 12,
                      color: Colors.grey,
                    ),
                  if (previewType == 'audio' || previewType == 'video')
                    const Icon(
                      Icons.play_circle_outline,
                      size: 12,
                      color: Colors.grey,
                    ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      previewText.length > 100
                          ? '${previewText.substring(0, 100)}...'
                          : previewText,
                      style: TextStyle(
                        fontSize: 11,
                        color: isMe
                            ? const Color.fromARGB(179, 0, 0, 0)
                            : Colors.grey[600],
                        fontStyle: FontStyle.italic,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Add these methods to handle call message interactions
  // 1. Update the _buildCallOrRecordingBubble method to make it clickable
  Widget _buildCallOrRecordingBubble(ChatMessageModel message, bool isMe) {
    final isRecording = message.messageType == 'call_recording';
    final callInfo = _getCallStatusInfo(message.message, isMe);
    // Parse call duration and time from message if available
    final callData = _parseCallMessageData(message.message);
    return GestureDetector(
      onTap: () async {
        if (isRecording && message.mediaUrl != null) {
          // Open call recording
          _openCallRecording(message);
        } else if (message.id != null && message.id!.isNotEmpty) {
          // Show call details or redial
          _showCallDetailsDialog(message, isMe);
        } else {
          // Initiate new call if it's a missed call or call initiation message
          _initiateCallFromMessage(message);
        }
      },
      onLongPress: () {
        // Show message actions even for call messages
        if (!message.isDeleted) {
          _showMessageActions(message, Offset.zero);
        }
      },
      child: Container(
        width: math.min(context.sw * 0.72, 250),
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF0F233C).withValues(alpha: 0.06),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: isMe
                ? const Color(0xFF062B72).withOpacity(0.2)
                : Colors.grey[200],
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: isRecording
                      ? const Color(0xFF062B72).withOpacity(0.1)
                      : (callInfo['color'] as Color).withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isRecording
                      ? Icons.fiber_manual_record
                      : (callInfo['icon'] as IconData),
                  size: 30,
                  color: isRecording
                      ? const Color(0xFF062B72)
                      : (callInfo['color'] as Color),
                ),
              ),
              const SizedBox(width: 12),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            isRecording
                                ? '📞 Call Recording'
                                : (callInfo['text'] as String),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: context.fs(13.5),
                              fontWeight: FontWeight.w500,
                              color: Colors.black87,
                            ),
                          ),
                        ),
                        if (callData['duration'] != null && !isRecording)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.grey.withOpacity(0.3),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              callData['duration']!,
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                      ],
                    ),
                    if (isRecording && message.duration != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        _formatDuration(message.duration!),
                        style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                      ),
                    ],
                    const SizedBox(height: 2),
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      runSpacing: 2,
                      children: [
                        Text(
                          _formatTime(message.timestamp),
                          style: TextStyle(
                            fontSize: context.fs(10),
                            color: Colors.grey[600],
                          ),
                        ),
                        if (callData['startTime'] != null) ...[
                          const SizedBox(width: 6),
                          Icon(
                            Icons.access_time,
                            size: 10,
                            color: Colors.grey[500],
                          ),
                          const SizedBox(width: 2),
                          Text(
                            callData['startTime']!,
                            style: TextStyle(
                              fontSize: context.fs(10),
                              color: Colors.grey[600],
                            ),
                          ),
                        ],
                        if (message.isEdited && !isRecording) ...[
                          const SizedBox(width: 6),
                          Text(
                            'edited',
                            style: TextStyle(
                              fontSize: 9,
                              color: Colors.grey[500],
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ],
                        if (isMe) ...[
                          const SizedBox(width: 4),
                          MessageStatusIndicator.forOutgoing(
                            message,
                            size: 12,
                            // This bubble has a light background, so the
                            // muted grey tick and a darker "read" blue are
                            // both needed for contrast.
                            color: _tickOnLightBubble,
                            readColor: const Color(0xFF1D74C9),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              // Add a call back icon for missed calls
              if (!isRecording && callInfo['text'] == 'Missed call')
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF062B72),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      CupertinoIcons.phone_solid,
                      size: 16,
                      color: Colors.white,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // 2. Add method to parse call message data
  Map<String, String?> _parseCallMessageData(String message) {
    final result = <String, String?>{};
    // Parse duration from message (e.g., "Call duration: 5:23")
    final durationRegex = RegExp(
      r'duration:\s*([0-9:]+)',
      caseSensitive: false,
    );
    final durationMatch = durationRegex.firstMatch(message);
    if (durationMatch != null) {
      result['duration'] = durationMatch.group(1);
    }
    // Parse start time (e.g., "Started at 2:30 PM")
    final timeRegex = RegExp(
      r'started at\s*([0-9:]+(?:\s*[AP]M)?)',
      caseSensitive: false,
    );
    final timeMatch = timeRegex.firstMatch(message);
    if (timeMatch != null) {
      result['startTime'] = timeMatch.group(1);
    }
    return result;
  }

  // 3. Add method to open call recording
  Future<void> _openCallRecording(ChatMessageModel message) async {
    if (message.mediaUrl == null) {
      ToastService.instance.showError('Recording URL not available');
      return;
    }
    // Show loading
    ToastService.instance.showInfo('Loading recording...');
    try {
      // Navigate to call recording player
      // Navigator.push(
      //   context,
      //   MaterialPageRoute(
      //     builder: (context) => CallRecordingPlayerScreen(
      //       recordingUrl: message.mediaUrl!,
      //       callDate: message.timestamp,
      //       duration: message.duration ?? 0,
      //     ),
      //   ),
      // );
    } catch (e) {
      ToastService.instance.showError('Failed to load recording');
    }
  }

  // 4. Add method to show call details dialog
  void _showCallDetailsDialog(ChatMessageModel message, bool isMe) {
    final callData = _parseCallMessageData(message.message);
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: SingleChildScrollView(
          child: Container(
            padding: EdgeInsets.all(context.rsp(16)),
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 50,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0xFFD6E4F0),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 16),
                CircleAvatar(
                  radius: 32,
                  backgroundImage: widget.otherUserImage.isNotEmpty
                      ? NetworkImage(widget.otherUserImage)
                      : null,
                  child: widget.otherUserImage.isEmpty
                      ? Icon(
                          Icons.person,
                          size: 36,
                          color: const Color(0xFF6B7B8D),
                        )
                      : null,
                ),
                const SizedBox(height: 12),
                Text(
                  widget.otherUserName,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: context.fs(15),
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF1F2F44),
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEDF2F8),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    _getCallStatusInfo(message.message, isMe)['text'] as String,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: context.fs(12),
                      color: const Color(0xFF6B7B8D),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                if (callData['duration'] != null) ...[
                  _buildDetailRow(
                    Icons.timer,
                    'Duration',
                    callData['duration']!,
                  ),
                  const SizedBox(height: 10),
                ],
                if (callData['startTime'] != null) ...[
                  _buildDetailRow(
                    Icons.access_time,
                    'Started at',
                    callData['startTime']!,
                  ),
                  const SizedBox(height: 10),
                ],
                _buildDetailRow(
                  Icons.calendar_today,
                  'Date',
                  DateFormat('MMMM d, yyyy').format(message.timestamp),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          Navigator.pop(context);
                          _initiateCallFromMessage(message);
                        },
                        icon: const Icon(Icons.call, size: 18),
                        label: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            'Call Back',
                            style: TextStyle(fontSize: context.fs(13)),
                          ),
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF062B72),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: () {
                          Navigator.pop(context);
                          _sendMessageAboutCall(message);
                        },
                        icon: const Icon(
                          Icons.message,
                          color: Colors.white,
                          size: 18,
                        ),
                        label: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            'Send Message',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: context.fs(13),
                            ),
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF062B72),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // 5. Add method to initiate call from message
  Future<void> _initiateCallFromMessage(ChatMessageModel message) async {
    final user = ref.read(userProvider);
    if (user == null) {
      ToastService.instance.showError('Please login to make calls');
      return;
    }
    // Start audio call
    final channelId = 'call_${DateTime.now().millisecondsSinceEpoch}';
    try {
      final result = await _callController.startCallWithCheck(
        channelId: channelId,
        callerId: user.id,
        receiverId: widget.otherUserId,
        callerName: user.fullname,
        receiverName: widget.otherUserName,
        receiverType: widget.otherUserType ?? 'doctor',
        callerImage: user.image,
        receiverImage: widget.otherUserImage,
        callType: 'audio',
        callerType: user.role,
      );
      if (!mounted) return;
      if (result['success'] == true) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => CallScreen(
              channelId: channelId,
              callId: result['callId'],
              callType: 'audio',
              otherUserName: widget.otherUserName,
              otherUserImage: widget.otherUserImage,
              currentUserId: user.id,
              otherUserId: widget.otherUserId,
              otherUserType: widget.otherUserType ?? 'doctor',
              isCaller: true,
            ),
          ),
        );
      } else {
        ToastService.instance.showError(
          result['error'] ?? 'Failed to start call',
        );
      }
    } catch (e) {
      if (!mounted) return;
      ToastService.instance.showError('Error starting call: ${e.toString()}');
    }
  }

  // 6. Add method to send message about call
  void _sendMessageAboutCall(ChatMessageModel originalCallMessage) {
    _messageController.text =
        'About the ${originalCallMessage.messageType == 'audio' ? 'audio' : 'video'} call ';
    FocusScope.of(context).requestFocus();
  }

  // 7. Add helper method for detail row
  Widget _buildDetailRow(IconData icon, String label, String value) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: const Color(0xFFEDF2F8),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 18, color: const Color(0xFF062B72)),
        ),
        const SizedBox(width: 12),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: const Color(0xFF8FA4BD)),
              ),
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: context.fs(13.5),
                  fontWeight: FontWeight.w600,
                  color: const Color(0xFF1F2F44),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // 8. Update _getCallStatusInfo method to include duration parsing
  Map<String, dynamic> _getCallStatusInfo(String message, bool isMe) {
    final lowerMessage = message.toLowerCase();
    // Check for different call statuses
    if (lowerMessage.contains('missed') || lowerMessage.contains('no answer')) {
      // Extract duration if available
      final durationMatch = RegExp(r'(\d+:\d+)').firstMatch(message);
      final durationText = durationMatch != null
          ? ' (${durationMatch.group(1)})'
          : '';
      return {
        'icon': Icons.call_missed,
        'color': Colors.red,
        'text': 'Missed call$durationText',
      };
    }
    if (lowerMessage.contains('rejected') ||
        lowerMessage.contains('declined')) {
      return {
        'icon': Icons.call_end,
        'color': Colors.red,
        'text': 'Rejected call',
      };
    }
    if (lowerMessage.contains('completed') ||
        lowerMessage.contains('ended') ||
        (lowerMessage.contains('call') && lowerMessage.contains('duration'))) {
      // Extract duration for completed calls
      final durationMatch = RegExp(
        r'duration[:\s]+(\d+:\d+)',
        caseSensitive: false,
      ).firstMatch(message);
      final durationText = durationMatch != null
          ? ' - ${durationMatch.group(1)}'
          : '';
      return {
        'icon': Icons.call,
        'color': Colors.green,
        'text': 'Call ended$durationText',
      };
    }
    if (lowerMessage.contains('initiated') && isMe) {
      return {
        'icon': Icons.call_made,
        'color': Colors.orange,
        'text': 'Call initiated',
      };
    }
    if (lowerMessage.contains('initiated') && !isMe) {
      return {
        'icon': Icons.call_received,
        'color': Colors.blue,
        'text': 'Incoming call',
      };
    }
    return {'icon': Icons.call, 'color': Colors.green, 'text': message};
  }

  String _formatDuration(int seconds) {
    final minutes = seconds ~/ 60;
    final remainingSeconds = seconds % 60;
    if (minutes > 0) {
      return '$minutes:${remainingSeconds.toString().padLeft(2, '0')}';
    }
    return '0:$remainingSeconds'.padLeft(4, '0');
  }

  Widget _buildImageBubble(ChatMessageModel message, bool isMe) {
    if (message.isDeleted) {
      return _buildDeletedMessageBubble(isMe);
    }
    final double imageSize = math.min(context.sw * 0.55, 240);
    return GestureDetector(
      onTap: () {
        if (message.mediaUrl != null) {
          _showFullScreenImage(message.mediaUrl!);
        }
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF0F233C).withValues(alpha: 0.06),
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
                message.mediaUrl ?? '',
                width: imageSize,
                height: imageSize,
                fit: BoxFit.cover,
                loadingBuilder: (context, child, loadingProgress) {
                  if (loadingProgress == null) return child;
                  return Container(
                    width: imageSize,
                    height: imageSize,
                    color: Colors.grey[300],
                    child: const Center(child: CircularProgressIndicator()),
                  );
                },
                errorBuilder: (context, error, stackTrace) {
                  return Container(
                    width: imageSize,
                    height: imageSize,
                    color: Colors.grey[300],
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
                    color: Colors.black.withOpacity(0.6),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _formatTime(message.timestamp),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                        ),
                      ),
                      if (isMe) ...[
                        const SizedBox(width: 4),
                        MessageStatusIndicator.forOutgoing(
                          message,
                          color: Colors.white,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              if (message.isEdited)
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.6),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Text(
                      'edited',
                      style: TextStyle(color: Colors.white70, fontSize: 9),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // Add this method to download and open files
  Future<void> _downloadAndOpenFile(String url, String fileName) async {
    try {
      // Show downloading indicator
      ToastService.instance.showInfo('Downloading file...');
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final directory = await getTemporaryDirectory();
        final filePath = '${directory.path}/$fileName';
        final file = File(filePath);
        // Delete if file already exists
        if (await file.exists()) {
          await file.delete();
        }
        // Write file bytes
        await file.writeAsBytes(response.bodyBytes);
        // Verify file was created
        if (await file.exists()) {
          ToastService.instance.showSuccess('File downloaded, opening...');
          // Open the file
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
        } else {
          ToastService.instance.showError('Failed to save file');
        }
      } else {
        ToastService.instance.showError(
          'Failed to download file (${response.statusCode})',
        );
      }
    } catch (e) {
      print('Error downloading file: $e');
      ToastService.instance.showError('Error opening file: ${e.toString()}');
    }
  }

  // Add this method to format file size
  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024)
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  Widget _buildDocumentBubble(ChatMessageModel message, bool isMe) {
    if (message.isDeleted) {
      return _buildDeletedMessageBubble(isMe);
    }
    final fileName = message.fileName ?? 'Document';
    final fileExtension = fileName.split('.').last.toUpperCase();
    return GestureDetector(
      onTap: () {
        if (message.mediaUrl != null) {
          _downloadAndOpenFile(message.mediaUrl!, fileName);
        } else {
          ToastService.instance.showError('File URL not found');
        }
      },
      child: Container(
        width: math.min(context.sw * 0.75, 260),
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isMe
              ? const Color(0xFF062B72).withValues(alpha: 0.9)
              : Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF0F233C).withValues(alpha: 0.08),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: isMe ? Colors.white.withOpacity(0.2) : Colors.grey[200],
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                _getDocumentIcon(fileExtension),
                color: isMe ? Colors.white : const Color(0xFF062B72),
                size: 32,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildHighlightedText(
                    fileName.length > 25
                        ? '${fileName.substring(0, 25)}...'
                        : fileName,
                    message.id,
                    isMine: isMe,
                    fontSize: context.fs(13),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      // if (fileSize != null)
                      //   Text(
                      //     _formatFileSize(fileSize),
                      //     style: TextStyle(
                      //       fontSize: 10,
                      //       color: isMe ? Colors.white70 : Colors.grey[600],
                      //     ),
                      //   ),
                      // if (fileSize != null) const SizedBox(width: 6),
                      // Text(
                      //   _formatTime(message.timestamp),
                      //   style: TextStyle(
                      //     fontSize: 10,
                      //     color: isMe ? Colors.white70 : Colors.grey[600],
                      //   ),
                      // ),
                      if (isMe && message.isEdited) ...[
                        const SizedBox(width: 4),
                        Text(
                          'edited',
                          style: TextStyle(
                            fontSize: 9,
                            color: isMe ? Colors.white60 : Colors.grey[500],
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ],
                      // The document bubble's timestamp row is commented out
                      // upstream, so the receipt is appended to the same row
                      // rather than left out entirely.
                      if (isMe) ...[
                        const SizedBox(width: 4),
                        MessageStatusIndicator.forOutgoing(
                          message,
                          size: 12,
                          color: isMe ? Colors.white70 : _tickOnLightBubble,
                          readColor: _readTickOnDark,
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: isMe ? Colors.white.withOpacity(0.2) : Colors.grey[200],
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.download,
                size: 18,
                color: isMe ? Colors.white : const Color(0xFF062B72),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildForwardedReportBubble(ChatMessageModel message, bool isMe) {
    if (message.isDeleted) {
      return _buildDeletedMessageBubble(isMe);
    }

    final reportName = message.message;
    String uploadDate = 'Unknown date';

    if (message.callData != null && message.callData!['uploadDate'] != null) {
      try {
        final parsedDate = DateTime.parse(message.callData!['uploadDate']);
        uploadDate = DateFormat('dd MMM yyyy').format(parsedDate);
      } catch (_) {}
    }

    return Container(
      width: math.min(context.sw * 0.75, 260),
      margin: const EdgeInsets.only(bottom: 4),
      padding: EdgeInsets.all(context.rsp(12)),
      decoration: BoxDecoration(
        color: isMe ? const Color(0xFF062B72) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: isMe
            ? null
            : Border.all(color: const Color(0xFFE2E9F2), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0F233C).withValues(alpha: 0.08),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                Icons.medical_information_rounded,
                color: isMe ? Colors.white70 : const Color(0xFF062B72),
                size: 16,
              ),
              const SizedBox(width: 6),
              Text(
                'Medical Report',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: isMe ? Colors.white70 : const Color(0xFF062B72),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Report Name: $reportName',
            style: TextStyle(
              fontSize: context.fs(13.5),
              fontWeight: FontWeight.w600,
              color: isMe ? Colors.white : const Color(0xFF1F2F44),
            ),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  'Uploaded: $uploadDate',
                  style: TextStyle(
                    fontSize: 12,
                    color: isMe ? Colors.white70 : const Color(0xFF6B7B8D),
                  ),
                ),
              ),
              if (isMe) ...[
                const SizedBox(width: 4),
                MessageStatusIndicator.forOutgoing(
                  message,
                  size: 12,
                  color: Colors.white70,
                  readColor: _readTickOnDark,
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () {
                if (message.mediaUrl != null) {
                  _downloadAndOpenFile(
                    message.mediaUrl!,
                    message.fileName ?? 'report.pdf',
                  );
                } else {
                  ToastService.instance.showError('Report URL not found');
                }
              },
              style: OutlinedButton.styleFrom(
                side: BorderSide(
                  color: isMe
                      ? Colors.white38
                      : const Color(0xFF062B72).withValues(alpha: 0.3),
                  width: 1,
                ),
                padding: const EdgeInsets.symmetric(vertical: 8),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: Text(
                'View Report',
                style: TextStyle(
                  fontSize: context.fs(13.5),
                  fontWeight: FontWeight.w600,
                  color: isMe ? Colors.white : const Color(0xFF062B72),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  IconData _getDocumentIcon(String extension) {
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
      default:
        return Icons.insert_drive_file;
    }
  }

  Widget _buildDeletedMessageBubble(bool isMe) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFEDF2F8),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.delete_outline, size: 14, color: Color(0xFF8FA4BD)),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              'This message was deleted',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: const Color(0xFF8FA4BD),
                fontSize: context.fs(13),
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTextBubble(ChatMessageModel message, bool isMe) {
    if (message.isDeleted) {
      return _buildDeletedMessageBubble(isMe);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _buildHighlightedText(
            message.message,
            message.id,
            isMine: isMe,
            fontSize: context.fs(14),
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
                      color: isMe ? Colors.white60 : Colors.grey[500],
                      fontSize: 9,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
              Text(
                _formatTime(message.timestamp),
                style: TextStyle(
                  color: isMe ? Colors.white70 : Colors.grey[500],
                  fontSize: context.fs(10),
                ),
              ),
              if (isMe) ...[
                const SizedBox(width: 4),
                MessageStatusIndicator.forOutgoing(
                  message,
                  color: Colors.white70,
                  readColor: _readTickOnDark,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  // Make sure your _showFullScreenImage method is complete
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
            child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 4.0,
              child: Image.network(
                imageUrl,
                fit: BoxFit.contain,
                loadingBuilder: (context, child, loadingProgress) {
                  if (loadingProgress == null) return child;
                  return const Center(
                    child: CircularProgressIndicator(color: Colors.white),
                  );
                },
                errorBuilder: (context, error, stackTrace) {
                  return const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.broken_image,
                          size: 50,
                          color: Colors.white70,
                        ),
                        SizedBox(height: 16),
                        Text(
                          'Failed to load image',
                          style: TextStyle(color: Colors.white70),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ==================== Voice Recording & Playback ====================

  Future<void> _startVoiceRecording() async {
    try {
      _audioRecorder ??= AudioRecorder();
      final hasPermission = await _audioRecorder!.hasPermission();
      if (!hasPermission) {
        final status = await Permission.microphone.request();
        if (!status.isGranted) {
          ToastService.instance.showError(
            'Microphone permission is required to record voice messages',
          );
          return;
        }
      }

      await _stopPreview();

      final tempDir = await getTemporaryDirectory();
      final filePath =
          '${tempDir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';

      await _audioRecorder!.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 128000,
          sampleRate: 44100,
        ),
        path: filePath,
      );

      _recordingSeconds = 0;
      _recordingTimer?.cancel();
      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (mounted) {
          setState(() {
            _recordingSeconds++;
          });
        }
      });

      setState(() {
        _isRecording = true;
        _isPreviewingVoice = false;
        _recordedVoicePath = filePath;
      });
    } catch (e) {
      debugPrint('[ChatScreen] Error starting voice recording: $e');
      ToastService.instance.showError('Could not start recording: $e');
      _cancelVoiceRecording();
    }
  }

  Future<void> _cancelVoiceRecording() async {
    _recordingTimer?.cancel();
    _recordingTimer = null;
    try {
      if (_audioRecorder != null && await _audioRecorder!.isRecording()) {
        await _audioRecorder!.stop();
      }
      if (_recordedVoicePath != null) {
        final file = File(_recordedVoicePath!);
        if (await file.exists()) {
          await file.delete();
        }
      }
    } catch (e) {
      debugPrint('[ChatScreen] Error cancelling recording: $e');
    }
    if (mounted) {
      setState(() {
        _isRecording = false;
        _isPreviewingVoice = false;
        _recordingSeconds = 0;
        _recordedVoicePath = null;
      });
    }
  }

  Future<void> _stopAndPreviewVoiceRecording() async {
    _recordingTimer?.cancel();
    _recordingTimer = null;
    try {
      String? path;
      if (_audioRecorder != null && await _audioRecorder!.isRecording()) {
        path = await _audioRecorder!.stop();
      }
      path ??= _recordedVoicePath;

      if (path == null || _recordingSeconds < 1) {
        ToastService.instance.showInfo('Recording was too short');
        await _cancelVoiceRecording();
        return;
      }

      _recordedVoicePath = path;
      _previewPlayer ??= AudioPlayer();
      await _previewPlayer!.setFilePath(path);
      _previewDuration =
          _previewPlayer!.duration ?? Duration(seconds: _recordingSeconds);
      _previewPosition = Duration.zero;

      _previewPosSub?.cancel();
      _previewPosSub = _previewPlayer!.positionStream.listen((pos) {
        if (mounted) {
          setState(() {
            _previewPosition = pos;
          });
        }
      });

      _previewStateSub?.cancel();
      _previewStateSub = _previewPlayer!.playerStateStream.listen((state) {
        if (state.processingState == ProcessingState.completed) {
          if (mounted) {
            setState(() {
              _isPreviewPlaying = false;
              _previewPosition = Duration.zero;
            });
            _previewPlayer?.seek(Duration.zero);
          }
        }
      });

      if (mounted) {
        setState(() {
          _isRecording = false;
          _isPreviewingVoice = true;
          _isPreviewPlaying = false;
        });
      }
    } catch (e) {
      debugPrint('[ChatScreen] Error previewing voice recording: $e');
      _cancelVoiceRecording();
    }
  }

  Future<void> _togglePreviewPlayback() async {
    if (_previewPlayer == null) return;
    try {
      if (_isPreviewPlaying) {
        await _previewPlayer!.pause();
        if (mounted) setState(() => _isPreviewPlaying = false);
      } else {
        await _previewPlayer!.play();
        if (mounted) setState(() => _isPreviewPlaying = true);
      }
    } catch (e) {
      debugPrint('[ChatScreen] Error toggling preview playback: $e');
    }
  }

  Future<void> _stopPreview() async {
    try {
      await _previewPlayer?.stop();
    } catch (_) {}
    if (mounted) {
      setState(() {
        _isPreviewPlaying = false;
        _previewPosition = Duration.zero;
      });
    }
  }

  Future<void> _sendVoiceRecordingDirectly() async {
    _recordingTimer?.cancel();
    _recordingTimer = null;

    String? path;
    if (_audioRecorder != null && await _audioRecorder!.isRecording()) {
      path = await _audioRecorder!.stop();
    }
    path ??= _recordedVoicePath;

    if (path == null || _recordingSeconds < 1) {
      ToastService.instance.showInfo('Recording was too short');
      await _cancelVoiceRecording();
      return;
    }

    final durationSecs = _recordingSeconds;
    await _uploadAndSendVoice(path, durationSecs);
  }

  Future<void> _sendPreviewedVoice() async {
    if (_recordedVoicePath == null) return;
    await _stopPreview();
    final durationSecs = _previewDuration.inSeconds > 0
        ? _previewDuration.inSeconds
        : _recordingSeconds;
    await _uploadAndSendVoice(_recordedVoicePath!, durationSecs);
  }

  Future<void> _uploadAndSendVoice(String filePath, int durationSeconds) async {
    final user = ref.read(userProvider);
    if (user == null) {
      ToastService.instance.showError('User not logged in');
      return;
    }

    setState(() {
      _isUploadingVoice = true;
    });

    try {
      await _chatController.sendAudioMessage(
        senderId: user.id,
        receiverId: widget.otherUserId,
        audioPath: filePath,
        duration: durationSeconds,
        receiverRole: widget.otherUserRole ?? widget.otherUserType,
      );

      _pendingScrollToBottom = true;
      _scrollToBottom();
    } catch (e) {
      debugPrint('[ChatScreen] Error sending voice message: $e');
      ToastService.instance.showError('Failed to send voice message: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isUploadingVoice = false;
          _isRecording = false;
          _isPreviewingVoice = false;
          _recordingSeconds = 0;
          _recordedVoicePath = null;
        });
      }
    }
  }

  Widget _buildMicButton() {
    return GestureDetector(
      onTap: _startVoiceRecording,
      child: Container(
        width: 44,
        height: 44,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFFE3EAF2), Color(0xFFF5F8FC), Color(0xFFE2E9F2)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: const Color(0xFFBAC7D8), width: 1),
        ),
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFFF3F7FB), Colors.white, Color(0xFFF0F4F9)],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.mic_rounded,
            color: Color(0xFF062B72),
            size: 22,
          ),
        ),
      ),
    );
  }

  Widget _buildVoiceRecordingBar() {
    final minutes = _recordingSeconds ~/ 60;
    final seconds = _recordingSeconds % 60;
    final timeStr =
        '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';

    return Container(
      constraints: const BoxConstraints(minHeight: 46),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF5F5),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFFFFD1D1), width: 1),
      ),
      child: Row(
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: const BoxDecoration(
              color: Colors.red,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            timeStr,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              color: Color(0xFFC53030),
              fontSize: 14,
            ),
          ),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'Recording...',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                color: Color(0xFF718096),
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline_rounded, color: Colors.red),
            tooltip: 'Cancel',
            onPressed: _cancelVoiceRecording,
          ),
          IconButton(
            icon: const Icon(
              Icons.stop_circle_rounded,
              color: Color(0xFF062B72),
            ),
            tooltip: 'Stop & Preview',
            onPressed: _stopAndPreviewVoiceRecording,
          ),
          GestureDetector(
            onTap: _sendVoiceRecordingDirectly,
            child: Container(
              width: 38,
              height: 38,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Color(0xFF284F85),
                    Color(0xFF15386A),
                    Color(0xFF0D264E),
                  ],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
                shape: BoxShape.circle,
              ),
              child: _isUploadingVoice
                  ? const Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Colors.white,
                          ),
                        ),
                      ),
                    )
                  : const Icon(
                      Icons.send_rounded,
                      color: Colors.white,
                      size: 18,
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVoicePreviewBar() {
    final curSecs = _previewPosition.inSeconds;
    final totSecs = _previewDuration.inSeconds > 0
        ? _previewDuration.inSeconds
        : _recordingSeconds;
    final curStr =
        '${(curSecs ~/ 60).toString().padLeft(2, '0')}:${(curSecs % 60).toString().padLeft(2, '0')}';
    final totStr =
        '${(totSecs ~/ 60).toString().padLeft(2, '0')}:${(totSecs % 60).toString().padLeft(2, '0')}';

    final double progress = totSecs > 0
        ? (_previewPosition.inMilliseconds / (totSecs * 1000)).clamp(0.0, 1.0)
        : 0.0;

    return Container(
      constraints: const BoxConstraints(minHeight: 46),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F7FB),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFFBAC7D8), width: 1),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: _togglePreviewPlayback,
            child: Container(
              width: 34,
              height: 34,
              decoration: const BoxDecoration(
                color: Color(0xFF062B72),
                shape: BoxShape.circle,
              ),
              child: Icon(
                _isPreviewPlaying
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
                color: Colors.white,
                size: 20,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            curStr,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Color(0xFF1E2F44),
            ),
          ),
          Expanded(
            child: SliderTheme(
              data: const SliderThemeData(
                thumbShape: RoundSliderThumbShape(enabledThumbRadius: 4.0),
                trackHeight: 3.0,
                activeTrackColor: Color(0xFF062B72),
                inactiveTrackColor: Color(0xFFD2DCE8),
                thumbColor: Color(0xFF062B72),
                overlayShape: RoundSliderOverlayShape(overlayRadius: 8.0),
              ),
              child: Slider(
                value: progress,
                onChanged: (val) {
                  if (totSecs > 0) {
                    final seekMs = (val * totSecs * 1000).round();
                    _previewPlayer?.seek(Duration(milliseconds: seekMs));
                  }
                },
              ),
            ),
          ),
          Text(
            totStr,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Color(0xFF6B7E96),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline_rounded, color: Colors.red),
            tooltip: 'Discard',
            onPressed: _cancelVoiceRecording,
          ),
          GestureDetector(
            onTap: _sendPreviewedVoice,
            child: Container(
              width: 38,
              height: 38,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Color(0xFF284F85),
                    Color(0xFF15386A),
                    Color(0xFF0D264E),
                  ],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
                shape: BoxShape.circle,
              ),
              child: _isUploadingVoice
                  ? const Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Colors.white,
                          ),
                        ),
                      ),
                    )
                  : const Icon(
                      Icons.send_rounded,
                      color: Colors.white,
                      size: 18,
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageInput() {
    final user = ref.read(userProvider);
    if (user == null) return const SizedBox.shrink();
    return Container(
      constraints: BoxConstraints(maxWidth: context.contentMaxWidth),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF12263F).withValues(alpha: 0.06),
            blurRadius: 12,
            offset: const Offset(0, -3),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isEditingMessage) _buildEditPreviewInput(),
            if (_replyToMessage != null) _buildReplyPreviewInput(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: _isRecording
                  ? _buildVoiceRecordingBar()
                  : _isPreviewingVoice
                  ? _buildVoicePreviewBar()
                  : Row(
                      children: [
                        // Attachment button - metallic style
                        GestureDetector(
                          onTap: _showAttachmentOptions,
                          child: Container(
                            width: 44,
                            height: 44,
                            padding: const EdgeInsets.all(2),
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                colors: [
                                  Color(0xFFE3EAF2),
                                  Color(0xFFF5F8FC),
                                  Color(0xFFE2E9F2),
                                ],
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                              ),
                              borderRadius: BorderRadius.circular(22),
                              border: Border.all(
                                color: const Color(0xFFBAC7D8),
                                width: 1,
                              ),
                            ),
                            child: Container(
                              decoration: BoxDecoration(
                                gradient: const LinearGradient(
                                  colors: [
                                    Color(0xFFF3F7FB),
                                    Colors.white,
                                    Color(0xFFF0F4F9),
                                  ],
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                ),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.attach_file_rounded,
                                color: Color(0xFF062B72),
                                size: 20,
                              ),
                            ),
                          ),
                        ),
                        SizedBox(width: context.rsp(8)),
                        // Message input - metallic beveled style
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.all(3),
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                colors: [
                                  Color(0xFFE3EAF2),
                                  Color(0xFFF5F8FC),
                                  Color(0xFFE2E9F2),
                                ],
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                              ),
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(
                                color: const Color(0xFFBAC7D8),
                                width: 1.5,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(
                                    0xFF0F233C,
                                  ).withValues(alpha: 0.06),
                                  blurRadius: 6,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: Container(
                              constraints: const BoxConstraints(minHeight: 42),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                              ),
                              decoration: BoxDecoration(
                                gradient: const LinearGradient(
                                  colors: [
                                    Color(0xFFF3F7FB),
                                    Colors.white,
                                    Color(0xFFF0F4F9),
                                  ],
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                ),
                                borderRadius: BorderRadius.circular(22),
                              ),
                              child: TextFormField(
                                controller: _messageController,
                                onChanged: _handleTyping,
                                textInputAction: TextInputAction.send,
                                onFieldSubmitted: (_) => _sendMessage(),
                                decoration: InputDecoration(
                                  hintText: _isEditingMessage
                                      ? 'Edit message...'
                                      : _replyToMessage != null
                                      ? 'Reply...'
                                      : 'Type a message...',
                                  border: InputBorder.none,
                                  hintStyle: TextStyle(
                                    color: const Color(0xFF7E90A6),
                                    fontSize: context.fs(13.5),
                                  ),
                                ),
                                maxLines: 5,
                                minLines: 1,
                                style: TextStyle(
                                  fontSize: context.fs(13.5),
                                  color: const Color(0xFF1E2F44),
                                ),
                              ),
                            ),
                          ),
                        ),
                        SizedBox(width: context.rsp(8)),
                        _buildMicButton(),
                        SizedBox(width: context.rsp(8)),
                        // Send button - navy gradient
                        GestureDetector(
                          onTap: _sendMessage,
                          child: Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                colors: [
                                  Color(0xFF284F85),
                                  Color(0xFF15386A),
                                  Color(0xFF0D264E),
                                  Color(0xFF081938),
                                ],
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                              ),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: const Color(0xFF132D56),
                                width: 1,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(
                                    0xFF0B2041,
                                  ).withValues(alpha: 0.32),
                                  blurRadius: 10,
                                  offset: const Offset(0, 3),
                                ),
                              ],
                            ),
                            child: Icon(
                              // Editing reuses the send button as "commit the edit",
                              // so the glyph changes to a tick for clarity.
                              _isEditingMessage
                                  ? Icons.check_rounded
                                  : Icons.send_rounded,
                              color: Colors.white,
                              size: 20,
                            ),
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

  /// Amber banner above the composer while a message is being edited. The X
  /// restores the composer to a blank new-message state.
  Widget _buildEditPreviewInput() {
    final original = _originalEditText ?? '';
    return Container(
      margin: const EdgeInsets.only(top: 8, left: 12, right: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF8E1),
        borderRadius: BorderRadius.circular(12),
        border: Border(
          left: BorderSide(color: const Color(0xFFF9A825), width: 3),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.edit_rounded, size: 16, color: Color(0xFFF9A825)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Editing message',
                  style: TextStyle(
                    fontSize: 11,
                    color: const Color(0xFF8A6D1A),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  original.length > 60
                      ? '${original.substring(0, 60)}...'
                      : original,
                  style: TextStyle(
                    fontSize: context.fs(12),
                    color: const Color(0xFF6B7B8D),
                    fontStyle: FontStyle.italic,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: _cancelEditing,
            child: SizedBox(
              width: 40,
              height: 40,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF3E5B5),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.close,
                    size: 16,
                    color: Color(0xFF8A6D1A),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReplyPreviewInput() {
    return Container(
      margin: const EdgeInsets.only(top: 8, left: 12, right: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F8FC),
        borderRadius: BorderRadius.circular(12),
        border: Border(
          left: BorderSide(color: const Color(0xFF062B72), width: 3),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Replying to ${_replyToMessage!.senderName}',
                  style: TextStyle(
                    fontSize: 11,
                    color: const Color(0xFF062B72),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _replyToMessage!.message.length > 40
                      ? '${_replyToMessage!.message.substring(0, 40)}...'
                      : _replyToMessage!.message,
                  style: TextStyle(
                    fontSize: context.fs(12),
                    color: const Color(0xFF6B7B8D),
                    fontStyle: FontStyle.italic,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: _cancelReply,
            child: SizedBox(
              width: 40,
              height: 40,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: const Color(0xFFD6E4F0),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.close,
                    size: 16,
                    color: Color(0xFF6B7B8D),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// "View Prescription" pill used inside the prescription chat card.
class _PrescriptionActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const _PrescriptionActionButton({
    required this.icon,
    required this.label,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final fg = enabled ? const Color(0xFF062B72) : const Color(0xFFBAC6D5);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFFEDF2F8),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFDCE6F2)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 17, color: fg),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: context.fs(13.5),
                    fontWeight: FontWeight.w600,
                    color: fg,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The rate-doctor / your-rating row of a prescription card.
///
/// Watches only the single rating document for this doctor + patient +
/// prescription, so the row updates itself in place after a rating is saved
/// and nothing in the chat is reloaded or refetched.
class _DoctorRatingRow extends ConsumerStatefulWidget {
  final String doctorId;
  final String doctorName;
  final String patientId;
  final String patientName;
  final String prescriptionId;

  const _DoctorRatingRow({
    required this.doctorId,
    required this.doctorName,
    required this.patientId,
    required this.patientName,
    required this.prescriptionId,
  });

  @override
  ConsumerState<_DoctorRatingRow> createState() => _DoctorRatingRowState();
}

class _DoctorRatingRowState extends ConsumerState<_DoctorRatingRow> {
  bool _saving = false;

  Future<void> _rate() async {
    if (_saving) return;
    final popup = await showDoctorRatingPopup(
      context: context,
      doctorName: widget.doctorName,
    );
    if (popup == null || !popup.isSuccess || !mounted) return;

    setState(() => _saving = true);
    try {
      final result = await ref
          .read(doctorRatingControllerProvider)
          .submit(
            currentUserId: widget.patientId,
            doctorId: widget.doctorId,
            patientId: widget.patientId,
            patientName: widget.patientName,
            prescriptionId: widget.prescriptionId,
            rating: popup.rating,
          );

      if (!mounted) return;
      if (result.isSuccess) {
        ToastService.instance.showSuccess('Thanks for rating');
      } else {
        ToastService.instance.showWarning(_messageFor(result.failure!));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _messageFor(RatingFailure failure) {
    switch (failure) {
      case RatingFailure.alreadyRated:
        return 'You have already rated this prescription';
      case RatingFailure.prescriptionMismatch:
      case RatingFailure.prescriptionMissing:
        return 'This prescription does not belong to you';
      case RatingFailure.notThePatient:
        return 'Only the patient can rate this prescription';
      default:
        return 'Could not save your rating';
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(
      prescriptionRatingProvider((
        doctorId: widget.doctorId,
        patientId: widget.patientId,
        prescriptionId: widget.prescriptionId,
      )),
    );
    final existing = async.value;

    // Already rated for this prescription: show it instead of the button.
    if (existing != null) {
      return _SubmittedRating(rating: existing.rating);
    }
    return _RateButton(saving: _saving, onTap: _rate);
  }
}

class _SubmittedRating extends StatelessWidget {
  final int rating;

  const _SubmittedRating({required this.rating});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var star = 1; star <= 5; star++)
          Icon(
            star <= rating ? Icons.star_rounded : Icons.star_border_rounded,
            size: 18,
            color: star <= rating
                ? const Color(0xFFE9A400)
                : const Color(0xFFDCE6F2),
          ),
        const SizedBox(width: 8),
        Text(
          'Your Rating',
          style: TextStyle(
            fontSize: context.fs(12.5),
            fontWeight: FontWeight.w600,
            color: const Color(0xFF163B6E),
          ),
        ),
      ],
    );
  }
}

class _RateButton extends StatelessWidget {
  final bool saving;
  final VoidCallback onTap;

  const _RateButton({required this.saving, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: saving ? null : onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: BoxDecoration(
            color: const Color(0xFFF0F4FA),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFDCE6F2)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.star_rounded,
                size: 18,
                color: Color(0xFFE9A400),
              ),
              const SizedBox(width: 8),
              Text(
                'Rate Doctor',
                style: TextStyle(
                  fontSize: context.fs(13.5),
                  fontWeight: FontWeight.w600,
                  color: const Color(0xFF062B72),
                ),
              ),
              // Button-level loading only - never a full-screen indicator.
              if (saving) ...[
                const SizedBox(width: 10),
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Color(0xFF062B72),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
