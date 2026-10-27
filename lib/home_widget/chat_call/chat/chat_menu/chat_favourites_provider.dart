import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemedicine/auth/auth_provider/user_provider.dart';
import 'package:telemedicine/offline_db/offline_chat_service.dart';

/// Resolves the key used to identify a conversation in the favourites store.
/// Prefers the canonical `chatId` and falls back to the other user's id so
/// that entries created before a chat document existed still resolve.
String chatFavouriteKey({
  String? chatId,
  String? otherUserId,
}) {
  final id = (chatId ?? '').trim();
  if (id.isNotEmpty) return id;
  return (otherUserId ?? '').trim();
}

/// Shared, reactive favourite-conversation state backed by the local Hive
/// cache. Both the chat list (Favourite tab + star) and the chat screen
/// 3-dot menu read and write this single source, so a change made in one
/// place is reflected immediately in the other without touching Firestore.
class ChatFavouritesNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() {
    final user = ref.watch(userProvider);
    if (user == null) return <String>{};
    return OfflineChatService.instance.getFavouriteChatIds(user.id);
  }

  bool isFavourite({String? chatId, String? otherUserId}) {
    final key = chatFavouriteKey(chatId: chatId, otherUserId: otherUserId);
    if (key.isEmpty) return false;
    return state.contains(key);
  }

  /// Adds or removes [key] and returns the resulting favourite state.
  Future<bool> toggle(String key) async {
    if (key.isEmpty) return false;
    final next = state.toSet();
    final nowFavourite = !next.remove(key);
    if (nowFavourite) next.add(key);

    state = next;
    final userId = ref.read(userProvider)?.id;
    if (userId != null) {
      await OfflineChatService.instance.saveFavouriteChatIds(userId, next);
    }
    return nowFavourite;
  }
}

final chatFavouritesProvider =
    NotifierProvider<ChatFavouritesNotifier, Set<String>>(
  ChatFavouritesNotifier.new,
);
