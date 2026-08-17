import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

/// Announces a rank change the next time the app is opened.
///
/// CLAUDE.md asks for this as a real moment rather than a silent field
/// change: rank is the app's one status system, so the instant it moves is
/// the payoff for everything else. A promotion nobody is told about might
/// as well not have happened.
///
/// BOTH THE LADDER ORDER AND THE COPY COME FROM THE SERVER
/// (functions/rankChange.js). Comparing the two fields here instead would
/// mean duplicating the rank order to tell a promotion from a demotion and
/// duplicating twenty lines of voice-sensitive writing to say anything.
/// The first attempt at that drifted immediately - the hand-copied order
/// left out Headliner, which would have called a promotion a demotion for
/// anyone near it. It also keeps the push notification and this popup
/// saying the same thing about the same event.
class RankChangePopup {
  /// Shows the popup if this player's rank has moved since they last saw
  /// it. Asking is what marks it seen, so it fires exactly once.
  ///
  /// Fails silently: this is a celebration, and nothing about it is worth
  /// interrupting a session with an error.
  static Future<void> maybeShow(BuildContext context) async {
    try {
      final result = await FirebaseFunctions.instance
          .httpsCallable('getPendingRankChange')
          .call<Map<String, dynamic>>();
      final change = (result.data['change'] as Map?)?.cast<String, dynamic>();
      if (change == null || !context.mounted) return;

      final title = change['title'] as String?;
      final message = change['message'] as String?;
      if (title == null || message == null) return;
      final up = change['direction'] == 'up';

      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          icon: Icon(up ? Icons.trending_up : Icons.trending_down),
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              // Direction-specific, because "Nice" under a demotion roast
              // reads as the app not having noticed what it just said.
              child: Text(up ? 'Obviously' : 'Fine'),
            ),
          ],
        ),
      );
    } catch (_) {
      // Never let a celebration break a session.
    }
  }
}
