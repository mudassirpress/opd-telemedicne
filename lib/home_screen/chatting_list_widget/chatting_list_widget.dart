import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:telemedicine/admin_portal/admin_chat/admin_chat_screen.dart';
import 'package:telemedicine/admin_portal/admin_ui.dart';
import 'package:telemedicine/auth/auth_provider/user_provider.dart';
import 'package:telemedicine/home_widget/chat_call/chat/chat_status/message_status_indicator.dart';
import 'package:telemedicine/home_widget/chat_call/chat/chat_controller/chat_providers.dart';
import 'package:telemedicine/home_widget/chat_call/chat/chat_menu/chat_favourites_provider.dart';
import 'package:telemedicine/home_widget/chat_call/chat/chat_screen.dart';
import 'package:telemedicine/data/models/chat_model.dart';
import 'package:telemedicine/home_widget/chat_call/call/call_controller/call_controller.dart';
import 'package:telemedicine/core/theme/app_theme.dart';
import 'package:telemedicine/core/services/doctor_presence_service.dart';
import 'package:telemedicine/core/utils/responsive.dart';
import 'package:telemedicine/core/utils/toast_utils.dart';
import 'package:telemedicine/offline_db/offline_chat_service.dart';
import 'package:telemedicine/core/providers/badge_providers.dart';

class ChatingListWidget extends ConsumerStatefulWidget {
  final String searchQuery;
  final bool adminView;
  final String? doctorId;
  final String? doctorName;
  final bool isAdminMode;
  final String? adminId;
  final String? adminName;

  const ChatingListWidget({
    super.key,
    required this.searchQuery,
    this.adminView = false,
    this.doctorId,
    this.doctorName,
    this.isAdminMode = false,
    this.adminId,
    this.adminName,
  });

  @override
  ConsumerState<ChatingListWidget> createState() => _ChatingListWidgetState();
}

class _ChatingListWidgetState extends ConsumerState<ChatingListWidget> {
  // NOTE: CallController is an app-wide singleton. Its `dispose()` tears down
  // call-wide timers/listeners and must NEVER be invoked from a screen — doing
  // so from here silently killed the ring-timeout timer while a call rang.
  final CallController _callController = CallController();

  /// Cached presence stream per user id. StreamBuilders previously created a
  /// brand-new Firestore listener on every rebuild (one per visible tile per
  /// emission), which churned listeners and wasted reads.
  final Map<String, Stream<dynamic>> _presenceStreams = {};

  String _activeTab = 'all';

  /// Single connectivity subscription for the subtle offline chip below.
  /// Held on the State (not rebuilt per frame) so the listener is not
  /// re-created on every list emission.
  StreamSubscription<ConnectivityResult>? _connectivitySub;
  bool _isOffline = false;

  @override
  void initState() {
    super.initState();
    _connectivitySub = Connectivity().onConnectivityChanged.listen(
      (result) {
        if (!mounted) return;
        final offline = result == ConnectivityResult.none;
        if (offline != _isOffline) {
          setState(() => _isOffline = offline);
        }
      },
      onError: (Object e) {
        debugPrint('Chat list connectivity listener error: $e');
      },
    );
  }

  Stream<dynamic> _presenceStreamFor(String userId, String userType) {
    final key = '$userType:$userId';
    return _presenceStreams.putIfAbsent(
      key,
      () => _callController.checkUserOnlineStatusStream(
        userId: userId,
        userType: userType,
      ),
    );
  }

  @override
  void dispose() {
    _connectivitySub?.cancel();
    // Deliberately does NOT call _callController.dispose(): the singleton
    // outlives this widget.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(userProvider);

    if (user == null) {
      return const Center(child: Text('Please login to view chats'));
    }

    if (widget.isAdminMode && widget.doctorId != null) {
      return _buildAdminDoctorPatientsView();
    }

    return _buildRegularChatsView(user.id);
  }

  Widget _buildAdminDoctorPatientsView() {
    final patientsStateAsync =
        ref.watch(doctorPatientsStateProvider(widget.doctorId!));
    
    return patientsStateAsync.when(
      skipLoadingOnReload: true,
      skipLoadingOnRefresh: true,
      // First frame before the cache-first yield: render the cached patient
      // list when one exists rather than a full-screen spinner (the spinner
      // stays for a genuine first-ever load with an empty local cache).
      loading: () {
        final cached = OfflineChatService.instance.getChatList(widget.doctorId!);
        if (cached != null && cached.isNotEmpty) {
          return _buildPatientsBody(cached, isSyncing: true);
        }
        return const Center(
          child: CircularProgressIndicator(),
        );
      },
      error: (error, stack) {
        // Offline / Firestore outage on a device that already has this list
        // cached: keep serving the cached conversations instead of replacing
        // a usable list with an error screen. The error state is only shown
        // when there is genuinely nothing local to render.
        final cached = OfflineChatService.instance.getChatList(widget.doctorId!);
        if (cached != null && cached.isNotEmpty) {
          return _buildPatientsBody(cached, isSyncing: false);
        }
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 12),
              Text(
                'Could not load patients. Check your connection.',
                textAlign: TextAlign.center,
                style: TextStyle(),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () {
                  ref.invalidate(doctorPatientsStateProvider(widget.doctorId!));
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primaryRed,
                ),
                child: const Text('Retry'),
              ),
            ],
          ),
        );
      },
      data: (state) => _buildPatientsBody(
        state.chats,
        isSyncing: state.isSyncing,
      ),
    );
  }

  /// Search + empty-state + list rendering for the admin patients view.
  /// Shared between the provider's `data` branch and the cache fallback in
  /// its `loading` branch so both render identically.
  Widget _buildPatientsBody(
    List<Map<String, dynamic>> patients, {
    bool isSyncing = false,
  }) {
    final query = widget.searchQuery.trim().toLowerCase();
    final filteredPatients = query.isEmpty
        ? patients
        : patients.where((patient) {
            final name = (patient['patientName'] ?? '')
                .toString()
                .toLowerCase();
            final patientId = (patient['patientId'] ?? '')
                .toString()
                .toLowerCase();
            return name.contains(query) || patientId.contains(query);
          }).toList();

    if (filteredPatients.isEmpty) {
      // Do not flash the empty view if remote sync is actively in flight
      if (patients.isEmpty && isSyncing) {
        return const Center(
          child: CircularProgressIndicator(),
        );
      }
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.chat_bubble_outline,
              size: 48,
              color: Colors.grey[400],
            ),
            const SizedBox(height: 12),
            Text(
              patients.isEmpty
                  ? 'No patients have chatted with ${widget.doctorName ?? "this doctor"} yet'
                  : 'No patients match your search',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey[600]),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: filteredPatients.length,
      itemBuilder: (context, index) {
        final patient = filteredPatients[index];
        return _buildAdminPatientChatTile(patient);
      },
    );
  }

  Widget _buildAdminPatientChatTile(Map<String, dynamic> patient) {
    // Defensive normalization: these tiles render Hive-cached maps written by
    // older builds, where a missing key would otherwise crash the list with a
    // null-comparison error.
    final String patientId = (patient['patientId'] ?? '').toString();
    final String patientName =
        (patient['patientName'] ?? 'Patient').toString();
    final String patientImage = (patient['patientImage'] ?? '').toString();
    final String lastMessage = (patient['lastMessage'] ?? '').toString();
    final int unreadCount = ((patient['unreadCount'] as num?) ?? 0).toInt();
    final String chatId = (patient['chatId'] ?? '').toString();

    return StreamBuilder<dynamic>(
      stream: _presenceStreamFor(patientId, 'patient'),
      builder: (context, onlineSnapshot) {
        final bool isOnline = onlineSnapshot.data ?? false;

        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            gradient: AdminPalette.cardGradient,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AdminPalette.cardBorder),
            boxShadow: [
              BoxShadow(
                color: AdminPalette.cardShadow.withValues(alpha: 0.08),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 8,
            ),
            leading: Stack(
              clipBehavior: Clip.none,
              children: [
                CircleAvatar(
                  radius: 24,
                  backgroundColor: AdminPalette.brand.withValues(alpha: 0.1),
                  backgroundImage: patientImage.isNotEmpty
                      ? NetworkImage(patientImage)
                      : null,
                  child: patientImage.isEmpty
                      ? Icon(
                          Icons.person,
                          color: AdminPalette.brand,
                          size: 28,
                        )
                      : null,
                ),
                // Green online status dot
                Positioned(
                  bottom: 2,
                  right: 2,
                  child: Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isOnline ? Colors.green : Colors.grey,
                      border: Border.all(color: Colors.white, width: 2),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.1),
                          blurRadius: 2,
                          offset: const Offset(0, 1),
                        ),
                      ],
                    ),
                  ),
                ),
                if (unreadCount > 0)
                  Positioned(
                    right: -4,
                    top: -4,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: AdminPalette.brand,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 1.5),
                      ),
                      child: Text(
                        '$unreadCount',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: context.fs(10.5),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            title: Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          patientName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: context.fs(14.5),
                          ),
                        ),
                      ),
                      // Label only — a soft-deleted patient keeps their full
                      // historical conversation with this doctor.
                      if (patient['isPatientDeleted'] == true) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.grey[300],
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            'Deleted',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: Colors.grey[700],
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Text(
                  _formatTime(_parseTime(patient['lastMessageTime'])),
                  style: TextStyle(
                    fontSize: context.fs(11),
                    color: Colors.grey[500],
                  ),
                ),
              ],
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 4),
                Row(
                  children: [
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        lastMessage,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: context.fs(12.5),
                          color: unreadCount > 0
                              ? Colors.black87
                              : Colors.grey[600],
                          fontWeight: unreadCount > 0
                              ? FontWeight.w500
                              : FontWeight.normal,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => AdminChatViewScreen(
                    patientId: patientId,
                    patientName: patientName,
                    patientImage: patientImage,
                    doctorId: widget.doctorId!,
                    doctorName: widget.doctorName ?? 'Doctor',
                    adminId: widget.adminId!,
                    adminName: widget.adminName ?? 'Admin',
                    chatId: chatId,
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildRegularChatsView(String userId) {
    final chatStateAsync = ref.watch(recentChatsStateProvider(userId));
    // Shared with the chat screen overflow menu, so a favourite toggled there
    // is reflected in this list (and the Favourite tab) right away.
    final favouriteChatIds = ref.watch(chatFavouritesProvider);
    
    final body = chatStateAsync.when(
      skipLoadingOnReload: true,
      skipLoadingOnRefresh: true,
      // First frame before the provider's cache-first yield lands. Render the
      // Hive cache directly whenever it holds data, so a valid local list
      // never flashes a full-screen spinner; the spinner is reserved for a
      // genuine first-ever load with nothing cached.
      loading: () {
        final cached = OfflineChatService.instance.getChatList(userId);
        if (cached != null && cached.isNotEmpty) {
          return _buildChatsBody(cached, favouriteChatIds, isSyncing: true);
        }
        return const Center(
          child: CircularProgressIndicator(),
        );
      },
      error: (error, stack) {
        // Offline / Firestore outage with a local cache: show the cached
        // conversations rather than a blank error screen. Only a genuine
        // first-ever load with nothing cached reaches the error UI below.
        final cached = OfflineChatService.instance.getChatList(userId);
        if (cached != null && cached.isNotEmpty) {
          return _buildChatsBody(cached, favouriteChatIds, isSyncing: false);
        }
        // No toast here: `when(error:)` can rebuild and would re-fire a toast
        // on every rebuild. The inline error state with Retry is the feedback.
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 12),
              Text(
                'Could not load chats. Check your connection.',
                textAlign: TextAlign.center,
                style: TextStyle(),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () {
                  ref.invalidate(recentChatsStateProvider(userId));
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primaryRed,
                ),
                child: const Text('Retry'),
              ),
            ],
          ),
        );
      },
      data: (state) => _buildChatsBody(
        state.chats,
        favouriteChatIds,
        isSyncing: state.isSyncing,
      ),
    );

    // Tabs are part of the permanent layout and must ALWAYS stay visible,
    // regardless of whether the selected filter has 0, 1, or many chats.
    return Column(
      children: [
        _buildTabsRow(),
        Expanded(child: body),
      ],
    );
  }

  /// Search + tab filtering + list/empty rendering for the regular chat list.
  /// Shared between the provider's `data` branch and the cache fallback in
  /// its `loading` branch so both render identically.
  Widget _buildChatsBody(
    List<Map<String, dynamic>> chats,
    Set<String> favouriteChatIds, {
    bool isSyncing = false,
  }) {
    final query = widget.searchQuery.trim().toLowerCase();
    final filteredChats = query.isEmpty
        ? chats
        : chats.where((chat) {
            final name = (chat['otherUserName'] ?? '').toString().toLowerCase();
            final patientName =
                (chat['patientName'] ?? '').toString().toLowerCase();
            final doctorName =
                (chat['doctorName'] ?? '').toString().toLowerCase();
            return name.contains(query) ||
                patientName.contains(query) ||
                doctorName.contains(query);
          }).toList();

    // Apply the active ALL / UNREAD / FAVOURITE tab filter on top of search.
    final tabFilteredChats = filteredChats.where((chat) {
      switch (_activeTab) {
        case 'unread':
          return (((chat['unreadCount'] as num?) ?? 0).toInt()) > 0;
        case 'favourite':
          return favouriteChatIds.contains(_chatKey(chat));
        default:
          return true;
      }
    }).toList();

    if (tabFilteredChats.isEmpty) {
      // Do not flash the empty view if remote sync is actively in flight
      if (chats.isEmpty && isSyncing) {
        return const Center(
          child: CircularProgressIndicator(),
        );
      }
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _activeTab == 'favourite'
                  ? Icons.star_border_rounded
                  : _activeTab == 'unread'
                      ? Icons.mark_email_unread_outlined
                      : Icons.chat_bubble_outline,
              size: 48,
              color: Colors.grey[400],
            ),
            const SizedBox(height: 12),
            Text(
              _activeTab == 'favourite'
                  ? 'No favourite chats yet.\nTap the star on a chat to pin it.'
                  : _activeTab == 'unread'
                      ? 'You\'re all caught up!\nNo unread chats.'
                      : widget.searchQuery.isEmpty
                          ? 'No conversations yet.\nStart chatting with patients!'
                          : 'No matches found',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey[600]),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: tabFilteredChats.length,
      itemBuilder: (context, index) {
        final chat = tabFilteredChats[index];
        return _buildRegularChatTile(chat);
      },
    );
  }

  Widget _buildFilterChip(String label, String filter) {
    return AdminFilterChip(
      label: label,
      selected: _activeTab == filter,
      onTap: () {
        if (_activeTab != filter) {
          setState(() => _activeTab = filter);
        }
      },
    );
  }

  Widget _buildTabsRow() {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: context.rsp(16), vertical: 5),
      width: double.infinity,
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _buildFilterChip('All', 'all'),
          _buildFilterChip('Unread', 'unread'),
          _buildFilterChip('Favorite', 'favourite'),
          // Subtle, unobtrusive offline marker: the list above keeps showing
          // cached conversations; this only tells the user why new messages
          // are not arriving yet. Same chip language as the filter chips.
          if (_isOffline) _buildOfflineChip(),
        ],
      ),
    );
  }

  Widget _buildOfflineChip() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.grey.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.grey.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off, size: 14, color: Colors.grey[600]),
          const SizedBox(width: 4),
          Text(
            'Offline',
            style: TextStyle(
              fontSize: context.fs(11),
              fontWeight: FontWeight.w500,
              color: Colors.grey[700],
            ),
          ),
        ],
      ),
    );
  }

  bool _isFavouriteChat(Map<String, dynamic> chat) =>
      ref.read(chatFavouritesProvider).contains(_chatKey(chat));

  String _chatKey(Map<String, dynamic> chat) {
    return chatFavouriteKey(
      chatId: (chat['chatId'] ?? '').toString(),
      otherUserId: (chat['otherUserId'] ?? '').toString(),
    );
  }

  Widget _buildRegularChatTile(Map<String, dynamic> chat) {
    // Defensive normalization: these maps can come from the Hive cache
    // written by older app versions, where a missing key would otherwise
    // crash the whole chat list with a null-comparison error.
    final String otherUserId = (chat['otherUserId'] ?? '').toString();
    final String otherUserRole =
        (chat['otherUserRole'] ?? chat['role'] ?? 'patient').toString();

    // Get current user
    final user = ref.read(userProvider);
    final bool isLastMessageFromMe = chat['lastMessageSenderId'] == user?.id;
    final bool isLastMessageRead = chat['lastMessageRead'] == true;
    final bool isLastMessageDelivered = chat['lastMessageDelivered'] == true;

    // Use centralized presence for doctors, CallController for patients
    final bool isDoctor = otherUserRole == 'doctor';

    if (isDoctor) {
      // Centralized doctor presence — same source as Doctor List
      final isOnline = ref.watch(doctorOnlineProvider(otherUserId));
      return _buildChatTileWithStatus(
        chat: chat,
        isOnline: isOnline,
        isLastMessageFromMe: isLastMessageFromMe,
        isLastMessageRead: isLastMessageRead,
        isLastMessageDelivered: isLastMessageDelivered,
        user: user,
        otherUserRole: otherUserRole,
      );
    }

    // For patients, use existing CallController stream (cached per user so
    // rebuilds re-subscribe nothing).
    return StreamBuilder<dynamic>(
      stream: _presenceStreamFor(otherUserId, otherUserRole),
      builder: (context, onlineSnapshot) {
        final bool isOnline = onlineSnapshot.data ?? false;
        return _buildChatTileWithStatus(
          chat: chat,
          isOnline: isOnline,
          isLastMessageFromMe: isLastMessageFromMe,
          isLastMessageRead: isLastMessageRead,
          isLastMessageDelivered: isLastMessageDelivered,
          user: user,
          otherUserRole: otherUserRole,
        );
      },
    );
  }

  Widget _buildChatTileWithStatus({
    required Map<String, dynamic> chat,
    required bool isOnline,
    required bool isLastMessageFromMe,
    required bool isLastMessageRead,
    required bool isLastMessageDelivered,
    required dynamic user,
    required String otherUserRole,
  }) {
    final String otherUserId = (chat['otherUserId'] ?? '').toString();
    final String otherUserName =
        (chat['otherUserName'] ?? 'Unknown').toString();
    final String otherUserImage = (chat['otherUserImage'] ?? '').toString();
    final String lastMessage = (chat['lastMessage'] ?? '').toString();
    final int unreadCount = ((chat['unreadCount'] as num?) ?? 0).toInt();
    final DateTime? lastMessageTime = _parseTime(chat['lastMessageTime']);

    return Container(
      
      child: InkWell(
        onTap: () {
          final chatId = (chat['chatId'] ?? '').toString();
          if (chatId.isNotEmpty) {
            markChatAsReadLocally(ref, chatId);
          }
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => ChatScreen(
                otherUserId: otherUserId,
                otherUserName: otherUserName,
                otherUserImage: otherUserImage,
                otherUserRole: otherUserRole,
                otherUserType: otherUserRole,
                currentUserRole: (chat['currentUserRole'] ?? '').toString(),
              ),
            ),
          );
        },
        onLongPress: () async {
          // Provide an alternative way to favourite/unfavourite via long press
          final nowFavourite = await ref
              .read(chatFavouritesProvider.notifier)
              .toggle(_chatKey(chat));
          if (!mounted) return;
          ToastService.instance.showInfo(
            nowFavourite ? 'Added to Favourites' : 'Removed from Favourites',
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 10),
          child: Row(
            children: [
              // Profile Picture with Online Indicator
              Stack(
                clipBehavior: Clip.none,
                children: [
                  CircleAvatar(
                    radius: 24,
                    backgroundColor: AppColors.primaryRed.withValues(alpha: 0.1),
                    backgroundImage: otherUserImage.isNotEmpty
                        ? NetworkImage(otherUserImage)
                        : null,
                    child: otherUserImage.isEmpty
                        ? const Icon(
                            Icons.person,
                            color: AppColors.primaryRed,
                            size: 28,
                          )
                        : null,
                  ),
                  Positioned(
                    bottom: 0,
                    right: 0,
                    child: Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isOnline ? Colors.green : Colors.grey,
                        border: Border.all(color: Colors.white, width: 2),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 14),
              // Chat details
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Top row: Name + Deleted badge + Star + Time
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            otherUserName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: context.fs(14.5),
                              color: const Color(0xFF1F2F44),
                            ),
                          ),
                        ),
                        // Soft delete is surfaced as a label, never as a
                        // filter. The counterpart's preserved name and profile
                        // are shown exactly as they were — the conversation
                        // stays openable and readable.
                        if (chat['isOtherUserDeleted'] == true) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.grey[300],
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              'Deleted',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: Colors.grey[700],
                              ),
                            ),
                          ),
                        ],
                        if (_isFavouriteChat(chat)) ...[
                          const SizedBox(width: 4),
                          const Icon(Icons.star_rounded, size: 16, color: AppColors.secondaryYellow),
                        ],
                        const Spacer(),
                        Text(
                          _formatTime(lastMessageTime),
                          style: TextStyle(
                            fontSize: context.fs(11),
                            color: unreadCount > 0 ? AppColors.primaryRed : Colors.grey[500],
                            fontWeight: unreadCount > 0 ? FontWeight.w600 : FontWeight.normal,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    // Bottom row: Read receipts + Message + Unread badge
                    Row(
                      children: [
                        if (isLastMessageFromMe && !_isTypingFresh(chat)) ...[
                          // Uses the explicit receipt state so the tile shows
                          // the same four stages as the bubble — including the
                          // pending clock, which the previous
                          // read/delivered boolean chain could not express.
                          MessageStatusIndicator(
                            state: MessageDeliveryState.parse(
                              chat['lastMessageStatus'] ??
                                  (isLastMessageRead
                                      ? 'read'
                                      : (isLastMessageDelivered
                                          ? 'delivered'
                                          : 'sent')),
                            ),
                            size: 16,
                            color: const Color(0xFF7E90A6),
                            readColor: const Color(0xFF1D74C9),
                          ),
                          const SizedBox(width: 4),
                        ],
                        Expanded(
                          child: _isTypingFresh(chat)
                              ? Text(
                                  'typing...',
                                  maxLines: 1,
                                  style: TextStyle(
                                    fontSize: context.fs(12.5),
                                    color: const Color(0xFF4ADE80), // WhatsApp green
                                    fontWeight: FontWeight.w600,
                                    fontStyle: FontStyle.italic,
                                  ),
                                )
                              : Text(
                                  lastMessage,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: context.fs(12.5),
                                    color: unreadCount > 0
                                        ? const Color(0xFF1F2F44)
                                        : Colors.grey[600],
                                    fontWeight: unreadCount > 0
                                        ? FontWeight.w600
                                        : FontWeight.normal,
                                  ),
                                ),
                        ),
                        if (unreadCount > 0) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.all(6),
                            decoration: const BoxDecoration(
                              color: AppColors.primaryRed,
                              shape: BoxShape.circle,
                            ),
                            child: Text(
                              '$unreadCount',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: context.fs(10.5),
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Typing freshness: a `isTyping=true` flag written by an app that was
  /// later killed mid-burst would otherwise stick forever. The flag is only
  /// honoured while `lastTypingUpdate` is recent; legacy docs without the
  /// timestamp keep the old behaviour.
  bool _isTypingFresh(Map<String, dynamic> chat) {
    if (chat['isTyping'] != true) return false;
    final raw = chat['lastTypingUpdate'];
    if (raw == null) return true;
    DateTime? at;
    if (raw is DateTime) {
      at = raw;
    } else if (raw is num) {
      at = DateTime.fromMillisecondsSinceEpoch(raw.toInt());
    } else if (raw is String) {
      at = DateTime.tryParse(raw);
    }
    // Timestamp (Firestore) exposes toDate(); checked dynamically to avoid a
    // hard dependency in this widget.
    if (at == null) {
      try {
        final dynamic ts = raw;
        at = ts.toDate() as DateTime?;
      } catch (_) {
        return true;
      }
    }
    if (at == null) return true;
    return DateTime.now().difference(at).inSeconds < 8;
  }

  /// Tolerant time parser: cached entries may store the timestamp as a
  /// [DateTime], a Firestore [Timestamp], an epoch number or an ISO string.
  DateTime? _parseTime(dynamic raw) {
    if (raw == null) return null;
    if (raw is DateTime) return raw;
    if (raw is num) return DateTime.fromMillisecondsSinceEpoch(raw.toInt());
    if (raw is String) return DateTime.tryParse(raw);
    try {
      final dynamic ts = raw;
      return ts.toDate() as DateTime?;
    } catch (_) {
      return null;
    }
  }

  String _formatTime(DateTime? time) {
    if (time == null) return '';
    final now = DateTime.now();
    final difference = now.difference(time);

    if (difference.inDays > 7) {
      return DateFormat('MMM d').format(time);
    } else if (difference.inDays > 0) {
      return '${difference.inDays}d ago';
    } else if (difference.inHours > 0) {
      return '${difference.inHours}h ago';
    } else if (difference.inMinutes > 0) {
      return '${difference.inMinutes}m ago';
    } else {
      return 'Just now';
    }
  }
}
