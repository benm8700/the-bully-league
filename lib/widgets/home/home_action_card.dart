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
    this.topRight,
    this.center,
    this.centerAlignment = Alignment.center,
  });

  final String asset;
  final VoidCallback onTap;
  final Widget? topRight;
  final Widget? center;
  final Alignment centerAlignment;

  /// Native aspect of the 1200x360 button art.
  static const double aspect = 1200 / 360;
  static const double _radius = 22;
  static const double _widthFactor = 0.91;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width * _widthFactor;
    return Center(
      child: SizedBox(
        width: width,
        child: AspectRatio(
          aspectRatio: aspect,
          child: ClipRRect(
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
                // Whole-card tap layer; any topRight control sits above it and
                // keeps its own tap.
                Positioned.fill(
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(onTap: onTap),
                  ),
                ),
                if (center != null)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Align(alignment: centerAlignment, child: center!),
                    ),
                  ),
                if (topRight != null)
                  Positioned(top: 6, right: 6, child: topRight!),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
