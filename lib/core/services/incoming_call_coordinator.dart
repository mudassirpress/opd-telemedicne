// lib/core/services/incoming_call_coordinator.dart
//
// Single source of truth for the incoming-call flow.
//
//   ONE call event -> ONE notification -> ONE Incoming Call screen -> ONE call
//   session
//
// Every producer of an incoming call (FCM foreground push, FCM
// background/terminated push, the notification body tap, the notification
// Accept/Decline actions, the Firestore recovery watcher) funnels through
// [registerIncomingCall] / [performAction] here, so de-duplication, the
// lifecycle state machine and the accept/decline side effects are implemented
// exactly once.
//
// De-duplication is keyed on `callId` and is backed by SharedPreferences, not
// just an in-memory set: the background handler runs in a *separate* isolate
// with its own copy of every singleton, and a killed app starts again with an
// empty set. Without storage-backed claiming the same push is processed two or
// three times and the user sees several notifications for one call.

import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:telemedicine/core/constants/app_constants.dart';
import 'package:telemedicine/core/services/audio_service.dart';
import 'package:telemedicine/core/services/call_ringtone_service.dart';
import 'package:telemedicine/features/calls/presentation/controllers/call_controller.dart';

/// How a particular incoming-call event reached the app. Used only to decide
/// *what* should happen (show a notification vs. open the screen) — never to
/// decide *whether* it happens, which is always the `callId` claim.
enum IncomingCallOrigin {
  /// `FirebaseMessaging.onMessage` — app is in the foreground.
  foregroundPush,

  /// `FirebaseMessaging.onBackgroundMessage` — background or terminated.
  backgroundPush,

  /// Notification body tap, or cold start from a notification.
  notificationTap,

  /// `calls` Firestore watcher acting as a lost-push safety net.
  firestoreWatcher,

  /// Pending-call recovery after a cold start.
  recovery,
}

/// The user-visible result of [IncomingCallCoordinator.performAction].
@immutable
class IncomingCallOutcome {
  /// `true` when this call performed the state transition. `false` means the
  /// action was a duplicate or the call was no longer in a state that allows
  /// it (already accepted, already declined, timed out, …) and the caller
  /// should not navigate as if it had succeeded.
  final bool handled;

  final String callId;
  final String reason;

  const IncomingCallOutcome.handled(this.callId)
    : handled = true,
      reason = 'ok';

  const IncomingCallOutcome.skipped(this.callId, this.reason) : handled = false;
}

/// Normalized incoming-call payload.
///
/// [tryParse] is the only accepted way to build one, so an FCM `data` map, a
/// notification payload string and a Firestore call document all collapse into
/// the same shape before anything downstream looks at them.
@immutable
class IncomingCallPayload {
  final String callId;
  final String callerId;
  final String callerName;
  final String callerImage;
  final String receiverId;
  final String callerType;
  final String callType;
  final String channelId;

  /// Media room. Equal to [channelId]; both names exist in the wild so they
  /// are unified here.
  final String roomId;

  final String timestamp;

  /// Server payload contract version. Empty/`0` means a legacy payload.
  final String schemaVersion;

  /// Epoch millis after which the invitation must not be shown or accepted.
  /// `0` means the sender did not supply one (legacy payload).
  final int expiresAtMillis;

  const IncomingCallPayload({
    required this.callId,
    required this.callerId,
    required this.callerName,
    required this.callerImage,
    required this.receiverId,
    required this.callerType,
    required this.callType,
    required this.channelId,
    required this.roomId,
    required this.timestamp,
    this.schemaVersion = '',
    this.expiresAtMillis = 0,
  });

  bool get isVideo => callType == 'video';

  bool get isExpired =>
      expiresAtMillis > 0 &&
      DateTime.now().millisecondsSinceEpoch >= expiresAtMillis;

  /// Builds a payload from an FCM `data` map, a decoded notification payload
  /// or a Firestore call document. Returns `null` when the payload cannot
  /// possibly be a call — an empty `callId` means the event cannot be
  /// de-duplicated, so it is dropped rather than risking a second
  /// notification for the same call.
  static IncomingCallPayload? tryParse(Map<String, dynamic> data) {
    final callId = _str(data[CallPayloadKeys.callId]);
    if (callId.isEmpty) return null;

    final channelId = _str(data[CallPayloadKeys.channelId]);
    final roomId = _str(data[CallPayloadKeys.roomId]).isNotEmpty
        ? _str(data[CallPayloadKeys.roomId])
        : channelId;

    final rawType = _str(data[CallPayloadKeys.callType]).toLowerCase();
    final callType = rawType == 'video' ? 'video' : 'audio';

    final rawCallerType = _str(data[CallPayloadKeys.callerType]).toLowerCase();

    return IncomingCallPayload(
      callId: callId,
      callerId: _str(data[CallPayloadKeys.callerId]),
      callerName: _fallback(
        _str(data[CallPayloadKeys.callerName]),
        'Unknown Caller',
      ),
      callerImage: _str(data[CallPayloadKeys.callerImage]),
      receiverId: _str(data[CallPayloadKeys.receiverId]),
      callerType: rawCallerType == 'patient' ? 'patient' : 'doctor',
      callType: callType,
      channelId: channelId.isNotEmpty ? channelId : roomId,
      roomId: roomId.isNotEmpty ? roomId : channelId,
      timestamp: _str(data[CallPayloadKeys.timestamp]),
      schemaVersion: _str(data[CallPayloadKeys.schemaVersion]),
      expiresAtMillis: int.tryParse(_str(data[CallPayloadKeys.expiresAt])) ?? 0,
    );
  }

  Map<String, dynamic> toMap() => <String, dynamic>{
    CallPayloadKeys.schemaVersion: schemaVersion,
    CallPayloadKeys.type: FcmMessageType.call,
    CallPayloadKeys.callId: callId,
    CallPayloadKeys.callerId: callerId,
    CallPayloadKeys.callerName: callerName,
    CallPayloadKeys.callerImage: callerImage,
    CallPayloadKeys.receiverId: receiverId,
    CallPayloadKeys.callerType: callerType,
    CallPayloadKeys.callType: callType,
    CallPayloadKeys.channelId: channelId,
    CallPayloadKeys.roomId: roomId,
    CallPayloadKeys.timestamp: timestamp,
    if (expiresAtMillis > 0) CallPayloadKeys.expiresAt: '$expiresAtMillis',
  };

  IncomingCallPayload copyWith({String? channelId, String? roomId}) =>
      IncomingCallPayload(
        callId: callId,
        callerId: callerId,
        callerName: callerName,
        callerImage: callerImage,
        receiverId: receiverId,
        callerType: callerType,
        callType: callType,
        channelId: channelId ?? this.channelId,
        roomId: roomId ?? this.roomId,
        timestamp: timestamp,
        schemaVersion: schemaVersion,
        expiresAtMillis: expiresAtMillis,
      );

  static String _str(dynamic value) => (value ?? '').toString().trim();

  static String _fallback(String value, String fallback) =>
      value.isEmpty ? fallback : value;

  @override
  String toString() =>
      'IncomingCallPayload(callId: $callId, caller: $callerName($callerId), '
      'type: $callType, room: $roomId)';
}

/// Hooks the coordinator needs from the layer that owns the OS notification
/// plugin and the navigator. [NotificationService] binds these once during
/// `initialize()`.
class IncomingCallHooks {
  /// Shows the single incoming-call notification. Must be idempotent per
  /// `callId` (it uses a stable id + tag, so a repeat simply replaces).
  final Future<void> Function(IncomingCallPayload payload) present;

  /// Removes the incoming-call notification for a `callId`.
  final Future<void> Function(String callId) dismiss;

  /// Pushes the app's custom Incoming Call screen. Returns `true` when the
  /// screen was actually shown (a duplicate request returns `false`).
  final Future<bool> Function(IncomingCallPayload payload, {bool autoAccept})
  openIncomingCallScreen;

  /// Pushes the live Call screen after a successful accept. Used when the
  /// accept came from a notification action and no Incoming Call screen was
  /// ever displayed.
  final Future<bool> Function(IncomingCallPayload payload, String currentUserId)
  openCallScreen;

  /// Blocks on app start-up completing so a cold-start navigation is not wiped
  /// by the splash screen's `pushReplacement`.
  final Future<bool> Function() awaitAppReady;

  const IncomingCallHooks({
    required this.present,
    required this.dismiss,
    required this.openIncomingCallScreen,
    required this.openCallScreen,
    required this.awaitAppReady,
  });
}

class IncomingCallCoordinator {
  IncomingCallCoordinator._internal();

  static final IncomingCallCoordinator instance =
      IncomingCallCoordinator._internal();

  static IncomingCallHooks? _hooks;

  /// Bind the presentation layer. Safe to call more than once.
  static void bindHooks(IncomingCallHooks hooks) => _hooks = hooks;

  static bool get isBound => _hooks != null;

  // ── Keys ──────────────────────────────────────────────────────────────
  static const String _kClaimedCalls = 'incoming_call_claimed_ids';
  static const String _kPendingCall = 'pending_call';
  static const String _kHandledActions = 'incoming_call_handled_actions';

  /// Bounded so the stores cannot grow forever.
  static const int _maxStoredIds = 30;

  // ── In-memory fast path ───────────────────────────────────────────────
  final Set<String> _claimedCallIds = <String>{};
  final Set<String> _handledActions = <String>{};

  /// `callId`s whose Incoming Call screen has been pushed, and the route is
  /// still on the stack. Cleared when the screen pops.
  final Set<String> _screenCallIds = <String>{};

  /// The one call that currently owns the incoming-call notification. A new
  /// call always supersedes the previous one, so there is never a second
  /// incoming-call notification in the tray.
  String? _activeCallId;

  /// Exposes the active incoming call ID, if any.
  String? get activeCallId => _activeCallId;

  /// Guards the auto-dismiss timer so only the live call's timer is armed.
  Timer? _autoDismissTimer;

  String? _autoDismissForCallId;

  /// Tears down any active incoming ringing state, notifications, and ringtone audio.
  Future<void> dismissAllActiveRinging() async {
    final callId = _activeCallId;
    if (callId != null && callId.isNotEmpty) {
      await dismissNotification(callId);
    }
    _armAutoDismissTimerCancel();
    unawaited(CallRingtoneService.instance.stopRingtone());
    unawaited(SystemRingtonePlayer.stopDefaultRingtone());
  }

  // ─────────────────────────────────────────────────────────────────────
  // 1. INBOUND: one call event -> at most one notification + one screen
  // ─────────────────────────────────────────────────────────────────────

  /// Registers an incoming call.
  ///
  /// Returns the payload when *this* call is the one that owns the
  /// notification/screen, or `null` when the event is a duplicate, malformed,
  /// or the call has already moved past ringing. Callers must treat `null` as
  /// "nothing to do" — that is what keeps a second FCM delivery, a
  /// `checkCallStatus` worker and a Firestore watcher from all doing the same
  /// work.
  Future<IncomingCallPayload?> registerIncomingCall(
    Map<String, dynamic> data, {
    required IncomingCallOrigin origin,
  }) async {
    final payload = IncomingCallPayload.tryParse(data);
    if (payload == null) {
      debugPrint('⚠️ Incoming call payload missing callId — ignored');
      return null;
    }

    // Identity and freshness checks apply to every origin, including taps:
    // a push left in the tray after logout, or one addressed to another
    // account, must never open this user's Incoming Call screen.
    if (!await _isAddressedToCurrentUser(payload)) {
      debugPrint(
        '⛔ Incoming call ${payload.callId} is not for the signed-in user',
      );
      return null;
    }
    if (payload.isExpired) {
      debugPrint('⌛ Incoming call ${payload.callId} has expired — ignored');
      await dismissNotification(payload.callId);
      return null;
    }

    if (origin == IncomingCallOrigin.notificationTap) {
      // A tap is a user gesture, not a delivery, so it is never claim-gated.
      // It still has to point at a call that is actually ringing right now;
      // a read failure degrades to "still ringing" (fail open).
      final status = await _currentStatus(payload.callId);
      if (status != null && !CallStatus.isRinging(status)) {
        debugPrint(
          '⚠️ Tapped call ${payload.callId} is "$status" — not opening',
        );
        await dismissNotification(payload.callId);
        return null;
      }
      return payload;
    }

    // Hooks are bound by NotificationService.initialize()/initializeForBackground()
    // as their FIRST step, so this should be unreachable — but if it ever is,
    // fail loudly instead of swallowing the call silently: the claim below
    // would be spent with no notification posted and no screen opened, and
    // the call would ring with zero UI until it timed out.
    if (_hooks == null) {
      debugPrint(
        '⚠️ IncomingCallCoordinator hooks not bound — cannot present or open '
        'call ${payload.callId}. NotificationService.initialize() must run '
        'before registerIncomingCall().',
      );
      return null;
    }

    // Reserve synchronously *before* any await: two pushes delivered in the
    // same frame must not both be allowed to continue.
    if (!_claimedCallIds.add(payload.callId)) {
      debugPrint(
        '🔁 Duplicate incoming call ignored in this isolate: ${payload.callId}',
      );
      return null;
    }

    final firstEver = await _claimAcrossIsolates(payload.callId);
    if (!firstEver) {
      debugPrint(
        '🔁 Duplicate incoming call ignored (already processed): '
        '${payload.callId}',
      );
      return null;
    }

    // Fast path for background push: do not block on asynchronous Firestore
    // network reads so the incoming call UI / heads-up rings immediately.
    if (origin != IncomingCallOrigin.backgroundPush) {
      final status = await _currentStatus(payload.callId);
      if (!CallStatus.isRinging(status)) {
        // Arrived too late: the callee already answered, declined, timed out or
        // the caller cancelled. Showing anything now would be a stale
        // notification for a dead call.
        debugPrint(
          '⚠️ Incoming call ${payload.callId} is "$status" — not ringing, '
          'nothing shown',
        );
        _releaseClaim(payload.callId);
        return null;
      }
    }

    // Persist so a cold start can recover the caller details if the process
    // was killed between the push and the tap.
    await _storePendingCall(payload);

    // One notification at a time: supersede whatever is still ringing.
    if (_activeCallId != null && _activeCallId != payload.callId) {
      _hooks?.dismiss(_activeCallId!);
    }
    _activeCallId = payload.callId;
    unawaited(_acknowledgeCallDelivery(payload.callId));

    // WHAT gets *opened* must be decided by the state of the app — never by
    // which producer happened to win the claim race above.
    //
    // The Firestore "lost-push" watchers (`main.dart` and Room Chat) are local
    // listeners that fire a few hundred milliseconds after the call document is
    // written, while the FCM network round trip takes a second or
    // three. The watcher therefore claims almost every call first. Routing it
    // unconditionally to the screen meant a backgrounded receiver got an
    // invisible route push instead of a tray notification — and because the
    // claim was already spent, the FCM background handler arriving right
    // afterwards was rejected as a duplicate, so `present()` never ran at all.
    // That is what made the incoming-call notification disappear entirely.
    final bool showScreen =
        origin == IncomingCallOrigin.foregroundPush ||
        origin == IncomingCallOrigin.recovery ||
        (origin == IncomingCallOrigin.firestoreWatcher && _isAppForegrounded);

    _armAutoDismiss(payload.callId);

    // The tray notification is posted for EVERY origin, foreground included:
    // it is what keeps the call visible if the user backgrounds the app while
    // it rings, swipes the Incoming Call screen away, or if the screen push
    // fails (no navigator, payment lock, app not ready yet). It carries a
    // stable id + tag so a repeat delivery replaces it instead of stacking,
    // and `dismissNotification` clears it on accept / decline / miss /
    // handover / ring timeout.
    try {
      await _hooks?.present(payload);
    } catch (e) {
      debugPrint('⚠️ Could not post incoming-call notification: $e');
      // The claim was just spent on a notification that never went up.
      // Release it so the Firestore watcher (or a redelivered push) can try
      // again, instead of the call ringing with zero UI until it times out —
      // which is exactly what a failed channel/plugin init used to do.
      await clearCallRecord(payload.callId);
      return null;
    }

    if (showScreen) {
      // The screen is the richer of the two surfaces; the notification stays
      // in the tray alongside it as the "still ringing" indicator.
      //
      // Routed through the coordinator's OWN [openIncomingCallScreen] (not the
      // raw hook) so the screen slot is claimed synchronously. Calling the
      // hook directly skipped the `_screenCallIds` claim: a notification
      // Accept landing while this push was in flight saw
      // `isScreenOpenFor == false`, pushed a second live CallScreen, and the
      // handover then pushed a third via pushReplacement.
      await openIncomingCallScreen(payload);
    }

    debugPrint('📞 Incoming call claimed: ${payload.callId} (origin=$origin)');
    return payload;
  }

  /// `true` when no other isolate has already processed this `callId`.
  Future<bool> _claimAcrossIsolates(String callId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getStringList(_kClaimedCalls) ?? <String>[];
      if (stored.contains(callId)) return false;

      stored.add(callId);
      if (stored.length > _maxStoredIds) {
        stored.removeRange(0, stored.length - _maxStoredIds);
      }
      await prefs.setStringList(_kClaimedCalls, stored);
      return true;
    } catch (e) {
      // Fail open on a storage error rather than swallowing a real call: the
      // in-memory set above already blocks the common single-isolate case.
      debugPrint('⚠️ Could not persist call claim: $e');
      return true;
    }
  }

  /// Releases a claim synchronously in memory and asynchronously in storage.
  void _releaseClaim(String callId) {
    _claimedCallIds.remove(callId);
    unawaited(_removePersistedId(_kClaimedCalls, callId));
  }

  Future<void> _removePersistedId(String key, String value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getStringList(key) ?? <String>[];
      stored.remove(value);
      await prefs.setStringList(key, stored);
    } catch (e) {
      debugPrint('⚠️ Could not release stored id from $key: $e');
    }
  }

  Future<void> _storePendingCall(IncomingCallPayload payload) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kPendingCall, jsonEncode(payload.toMap()));
    } catch (e) {
      debugPrint('⚠️ Could not persist pending call: $e');
    }
  }

  /// Consumes the pending call written by the background isolate. Returns it
  /// once; a second call returns `null` so a cold start cannot replay it.
  Future<IncomingCallPayload?> consumePendingCall() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kPendingCall);
      if (raw == null || raw.isEmpty) return null;
      await prefs.remove(_kPendingCall);
      return IncomingCallPayload.tryParse(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (e) {
      debugPrint('⚠️ Could not read pending call: $e');
      return null;
    }
  }

  // ─────────────────────────────────────────────────────────────────────
  // 2. NOTIFICATION LIFECYCLE
  // ─────────────────────────────────────────────────────────────────────

  void _armAutoDismiss(String callId) {
    _autoDismissTimer?.cancel();
    _autoDismissForCallId = callId;
    _autoDismissTimer = Timer(
      const Duration(seconds: AppLimits.ringTimeoutSeconds),
      () {
        // Only the call the timer was armed for may be dismissed, otherwise
        // a slow first call could tear down a newer one.
        if (_autoDismissForCallId == callId) {
          dismissNotification(callId);
        }
      },
    );
  }

  /// Removes the incoming-call notification and stops the auto-dismiss timer.
  /// Idempotent, and safe to call from accept, decline, miss, cancel, end and
  /// the Firestore status listener.
  Future<void> dismissNotification(String callId) async {
    if (callId.isEmpty) return;
    if (_activeCallId == callId) {
      _activeCallId = null;
    }
    if (_autoDismissForCallId == callId) {
      _autoDismissTimer?.cancel();
      _autoDismissTimer = null;
      _autoDismissForCallId = null;
    }
    await _hooks?.dismiss(callId);
    unawaited(CallRingtoneService.instance.stopRingtone());
    unawaited(SystemRingtonePlayer.stopDefaultRingtone());
  }

  /// Drops every trace of a finished call so a *new* call from the same caller
  /// is not mistaken for a duplicate.
  Future<void> clearCallRecord(String callId) async {
    if (callId.isEmpty) return;
    _claimedCallIds.remove(callId);
    if (_activeCallId == callId) {
      _activeCallId = null;
      _armAutoDismissTimerCancel();
    }
    await _removePersistedId(_kClaimedCalls, callId);
  }

  void _armAutoDismissTimerCancel() {
    _autoDismissTimer?.cancel();
    _autoDismissTimer = null;
    _autoDismissForCallId = null;
  }

  // ─────────────────────────────────────────────────────────────────────
  // 3. ACTIONS — the ONE accept implementation and the ONE decline
  //    implementation, shared by the app's buttons, the notification actions
  //    and the CallKit-free background isolate.
  // ─────────────────────────────────────────────────────────────────────

  Future<IncomingCallOutcome> accept(String callId) =>
      _performAction(callId, CallActionIds.accept);

  Future<IncomingCallOutcome> decline(String callId) =>
      _performAction(callId, CallActionIds.decline);

  Future<IncomingCallOutcome> _performAction(
    String callId,
    String action,
  ) async {
    if (callId.isEmpty) {
      return IncomingCallOutcome.skipped(callId, 'missing callId');
    }

    // Double-tap guard, reserved before the first await so a second press in
    // the same frame is dropped. The persisted check covers the case where
    // the action arrives in a *new* isolate (background notification tap).
    final actionKey = '$action:$callId';
    if (!_handledActions.add(actionKey)) {
      debugPrint('🔁 Duplicate $action ignored: $callId');
      return IncomingCallOutcome.skipped(callId, 'duplicate $action');
    }
    final alreadyHandled = await _claimActionAcrossIsolates(actionKey);
    if (alreadyHandled) {
      debugPrint('🔁 Duplicate $action ignored (already processed): $callId');
      return IncomingCallOutcome.skipped(callId, 'duplicate $action');
    }

    final status = await _currentStatus(callId);
    final isAccept = action == CallActionIds.accept;

    if (isAccept && !CallStatus.canAccept(status)) {
      _markActionHandledLocally(actionKey);
      await dismissNotification(callId);
      debugPrint(
        '⚠️ acceptCall rejected: call $callId is "$status", not ringing',
      );
      return IncomingCallOutcome.skipped(callId, 'not ringing ($status)');
    }
    if (!isAccept && !CallStatus.canDecline(status)) {
      _markActionHandledLocally(actionKey);
      await dismissNotification(callId);
      debugPrint(
        '⚠️ declineCall rejected: call $callId is "$status", not ringing',
      );
      return IncomingCallOutcome.skipped(callId, 'not ringing ($status)');
    }

    // The notification must go away whether or not the transition succeeds,
    // otherwise a declined-but-notified call rings forever.
    await dismissNotification(callId);

    final controller = CallController();
    if (isAccept) {
      final ok = await controller.acceptCall(callId);
      if (!ok) {
        return IncomingCallOutcome.skipped(callId, 'accept failed');
      }
    } else {
      final ok = await controller.rejectCall(callId);
      if (!ok) {
        return IncomingCallOutcome.skipped(callId, 'decline failed');
      }
    }

    // A terminal call no longer owns a claim: the next call from the same
    // caller must be allowed through.
    await clearCallRecord(callId);

    debugPrint('📞 $action applied to $callId (was "$status")');
    return IncomingCallOutcome.handled(callId);
  }

  void _markActionHandledLocally(String actionKey) =>
      _handledActions.add(actionKey);

  Future<bool> _claimActionAcrossIsolates(String actionKey) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getStringList(_kHandledActions) ?? <String>[];
      if (stored.contains(actionKey)) return true;
      stored.add(actionKey);
      if (stored.length > _maxStoredIds) {
        stored.removeRange(0, stored.length - _maxStoredIds);
      }
      await prefs.setStringList(_kHandledActions, stored);
      return false;
    } catch (e) {
      debugPrint('⚠️ Could not persist action claim: $e');
      return false;
    }
  }

  // ─────────────────────────────────────────────────────────────────────
  // 4. NAVIGATION
  // ─────────────────────────────────────────────────────────────────────

  /// Whether the app's Incoming Call screen is currently on the stack for
  /// [callId]. Used by every producer so a Firestore watcher, a push and a
  /// notification tap cannot each push their own copy.
  bool isScreenOpenFor(String callId) =>
      callId.isNotEmpty && _screenCallIds.contains(callId);

  /// Called by `IncomingCallScreen` once it is actually built.
  void markScreenOpened(String callId) {
    if (callId.isEmpty) return;
    if (_screenCallIds.contains(callId)) return;
    _screenCallIds.add(callId);
    debugPrint('📞 IncomingCallScreen opened for $callId');
  }

  /// Called by `IncomingCallScreen.dispose()`.
  void markScreenClosed(String callId) {
    if (callId.isEmpty) return;
    _screenCallIds.remove(callId);
  }

  /// Opens the custom Incoming Call screen for an already-validated payload.
  /// Used by the notification body tap and the cold-start recovery path.
  Future<bool> openIncomingCallScreen(
    IncomingCallPayload payload, {
    bool autoAccept = false,
  }) async {
    if (_screenCallIds.contains(payload.callId)) {
      debugPrint(
        '⚠️ Incoming call screen already open for ${payload.callId} — '
        'not pushing again',
      );
      return false;
    }
    // Claim the screen slot SYNCHRONOUSLY, before the first await. The old
    // order (check → await appReady → add) left a window where two concurrent
    // callers both passed the `contains` check, both awaited, then both pushed
    // — the double Incoming Call screen seen on notification taps. The slot is
    // released again on any failure below.
    _screenCallIds.add(payload.callId);

    try {
      if (_hooks == null) {
        debugPrint(
          '⚠️ No navigation hooks wired — dropping incoming call screen '
          'for ${payload.callId}',
        );
        _screenCallIds.remove(payload.callId);
        return false;
      }
      if (await _hooks!.awaitAppReady() == false) {
        debugPrint('⚠️ App not ready — dropping incoming call navigation');
        _screenCallIds.remove(payload.callId);
        return false;
      }
      final opened = await _hooks!.openIncomingCallScreen(
        payload,
        autoAccept: autoAccept,
      );
      if (!opened) {
        _screenCallIds.remove(payload.callId);
      }
      return opened;
    } catch (e) {
      debugPrint('⚠️ Failed to open incoming call screen: $e');
      _screenCallIds.remove(payload.callId);
      return false;
    }
  }

  /// Accepts straight into the live Call screen. Used when the accept came
  /// from the notification's Accept action: no Incoming Call screen was ever
  /// shown, so there is nothing to transition away from.
  ///
  /// If an Incoming Call screen *is* open for this call, the transition is
  /// still applied but no second screen is pushed — that screen watches the
  /// call document and performs the handover itself, which keeps the
  /// "one call session per callId" guarantee even when both surfaces fire.
  Future<bool> acceptAndOpenCallScreen(IncomingCallPayload payload) async {
    final outcome = await accept(payload.callId);
    final isAlreadyAccepted = outcome.reason.contains('duplicate') ||
        outcome.reason.contains('already processed');
    if (!outcome.handled && !isAlreadyAccepted) return false;
    if (await _hooks?.awaitAppReady() == false) return false;

    if (isScreenOpenFor(payload.callId)) {
      debugPrint(
        '📞 Accept applied; the open Incoming Call screen will hand over to '
        'the call screen (callId=${payload.callId})',
      );
      return true;
    }

    final currentUserId = await resolveCurrentUserId();
    if (currentUserId.isEmpty) {
      debugPrint('⚠️ No signed-in user — cannot open the call screen');
      return false;
    }
    return await _hooks?.openCallScreen(payload, currentUserId) ?? false;
  }

  /// Declines straight from the notification's Decline action. No navigation
  /// is required — the caller sees the chat call-message turn to "rejected".
  Future<bool> declineFromNotification(IncomingCallPayload payload) async {
    final outcome = await decline(payload.callId);
    return outcome.handled;
  }

  // ─────────────────────────────────────────────────────────────────────
  // 5. HELPERS
  // ─────────────────────────────────────────────────────────────────────

  /// `true` only while the main isolate exists *and* the app is on screen.
  ///
  /// The FCM background handler runs in a headless isolate where no Flutter
  /// binding was ever created, and a backgrounded main isolate reports
  /// `paused`/`hidden`. Both must fall through to the tray notification —
  /// opening a route the user cannot see would show them nothing and spend
  /// the `callId` claim, which then also swallows the notification.
  static bool get _isAppForegrounded {
    try {
      return WidgetsBinding.instance.lifecycleState ==
          AppLifecycleState.resumed;
    } catch (_) {
      // No binding ⇒ headless isolate ⇒ not foreground.
      return false;
    }
  }

  /// Authoritative call status straight from Firestore. A read failure
  /// returns `null`, which the state machine treats as "still ringing" so a
  /// transient network error never swallows a legitimate call.
  ///
  /// Bounded on purpose: this runs inside the FCM background handler, where
  /// Android gives the headless isolate a few seconds before killing it. A
  /// hung read used to be able to outlive that budget, so the callee's app
  /// was killed mid-handler and no notification was ever posted — even though
  /// the call was ringing. A timeout degrades to "still ringing" (the same
  /// fail-open path as a read error) and the notification still goes up.
  Future<String?> _currentStatus(String callId) async {
    if (callId.isEmpty) return null;
    try {
      final doc = await FirebaseFirestore.instance
          .collection(FirestoreCollections.calls)
          .doc(callId)
          .get()
          .timeout(const Duration(seconds: 5));
      if (!doc.exists) return CallStatus.ended;
      return doc.data()?['callStatus'] as String?;
    } catch (e) {
      debugPrint('⚠️ Could not read call status for $callId: $e');
      return null;
    }
  }

  /// Rejects a call addressed to a different profile. When no session can be
  /// read (cold start before the session blob is available) the push is
  /// allowed through: the background handler must not drop a real call just
  /// because SharedPreferences is slow, and the call document still has to be
  /// ringing for anything to be shown.
  Future<bool> _isAddressedToCurrentUser(IncomingCallPayload payload) async {
    final receiver = payload.receiverId.trim();
    if (receiver.isEmpty) return true;
    final accountIds = await resolveAllCurrentAccountIds();
    if (accountIds.isEmpty) return true;
    return accountIds.contains(receiver);
  }

  /// Resolves all account IDs on this device (covering doctor and patient slots).
  Future<Set<String>> resolveAllCurrentAccountIds() async {
    final ids = <String>{};
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final key in const ['current_doctor', 'current_user']) {
        final raw = prefs.getString(key);
        if (raw == null || raw.isEmpty) continue;
        try {
          final map = jsonDecode(raw) as Map<String, dynamic>;
          final id = (map['id'] ?? '').toString().trim();
          if (id.isNotEmpty) ids.add(id);
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('⚠️ Could not resolve current account ids: $e');
    }
    return ids;
  }

  /// Reads the primary signed-in user's id, prioritizing the doctor session.
  Future<String> resolveCurrentUserId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final key in const ['current_doctor', 'current_user']) {
        final raw = prefs.getString(key);
        if (raw == null || raw.isEmpty) continue;
        try {
          final map = jsonDecode(raw) as Map<String, dynamic>;
          final id = (map['id'] ?? '').toString().trim();
          if (id.isNotEmpty) return id;
        } catch (_) {
          // Ignore a malformed blob and try the next one.
        }
      }
    } catch (e) {
      debugPrint('⚠️ Could not resolve the signed-in user: $e');
    }
    return '';
  }

  /// Reads the primary signed-in user's display name, prioritizing the doctor session.
  Future<String> resolveCurrentUserName() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final key in const ['current_doctor', 'current_user']) {
        final raw = prefs.getString(key);
        if (raw == null || raw.isEmpty) continue;
        try {
          final map = jsonDecode(raw) as Map<String, dynamic>;
          final name = (map['name'] ?? map['fullname'] ?? map['doctorName'] ?? '')
              .toString()
              .trim();
          if (name.isNotEmpty) return name;
        } catch (_) {
          // Ignore a malformed blob and try the next one.
        }
      }
    } catch (e) {
      debugPrint('⚠️ Could not resolve the signed-in user name: $e');
    }
    return 'User';
  }

  /// Re-reads the call document and merges it over a push payload, so a
  /// screen opened from a bare notification (or a notification action) always
  /// shows the authoritative caller name/image/room rather than the values
  /// that happened to be in the push.
  Future<IncomingCallPayload?> enrichFromFirestore(
    IncomingCallPayload payload,
  ) async {
    if (payload.callId.isEmpty) return payload;
    try {
      final doc = await FirebaseFirestore.instance
          .collection(FirestoreCollections.calls)
          .doc(payload.callId)
          .get();
      if (!doc.exists) return payload;
      final data = doc.data();
      if (data == null) return payload;
      final merged = IncomingCallPayload.tryParse(<String, dynamic>{
        ...payload.toMap(),
        ...data.map((k, v) => MapEntry(k.toString(), v)),
        // Never let a document field blank out good push data.
        CallPayloadKeys.callerName: payload.callerName,
        CallPayloadKeys.callerImage: payload.callerImage,
      });
      return merged ?? payload;
    } catch (e) {
      debugPrint('⚠️ Could not enrich call ${payload.callId}: $e');
      return payload;
    }
  }

  /// Acknowledges incoming call delivery by writing `callStatus: ringing` and `deliveredAt`
  /// onto Firestore, turning the caller's UI from "Calling..." to "Ringing...".
  Future<void> _acknowledgeCallDelivery(String callId) async {
    try {
      final callRef = FirebaseFirestore.instance
          .collection(FirestoreCollections.calls)
          .doc(callId);
      final snapshot = await callRef.get();
      if (!snapshot.exists) return;
      final currentStatus = snapshot.data()?['callStatus'] as String?;
      if (currentStatus == CallStatus.calling) {
        await callRef.update({
          'callStatus': CallStatus.ringing,
          'deliveredAt': FieldValue.serverTimestamp(),
        });
        debugPrint(
          '📞 [DeliveryAck] Acknowledged delivery for call $callId -> transitioned to ringing',
        );
      }
    } catch (e) {
      debugPrint('⚠️ [DeliveryAck] Failed to acknowledge call delivery: $e');
    }
  }

  /// Test/maintenance hook: forget every claim. Used after a call finishes so
  /// the next ring is never mistaken for a replay.
  void resetForTesting() {
    _claimedCallIds.clear();
    _handledActions.clear();
    _screenCallIds.clear();
    _activeCallId = null;
    _armAutoDismissTimerCancel();
  }
}
