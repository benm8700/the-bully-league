import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import 'home/rank_badges.dart';

/// Announces a rank change the next time the app is opened.
///
/// CLAUDE.md asks for this as a real MOMENT rather than a silent field
/// change: rank is the app's one status system, so the instant it moves is
/// the payoff for everything else. It is presented as a celebration (a
/// glowing rank crest that pops in, gold accents), not a stock dialog -
/// the developer's call (2026-09-16), the plain AlertDialog read as lame.
///
/// BOTH THE LADDER ORDER AND THE COPY COME FROM THE SERVER
/// (functions/rankChange.js). Comparing the two fields here instead would
/// mean duplicating the rank order to tell a promotion from a demotion and
/// duplicating twenty lines of voice-sensitive writing. It also keeps the
/// push notification and this popup saying the same thing about the event.
class RankChangePopup {
  /// Shows the popup if this player's rank has moved since they last saw it.
  /// Asking is what marks it seen, so it fires exactly once. Fails silently:
  /// a celebration is never worth interrupting a session with an error.
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
      // The bare rank name (e.g. "Door Guy") for the crest lookup - `title` is
      // the headline sentence ("Congratulations! You achieved the rank of
      // Door Guy"), which the badge map wouldn't match.
      final rankTitle = change['to'] as String?;

      await showDialog<void>(
        context: context,
        barrierColor: Colors.black.withValues(alpha: 0.75),
        builder: (dialogContext) => _RankChangeDialog(
          title: title,
          message: message,
          up: up,
          rankTitle: rankTitle,
        ),
      );
    } catch (_) {
      // Never let a celebration break a session.
    }
  }
}

class _RankChangeDialog extends StatelessWidget {
  const _RankChangeDialog({
    required this.title,
    required this.message,
    required this.up,
    required this.rankTitle,
  });

  final String title;
  final String message;
  final bool up;

  /// The bare rank name for the crest (e.g. "Door Guy"), distinct from the
  /// headline [title] ("Congratulations! You achieved the rank of Door Guy").
  final String? rankTitle;

  // Identity palette (see the color-hierarchy note): dark base, purple/magenta
  // frame, gold as the celebratory data accent for a promotion.
  static const _gold = Color(0xFFF4C838);
  static const _purple = Color(0xFF9C4DCC);

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    // Gold and glowing for a promotion; cooler and dimmer for a demotion (the
    // copy already carries the playful-roast tone, so the visual just steps
    // back rather than celebrating).
    final Color accent = up ? _gold : const Color(0xFFB9B2C4);
    final Color glow = up ? _gold : _purple;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF241A33), Color(0xFF120D1A)],
          ),
          borderRadius: BorderRadius.circular(26),
          border: Border.all(color: _purple.withValues(alpha: 0.55), width: 1.5),
          boxShadow: [
            BoxShadow(
              color: glow.withValues(alpha: up ? 0.40 : 0.22),
              blurRadius: 34,
              spreadRadius: 2,
            ),
          ],
        ),
        // Scrolls if the content is taller than the screen allows - the
        // top-rank messages (Featured Talent especially) are a paragraph.
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.82,
          ),
          child: SingleChildScrollView(
            child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Eyebrow: what just happened, in one loud little word.
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  up
                      ? Icons.keyboard_double_arrow_up_rounded
                      : Icons.keyboard_double_arrow_down_rounded,
                  color: accent,
                  size: 18,
                ),
                const SizedBox(width: 6),
                Text(
                  up ? 'RANK UP' : 'RANK DOWN',
                  style: text.labelLarge?.copyWith(
                    color: accent,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 3,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            // The signature: the earned crest pops in over its own glow. It
            // is the HERO of the popup (developer's call) and was enlarged
            // again (2026-09-18) - the box was tightened around it so the
            // shield dominates. FittedBox(scaleDown) keeps the big size on a
            // normal phone while guaranteeing it can never overflow the box
            // on a narrow screen.
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 700),
              curve: Curves.easeOutBack,
              builder: (_, t, child) => Opacity(
                opacity: t.clamp(0.0, 1.0),
                child: Transform.scale(scale: 0.6 + 0.4 * t, child: child),
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        glow.withValues(alpha: up ? 0.5 : 0.2),
                        Colors.transparent,
                      ],
                      stops: const [0.2, 1.0],
                    ),
                  ),
                  child: RankBadge(title: rankTitle, size: 300),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: text.headlineMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(
                color: Colors.white.withValues(alpha: 0.82),
                height: 1.35,
              ),
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 50),
                  backgroundColor: up ? _gold : const Color(0xFF3A3446),
                  foregroundColor: up ? Colors.black : Colors.white,
                ),
                onPressed: () => Navigator.of(context).pop(),
                // Direction-specific: a cocky confirm on a promotion, a dry
                // one on a demotion ("Nice" there would read as the app not
                // noticing what it just said).
                child: Text(
                  up ? 'Damn right' : 'Fine',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
            ),
          ),
        ),
      ),
    );
  }
}
