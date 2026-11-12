import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_theme.dart';

/// "PASSING THE MIC" - the silence countdown, drawn as a draining bar.
///
/// Replaces the old flat red button (2026-11-10, developer: "looks like a
/// third grader did it"). Styled like the Home doors: frosted glass, a neon
/// edge in the live colour, the display font. The COUNTDOWN IS THE BAR - its
/// fill drains left to right over [drainMs], so there is no number to read.
/// It slides up when the player goes quiet; the parent removes it the instant
/// they talk again. Tapping anywhere passes now.
///
/// [drainMs] null = no countdown (silence auto-pass switched off in config):
/// a static bar that still passes on tap.
class PassMicBar extends StatefulWidget {
  const PassMicBar({
    super.key,
    required this.prompt,
    required this.onTap,
    this.title = 'Pass the mic',
    this.passingTitle = 'Passing the mic...',
    this.pillText = 'TAP TO PASS',
    this.drainMs,
    this.passing = false,
    this.enabled = true,
  });

  /// Small line above the title, e.g. "Out of material?".
  final String prompt;

  /// The big line. "Put the mic down" on the last turn (ends the battle).
  final String title;
  final String passingTitle;
  final String pillText;
  final VoidCallback onTap;
  final int? drainMs;

  /// Tapped and waiting for the minimum hold to end - shows "Passing...".
  final bool passing;
  final bool enabled;

  @override
  State<PassMicBar> createState() => _PassMicBarState();
}

class _PassMicBarState extends State<PassMicBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _drain;

  @override
  void initState() {
    super.initState();
    _drain = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: widget.drainMs ?? 1),
      value: 1,
    );
    if (widget.drainMs != null) {
      _drain.reverse(from: 1);
      HapticFeedback.lightImpact();
    }
  }

  @override
  void dispose() {
    _drain.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final live = p.live;
    final title = widget.passing ? widget.passingTitle : widget.title;
    final drains = widget.drainMs != null;

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, 18 * (1 - t)),
          child: child,
        ),
      ),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.enabled && !widget.passing
            ? () {
                HapticFeedback.mediumImpact();
                widget.onTap();
              }
            : null,
        child: Container(
          height: 56,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: live.withValues(alpha: 0.9), width: 1.5),
            boxShadow: [
              BoxShadow(color: live.withValues(alpha: 0.45), blurRadius: 18),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(17),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(color: Colors.black.withValues(alpha: 0.55)),
                  // The draining fill - the countdown itself.
                  if (drains || widget.passing)
                    AnimatedBuilder(
                      animation: _drain,
                      builder: (context, _) => Align(
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: widget.passing ? 1 : _drain.value,
                          heightFactor: 1,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  live.withValues(alpha: 0.55),
                                  live.withValues(alpha: 0.30),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        Icon(
                          Icons.mic_rounded,
                          color: Colors.white,
                          size: 26,
                          shadows: [Shadow(color: live, blurRadius: 12)],
                        ),
                        const Icon(
                          Icons.east_rounded,
                          color: Colors.white70,
                          size: 16,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (!widget.passing && widget.prompt.isNotEmpty)
                                Text(
                                  widget.prompt.toUpperCase(),
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.75),
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 1.6,
                                  ),
                                ),
                              Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontFamily: p.display,
                                  color: Colors.white,
                                  fontSize: 20,
                                  height: 1.1,
                                  fontVariations: [
                                    const FontVariation('wght', 700),
                                    FontVariation('wdth', p.displayWidth),
                                  ],
                                  shadows: [
                                    Shadow(
                                      color: live.withValues(alpha: 0.7),
                                      blurRadius: 10,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (!widget.passing)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.6),
                              ),
                              color: Colors.white.withValues(alpha: 0.08),
                            ),
                            child: Text(
                              widget.pillText,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10.5,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1.2,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
