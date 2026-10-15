import 'dart:math';

import 'package:flutter/material.dart';

/// An animated tomato BARRAGE overlay: ONE throw fires a rapid burst of
/// several tomatoes (boom-boom-boom) that smack the screen at scattered
/// positions - over the video, the timers and the buttons - each bursting
/// into a red splatter with flung droplets and seed flecks, then dripping and
/// fading. Ephemeral and non-interactive (IgnorePointer), drawn only on the
/// live client view, so it can never reach a recording.
///
/// Self-timing: the whole barrage plays once and calls [onDone] so the host
/// can clear it. Mount under a unique key per throw so a second throw replays
/// rather than reusing the finished controller.
class TomatoSplat extends StatefulWidget {
  const TomatoSplat({super.key, this.onDone, this.count = 5});

  final VoidCallback? onDone;

  /// How many tomatoes one throw lobs. 4-6 reads as a satisfying barrage.
  final int count;

  @override
  State<TomatoSplat> createState() => _TomatoSplatState();
}

/// Each tomato in the barrage: when it lands (fraction of the whole barrage),
/// where it lands (fractional screen position), and its splatter.
class _Splat {
  const _Splat(this.start, this.cx, this.cy, this.scale, this.drops);
  final double start; // 0..1 into the barrage timeline
  final double cx; // 0..1 of width
  final double cy; // 0..1 of height
  final double scale; // per-tomato size variation
  final List<_Drop> drops;
}

class _TomatoSplatState extends State<TomatoSplat>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final List<_Splat> _splats;

  // Each splat's own impact->spread->fade takes this long; the barrage is the
  // last splat's start plus this.
  static const _splatMs = 950;
  // Gap between successive tomatoes - the boom-boom-boom cadence.
  static const _staggerMs = 135;

  @override
  void initState() {
    super.initState();
    final r = Random();
    final n = widget.count.clamp(1, 8);
    final totalMs = (n - 1) * _staggerMs + _splatMs;
    _splats = List.generate(n, (i) {
      final startMs = i * _staggerMs;
      return _Splat(
        startMs / totalMs,
        // Scattered across the screen (kept off the very edges so each splat
        // reads whole). The first lands central-ish; the rest spread out.
        i == 0 ? 0.4 + r.nextDouble() * 0.2 : 0.12 + r.nextDouble() * 0.76,
        i == 0 ? 0.38 + r.nextDouble() * 0.24 : 0.14 + r.nextDouble() * 0.72,
        0.8 + r.nextDouble() * 0.5,
        _makeDrops(r),
      );
    });
    _c = AnimationController(
        vsync: this, duration: Duration(milliseconds: totalMs))
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
          return CustomPaint(
            painter: _BarragePainter(t: _c.value, splats: _splats),
            child: const SizedBox.expand(),
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

class _BarragePainter extends CustomPainter {
  _BarragePainter({required this.t, required this.splats});

  final double t; // 0..1 across the whole barrage
  final List<_Splat> splats;

  static const _red = Color(0xFFE23B2E);
  static const _dark = Color(0xFFB11C12);
  static const _seed = Color(0xFFF4D9A0);

  @override
  void paint(Canvas canvas, Size size) {
    final red = Paint()..color = _red;
    final dark = Paint()..color = _dark;
    final seedPaint = Paint()..color = _seed;

    // ONE full-screen red flash on the first impact only - repeating it per
    // tomato would strobe. Keyed to the first splat's impact window.
    final first = splats.first;
    final firstLocal = ((t - first.start) / _localSpan()).clamp(0.0, 1.0);
    final flash = (1 - (firstLocal / 0.3).clamp(0.0, 1.0)) * 0.22;
    if (flash > 0) {
      canvas.drawRect(
          Offset.zero & size, Paint()..color = _red.withValues(alpha: flash));
    }

    for (final s in splats) {
      // This tomato's own 0..1 progress, from when it was thrown.
      final local = (t - s.start) / _localSpan();
      if (local <= 0) continue; // not thrown yet
      final lt = local.clamp(0.0, 1.0);

      final impact = Curves.easeOutBack.transform((lt / 0.22).clamp(0.0, 1.0));
      final spread =
          Curves.easeOutCubic.transform(((lt - 0.16) / 0.5).clamp(0.0, 1.0));
      final fade =
          1 - Curves.easeIn.transform(((lt - 0.6) / 0.4).clamp(0.0, 1.0));
      final alpha = fade.clamp(0.0, 1.0);
      if (alpha <= 0) continue;

      final center = Offset(size.width * s.cx, size.height * s.cy);
      final maxDist = size.shortestSide * 0.34 * s.scale;

      void withAlpha(Paint p, Color base) =>
          p.color = base.withValues(alpha: base.a * alpha);
      withAlpha(red, _red);
      withAlpha(dark, _dark);
      withAlpha(seedPaint, _seed);

      for (final d in s.drops) {
        final travel = maxDist * d.dist * spread;
        final dir = Offset(cos(d.angle), sin(d.angle));
        final pos = center + dir * travel;
        final rad = d.radius * s.scale * (0.4 + 0.6 * spread);
        if (d.seed) {
          canvas.drawCircle(pos, rad, seedPaint);
        } else {
          canvas.drawCircle(pos - dir * rad * 0.7, rad * 0.55, dark);
          canvas.drawCircle(pos, rad, red);
        }
      }

      final coreR = size.shortestSide * 0.15 * s.scale * spread;
      if (coreR > 0) {
        canvas.drawCircle(center, coreR, red);
        for (var i = 0; i < 7; i++) {
          final a = i / 7 * 2 * pi;
          canvas.drawCircle(
              center + Offset(cos(a), sin(a)) * coreR * 0.85, coreR * 0.46, red);
        }
        for (var i = 0; i < 4; i++) {
          final a = i / 4 * 2 * pi + 0.6;
          canvas.drawCircle(center + Offset(cos(a), sin(a)) * coreR * 0.4,
              coreR * 0.07, seedPaint);
        }
      }

      if (impact > 0 && lt < 0.5) {
        final tp = TextPainter(
          text: TextSpan(
              text: '🍅',
              style: TextStyle(
                  fontSize: 64 * s.scale * (0.5 + 0.5 * impact),
                  color: Colors.white.withValues(alpha: alpha))),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
      }
    }
  }

  /// A single tomato's lifetime as a fraction of the whole barrage timeline.
  double _localSpan() {
    final n = splats.length;
    final totalMs = (n - 1) * _TomatoSplatState._staggerMs +
        _TomatoSplatState._splatMs;
    return _TomatoSplatState._splatMs / totalMs;
  }

  @override
  bool shouldRepaint(covariant _BarragePainter old) => old.t != t;
}
