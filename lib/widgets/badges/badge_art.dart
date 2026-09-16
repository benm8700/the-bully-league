import 'package:flutter/material.dart';

import '../../core/badges/badges.dart';

/// Renders a badge's illustrated emblem at [size], greyed + dimmed when
/// [earned] is false.
///
/// Uses the developer-provided art at `assets/badges/<id>.png`. If a file is
/// missing it falls back to a drawn medallion so the case never shows a broken
/// image. Locked badges are desaturated and dimmed with the same treatment
/// whether real art or the fallback.
class BadgeArt extends StatelessWidget {
  const BadgeArt({
    super.key,
    required this.def,
    required this.earned,
    this.size = 64,
  });

  final BadgeDef def;
  final bool earned;
  final double size;

  // Luminance greyscale, used to desaturate a locked badge.
  static const ColorFilter _grey = ColorFilter.matrix(<double>[
    0.2126, 0.7152, 0.0722, 0, 0, //
    0.2126, 0.7152, 0.0722, 0, 0, //
    0.2126, 0.7152, 0.0722, 0, 0, //
    0, 0, 0, 1, 0,
  ]);

  IconData get _icon => switch (def.metric) {
        BadgeMetric.wins => Icons.local_fire_department,
        BadgeMetric.battlesPlayed => Icons.sports_mma,
        BadgeMetric.voteStreakDays => Icons.gavel,
      };

  @override
  Widget build(BuildContext context) {
    final art = Image.asset(
      'assets/badges/${def.id}.png',
      width: size,
      height: size,
      fit: BoxFit.contain,
      errorBuilder: (_, _, _) => _fallbackMedallion(),
    );
    if (earned) return art;
    // Locked: desaturate and dim so it reads as "not yet earned".
    return Opacity(
      opacity: 0.4,
      child: ColorFiltered(colorFilter: _grey, child: art),
    );
  }

  Widget _fallbackMedallion() {
    const gold = Color(0xFFF4C838);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const RadialGradient(
          center: Alignment(-0.3, -0.4),
          radius: 0.95,
          colors: [Color(0xFF3A2F14), Color(0xFF1A1508)],
        ),
        border: Border.all(color: gold.withValues(alpha: 0.85), width: 2),
        boxShadow: earned
            ? [BoxShadow(color: gold.withValues(alpha: 0.30), blurRadius: 10)]
            : null,
      ),
      child: Icon(_icon, color: gold, size: size * 0.46),
    );
  }
}
