import 'dart:math';

import 'package:cloud_functions/cloud_functions.dart';

/// Client wrapper for the emoji-cleanup callables (spend points to remove a
/// negative emoji). The server (functions/emojiScrub.js) is the authority -
/// emojiCounts is server-only, so this is the only way to lower a count.
class EmojiScrubService {
  static final _fns = FirebaseFunctions.instance;
  static final _rand = Random();

  /// The current cleanup offer: enabled, price per removal, daily remaining,
  /// the player's balance, and their negative counts.
  static Future<Map<String, dynamic>> getState() async {
    final r = await _fns
        .httpsCallable('getEmojiScrubState')
        .call<Map<String, dynamic>>();
    return r.data;
  }

  /// Remove up to [count] of [emojiKey]. Returns the server result (scrubbed,
  /// cost, newCount, balance, dailyRemaining). A fresh requestId per call makes
  /// a network retry idempotent.
  static Future<Map<String, dynamic>> scrub({
    required String emojiKey,
    required int count,
  }) async {
    final requestId =
        'scrub_${DateTime.now().microsecondsSinceEpoch}_${_rand.nextInt(1 << 32)}';
    final r = await _fns.httpsCallable('scrubEmojiRating').call<Map<String, dynamic>>({
      'emojiKey': emojiKey,
      'count': count,
      'requestId': requestId,
    });
    return r.data;
  }
}
