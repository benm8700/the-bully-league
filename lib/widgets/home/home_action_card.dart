import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// The shared Home mode button - Play, Watch, Main Stage - as a neon CAPSULE
/// matching the developer's reference (2026-10-29): a fully-rounded pill with a
/// GRADIENT neon border + outer glow, a glassy dark interior the background
/// shows through, and inside: a glowing icon, a thin divider, the label in the
/// accent colour, and a chevron. All three are identical in size.
///
/// The old full-bleed hero PNGs are KEPT in assets/home/ for reuse; not rendered.
class HomeActionCard extends StatelessWidget {
  const HomeActionCard({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
    required this.accent,
    required this.accentEnd,
    this.subtitle,
    this.badge,
  });

  /// The big button word, e.g. "PLAY".
  final String label;

  /// The leading icon widget (use [neonIcon] for a glowing Material icon, or an
  /// emoji Text for the crown).
  final Widget icon;

  final VoidCallback onTap;

  /// The primary neon colour - icon, label, chevron and the gradient start.
  final Color accent;

  /// The gradient border's cooler second colour.
  final Color accentEnd;

  /// A short line under the label, e.g. "Roast a complete stranger".
  final String? subtitle;

  /// An optional pill below the label (Main Stage's COMING SOON).
  final Widget? badge;

  static const double _height = 100;
  static const double _border = 2.5;

  /// A glowing Material icon for the leading slot.
  static Widget neonIcon(IconData icon, Color color) => Icon(
        icon,
        color: color,
        size: 38,
        shadows: [Shadow(color: color, blurRadius: 14)],
      );

  @override
  Widget build(BuildContext context) {
    const radius = _height / 2; // fully-rounded capsule

    // The marquee word uses the app's DISPLAY face (Fraunces) - the same
    // high-contrast serif as the rank title on the player card above and every
    // headline in the app - instead of the default body sans. A serif in caps
    // reads like a theatre marquee, which is exactly the "House Lights Down"
    // identity, and it stops these buttons looking like generic w900 chips.
    final p = context.palette;
    final labelStyle = TextStyle(
      fontFamily: p.display,
      color: accent,
      fontSize: 27,
      letterSpacing: 0.5,
      height: 1.0,
      fontVariations: [
        const FontVariation('wght', 680), // louder than a headline, still elegant
        FontVariation('wdth', p.displayWidth),
        const FontVariation('opsz', 27),
      ],
      shadows: [
        Shadow(color: accent.withValues(alpha: 0.6), blurRadius: 14),
      ],
    );
    return SizedBox(
      width: double.infinity,
      height: _height,
      // Neon outer glow, two-tone to match the gradient border. Outside the
      // ClipRRect so the clip can't cut it off.
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          boxShadow: [
            BoxShadow(
                color: accent.withValues(alpha: 0.45),
                blurRadius: 20,
                spreadRadius: 1),
            BoxShadow(
                color: accentEnd.withValues(alpha: 0.28),
                blurRadius: 22,
                spreadRadius: 1),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // The gradient fills the whole pill; the dark interior is inset by
              // the border width, leaving a crisp neon ring.
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [accent, accentEnd],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(_border),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    // Glassy dark interior - the Home background shows through.
                    color: Colors.black.withValues(alpha: 0.66),
                    borderRadius: BorderRadius.circular(radius - _border),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 0, 18, 0),
                child: Row(
                  children: [
                    SizedBox(width: 44, child: Center(child: icon)),
                    const SizedBox(width: 14),
                    Container(
                      width: 1.5,
                      height: 46,
                      color: Colors.white.withValues(alpha: 0.16),
                    ),
                    const SizedBox(width: 18),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(label, style: labelStyle),
                          if (subtitle != null) ...[
                            const SizedBox(height: 5),
                            Text(
                              subtitle!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.74),
                                fontSize: 12.5,
                                height: 1.25,
                                letterSpacing: 0.1,
                                fontWeight: FontWeight.w500,
                                shadows: const [
                                  Shadow(color: Colors.black, blurRadius: 6),
                                ],
                              ),
                            ),
                          ],
                          if (badge != null) ...[
                            const SizedBox(height: 7),
                            badge!,
                          ],
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right, color: accent, size: 30),
                  ],
                ),
              ),
              // Whole-card tap + ripple, on top so it rings over the content.
              Positioned.fill(
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(onTap: onTap),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
