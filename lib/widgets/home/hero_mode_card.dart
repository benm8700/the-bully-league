import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

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

/// Roast a Stranger - the secondary hero. Illustrated red/blue opponents +
/// VS artwork behind, with the title, subtitle and FIND A MATCH CTA as Flutter
/// overlays. Pink/red identity, distinct from the gold tournament hero.
class RoastHero extends StatelessWidget {
  const RoastHero({super.key, required this.onFindMatch});

  final VoidCallback onFindMatch;

  @override
  Widget build(BuildContext context) {
    final accent = context.palette.accent;
    return HeroModeCard(
      asset: 'assets/home/roast_hero.png',
      glow: accent,
      // More compact than 3/2 - shorter so it reads as the clear second option
      // under the tournament hero and both cards clear the fold on shorter
      // screens. Display-only crop; the roaster art stays centred and the file
      // is untouched.
      aspectRatio: 5 / 3,
      onTap: onFindMatch,
      centerAlignment: const Alignment(0, -0.5),
      center: Text(
        'VS',
        style: TextStyle(
          fontSize: 52,
          fontWeight: FontWeight.w900,
          fontStyle: FontStyle.italic,
          color: Colors.white,
          letterSpacing: 1,
          shadows: [
            Shadow(color: accent, blurRadius: 26),
            const Shadow(color: Color(0xFF3B7DFF), blurRadius: 26),
            const Shadow(color: Colors.black, blurRadius: 10),
          ],
        ),
      ),
      overlay: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          HeroTitle('ROAST A STRANGER', color: accent),
          const SizedBox(height: 6),
          const HeroSubtitle('RANDOM OPPONENT. REAL ROASTS.'),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: onFindMatch,
              style: FilledButton.styleFrom(
                backgroundColor: accent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 13),
                textStyle: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                    ),
              ),
              icon: const Icon(Icons.bolt, size: 20),
              label: const Text('FIND A MATCH'),
            ),
          ),
        ],
      ),
    );
  }
}
