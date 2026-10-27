import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:hive/hive.dart';

import 'hive_db_service.dart';
import 'models/offline_chat_message.dart';

/// Provides offline-first storage and synchronization for chat messages using
/// a Hive box as the local cache. The backend remains the source of truth and
/// is used only for synchronization.
class OfflineChatService {
  OfflineChatService._();

  static final OfflineChatService instance = OfflineChatService._();

  static String messageKey(String chatId, String messageId) =>
      '${chatId}_$messageId';

  /// Fires whenever the local "hide for me" marks change.
  ///
  /// Those marks live in the chat-list box rather than the message box, so a
  /// stream watching only `chatMessagesBox` would not learn that a message
  /// just disappeared for this account.
  static final StreamController<void> _hiddenChangedController =
      StreamController<void>.broadcast();

  static Stream<void> get onHiddenChanged => _hiddenChangedController.stream;

  Box<OfflineChatMessage>? get _box => HiveDBService.chatMessagesBox;

  /// Exposes the underlying box so listeners can watch for local writes
  /// (e.g. an offline-queued message) and re-emit immediately.
  Box<OfflineChatMessage>? get box => _box;
  
  Box<String>? get _chatListBox => HiveDBService.chatListBox;

  bool get _ready => HiveDBService.chatBoxReady;
  
  bool get _listReady => HiveDBService.chatListBoxReady;
  
  static String favouritesKey(String userId) => 'favourite_chats_$userId';

  static String syncStateKey(String userId) => 'chat_sync_state_$userId';

  /// Interval below which repeated sync-state writes are skipped. Server
  /// snapshots can arrive in bursts (typing flags, latency-compensated
  /// writes), and this marker only needs to be approximately fresh.
  static const Duration _syncStateThrottle = Duration(seconds: 15);

  static DateTime? _lastSyncStateWrite;

  /// Reads the local sync marker for [userId]: `{initialSyncCompleted, lastSyncedAt}`.
  Map<String, dynamic>? getSyncState(String userId) {
    if (!_listReady) return null;
    try {
      final raw = _chatListBox!.get(syncStateKey(userId));
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded;
    } catch (e) {
      print('Error reading chat sync state: $e');
      return null;
    }
  }

  /// Records that a server-backed chat list for [userId] has been persisted.
  ///
  /// Throttled once completed: before completion every write matters (it is
  /// the latch that stops recovery re-fetching), afterwards a re-write within
  /// [_syncStateThrottle] adds nothing.
  Future<void> markSyncCompleted(String userId) async {
    if (!_listReady) return;
    final existing = getSyncState(userId);
    final completed = existing?['initialSyncCompleted'] == true;
    if (completed &&
        _lastSyncStateWrite != null &&
        DateTime.now().difference(_lastSyncStateWrite!) < _syncStateThrottle) {
      return;
    }
    await saveSyncState(userId, initialSyncCompleted: true);
  }

  /// Writes the local sync marker for [userId].
  Future<void> saveSyncState(
    String userId, {
    required bool initialSyncCompleted,
  }) async {
    if (!_listReady) return;
    try {
      await _chatListBox!.put(
        syncStateKey(userId),
        jsonEncode({
          'initialSyncCompleted': initialSyncCompleted,
          'lastSyncedAt': DateTime.now().toIso8601String(),
        }),
      );
      _lastSyncStateWrite = DateTime.now();
    } catch (e) {
      print('Error saving chat sync state: $e');
    }
  }

  /// Whether the local chat list for [userId] is missing or was never
  /// confirmed complete by a server-backed fetch, i.e. a recovery fetch is
  /// required. Pure decision logic lives in [needsRecovery] so it can be
  /// unit-tested without a Hive box.
  bool needsChatListRecovery(String userId) {
    if (!_listReady) return false;
    final cached = getChatList(userId);
    final state = getSyncState(userId);
    return needsRecovery(
      hasCachedList: cached != null && cached.isNotEmpty,
      syncCompleted: state?['initialSyncCompleted'] == true,
    );
  }

  /// Pure recovery decision: fetch only when local data is missing or the
  /// cache was never confirmed against the server.
  static bool needsRecovery({
    required bool hasCachedList,
    required bool syncCompleted,
  }) =>
      !hasCachedList || !syncCompleted;

  /// Set of chat ids the user has marked as favourite, persisted locally.
  Set<String> getFavouriteChatIds(String userId) {
    if (!_listReady) return {};
    try {
      final raw = _chatListBox!.get(favouritesKey(userId));
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded.map((e) => e.toString()).toSet();
    } catch (e) {
      print('Error reading favourites: $e');
      return {};
    }
  }

  /// Persist the user's favourite chat ids locally.
  Future<void> saveFavouriteChatIds(String userId, Set<String> ids) async {
    if (!_listReady) return;
    try {
      await _chatListBox!.put(
        favouritesKey(userId),
        jsonEncode(ids.toList()),
      );
    } catch (e) {
      print('Error saving favourites: $e');
    }
  }

  /// Storage key for the messages [userId] deleted for themselves only.
  ///
  /// `chatId_messageId` strings, so a "delete for me" survives a restart and a
  /// cold device without any server round-trip, while the row itself stays in
  /// the store for devices that share the account.
  static String hiddenMessagesKey(String userId) => 'hidden_messages_$userId';

  /// Message keys hidden for [userId] by "Delete for Me".
  Set<String> getHiddenMessageKeys(String userId) {
    if (!_listReady) return {};
    try {
      final raw = _chatListBox!.get(hiddenMessagesKey(userId));
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded.map((e) => e.toString()).toSet();
    } catch (e) {
      print('Error reading hidden messages: $e');
      return {};
    }
  }

  /// Adds message keys hidden for [userId]. Idempotent.
  Future<void> addHiddenMessageKeys(
    String userId,
    Iterable<String> keys,
  ) async {
    if (!_listReady) return;
    try {
      final updated = {...getHiddenMessageKeys(userId), ...keys};
      await _chatListBox!.put(
        hiddenMessagesKey(userId),
        jsonEncode(updated.toList()),
      );
      _hiddenChangedController.add(null);
    } catch (e) {
      print('Error saving hidden messages: $e');
    }
  }

  /// Removes message keys hidden for [userId] (rollback path).
  Future<void> removeHiddenMessageKeys(
    String userId,
    Iterable<String> keys,
  ) async {
    if (!_listReady) return;
    try {
      final updated = {...getHiddenMessageKeys(userId)}..removeAll(keys);
      await _chatListBox!.put(
        hiddenMessagesKey(userId),
        jsonEncode(updated.toList()),
      );
      _hiddenChangedController.add(null);
    } catch (e) {
      print('Error saving hidden messages: $e');
    }
  }

  /// Reactive stream that immediately emits the locally cached chat list and
  /// re-emits whenever the local database changes (cache-first / offline-first).
  Stream<List<Map<String, dynamic>>> watchChatList(String userId) async* {
    yield getChatList(userId) ?? <Map<String, dynamic>>[];
    if (!_listReady) return;
    final box = _chatListBox;
    if (box == null) return;
    yield* box.watch(key: 'chat_list_$userId').map((_) {
      return getChatList(userId) ?? <Map<String, dynamic>>[];
    });
  }

  /// Upserts records into the local database without wiping existing cached
  /// entries on transient or unconfirmed remote empty emissions.
  Future<void> upsertChatList(String userId, List<Map<String, dynamic>> remoteChats) async {
    if (!_listReady) return;
    final existing = getChatList(userId) ?? <Map<String, dynamic>>[];
    
    // Prevent wiping cached data if remote returns empty while sync is in progress
    if (remoteChats.isEmpty && existing.isNotEmpty) {
      final syncState = getSyncState(userId);
      if (syncState?['initialSyncCompleted'] != true) {
        return;
      }
    }

    await saveChatList(userId, remoteChats);
  }

  static dynamic _sanitizeForStorage(dynamic value) {
    if (value == null) return null;
    if (value is Timestamp) {
      return value.toDate().toIso8601String();
    }
    if (value is DateTime) {
      return value.toIso8601String();
    }
    if (value is Map) {
      final sanitized = <String, dynamic>{};
      for (final entry in value.entries) {
        sanitized[entry.key.toString()] = _sanitizeForStorage(entry.value);
      }
      return sanitized;
    }
    if (value is Iterable) {
      return value.map(_sanitizeForStorage).toList();
    }
    return value;
  }

  Future<void> saveChatList(String userId, List<Map<String, dynamic>> chats) async {
    if (!_listReady) return;
    try {
      final encodableList = chats.map((chat) {
        final sanitized = _sanitizeForStorage(chat) as Map<String, dynamic>;
        if (sanitized['lastMessageTime'] is DateTime) {
          sanitized['lastMessageTime'] =
              (sanitized['lastMessageTime'] as DateTime).toIso8601String();
        }
        return sanitized;
      }).toList();
      final jsonStr = jsonEncode(
        encodableList,
        toEncodable: (nonEncodable) {
          if (nonEncodable is Timestamp) {
            return nonEncodable.toDate().toIso8601String();
          }
          if (nonEncodable is DateTime) {
            return nonEncodable.toIso8601String();
          }
          return nonEncodable.toString();
        },
      );
      await _chatListBox!.put('chat_list_$userId', jsonStr);
    } catch (e) {
      print('Error saving chat list to Hive: $e');
    }
  }

  List<Map<String, dynamic>>? getChatList(String userId) {
    if (!_listReady) return null;
    try {
      final jsonStr = _chatListBox!.get('chat_list_$userId');
      if (jsonStr == null) return null;
      final List<dynamic> decoded = jsonDecode(jsonStr);
      return decoded.map((item) {
        final map = Map<String, dynamic>.from(item as Map);
        if (map['lastMessageTime'] != null) {
          map['lastMessageTime'] = DateTime.parse(map['lastMessageTime'].toString());
        }
        return map;
      }).toList();
    } catch (e) {
      print('Error getting chat list from Hive: $e');
      return null;
    }
  }

  /// Save (or update) a single message locally, keyed by [chatId] + messageId
  /// to avoid duplicates. Returns false if the local database is unavailable.
  Future<bool> saveMessage(OfflineChatMessage message) async {
    if (!_ready) return false;
    _box!.put(messageKey(message.chatId, message.messageId), message);
    return true;
  }

  /// Bulk save (upsert) a list of messages, de-duplicating by messageId.
  Future<int> saveMessages(List<OfflineChatMessage> messages) async {
    if (!_ready) return 0;
    final box = _box!;
    var count = 0;
    await box.putAll({
      for (final m in messages) messageKey(m.chatId, m.messageId): m,
    });
    count = messages.length;
    return count;
  }

  /// Retrieve all locally cached messages for a given [chatId], sorted
  /// ascending by timestamp.
  List<OfflineChatMessage> getMessagesForChat(String chatId) {
    if (!_ready) return const [];
    final box = _box!;
    final results = <OfflineChatMessage>[];
    for (final message in box.values) {
      if (message.chatId == chatId) {
        results.add(message);
      }
    }
    results.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return results;
  }

  /// Get a single message by id within a chat.
  OfflineChatMessage? getMessage(String chatId, String messageId) {
    if (!_ready) return null;
    return _box!.get(messageKey(chatId, messageId));
  }

  /// All messages that are queued locally but not yet sent to the server.
  List<OfflineChatMessage> getPendingMessages() {
    if (!_ready) return const [];
    return _box!
        .values
        .where((m) => m.deliveryStatus == OfflineDeliveryStatus.pending.name)
        .toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  }

  /// Update the delivery status of a message.
  Future<bool> updateDeliveryStatus(
    String chatId,
    String messageId,
    OfflineDeliveryStatus status,
  ) async {
    if (!_ready) return false;
    final key = messageKey(chatId, messageId);
    final current = _box!.get(key);
    if (current == null) return false;
    await _box!.put(
      key,
      current.copyWith(deliveryStatus: status.name),
    );
    return true;
  }

  /// Update the read status of a message.
  Future<bool> updateReadStatus(
    String chatId,
    String messageId,
    OfflineReadStatus status,
  ) async {
    if (!_ready) return false;
    final key = messageKey(chatId, messageId);
    final current = _box!.get(key);
    if (current == null) return false;
    await _box!.put(key, current.copyWith(readStatus: status.name));
    return true;
  }

  /// Update read status for all received messages in a chat for [currentUserId].
  /// Strictly filters to incoming messages only (receiverId == currentUserId AND
  /// senderId != currentUserId), never marking outgoing messages.
  Future<int> markChatAsRead(String chatId, String currentUserId) async {
    if (!_ready) return 0;
    final box = _box!;
    var updated = 0;
    for (final message in box.values) {
      final isIncoming = message.receiverId == currentUserId &&
          message.senderId != currentUserId;
      if (message.chatId == chatId &&
          isIncoming &&
          message.readStatus != OfflineReadStatus.read.name) {
        await box.put(
          messageKey(chatId, message.messageId),
          message.copyWith(readStatus: OfflineReadStatus.read.name),
        );
        updated++;
      }
    }

    // Immediately synchronize the cached chat list unreadCount to 0 in Hive
    await setCachedChatUnreadCount(
      userId: currentUserId,
      chatId: chatId,
      count: 0,
    );

    return updated;
  }

  /// Pure unread calculation for local database rows:
  /// ONLY counts incoming messages where receiverId == currentUserId AND
  /// senderId != currentUserId AND readStatus != read.
  /// Never counts outgoing messages sent by the user.
  int countUnreadIncomingMessages(String chatId, String currentUserId) {
    if (!_ready) return 0;
    final box = _box!;
    var unread = 0;
    for (final message in box.values) {
      if (message.chatId == chatId &&
          message.receiverId == currentUserId &&
          message.senderId != currentUserId &&
          message.readStatus != OfflineReadStatus.read.name) {
        unread++;
      }
    }
    return unread;
  }

  /// Mirrors a conversation's server-side unread count into the cached chat
  /// list.
  ///
  /// The chat list is served from Hive first and then refreshed live, so a
  /// stale count in the cache would briefly render the wrong badge when the
  /// user navigates back from a conversation they just read. Firestore stays
  /// the source of truth — this only stops the cache contradicting it.
  Future<void> setCachedChatUnreadCount({
    required String userId,
    required String chatId,
    required int count,
  }) async {
    if (!_listReady) return;
    try {
      final key = 'chat_list_$userId';
      final jsonStr = _chatListBox!.get(key);
      if (jsonStr == null) return;

      final decoded = jsonDecode(jsonStr) as List<dynamic>;
      var changed = false;

      final updated = decoded.map((entry) {
        final map = Map<String, dynamic>.from(entry as Map);
        if (map['chatId'] == chatId) {
          map['unreadCount'] = count;
          changed = true;
        }
        return map;
      }).toList();

      if (changed) {
        await _chatListBox!.put(key, jsonEncode(updated));
      }
    } catch (e) {
      print('Error setting cached chat unread count: $e');
    }
  }

  /// Applies an incoming chat FCM push to the local cache.
  ///
  /// Used by both the foreground handler and the background isolate so a
  /// message that arrives while the chat screen is NOT open still refreshes
  /// the cached list preview, unread badge and message store. Every step is
  /// idempotent: the message upserts under its `chatId_messageId` key and the
  /// list patch no-ops when `lastMessageId` already matches, so a redelivered
  /// push cannot double-count an unread badge or duplicate a message.
  static Future<void> applyChatPushPayload(Map<String, dynamic> data) async {
    final chatId = (data['chatId'] ?? '').toString();
    final messageId = (data['messageId'] ?? '').toString();
    final receiverId = (data['receiverId'] ?? '').toString();
    final senderId = (data['senderId'] ?? '').toString();
    if (chatId.isEmpty || messageId.isEmpty || receiverId.isEmpty) return;
    if (senderId.isEmpty || senderId == receiverId) return;

    await HiveDBService.initialize();

    final rawTs = (data['timestamp'] ?? '').toString();
    final epochMs = int.tryParse(rawTs);
    final timestamp =
        epochMs != null ? DateTime.fromMillisecondsSinceEpoch(epochMs) : DateTime.now();

    await instance.applyIncomingChatPush(
      receiverId: receiverId,
      chatId: chatId,
      messageId: messageId,
      senderId: senderId,
      messageText: (data['messageText'] ?? '').toString(),
      messageType: (data['messageType'] ?? 'text').toString(),
      timestamp: timestamp,
    );
  }

  Future<void> applyIncomingChatPush({
    required String receiverId,
    required String chatId,
    required String messageId,
    required String senderId,
    required String messageText,
    required String messageType,
    required DateTime timestamp,
  }) async {
    // 1. The message row itself (skipped when this push was already applied).
    if (getMessage(chatId, messageId) == null) {
      await saveMessage(
        OfflineChatMessage(
          messageId: messageId,
          senderId: senderId,
          receiverId: receiverId,
          message: messageText,
          timestamp: timestamp,
          messageType: messageType,
          deliveryStatus: OfflineDeliveryStatus.delivered.name,
          readStatus: OfflineReadStatus.unread.name,
          chatId: chatId,
        ),
      );
    }

    // 2. The cached chat-list preview + unread badge + ordering.
    if (!_listReady) return;
    final cached = getChatList(receiverId);
    if (cached == null) return;
    final patched = patchChatListForPush(
      cached,
      chatId: chatId,
      messageId: messageId,
      senderId: senderId,
      messageText: messageText,
      timestamp: timestamp,
    );
    if (patched != null) {
      await saveChatList(receiverId, patched);
    }
  }

  /// Pure chat-list patch for an incoming push. Returns the updated list, or
  /// `null` when nothing should change:
  ///
  ///  * the chat is not in the cached list (mount/recovery will build it with
  ///    a full profile — a push payload must never invent a half-filled tile);
  ///  * the entry already carries this `messageId` (redelivered push).
  static List<Map<String, dynamic>>? patchChatListForPush(
    List<Map<String, dynamic>> chats, {
    required String chatId,
    required String messageId,
    required String senderId,
    required String messageText,
    required DateTime timestamp,
  }) {
    final index = chats.indexWhere((chat) => chat['chatId'] == chatId);
    if (index == -1) return null;
    if ((chats[index]['lastMessageId'] ?? '').toString() == messageId) {
      return null;
    }

    final entry = Map<String, dynamic>.from(chats[index]);
    entry['lastMessage'] = messageText;
    entry['lastMessageTime'] = timestamp;
    entry['lastMessageSenderId'] = senderId;
    entry['lastMessageId'] = messageId;
    // The push reached THIS device, so the message is delivered to us; read
    // state is still false. The badge overlay in Firestore remains the source
    // of truth — this only keeps the offline mirror plausible.
    entry['lastMessageDelivered'] = true;
    entry['lastMessageRead'] = false;
    entry['lastMessageStatus'] = null;
    entry['unreadCount'] = (((entry['unreadCount'] as num?) ?? 0).toInt()) + 1;

    final updated = [...chats]..[index] = entry;
    updated.sort((a, b) {
      final aTime = _entryTime(a['lastMessageTime']);
      final bTime = _entryTime(b['lastMessageTime']);
      return bTime.compareTo(aTime);
    });
    return updated;
  }

  static DateTime _entryTime(dynamic raw) {
    if (raw is DateTime) return raw;
    if (raw is num) return DateTime.fromMillisecondsSinceEpoch(raw.toInt());
    if (raw is String) return DateTime.tryParse(raw) ?? DateTime(2000);
    return DateTime(2000);
  }

  /// Merge messages fetched from the server into the local cache,
  /// keeping the local (possibly pending) version wins for outbound pending
  /// messages so we don't lose unsent local data.
  Future<int> mergeServerMessages(
    String chatId,
    List<OfflineChatMessage> serverMessages,
  ) async {
    if (serverMessages.isEmpty) return 0;
    final box = _box!;
    var merged = 0;
    for (final serverMsg in serverMessages) {
      final key = messageKey(chatId, serverMsg.messageId);
      final localMsg = box.get(key);
      // If we have a local pending version, keep it (it will be re-synced).
      if (localMsg != null &&
          localMsg.deliveryStatus == OfflineDeliveryStatus.pending.name) {
        continue;
      }
      if (localMsg == null || _isNewer(serverMsg, localMsg)) {
        await box.put(key, serverMsg);
        merged++;
      }
    }
    return merged;
  }

  bool _isNewer(OfflineChatMessage incoming, OfflineChatMessage existing) {
    if (incoming.timestamp.isAfter(existing.timestamp)) return true;
    if (incoming.timestamp.isBefore(existing.timestamp)) return false;
    // Same timestamp: prefer the one that is read/delivered (more up to date).
    final incomingTicks = _statusTicks(incoming);
    final existingTicks = _statusTicks(existing);
    return incomingTicks > existingTicks;
  }

  int _statusTicks(OfflineChatMessage m) {
    var ticks = 0;
    if (m.deliveryStatus == OfflineDeliveryStatus.delivered.name) ticks++;
    if (m.readStatus == OfflineReadStatus.read.name) ticks++;
    return ticks;
  }

  /// Delete a message from the local cache.
  Future<bool> deleteMessage(String chatId, String messageId) async {
    if (!_ready) return false;
    await _box!.delete(messageKey(chatId, messageId));
    return true;
  }

  /// Delete all locally cached messages for a chat.
  Future<void> clearChat(String chatId) async {
    if (!_ready) return;
    final box = _box!;
    final keys = <dynamic>[];
    for (final entry in box.toMap().entries) {
      if (entry.value.chatId == chatId) {
        keys.add(entry.key);
      }
    }
    await box.deleteAll(keys);
  }
}
