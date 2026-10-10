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
        BadgeMetric.votesCast => Icons.balance,
        // Never reached for glyph-medallion badges (emoji awards + the 🏆
        // champion / 🥈 runner-up render their glyph), but the switch must be
        // exhaustive.
        BadgeMetric.tournamentWins ||
        BadgeMetric.tournamentRunnerUps ||
        BadgeMetric.topFire ||
        BadgeMetric.topClever ||
        BadgeMetric.topBoring ||
        BadgeMetric.topTrash ||
        BadgeMetric.topRedFlag =>
          Icons.emoji_events,
      };

  @override
  Widget build(BuildContext context) {
    // Emoji superlative awards have no PNG - they render the glyph in a
    // medallion (gold for the chase emojis, tarnished grey for the negatives).
    if (def.emoji != null) {
      final medal = _emojiMedallion();
      if (earned) return medal;
      return Opacity(
        opacity: 0.4,
        child: ColorFiltered(colorFilter: _grey, child: medal),
      );
    }

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

  /// A medallion with the award's glyph, in one of three finishes:
  ///  - GOLD for honours (🔥/🧠 and the 🏆 champion),
  ///  - SILVER for the 🥈 runner-up (an honour, clearly below gold),
  ///  - TARNISHED grey for the negatives (🥱/💩/🚩), so a 💩 trophy never reads
  ///    as a gold honour - matching the emoji-badge medals.
  Widget _emojiMedallion() {
    final gold = def.emoji == '🔥' || def.emoji == '🧠' || def.emoji == '🏆';
    final silver = def.emoji == '🥈';
    final accent = gold
        ? const Color(0xFFF4C838)
        : silver
            ? const Color(0xFFC9D2DC)
            : const Color(0xFF9198A3);
    final disc = gold
        ? const [Color(0xFF3A2F14), Color(0xFF1A1508)]
        : silver
            ? const [Color(0xFF2E333B), Color(0xFF14171B)]
            : const [Color(0xFF2A2C30), Color(0xFF131416)];
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          center: const Alignment(-0.3, -0.4),
          radius: 0.95,
          colors: disc,
        ),
        border: Border.all(color: accent.withValues(alpha: 0.85), width: 2),
        boxShadow: earned
            ? [BoxShadow(color: accent.withValues(alpha: 0.30), blurRadius: 10)]
            : null,
      ),
      child: Center(
        child: Text(def.emoji!, style: TextStyle(fontSize: size * 0.42)),
      ),
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
