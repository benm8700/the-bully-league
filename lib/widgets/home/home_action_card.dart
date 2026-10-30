import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// The shared Home mode button - Play, Watch, Main Stage.
///
/// Redesign (2026-10-29): THE ICON IS THE BUTTON. A big rounded-square neon
/// tile - gradient border + outer glow in the mode's colours, a glassy dark
/// interior, and a large glowing icon centred inside - with the label set
/// beside it in the display serif. The old full-bleed pill that spanned the
/// whole width is gone; these now read as three big tappable icons, not three
/// bars running edge to edge.
///
/// All three modes share this, so Play, Watch and Main Stage stay identical in
/// treatment and differ only by colour, icon and label. The whole row is the
/// tap target (so the label is tappable too), but the ripple is clipped to the
/// tile so the icon reads as the pressable "button".
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

  /// The glowing icon for the tile (use [neonIcon]).
  final Widget icon;

  final VoidCallback onTap;

  /// The mode's primary neon colour - the gradient start, the icon, the label.
  final Color accent;

  /// The tile border's cooler second colour.
  final Color accentEnd;

  /// A short line under the label, e.g. "Roast a stranger".
  final String? subtitle;

  /// An optional pill below the label (Main Stage's COMING SOON).
  final Widget? badge;

  static const double _tile = 94; // the big icon button
  static const double _tileRadius = 28;
  static const double _border = 2.2;

  /// A big glowing Material icon for the tile.
  static Widget neonIcon(IconData icon, Color color) => Icon(
        icon,
        color: color,
        size: 46,
        shadows: [Shadow(color: color, blurRadius: 18)],
      );

  @override
  Widget build(BuildContext context) {
    // The marquee word uses the app's DISPLAY face (Fraunces) - the same
    // high-contrast serif as the rank title on the player card above and every
    // headline in the app.
    final p = context.palette;
    final labelStyle = TextStyle(
      fontFamily: p.display,
      color: accent,
      fontSize: 31,
      letterSpacing: 0.5,
      height: 1.0,
      fontVariations: [
        const FontVariation('wght', 700),
        FontVariation('wdth', p.displayWidth),
        const FontVariation('opsz', 31),
      ],
      shadows: [
        Shadow(color: accent.withValues(alpha: 0.5), blurRadius: 12),
      ],
    );

    // The framed icon tile - this is the "button" the user taps.
    final tile = DecoratedBox(
      // Neon outer glow, two-tone to match the gradient border. Outside the
      // ClipRRect so the clip can't cut it off.
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(_tileRadius),
        boxShadow: [
          BoxShadow(
              color: accent.withValues(alpha: 0.42),
              blurRadius: 20,
              spreadRadius: 0),
          BoxShadow(
              color: accentEnd.withValues(alpha: 0.22),
              blurRadius: 22,
              spreadRadius: 0),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(_tileRadius),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // The gradient fills the whole tile; the dark interior is inset by
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
                  color: Colors.black.withValues(alpha: 0.68),
                  borderRadius: BorderRadius.circular(_tileRadius - _border),
                ),
              ),
            ),
            // A top glass highlight so the tile reads as a raised button.
            Positioned(
              top: _border,
              left: _border,
              right: _border,
              height: _tile * 0.42,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.vertical(
                        top: Radius.circular(_tileRadius - _border)),
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.white.withValues(alpha: 0.10),
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Center(child: icon),
            // The ripple, clipped to the tile so the ICON is what presses.
            Positioned.fill(
              child: Material(
                color: Colors.transparent,
                child: InkWell(onTap: onTap),
              ),
            ),
          ],
        ),
      ),
    );

    // Whole-row tap target (so the label is tappable), with the visible ripple
    // living on the tile above.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(width: _tile, height: _tile, child: tile),
            const SizedBox(width: 20),
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
                    const SizedBox(height: 8),
                    badge!,
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
