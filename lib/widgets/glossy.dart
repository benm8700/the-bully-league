import 'package:flutter/material.dart';

/// A glossy, shining finish for the app's loud "act now" pink surfaces
/// (Accept challenge, "your battle is ready"). A light-to-deep gradient, a
/// glass highlight across the top half, a soft outer glow, and a shine that
/// sweeps across every few seconds so it catches the eye without flashing.
class GlossyShine extends StatefulWidget {
  const GlossyShine({
    super.key,
    required this.child,
    required this.color,
    this.borderRadius = 16,
    this.glow = true,
  });

  final Widget child;
  final Color color;
  final double borderRadius;
  final bool glow;

  @override
  State<GlossyShine> createState() => _GlossyShineState();
}

class _GlossyShineState extends State<GlossyShine>
    with SingleTickerProviderStateMixin {
  // One sweep takes the first ~30% of the cycle; the rest is a rest, so the
  // shine reads as a glint rather than a constant flicker.
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3200),
  )..repeat();

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(widget.borderRadius);
    final hsl = HSLColor.fromColor(widget.color);
    final light = hsl
        .withLightness((hsl.lightness + 0.12).clamp(0.0, 1.0))
        .toColor();
    final deep = hsl
        .withLightness((hsl.lightness - 0.14).clamp(0.0, 1.0))
        .toColor();
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [light, widget.color, deep],
          stops: const [0.0, 0.5, 1.0],
        ),
        border: Border.all(color: Colors.white.withValues(alpha: 0.28)),
        boxShadow: widget.glow
            ? [
                BoxShadow(
                  color: widget.color.withValues(alpha: 0.55),
                  blurRadius: 18,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Stack(
          children: [
            widget.child,
            // Glass highlight on the top half.
            Positioned.fill(
              child: IgnorePointer(
                child: FractionallySizedBox(
                  alignment: Alignment.topCenter,
                  heightFactor: 0.5,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.white.withValues(alpha: 0.38),
                          Colors.white.withValues(alpha: 0.06),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // The moving glint.
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedBuilder(
                  animation: _sweep,
                  builder: (context, _) {
                    final t = (_sweep.value / 0.3).clamp(0.0, 1.0);
                    if (t >= 1.0) return const SizedBox.shrink();
                    final x = -1.6 + 3.2 * t;
                    return DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment(x - 0.5, -1),
                          end: Alignment(x + 0.5, 1),
                          colors: [
                            Colors.white.withValues(alpha: 0.0),
                            Colors.white.withValues(alpha: 0.45),
                            Colors.white.withValues(alpha: 0.0),
                          ],
                          stops: const [0.35, 0.5, 0.65],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A full-width glossy button built on [GlossyShine].
class GlossyButton extends StatelessWidget {
  const GlossyButton({
    super.key,
    required this.label,
    required this.onPressed,
    required this.color,
    this.foreground = Colors.white,
    this.height = 50,
  });

  final String label;
  final VoidCallback? onPressed;
  final Color color;
  final Color foreground;
  final double height;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Opacity(
      opacity: enabled ? 1 : 0.6,
      child: GlossyShine(
        color: color,
        borderRadius: height / 2,
        glow: enabled,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onPressed,
            child: SizedBox(
              height: height,
              child: Center(
                child: Text(
                  label,
                  style: TextStyle(
                    color: foreground,
                    fontWeight: FontWeight.w800,
                    fontSize: 17,
                    letterSpacing: 0.3,
                    shadows: const [
                      Shadow(color: Colors.black38, blurRadius: 4),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
