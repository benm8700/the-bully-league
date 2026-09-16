import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

/// Celebrates crossing a fame milestone (10 / 50 / 100 / 500 / 1,000
/// followers) the next time the app is opened - the same "make it a moment"
/// pattern as the rank-change popup, applied to the fame axis.
///
/// The milestone, the threshold and the copy all come from the server
/// (functions/follows.js's getPendingFameMilestone), which also marks it seen
/// so it fires exactly once. Fame wears the brand PINK here, distinct from the
/// skill rank-change popup.
class FameMilestonePopup {
  static const _pink = Color(0xFFFF3B6B);

  /// Shows the popup if the player has crossed a new follower milestone since
  /// they last saw one. Fails silently - a celebration must never break a
  /// session.
  static Future<void> maybeShow(BuildContext context) async {
    try {
      final result = await FirebaseFunctions.instance
          .httpsCallable('getPendingFameMilestone')
          .call<Map<String, dynamic>>();
      final milestone = (result.data['milestone'] as num?)?.toInt();
      if (milestone == null || !context.mounted) return;
      final line = result.data['line'] as String?;

      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          icon: const Icon(Icons.favorite, color: _pink, size: 34),
          title: Text('$milestone followers'),
          content: Text(
            line ?? "Your following is growing. People want to watch you.",
          ),
          actions: [
            TextButton(
              style: TextButton.styleFrom(foregroundColor: _pink),
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Let them watch'),
            ),
          ],
        ),
      );
    } catch (_) {
      // Never let a celebration break a session.
    }
  }
}
