import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

import 'models/offline_call_record.dart';
import 'models/offline_chat_message.dart';

/// Manages the initialization and lifetime of all Hive boxes used by the
/// offline-first data layer.
class HiveDBService {
  HiveDBService._();

  static const String chatMessagesBoxName = 'offline_chat_messages';
  static const String callHistoryBoxName = 'offline_call_history';
  static const String chatListBoxName = 'offline_chat_list_cache';
  static const String doctorListBoxName = 'offline_doctor_list_cache';

  static bool _initialized = false;
  static Box<OfflineChatMessage>? _chatMessagesBox;
  static Box<OfflineCallRecord>? _callHistoryBox;
  static Box<String>? _chatListBox;
  static Box<String>? _doctorListBox;

  static bool get isInitialized => _initialized;

  /// Call once before the app starts using offline data (e.g. in main()).
  static Future<void> initialize() async {
    if (_initialized) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      Hive.init(dir.path);

      Hive.registerAdapter(OfflineChatMessageAdapter());
      Hive.registerAdapter(OfflineCallRecordAdapter());

      await Future.wait([
        Hive.openBox<OfflineChatMessage>(chatMessagesBoxName),
        Hive.openBox<OfflineCallRecord>(callHistoryBoxName),
        Hive.openBox<String>(chatListBoxName),
        Hive.openBox<String>(doctorListBoxName),
      ]);

      _chatMessagesBox = Hive.box<OfflineChatMessage>(chatMessagesBoxName);
      _callHistoryBox = Hive.box<OfflineCallRecord>(callHistoryBoxName);
      _chatListBox = Hive.box<String>(chatListBoxName);
      _doctorListBox = Hive.box<String>(doctorListBoxName);

      _initialized = true;
    } catch (e) {
      // Never let Hive init failures crash the app; fail safe to in-memory.
      _chatMessagesBox = null;
      _callHistoryBox = null;
      _chatListBox = null;
      _doctorListBox = null;
    }
  }

  static Box<OfflineChatMessage>? get chatMessagesBox => _chatMessagesBox;

  static Box<OfflineCallRecord>? get callHistoryBox => _callHistoryBox;

  static Box<String>? get chatListBox => _chatListBox;

  /// Local mirror of `telemedicine_doctors`, used to paint doctor pickers
  /// instantly on a cold start before Firestore answers.
  static Box<String>? get doctorListBox => _doctorListBox;

  static bool get chatBoxReady =>
      _initialized && _chatMessagesBox != null && _chatMessagesBox!.isOpen;

  static bool get chatListBoxReady =>
      _initialized && _chatListBox != null && _chatListBox!.isOpen;

  /// Unlike the other boxes, the doctor cache being unavailable is a
  /// performance regression only — every consumer falls back to Firestore —
  /// so this deliberately reports ready even when the box failed to open.
  static bool get doctorListBoxReady =>
      _doctorListBox != null && _doctorListBox!.isOpen;

  static bool get callBoxReady =>
      _initialized && _callHistoryBox != null && _callHistoryBox!.isOpen;

  static Future<void> close() async {
    if (_initialized) {
      await Hive.close();
      _initialized = false;
      _chatMessagesBox = null;
      _callHistoryBox = null;
      _chatListBox = null;
      _doctorListBox = null;
    }
  }
}
