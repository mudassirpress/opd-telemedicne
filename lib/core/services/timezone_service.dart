import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

/// Global service for IANA timezone conversions, profile synchronization,
/// and UTC timestamp formatting across the application.
class TimezoneService {
  TimezoneService._();
  static final TimezoneService instance = TimezoneService._();

  static bool _initialized = false;
  static String? _cachedCanonicalTimezone;

  /// Initializes the timezone database once.
  static void initialize() {
    if (_initialized) return;
    try {
      tz.initializeTimeZones();
      _initialized = true;
      _cachedCanonicalTimezone = _resolveCanonicalIanaTimezone();
      debugPrint(
        '🌍 [TimezoneService] Initialized with canonical timezone: $_cachedCanonicalTimezone',
      );
    } catch (e) {
      debugPrint('⚠️ [TimezoneService] Initialization error: $e');
    }
  }

  /// Resolves the canonical IANA timezone string for this device.
  static String get canonicalTimezone {
    if (_cachedCanonicalTimezone != null) return _cachedCanonicalTimezone!;
    initialize();
    return _cachedCanonicalTimezone ?? 'UTC';
  }

  /// Maps local timezone or offset to canonical IANA identifier.
  static String _resolveCanonicalIanaTimezone() {
    try {
      final now = DateTime.now();
      final offset = now.timeZoneOffset;
      final name = now.timeZoneName.trim();

      // Check if system name is already a valid IANA location
      try {
        if (tz.timeZoneDatabase.locations.containsKey(name)) {
          return name;
        }
      } catch (_) {}

      // Common regional mapping based on standard offsets & abbreviations
      final totalMinutes = offset.inMinutes;

      // UTC+5: PKT -> Asia/Karachi, Tashkent, Yekaterinburg
      if (totalMinutes == 300) {
        return 'Asia/Karachi';
      }
      // UTC+5:30: IST -> Asia/Kolkata
      if (totalMinutes == 330) {
        return 'Asia/Kolkata';
      }
      // UTC+4: GST -> Asia/Dubai
      if (totalMinutes == 240) {
        return 'Asia/Dubai';
      }
      // UTC+6: BST -> Asia/Dhaka
      if (totalMinutes == 360) {
        return 'Asia/Dhaka';
      }
      // UTC+0: GMT / WET -> Europe/London
      if (totalMinutes == 0) {
        return 'Europe/London';
      }
      // UTC+1: CET -> Europe/Paris
      if (totalMinutes == 60) {
        return 'Europe/Paris';
      }
      // UTC-5: EST -> America/New_York
      if (totalMinutes == -300) {
        return 'America/New_York';
      }
      // UTC-8: PST -> America/Los_Angeles
      if (totalMinutes == -480) {
        return 'America/Los_Angeles';
      }

      // General search across database locations matching current offset
      for (final entry in tz.timeZoneDatabase.locations.entries) {
        final loc = entry.value;
        final tzTime = tz.TZDateTime.now(loc);
        if (tzTime.timeZoneOffset == offset) {
          return entry.key;
        }
      }
    } catch (_) {}

    return 'Asia/Karachi'; // Safe regional fallback
  }

  /// Synchronizes the user's canonical IANA timezone onto their Firestore profile.
  static Future<void> syncUserTimezone({
    required String collectionName,
    required String documentId,
  }) async {
    if (documentId.trim().isEmpty) return;

    try {
      final iana = canonicalTimezone;
      final docRef = FirebaseFirestore.instance
          .collection(collectionName)
          .doc(documentId.trim());

      await docRef.set({
        'ianaTimezone': iana,
        'timezoneOffsetMinutes': DateTime.now().timeZoneOffset.inMinutes,
        'timezoneSyncedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      debugPrint(
        '🌍 [TimezoneService] Synchronized timezone $iana for $documentId in $collectionName',
      );
    } catch (e) {
      debugPrint('⚠️ [TimezoneService] Error syncing timezone: $e');
    }
  }

  /// Converts any dynamic timestamp (Firestore Timestamp, DateTime, ISO string) to local DateTime.
  static DateTime toLocalDateTime(dynamic timestamp) {
    if (timestamp == null) return DateTime.now();

    DateTime utcDate;
    if (timestamp is Timestamp) {
      utcDate = timestamp.toDate();
    } else if (timestamp is DateTime) {
      utcDate = timestamp;
    } else if (timestamp is String) {
      final parsed = DateTime.tryParse(timestamp);
      utcDate = parsed ?? DateTime.now();
    } else {
      return DateTime.now();
    }

    if (!utcDate.isUtc) {
      utcDate = utcDate.toUtc();
    }

    initialize();
    try {
      final loc = tz.getLocation(canonicalTimezone);
      return tz.TZDateTime.from(utcDate, loc);
    } catch (_) {
      return utcDate.toLocal();
    }
  }

  /// Converts a local DateTime to a Firestore UTC Timestamp.
  static Timestamp toUtcTimestamp(DateTime dateTime) {
    return Timestamp.fromDate(dateTime.toUtc());
  }

  /// Formats any timestamp into local time string (default: 'h:mm a').
  static String formatTime(dynamic timestamp, {String format = 'h:mm a'}) {
    final local = toLocalDateTime(timestamp);
    return DateFormat(format).format(local);
  }

  /// Formats any timestamp into local date string (default: 'dd MMM yyyy').
  static String formatDate(dynamic timestamp, {String format = 'dd MMM yyyy'}) {
    final local = toLocalDateTime(timestamp);
    return DateFormat(format).format(local);
  }

  /// Formats any timestamp into local date and time (default: 'dd MMM yyyy • h:mm a').
  static String formatDateTime(
    dynamic timestamp, {
    String format = 'dd MMM yyyy • h:mm a',
  }) {
    final local = toLocalDateTime(timestamp);
    return DateFormat(format).format(local);
  }

  /// Formats relative chat last seen timestamp (e.g. 'last seen today at 3:15 PM').
  static String formatChatLastSeen(dynamic timestamp) {
    final date = toLocalDateTime(timestamp);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final checkDate = DateTime(date.year, date.month, date.day);

    if (checkDate == today) {
      return 'last seen today at ${DateFormat('h:mm a').format(date)}';
    } else if (checkDate == yesterday) {
      return 'last seen yesterday at ${DateFormat('h:mm a').format(date)}';
    } else {
      return 'last seen ${DateFormat('MMM d, h:mm a').format(date)}';
    }
  }
}
