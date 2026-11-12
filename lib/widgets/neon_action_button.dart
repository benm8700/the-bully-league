import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// THE BIG NEON CALL-TO-ACTION (2026-11-11, developer: "Send challenge looks
/// super stock"). The filled sibling of the Home doors (home_action_card.dart):
/// a lit hot-pink -> magenta gradient body, a glass gloss across the top, a
/// two-tone neon glow, the display serif in caps, and a small press-in
/// animation. Use for the ONE main action on a screen.
class NeonActionButton extends StatefulWidget {
  const NeonActionButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon = Icons.local_fire_department_rounded,
    this.busy = false,
    this.colors = const [Color(0xFFFF2E7E), Color(0xFFC21FD8)],
    this.glow = const Color(0xFF3D7BFF),
    this.compact = false,
  });

  /// A shorter (52px) version for inside cards.
  final bool compact;

  final String label;
  final IconData icon;

  /// Null disables the button (dimmed, no glow).
  final VoidCallback? onPressed;

  /// Shows a spinner in place of the label.
  final bool busy;

  /// Body gradient, left to right.
  final List<Color> colors;

  /// The cooler outer halo colour.
  final Color glow;

  @override
  State<NeonActionButton> createState() => _NeonActionButtonState();
}

class _NeonActionButtonState extends State<NeonActionButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final enabled = widget.onPressed != null && !widget.busy;
    const radius = 20.0;
    final height = widget.compact ? 52.0 : 64.0;
    final hot = widget.colors.first;

    final label = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          widget.icon,
          color: Colors.white,
          size: widget.compact ? 21 : 26,
          shadows: const [Shadow(color: Color(0xAAFFFFFF), blurRadius: 10)],
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            widget.label.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: p.display,
              color: Colors.white,
              fontSize: widget.compact ? 18 : 22,
              letterSpacing: widget.compact ? 1.2 : 1.6,
              height: 1,
              fontVariations: [
                const FontVariation('wght', 800),
                FontVariation('wdth', p.displayWidth),
              ],
              shadows: const [
                Shadow(
                  color: Color(0x66000000),
                  blurRadius: 4,
                  offset: Offset(0, 2),
                ),
              ],
            ),
          ),
        ),
      ],
    );

    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.label,
      child: GestureDetector(
        onTapDown: enabled ? (_) => setState(() => _down = true) : null,
        onTapCancel: () => setState(() => _down = false),
        onTapUp: enabled ? (_) => setState(() => _down = false) : null,
        onTap: enabled ? widget.onPressed : null,
        child: AnimatedScale(
          scale: _down ? 0.97 : 1,
          duration: const Duration(milliseconds: 90),
          child: AnimatedOpacity(
            opacity: enabled || widget.busy ? 1 : 0.45,
            duration: const Duration(milliseconds: 150),
            child: Container(
              height: height,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(radius),
                boxShadow: enabled
                    ? [
                        BoxShadow(
                          color: hot.withValues(alpha: _down ? 0.75 : 0.55),
                          blurRadius: _down ? 14 : 18,
                          offset: const Offset(0, 4),
                        ),
                        BoxShadow(
                          color: widget.glow.withValues(alpha: 0.28),
                          blurRadius: 32,
                          spreadRadius: 1,
                        ),
                      ]
                    : null,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(radius),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // Body.
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          colors: widget.colors,
                        ),
                      ),
                    ),
                    // Depth: darker toward the base.
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0x00000000), Color(0x40000000)],
                        ),
                      ),
                    ),
                    // Glass gloss across the top half.
                    Align(
                      alignment: Alignment.topCenter,
                      child: FractionallySizedBox(
                        heightFactor: 0.5,
                        widthFactor: 1,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.white.withValues(alpha: 0.28),
                                Colors.white.withValues(alpha: 0.04),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    // Bright rim along the top edge.
                    Positioned(
                      top: 1.5,
                      left: 18,
                      right: 18,
                      height: 1.5,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.45),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    // Thin light border.
                    DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(radius),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.22),
                          width: 1,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      child: Center(
                        child: widget.busy
                            ? const SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                  color: Colors.white,
                                ),
                              )
                            : label,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
