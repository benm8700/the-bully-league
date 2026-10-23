import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

/// The Main Stage FINALE celebration - shown once, the next time a player who
/// was in the finals opens the app after a champion is crowned.
///
/// EVERY participant gets a placement moment, not just the top two: Champion
/// (gold), Finalist (silver), Semifinalist (bronze), and deeper rounds. The
/// server (functions/mainStageFinale.js's getPendingTournamentFinale) returns
/// the placement once and clears it, so each fires exactly once. Fails silently
/// - a celebration must never break a session.
class TournamentFinalePopup {
  static Future<void> maybeShow(BuildContext context) async {
    try {
      final result = await FirebaseFunctions.instance
          .httpsCallable('getPendingTournamentFinale')
          .call<Map<String, dynamic>>();
      final finale = result.data['finale'];
      if (finale is! Map || !context.mounted) return;
      final place = (finale['place'] as num?)?.toInt();
      if (place == null || place < 1) return;
      final name = (finale['name'] as String?) ?? 'the Main Stage';
      final total = (finale['totalPlayers'] as num?)?.toInt();
      final serverLabel = (finale['label'] as String?);

      final look = _lookFor(place, total ?? 4, name, serverLabel);

      await showGeneralDialog<void>(
        context: context,
        barrierDismissible: true,
        barrierLabel: 'finale',
        barrierColor: Colors.black.withValues(alpha: 0.82),
        transitionDuration: const Duration(milliseconds: 420),
        pageBuilder: (_, _, _) => const SizedBox.shrink(),
        transitionBuilder: (dialogContext, anim, _, _) {
          // Scale + fade entrance; a tiny overshoot so it lands with a pop.
          final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutBack);
          return Opacity(
            opacity: anim.value.clamp(0.0, 1.0),
            child: Transform.scale(
              scale: 0.8 + 0.2 * curved.value,
              child: _FinaleCard(look: look),
            ),
          );
        },
      );
    } catch (_) {
      // Never let a celebration break a session.
    }
  }

  static _FinaleLook _lookFor(int place, int total, String name, String? label) {
    switch (place) {
      case 1:
        return _FinaleLook(
          accent: const Color(0xFFF4C838), // gold
          emoji: '🏆',
          eyebrow: name.toUpperCase(),
          headline: 'CHAMPION',
          badge: '1st Place',
          body: 'You ran the whole Main Stage and left nothing standing. '
              '$name is yours. Soak it in — someone is already practising '
              'their callout for you.',
          button: 'Take a bow',
        );
      case 2:
        return _FinaleLook(
          accent: const Color(0xFFC9D2DC), // silver
          emoji: '🥈',
          eyebrow: name.toUpperCase(),
          headline: 'FINALIST',
          badge: '2nd Place',
          body: 'You made the final of $name and went down swinging. One '
              'roaster beat you tonight — everyone else lost to you. Come '
              'back for the belt.',
          button: 'Run it back',
        );
      case 3:
        return _FinaleLook(
          accent: const Color(0xFFCD7F32), // bronze
          emoji: '🥉',
          eyebrow: name.toUpperCase(),
          headline: 'SEMIFINALIST',
          badge: 'Top $total',
          body: 'Top $total at $name. You outlasted the field and came up one '
              'win short of the final. The belt is still out there.',
          button: 'Run it back',
        );
      default:
        return _FinaleLook(
          accent: const Color(0xFFEA4C6D), // brand pink
          emoji: '🎤',
          eyebrow: name.toUpperCase(),
          headline: (label ?? 'MAIN STAGE').toUpperCase(),
          badge: 'Top $total',
          body: 'You made the Main Stage at $name — further than most ever '
              'get. Back for more next week.',
          button: 'Run it back',
        );
    }
  }
}

class _FinaleLook {
  const _FinaleLook({
    required this.accent,
    required this.emoji,
    required this.eyebrow,
    required this.headline,
    required this.badge,
    required this.body,
    required this.button,
  });
  final Color accent;
  final String emoji;
  final String eyebrow;
  final String headline;
  final String badge;
  final String body;
  final String button;
}

class _FinaleCard extends StatelessWidget {
  const _FinaleCard({required this.look});
  final _FinaleLook look;

  @override
  Widget build(BuildContext context) {
    final accent = look.accent;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Material(
          color: Colors.transparent,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Container(
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 22),
              decoration: BoxDecoration(
                color: const Color(0xFF17131A),
                borderRadius: BorderRadius.circular(26),
                border: Border.all(color: accent.withValues(alpha: 0.65), width: 1.5),
                boxShadow: [
                  BoxShadow(
                    color: accent.withValues(alpha: 0.35),
                    blurRadius: 46,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Glowing medal.
                  Container(
                    width: 118,
                    height: 118,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          accent.withValues(alpha: 0.45),
                          accent.withValues(alpha: 0.08),
                          Colors.transparent,
                        ],
                        stops: const [0.0, 0.6, 1.0],
                      ),
                    ),
                    child: Center(
                      child: Text(look.emoji, style: const TextStyle(fontSize: 64)),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    look.eyebrow,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: accent,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 2.5,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    look.headline,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontFamily: 'Fraunces',
                      fontSize: 38,
                      height: 1.05,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Placement pill.
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: accent.withValues(alpha: 0.5)),
                    ),
                    child: Text(
                      look.badge,
                      style: TextStyle(
                        color: accent,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    look.body,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.78),
                      fontSize: 14.5,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 22),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: accent,
                        foregroundColor: Colors.black,
                        minimumSize: const Size(0, 52),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(
                        look.button,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
