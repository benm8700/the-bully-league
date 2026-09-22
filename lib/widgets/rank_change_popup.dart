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

  /// The headline with the earned rank name coloured [goldName] so it pops
  /// out of the otherwise-white sentence. The server sends the full sentence
  /// as [title] (".. the rank of Legend") and the bare rank as [rankTitle],
  /// so the rank name is the trailing slice - split there and recolour it.
  /// Falls back to a plain white headline if the two don't line up.
  Widget _headlineText(BuildContext context, Color goldName) {
    final style = Theme.of(context).textTheme.headlineMedium?.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w800,
        );
    final r = rankTitle;
    if (r != null && r.isNotEmpty && title.endsWith(r)) {
      return RichText(
        textAlign: TextAlign.center,
        text: TextSpan(
          style: style,
          children: [
            TextSpan(text: title.substring(0, title.length - r.length)),
            TextSpan(text: r, style: TextStyle(color: goldName)),
          ],
        ),
      );
    }
    return Text(title, textAlign: TextAlign.center, style: style);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    // Gold and glowing for a promotion; cooler and dimmer for a demotion (the
    // copy already carries the playful-roast tone, so the visual just steps
    // back rather than celebrating).
    final Color accent = up ? _gold : const Color(0xFFB9B2C4);
    final Color glow = up ? _gold : _purple;

    // A metallic gradient FRAME instead of a flat border - richer and more
    // prestigious. Bright-to-deep gold for a promotion; cool purple for a
    // demotion. The frame is a gradient-filled box with the dark card padded
    // 2px inside it.
    final Gradient frame = up
        ? const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFFCEB9B), _gold, Color(0xFF9A6B10)],
          )
        : LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [_purple.withValues(alpha: 0.75), const Color(0xFF3A2F4A)],
          );

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: frame,
          borderRadius: BorderRadius.circular(28),
          boxShadow: [
            BoxShadow(
              color: glow.withValues(alpha: up ? 0.45 : 0.22),
              blurRadius: 46,
              spreadRadius: 3,
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(26),
            child: Stack(
              children: [
                Container(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      // Richer, glossier purple: a bright lilac-purple top that
                      // deepens to near-black, so light reads as catching the
                      // top of a polished surface.
                      colors: [
                        Color(0xFF4A3170),
                        Color(0xFF291940),
                        Color(0xFF120D1A),
                      ],
                      stops: [0.0, 0.42, 1.0],
                    ),
                  ),
                  // Scrolls if the content is taller than the screen allows -
                  // the top-rank messages (Featured Talent) are a paragraph.
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
            // Headline ABOVE the badge (developer's call, 2026-09-18), with
            // the earned RANK NAME in gold so it stands out from the white
            // rest of the sentence.
            _headlineText(context, up ? _gold : accent),
            const SizedBox(height: 8),
            // The signature: the earned crest pops in over its own glow. It
            // is the HERO of the popup - big, in a FittedBox(scaleDown) so it
            // can never overflow the box on a narrow screen.
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
                  padding: const EdgeInsets.all(4),
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
            const SizedBox(height: 8),
            // The one-liner sits BELOW the badge.
            Text(
              message,
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(
                color: Colors.white.withValues(alpha: 0.82),
                height: 1.35,
              ),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 46),
                  backgroundColor: up ? _gold : const Color(0xFF3A3446),
                  foregroundColor: up ? Colors.black : Colors.white,
                ),
                onPressed: () => Navigator.of(context).pop(),
                child: const Text(
                  'Accept',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
                      ),
                    ),
                  ),
                ),
                // Pristine top gloss - a stronger glass highlight across the
                // top edge, so the purple reads as polished rather than flat.
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: IgnorePointer(
                    child: Container(
                      height: 130,
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Color(0x4DFFFFFF),
                            Color(0x14FFFFFF),
                            Colors.transparent,
                          ],
                          stops: [0.0, 0.45, 1.0],
                        ),
                      ),
                    ),
                  ),
                ),
                // A one-time shine sweep across the card, for the shiny pop.
                const Positioned.fill(
                  child: IgnorePointer(child: _ShineSweep()),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A single diagonal light sweep across the card on appear - the "shiny"
/// touch. One-shot: it plays once and then sits still (a repeating shimmer
/// would read as a loading state, not a trophy).
class _ShineSweep extends StatefulWidget {
  const _ShineSweep();

  @override
  State<_ShineSweep> createState() => _ShineSweepState();
}

class _ShineSweepState extends State<_ShineSweep>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  )..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        return AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            final t = Curves.easeInOut.transform(_c.value);
            return Transform.translate(
              offset: Offset(-w * 0.7 + t * (w * 1.7), 0),
              child: Transform.rotate(
                angle: -0.42,
                child: Container(
                  width: w * 0.35,
                  height: h * 1.8,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [
                        Colors.transparent,
                        Colors.white.withValues(alpha: 0.24),
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
