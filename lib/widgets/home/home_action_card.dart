import 'package:flutter/material.dart';

/// The shared full-bleed image button for the three Home mode cards - Play,
/// Watch and Main Stage - so all three are IDENTICAL in size and shape.
///
/// Spec (developer, 2026-10-23): the art is 1200x480 (2.5:1), so the card is
/// AspectRatio(2.5) filling the available parent width, height computed
/// automatically. BoxFit.cover with the card AT the art's aspect means the
/// whole image shows with ZERO crop and ZERO stretch - no fixed heights,
/// forced image dimensions or BoxFit.fill anywhere. 20px rounded corners, the
/// WHOLE card tappable, responsive across iOS and Android. Optional [topRight]
/// and [center] overlays are used by Main Stage for the "?" explainer and the
/// COMING SOON badge; Play/Watch pass neither (their labels are in the art).
class HomeActionCard extends StatelessWidget {
  const HomeActionCard({
    super.key,
    required this.asset,
    required this.onTap,
    required this.accent,
    this.topRight,
    this.center,
    this.centerAlignment = Alignment.center,
  });

  final String asset;
  final VoidCallback onTap;

  /// The card's neon accent - the border + outer glow colour. Each mode gets
  /// its own (Play green, Watch magenta, Main Stage gold) so the card reads as
  /// a lit, tappable button rather than a flat banner.
  final Color accent;

  final Widget? topRight;
  final Widget? center;
  final Alignment centerAlignment;

  /// Display aspect = the art's exact 2.5:1, so BoxFit.cover shows the whole
  /// 1200x480 image with no crop and no stretch.
  static const double aspect = 2.5;
  static const double _radius = 20;

  @override
  Widget build(BuildContext context) {
    // AspectRatio fills the available parent width and computes the height
    // from the ratio - no fixed height, no forced image dimensions.
    return AspectRatio(
      aspectRatio: aspect,
      // Outer glow so the button looks lit/clickable. The shadow lives out
      // here, OUTSIDE the ClipRRect, since a clip would cut it off.
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(_radius),
          boxShadow: [
            BoxShadow(
              color: accent.withValues(alpha: 0.45),
              blurRadius: 18,
              spreadRadius: 1,
            ),
          ],
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(_radius),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.asset(
                    asset,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) =>
                        const ColoredBox(color: Color(0xFF14100F)),
                  ),
                  // Whole-card tap layer; any topRight control sits above it
                  // and keeps its own tap.
                  Positioned.fill(
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(onTap: onTap),
                    ),
                  ),
                  if (center != null)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: Align(
                            alignment: centerAlignment, child: center!),
                      ),
                    ),
                  if (topRight != null)
                    Positioned(top: 6, right: 6, child: topRight!),
                ],
              ),
            ),
            // The neon frame, drawn last over the art so it reads as a button
            // edge. IgnorePointer so it never eats a tap.
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(_radius),
                    border: Border.all(
                      color: accent.withValues(alpha: 0.95),
                      width: 2.5,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
