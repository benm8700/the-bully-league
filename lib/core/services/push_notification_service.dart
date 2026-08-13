import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

/// Push notifications (CLAUDE.md's match-found notification decision).
///
/// The one that actually matters right now is match-found. Matchmaking has
/// no scheduled battle window, so a player who queues and then switches
/// away has no way of learning they were paired: the client finds matches
/// by polling, and those timers stall once the app is backgrounded. The
/// push is what brings them back. Their queue entry stays flagged
/// "matched" server-side until they collect it, so returning to the app at
/// any point still drops them into the right match.
///
/// SCOPE: registration and match-found delivery only. CLAUDE.md also
/// decides on vote reminders, tournament alerts, rank-change alerts, and
/// per-category mute toggles in settings - none of those are built. When
/// they are, the category belongs in the message's data payload so the
/// server can honour a per-category preference before sending.
class PushNotificationService {
  PushNotificationService({
    FirebaseMessaging? messaging,
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
  })  : _messaging = messaging ?? FirebaseMessaging.instance,
        _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  final FirebaseMessaging _messaging;
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  StreamSubscription<String>? _tokenRefreshSub;
  String? _registeredToken;

  /// Asks for notification permission and records this device's FCM token
  /// against the signed-in user.
  ///
  /// Deliberately best-effort: every failure path here is swallowed and
  /// logged rather than surfaced. A denied permission, a device with no
  /// Play Services, or a network blip must not stop someone playing a
  /// match - they just don't get pushes, and the in-app poll still finds
  /// their match while the app is open.
  Future<void> register() async {
    try {
      // On Android 13+ this drives the real POST_NOTIFICATIONS prompt;
      // on older Android it's a no-op that reports as granted.
      final settings = await _messaging.requestPermission();
      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        debugPrint('Push notifications denied - match-found alerts disabled.');
        return;
      }

      final token = await _messaging.getToken();
      if (token != null) await _saveToken(token);

      // Tokens rotate (app reinstall, restore to a new device, FCM's own
      // rotation). Without this the stored token silently goes stale and
      // the player stops getting alerts with no visible symptom.
      _tokenRefreshSub ??= _messaging.onTokenRefresh.listen(_saveToken);
    } catch (e) {
      debugPrint('Push notification registration failed: $e');
    }
  }

  Future<void> _saveToken(String token) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null || token == _registeredToken) return;
    try {
      // An array rather than a single field: one account can be signed in
      // on a phone and a tablet, and CLAUDE.md's Device support decision
      // explicitly covers both.
      await _firestore.collection('users').doc(uid).update({
        'fcmTokens': FieldValue.arrayUnion([token]),
      });
      _registeredToken = token;
    } catch (e) {
      debugPrint('Could not save FCM token: $e');
    }
  }

  /// Drops this device's token on sign-out, so the next person to use the
  /// device doesn't receive the previous account's match alerts.
  Future<void> unregister() async {
    final uid = _auth.currentUser?.uid;
    final token = _registeredToken;
    _tokenRefreshSub?.cancel();
    _tokenRefreshSub = null;
    _registeredToken = null;
    if (uid == null || token == null) return;
    try {
      await _firestore.collection('users').doc(uid).update({
        'fcmTokens': FieldValue.arrayRemove([token]),
      });
    } catch (e) {
      debugPrint('Could not remove FCM token: $e');
    }
  }
}
