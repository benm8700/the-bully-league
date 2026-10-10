import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

/// The Main Stage FINALE celebration - shown once, the next time the finalists
/// open the app after the weekly finals crown a champion.
///
/// Two moments from one call: a GOLD "you won the tournament" for the champion,
/// and a distinct SILVER "second place" for the runner-up. Both come from the
/// server (functions/mainStageFinale.js's getPendingTournamentFinale), which
/// clears the pending payload so each fires exactly once. Fails silently - a
/// celebration must never break a session.
class TournamentFinalePopup {
  static const _gold = Color(0xFFF4C838);
  static const _silver = Color(0xFFC9D2DC);

  static Future<void> maybeShow(BuildContext context) async {
    try {
      final result = await FirebaseFunctions.instance
          .httpsCallable('getPendingTournamentFinale')
          .call<Map<String, dynamic>>();
      final finale = result.data['finale'];
      if (finale is! Map || !context.mounted) return;
      final place = (finale['place'] as num?)?.toInt();
      if (place != 1 && place != 2) return;
      final name = (finale['name'] as String?) ?? 'the Main Stage';

      final isWinner = place == 1;
      final accent = isWinner ? _gold : _silver;

      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          icon: Text(isWinner ? '🏆' : '🥈',
              style: const TextStyle(fontSize: 44)),
          title: Text(isWinner ? 'Champion.' : 'Second place.'),
          content: Text(
            isWinner
                ? 'You ran the whole Main Stage and left nothing standing. '
                    '$name is yours. Soak it in — someone is already '
                    'practising their callout for you.'
                : 'You made the final of $name and went down swinging. One '
                    'roaster beat you tonight; everyone else lost to you. '
                    'Come back for the belt.',
          ),
          actions: [
            TextButton(
              style: TextButton.styleFrom(foregroundColor: accent),
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(isWinner ? 'Take a bow' : 'Run it back'),
            ),
          ],
        ),
      );
    } catch (_) {
      // Never let a celebration break a session.
    }
  }
}
