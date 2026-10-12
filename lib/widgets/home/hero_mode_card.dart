import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// The shared aspect ratio for the two Home hero pills (Basement + Main Stage),
/// so they are the SAME size. The developer's matched banner art is ~2056x765
/// (aspect ~2.69) - a wide, short banner; displaying at its native aspect means
/// no cropping and a compact card. Used by both RoastHero and EventWindowBanner.
const double kHeroPillAspect = 2056 / 765;

/// A cinematic hero card for a Home battle mode: a full-bleed background
/// artwork with a glow border, a bottom scrim, and a bottom-anchored Flutter
/// [overlay] carrying every dynamic element (title, subtitle, chips, CTA).
///
/// The artwork is PURE BACKGROUND - no text is baked in - so all copy,
/// countdowns and buttons stay live Flutter widgets over the top. Until the
/// developer's PNG is added the [asset] fails to load and a plain dark
/// placeholder shows instead, so the layout is identical with or without art.
class HeroModeCard extends StatelessWidget {
  const HeroModeCard({
    super.key,
    required this.asset,
    required this.glow,
    required this.aspectRatio,
    required this.overlay,
    required this.onTap,
    this.topRight,
    this.center,
    this.centerAlignment = Alignment.center,
    this.left,
    this.right,
    this.sideBannerX = 0.80,
    this.sideBannerY = -0.28,
    this.scrim = true,
  });

  /// Background artwork path, e.g. `assets/home/tournament_hero.png`.
  final String asset;

  /// The mode's accent, used for the glow shadow and border - gold for the
  /// tournament, pink for Roast a Stranger - so the two read as distinct.
  final Color glow;

  final double aspectRatio;

  /// Bottom-anchored dynamic content (title, subtitle, info, CTA).
  final Widget overlay;

  /// Whole-card tap (the CTA button inside [overlay] keeps its own tap too).
  final VoidCallback onTap;

  /// Optional small control pinned top-right over the art (e.g. the "?"
  /// tournament explainer).
  final Widget? topRight;

  /// Optional centered element over the art (e.g. the Roast "VS"). Does not
  /// intercept taps - the whole card still taps through to [onTap].
  final Widget? center;

  /// Where [center] sits. Defaults to dead centre; the Roast "VS" pushes it up
  /// so it clears the title in the bottom overlay.
  final Alignment centerAlignment;

  /// Optional small overlays laid over the LEFT and RIGHT arena banners in
  /// the art, used for the tournament hero's banner text (BE FUNNY / WIN
  /// VOTES / TAKE THE CROWN | PRIZES / STATUS / FAME). They do not intercept
  /// taps. Positioned by fractional Alignment so they scale with the card and
  /// stay on the banners across phone sizes (the art is a fixed aspect ratio,
  /// so the banners sit at the same fractional position on every device).
  final Widget? left;
  final Widget? right;

  /// Horizontal position of [left]/[right] as a fraction from centre: the left
  /// overlay sits at Alignment(-sideBannerX, sideBannerY), the right at
  /// (sideBannerX, sideBannerY). Tuned so the text centres on the art's
  /// banners rather than the card edge.
  final double sideBannerX;

  /// Vertical position of [left]/[right] in Alignment y (-1 top, +1 bottom).
  final double sideBannerY;

  /// Whether to lay a bottom-up dark scrim over the art. On by default so
  /// overlay text/chips stay readable; turned off for a card whose art is used
  /// as-is with no bottom overlay (so the scrim would only dim the artwork).
  final bool scrim;

  static const _radius = 22.0;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(_radius),
        boxShadow: [
          BoxShadow(
            color: glow.withValues(alpha: 0.30),
            blurRadius: 26,
            spreadRadius: 1,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(_radius),
        child: AspectRatio(
          aspectRatio: aspectRatio,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Background art, or a plain dark placeholder if the PNG is not
              // in the project yet (deliberately trivial - the real art is the
              // developer's, not a stand-in worth building).
              Image.asset(
                asset,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        glow.withValues(alpha: 0.22),
                        const Color(0xFF14100F),
                      ],
                    ),
                  ),
                ),
              ),
              // Bottom-up scrim so the overlay text stays readable over any art.
              if (scrim)
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.center,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Colors.black87],
                    ),
                  ),
                ),
              // Tap layer under the overlay so empty areas of the card are
              // tappable, while the CTA button on top keeps its own ripple.
              Positioned.fill(
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(onTap: onTap),
                ),
              ),
              // Centered overlay (e.g. the "VS"), visible over the art but
              // letting taps fall through to the card.
              if (center != null)
                Positioned.fill(
                  child: IgnorePointer(
                    child: Align(alignment: centerAlignment, child: center!),
                  ),
                ),
              // Banner text (tournament) centred over the art's left/right
              // arena banners. Fractional alignment keeps it on the banners at
              // any phone size.
              if (left != null)
                Positioned.fill(
                  child: IgnorePointer(
                    child: Align(
                      alignment: Alignment(-sideBannerX, sideBannerY),
                      child: left!,
                    ),
                  ),
                ),
              if (right != null)
                Positioned.fill(
                  child: IgnorePointer(
                    child: Align(
                      alignment: Alignment(sideBannerX, sideBannerY),
                      child: right!,
                    ),
                  ),
                ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: overlay,
                ),
              ),
              if (topRight != null)
                Positioned(top: 8, right: 8, child: topRight!),
              // Glow border, drawn last so it sits above the art and scrim.
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(_radius),
                      border: Border.all(
                        color: glow.withValues(alpha: 0.85),
                        width: 2,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The big all-caps hero title (TOURNAMENT / ROAST A STRANGER), tinted in the
/// mode's accent with a soft glow so it reads over busy artwork.
class HeroTitle extends StatelessWidget {
  const HeroTitle(this.text, {super.key, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.headlineMedium?.copyWith(
            color: color,
            fontWeight: FontWeight.w900,
            letterSpacing: 1.5,
            height: 1.0,
            shadows: [
              Shadow(color: color.withValues(alpha: 0.5), blurRadius: 18),
              const Shadow(color: Colors.black, blurRadius: 8),
            ],
          ),
    );
  }
}

/// The tracked-out subtitle under a hero title.
class HeroSubtitle extends StatelessWidget {
  const HeroSubtitle(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: Colors.white.withValues(alpha: 0.85),
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
            shadows: const [Shadow(color: Colors.black, blurRadius: 6)],
          ),
    );
  }
}

/// A small icon + label info chip used in the tournament hero's stats row
/// (Real Prizes / Live Bracket / countdown).
class HeroInfoChip extends StatelessWidget {
  const HeroInfoChip({
    super.key,
    required this.icon,
    required this.label,
    this.color = Colors.white,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w700,
                  shadows: const [Shadow(color: Colors.black, blurRadius: 6)],
                ),
          ),
        ),
      ],
    );
  }
}

/// Roast a Stranger ("The Basement") - the everyday hero. The developer's art
/// carries the identity and title itself (the baked "BASEMENT" wordmark + the
/// two roasters facing off), so Flutter overlays ONLY the FIND A MATCH CTA and
/// the "?" explainer over the top - no title/subtitle/VS competing with the
/// baked wordmark. Same treatment as the tournament hero, whose text is baked
/// into its art too. Pink/red identity, distinct from the gold tournament hero.
class RoastHero extends StatelessWidget {
  const RoastHero({super.key, required this.onFindMatch});

  final VoidCallback onFindMatch;

  @override
  Widget build(BuildContext context) {
    final accent = context.palette.accent;
    return HeroModeCard(
      asset: 'assets/home/roast_hero.png',
      glow: accent,
      // Art used as-is with no bottom overlay, so no scrim dimming the wordmark.
      scrim: false,
      // Native aspect of the wide banner art, shared with the Main Stage pill
      // so the two cards are the same size (and compact). No crop.
      aspectRatio: kHeroPillAspect,
      onTap: onFindMatch,
      // A "?" explainer pinned top-right, matching the tournament hero's for
      // continuity - same icon, size, and dark disc.
      topRight: IconButton(
        icon: const Icon(Icons.help_outline),
        iconSize: 28,
        color: Colors.white,
        tooltip: 'About Roast a Stranger',
        style: IconButton.styleFrom(
          backgroundColor: Colors.black.withValues(alpha: 0.42),
          padding: const EdgeInsets.all(6),
        ),
        onPressed: () => _showRoastInfo(context, accent),
      ),
      // The art is used AS-IS: it carries the identity, the title (baked
      // "BASEMENT" wordmark) and the two roasters, with nothing drawn over it.
      // No bottom overlay, because a button here would bury the baked wordmark.
      // The whole card taps through to onFindMatch, and the "?" explains it.
      overlay: const SizedBox.shrink(),
    );
  }

  /// Explains the Roast a Stranger mode: what it is, how a battle runs, how you
  /// win, and the comedy line. Opened by the "?" top-right, mirroring the
  /// tournament hero's explainer.
  void _showRoastInfo(BuildContext context, Color accent) {
    final body = Theme.of(context).textTheme.bodyMedium;
    Widget heading(String label) => Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            label,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: accent,
                ),
          ),
        );
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Roast a Stranger'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Get matched with a random opponent for a live, one-on-one '
                'roast battle. No bracket, no waiting for the hour - just you, '
                'them, and a crowd to settle it.',
                style: body,
              ),
              const SizedBox(height: 16),
              heading('How it works'),
              Text(
                'This is The Basement - everyday play. You each get about 30 '
                'seconds of clock that only ticks while you hold the floor; '
                'roast, then yield (or get cut off when it runs out). Before '
                'the bell you watch their intro video, so you walk in with ammo '
                'instead of winging it. The whole thing is recorded.',
                style: body,
              ),
              const SizedBox(height: 16),
              heading('How you win'),
              Text(
                'The crowd watches and votes - most votes takes it. These are '
                'rated, so a win climbs your rank and a loss costs you, and '
                'your best moments can become a clip you can post.',
                style: body,
              ),
              const SizedBox(height: 16),
              heading('Keep it funny'),
              Text(
                'Go as hard as you want - it is comedy. However, deliberate '
                'hate or harassment will not be tolerated.',
                style: body,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }
}
