import 'package:flutter/material.dart';

/// The shared full-bleed image button for the three Home mode cards - Play,
/// Watch and Main Stage - so all three are IDENTICAL in size and shape.
///
/// Spec (developer, 2026-10-23): ~91% of the available screen width, the art's
/// native 1200x360 (3.33:1) aspect so it is ~100-110 logical px tall on a
/// typical phone, 22px rounded corners, BoxFit.cover (fills the card without
/// stretching - and since the card matches the art's aspect, nothing is
/// cropped either), centred, and the WHOLE card tappable. Responsive via
/// MediaQuery, so it scales across iOS and Android. Optional [topRight] and
/// [center] overlays are used by Main Stage for the "?" explainer and the
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

  /// Display aspect (developer, 2026-10-23): 2.7:1 - a touch shorter than 2.5
  /// so the banners don't read as stretched/tall, while still fuller than the
  /// old 3.33. The art is full-bleed 2.5:1, so BoxFit.cover trims only a sliver
  /// off the top/bottom (centred, never stretched); the labels sit mid-frame,
  /// so they stay visible.
  static const double aspect = 2.7;
  static const double _radius = 19;
  static const double _widthFactor = 0.95;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width * _widthFactor;
    return Center(
      child: SizedBox(
        width: width,
        child: AspectRatio(
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
                      // Whole-card tap layer; any topRight control sits above
                      // it and keeps its own tap.
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
                // The neon frame, drawn last over the art so it reads as a
                // button edge. IgnorePointer so it never eats a tap.
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
        ),
      ),
    );
  }
}
