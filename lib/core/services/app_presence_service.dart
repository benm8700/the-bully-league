import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/widgets.dart';

/// Tracks "how many people have the app open right now" for the admin
/// dashboard - a DIFFERENT number from the user-facing "N roasters online"
/// banner, which deliberately counts only people available to battle (in a
/// queue or mid-match).
///
/// DESIGN - deliberately cheap and battery-neutral:
///  - Writes one tiny `presence/{uid}` doc with a timestamp, ONLY while the
///    app is foregrounded and on-screen. One small write a minute, which is
///    nothing next to what an open app already does (video, listeners,
///    matchmaking polling). It never runs in the background, never wakes the
///    device, and keeps nothing alive.
///  - On background it CLEARS its doc, so the count drops promptly; on resume
///    it writes again. A crashed/closed app simply goes stale and the server
///    stops counting it (see the staleness window in functions/presence.js).
///  - Everything is best-effort: a failed write never surfaces to the user.
class AppPresenceService with WidgetsBindingObserver {
  AppPresenceService._();
  static final AppPresenceService instance = AppPresenceService._();

  static const Duration _beatEvery = Duration(seconds: 60);

  Timer? _timer;
  String? _uid;
  bool _started = false;

  /// Begin heartbeating for [uid]. Idempotent for the same uid.
  void start(String uid) {
    if (_started && _uid == uid) return;
    stop();
    _uid = uid;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    _beat();
    _timer = Timer.periodic(_beatEvery, (_) => _beat());
  }

  /// Stop heartbeating and clear this account's presence (sign-out / account
  /// switch / dispose).
  void stop() {
    _timer?.cancel();
    _timer = null;
    if (_started) {
      WidgetsBinding.instance.removeObserver(this);
      _clear();
    }
    _started = false;
    _uid = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_started) return;
    if (state == AppLifecycleState.resumed) {
      _beat();
      _timer ??= Timer.periodic(_beatEvery, (_) => _beat());
    } else {
      // Backgrounded/inactive/hidden/paused/detached: stop writing and drop
      // our presence immediately.
      _timer?.cancel();
      _timer = null;
      _clear();
    }
  }

  Future<void> _beat() async {
    final uid = _uid;
    if (uid == null) return;
    try {
      await FirebaseFirestore.instance.collection('presence').doc(uid).set({
        'lastSeenMs': DateTime.now().millisecondsSinceEpoch,
      }, SetOptions(merge: true));
    } catch (_) {
      // best-effort
    }
  }

  Future<void> _clear() async {
    final uid = _uid;
    if (uid == null) return;
    try {
      await FirebaseFirestore.instance.collection('presence').doc(uid).delete();
    } catch (_) {
      // best-effort
    }
  }
}
