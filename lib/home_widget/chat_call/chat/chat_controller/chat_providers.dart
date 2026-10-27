import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/home_widget/chat_call/chat/chat_controller/chat_controller.dart';
import 'package:telemedicine/offline_db/offline_chat_service.dart';

final chatControllerProvider = Provider<ChatController>((ref) {
  return ChatController();
});

/// Explicit synchronization statuses for offline-first state machine.
enum ChatSyncStatus {
  idle,
  syncing,
  synced,
  error,
}

/// Structured UI state separating cached data, remote syncing, and true empty state.
class ChatListUiState {
  final List<Map<String, dynamic>> chats;
  final ChatSyncStatus syncStatus;
  final bool hasCachedData;
  final Object? error;

  const ChatListUiState({
    required this.chats,
    this.syncStatus = ChatSyncStatus.idle,
    this.hasCachedData = false,
    this.error,
  });

  bool get isEmpty => chats.isEmpty;
  bool get isSyncing => syncStatus == ChatSyncStatus.syncing;
  bool get isSynced => syncStatus == ChatSyncStatus.synced;
  bool get hasError => syncStatus == ChatSyncStatus.error;

  /// The "No conversation yet" placeholder must ONLY render if:
  /// `localData.isEmpty && !isLoadingRemote` (i.e. 0 local records AND remote sync completed with 0 records).
  bool get shouldShowEmptyPlaceholder =>
      isEmpty && syncStatus != ChatSyncStatus.syncing && syncStatus != ChatSyncStatus.idle;

  ChatListUiState copyWith({
    List<Map<String, dynamic>>? chats,
    ChatSyncStatus? syncStatus,
    bool? hasCachedData,
    Object? error,
  }) {
    return ChatListUiState(
      chats: chats ?? this.chats,
      syncStatus: syncStatus ?? this.syncStatus,
      hasCachedData: hasCachedData ?? this.hasCachedData,
      error: error ?? this.error,
    );
  }
}

/// Reactive State Provider for patient/user chats with offline-first state machine.
final recentChatsStateProvider =
    StreamProvider.autoDispose.family<ChatListUiState, String>((ref, userId) async* {
  final controller = ref.watch(chatControllerProvider);
  final offlineService = OfflineChatService.instance;

  // 1. Initial State: Immediately emit records from local DB cache
  final cached = offlineService.getChatList(userId) ?? <Map<String, dynamic>>[];
  final hasCache = cached.isNotEmpty;

  yield ChatListUiState(
    chats: cached,
    syncStatus: ChatSyncStatus.syncing,
    hasCachedData: hasCache,
  );

  // 2. Reactive sync: listen to remote stream and upsert into local DB
  try {
    await for (final remoteChats in controller.getRecentChats(userId)) {
      // Do not wipe cache with an unconfirmed empty list while syncing
      if (remoteChats.isNotEmpty || !hasCache) {
        await offlineService.upsertChatList(userId, remoteChats);
      }

      final activeChats = remoteChats.isNotEmpty
          ? remoteChats
          : (hasCache ? (offlineService.getChatList(userId) ?? cached) : remoteChats);

      yield ChatListUiState(
        chats: activeChats,
        syncStatus: ChatSyncStatus.synced,
        hasCachedData: activeChats.isNotEmpty,
      );
    }
  } catch (error) {
    yield ChatListUiState(
      chats: cached,
      syncStatus: ChatSyncStatus.error,
      hasCachedData: hasCache,
      error: error,
    );
  }
});

/// Backward-compatible list provider that consumes the state stream.
final recentChatsProvider =
    StreamProvider.autoDispose.family<List<Map<String, dynamic>>, String>((ref, userId) async* {
  final stateStream = ref.watch(recentChatsStateProvider(userId).stream);
  await for (final state in stateStream) {
    yield state.chats;
  }
});

/// Reactive State Provider for doctor patient chats.
final doctorPatientsStateProvider =
    StreamProvider.autoDispose.family<ChatListUiState, String>((ref, doctorId) async* {
  final controller = ref.watch(chatControllerProvider);
  final offlineService = OfflineChatService.instance;

  final cached = offlineService.getChatList(doctorId) ?? <Map<String, dynamic>>[];
  final hasCache = cached.isNotEmpty;

  yield ChatListUiState(
    chats: cached,
    syncStatus: ChatSyncStatus.syncing,
    hasCachedData: hasCache,
  );

  try {
    await for (final remotePatients in controller.watchDoctorPatients(doctorId)) {
      if (remotePatients.isNotEmpty || !hasCache) {
        await offlineService.upsertChatList(doctorId, remotePatients);
      }

      final activePatients = remotePatients.isNotEmpty
          ? remotePatients
          : (hasCache ? (offlineService.getChatList(doctorId) ?? cached) : remotePatients);

      yield ChatListUiState(
        chats: activePatients,
        syncStatus: ChatSyncStatus.synced,
        hasCachedData: activePatients.isNotEmpty,
      );
    }
  } catch (error) {
    yield ChatListUiState(
      chats: cached,
      syncStatus: ChatSyncStatus.error,
      hasCachedData: hasCache,
      error: error,
    );
  }
});

/// Backward-compatible doctor patients provider.
final doctorPatientsProvider =
    StreamProvider.autoDispose.family<List<Map<String, dynamic>>, String>((ref, doctorId) async* {
  final stateStream = ref.watch(doctorPatientsStateProvider(doctorId).stream);
  await for (final state in stateStream) {
    yield state.chats;
  }
});
