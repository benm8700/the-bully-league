import 'dart:math';

import 'package:flutter/material.dart';

/// An animated tomato SPLAT overlay: a tomato smacks the screen, bursts into a
/// red splatter with droplets flung outward and seed flecks, then the whole
/// thing drips and fades. Ephemeral and non-interactive - it renders only on
/// the live client view and can never reach a recording (the splat is drawn
/// here, not in the camera stream).
///
/// Self-timing: plays once (~1.1s) and calls [onDone] so the host can clear it.
/// Mount it under a unique key per throw so a second tomato replays rather than
/// reusing the finished controller.
class TomatoSplat extends StatefulWidget {
  const TomatoSplat({super.key, this.onDone});

  final VoidCallback? onDone;

  @override
  State<TomatoSplat> createState() => _TomatoSplatState();
}

class _TomatoSplatState extends State<TomatoSplat>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final List<_Drop> _drops;

  @override
  void initState() {
    super.initState();
    _drops = _makeDrops(Random());
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1100))
      ..addStatusListener((s) {
        if (s == AnimationStatus.completed) widget.onDone?.call();
      })
      ..forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final t = _c.value;
          // Impact: the tomato scales in fast with an overshoot in the first
          // ~22%, then holds while the splat takes over.
          final impact =
              Curves.easeOutBack.transform((t / 0.22).clamp(0.0, 1.0));
          // The splatter spreads outward just after impact.
          final spread =
              Curves.easeOutCubic.transform(((t - 0.16) / 0.5).clamp(0.0, 1.0));
          // A brief red flash of the whole screen on impact, then clear.
          final flash = (1 - (t / 0.3).clamp(0.0, 1.0)) * 0.3;
          // Everything fades out over the last 40%.
          final fade = 1 - Curves.easeIn.transform(((t - 0.6) / 0.4).clamp(0.0, 1.0));
          return Opacity(
            opacity: fade.clamp(0.0, 1.0),
            child: CustomPaint(
              painter: _SplatPainter(
                  impact: impact, spread: spread, flash: flash, drops: _drops),
              child: const SizedBox.expand(),
            ),
          );
        },
      ),
    );
  }
}

/// One flung droplet: a direction, how far it travels (fraction of the max),
/// and its size.
class _Drop {
  const _Drop(this.angle, this.dist, this.radius, this.seed);
  final double angle;
  final double dist;
  final double radius;
  final bool seed; // a tan seed fleck rather than a red blob
}

List<_Drop> _makeDrops(Random r) {
  final n = 10 + r.nextInt(5);
  return List.generate(n, (_) {
    final seed = r.nextDouble() < 0.28;
    return _Drop(
      r.nextDouble() * 2 * pi,
      0.4 + r.nextDouble() * 0.6,
      seed ? 2.5 + r.nextDouble() * 3 : 8 + r.nextDouble() * 24,
      seed,
    );
  });
}

class _SplatPainter extends CustomPainter {
  _SplatPainter({
    required this.impact,
    required this.spread,
    required this.flash,
    required this.drops,
  });

  final double impact;
  final double spread;
  final double flash;
  final List<_Drop> drops;

  static const _red = Color(0xFFE23B2E);
  static const _dark = Color(0xFFB11C12);
  static const _seed = Color(0xFFF4D9A0);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxDist = size.shortestSide * 0.46;
    final red = Paint()..color = _red;
    final dark = Paint()..color = _dark;
    final seedPaint = Paint()..color = _seed;

    if (flash > 0) {
      canvas.drawRect(Offset.zero & size, Paint()..color = _red.withValues(alpha: flash));
    }

    // The flung droplets + seed flecks.
    for (final d in drops) {
      final travel = maxDist * d.dist * spread;
      final dir = Offset(cos(d.angle), sin(d.angle));
      final pos = center + dir * travel;
      final rad = d.radius * (0.4 + 0.6 * spread);
      if (d.seed) {
        canvas.drawCircle(pos, rad, seedPaint);
      } else {
        // A short dark drip trailing back toward the impact.
        canvas.drawCircle(pos - dir * rad * 0.7, rad * 0.55, dark);
        canvas.drawCircle(pos, rad, red);
      }
    }

    // The central splat: an irregular cluster of lobes so the edge isn't a
    // clean circle.
    final coreR = size.shortestSide * 0.17 * spread;
    if (coreR > 0) {
      canvas.drawCircle(center, coreR, red);
      for (var i = 0; i < 7; i++) {
        final a = i / 7 * 2 * pi;
        canvas.drawCircle(
            center + Offset(cos(a), sin(a)) * coreR * 0.85, coreR * 0.46, red);
      }
      // A couple of seeds on the splat.
      for (var i = 0; i < 4; i++) {
        final a = i / 4 * 2 * pi + 0.6;
        canvas.drawCircle(
            center + Offset(cos(a), sin(a)) * coreR * 0.4, coreR * 0.07, seedPaint);
      }
    }

    // The tomato itself at the moment of impact, on top, before the splat
    // swallows it.
    if (impact > 0) {
      final tp = TextPainter(
        text: TextSpan(
            text: '🍅', style: TextStyle(fontSize: 70 * (0.5 + 0.5 * impact))),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(covariant _SplatPainter old) =>
      old.impact != impact || old.spread != spread || old.flash != flash;
}
