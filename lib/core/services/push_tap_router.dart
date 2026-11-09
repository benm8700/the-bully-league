import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';

import '../../screens/battles/get_clip_sheet.dart';
import '../../screens/friends/challenge_screen.dart';

/// The app's root navigator, so a tapped notification can open a screen
/// without a BuildContext of its own.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

/// Opens the right screen when someone TAPS a push notification.
///
/// Before this, every tap just opened the app wherever it was. That was
/// worst for a friend challenge: you send one, nobody answers for a while,
/// you leave the app, then "X accepted" arrives - and tapping it dropped you
/// on Home with no hint that a battle was waiting (developer's report,
/// 2026-11-08). Now:
///   challenge_accepted -> straight into the camera check + battle
///   challenge          -> the Roast a friend screen, where it can be accepted
///   clip_ready         -> the clip sheet, with Watch / Share / Save
/// Anything else (match found, Happy Hour, reminders) keeps the old
/// behaviour: the app opens and its own banners take it from there.
class PushTapRouter {
  PushTapRouter._();
  static final PushTapRouter instance = PushTapRouter._();

  StreamSubscription<RemoteMessage>? _sub;
  final Set<String> _handled = {};

  /// Call once a signed-in user is past the gates (MainShell is showing),
  /// so the navigator exists and there is somewhere to come back to.
  Future<void> start() async {
    _sub ??= FirebaseMessaging.onMessageOpenedApp.listen(_open);
    // A tap that LAUNCHED the app from fully closed arrives here instead.
    try {
      final initial = await FirebaseMessaging.instance.getInitialMessage();
      if (initial != null) _open(initial);
    } catch (e) {
      debugPrint('getInitialMessage failed: $e');
    }
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
  }

  void _open(RemoteMessage message) {
    // getInitialMessage can hand back the same launch tap again after a
    // sign-out/sign-in in the same session; act on each tap once.
    final id = message.messageId ?? message.sentTime?.toIso8601String();
    if (id != null && !_handled.add(id)) return;

    final context = appNavigatorKey.currentContext;
    if (context == null) return;
    final data = message.data;
    switch (data['kind']) {
      case 'challenge_accepted':
        final matchId = data['matchId'];
        if (matchId is String && matchId.isNotEmpty) {
          // The pre-match screen already handles a battle that expired or
          // was abandoned while the notification sat unread.
          unawaited(startChallengeMatch(context, matchId));
        }
        break;
      case 'clip_ready':
        // "Your clip is ready" -> straight to the clip, with Watch / Share /
        // Save on screen. No hunting through My Battles for it.
        final clipMatchId = data['matchId'];
        if (clipMatchId is String && clipMatchId.isNotEmpty) {
          unawaited(GetClipSheet.show(context, clipMatchId));
        }
        break;
      case 'challenge':
        unawaited(
          Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const ChallengeScreen()),
          ),
        );
        break;
    }
  }
}
