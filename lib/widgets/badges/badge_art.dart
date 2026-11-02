import 'package:flutter/material.dart';

import '../../core/badges/badges.dart';

/// Renders a badge's illustrated emblem at [size], greyed + dimmed when
/// [earned] is false.
///
/// Uses the developer-provided art at `assets/badges/<id>.png`. If a file is
/// missing it falls back to a drawn METAL MEDALLION (a proper swept-metal coin,
/// not a flat disc) so a badge without art still reads as a real reward. Locked
/// badges are desaturated and dimmed with the same treatment whether real art
/// or the fallback.
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
        // Everyday Basement voting uses a ballot icon, so the voting family
        // (Voter/Juror/...) stays visually distinct from the prestigious Main
        // Stage Judge badge, which keeps the ⚖️ scales of the real panel.
        BadgeMetric.votesCast => Icons.how_to_vote,
        // Never reached for glyph-medallion badges (emoji awards + the 🏆
        // champion / 🥈 runner-up render their glyph), but the switch must be
        // exhaustive.
        BadgeMetric.tournamentWins ||
        BadgeMetric.tournamentRunnerUps ||
        BadgeMetric.editorsChoicePicks ||
        BadgeMetric.topFire ||
        BadgeMetric.topClever ||
        BadgeMetric.topBoring ||
        BadgeMetric.topTrash ||
        BadgeMetric.topRedFlag ||
        BadgeMetric.mainStagePanelsServed =>
          Icons.emoji_events,
      };

  @override
  Widget build(BuildContext context) {
    // Emoji superlative awards have no PNG - they render the glyph in a
    // medallion (gold for the chase emojis, tarnished grey for the negatives).
    if (def.emoji != null) {
      final finish = _finishForEmoji(def.emoji!);
      final medal = _medallion(
        Text(
          def.emoji!,
          style: TextStyle(
            fontSize: size * 0.4,
            shadows: const [
              Shadow(color: Color(0x99000000), blurRadius: 3, offset: Offset(0, 1)),
            ],
          ),
        ),
        finish,
      );
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

  _MedalFinish _finishForEmoji(String emoji) {
    final gold = emoji == '🔥' ||
        emoji == '🧠' ||
        emoji == '🏆' ||
        emoji == '⭐' ||
        emoji == '⚖️';
    final silver = emoji == '🥈';
    return gold
        ? _MedalFinish.gold
        : silver
            ? _MedalFinish.silver
            : _MedalFinish.tarnished;
  }

  Widget _fallbackMedallion() {
    // Drawn badges (the voting family, wins/battles/streak without PNG art) all
    // get the GOLD medal - an honour worth showing off, not a flat disc.
    return _medallion(
      Icon(
        _icon,
        color: const Color(0xFFFFE9A8),
        size: size * 0.4,
        shadows: const [
          Shadow(color: Color(0x80000000), blurRadius: 4, offset: Offset(0, 1.5)),
        ],
      ),
      _MedalFinish.gold,
    );
  }

  /// A proper struck-metal medal: a swept metallic rim (so the light actually
  /// travels around it like a coin), a recessed centre with a bevel, a glossy
  /// top-left sheen, and an outer glow when earned. The [center] glyph/icon sits
  /// in the recess.
  Widget _medallion(Widget center, _MedalFinish f) {
    final accent = switch (f) {
      _MedalFinish.gold => const Color(0xFFF4C838),
      _MedalFinish.silver => const Color(0xFFC9D2DC),
      _MedalFinish.tarnished => const Color(0xFF9198A3),
    };
    return SizedBox(
      width: size,
      height: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: earned
              ? [
                  BoxShadow(
                    color: accent.withValues(alpha: 0.38),
                    blurRadius: size * 0.2,
                    spreadRadius: 1,
                  ),
                ]
              : null,
        ),
        child: CustomPaint(
          painter: _MedalPainter(finish: f, earned: earned),
          child: Center(child: center),
        ),
      ),
    );
  }
}

enum _MedalFinish { gold, silver, tarnished }

class _MedalPainter extends CustomPainter {
  _MedalPainter({required this.finish, required this.earned});

  final _MedalFinish finish;
  final bool earned;

  // [dark, bright, mid] for the swept rim; [light, dark] for the recess.
  ({List<Color> rim, List<Color> recess}) get _palette => switch (finish) {
        _MedalFinish.gold => (
            rim: const [Color(0xFF6B4E10), Color(0xFFFFEFB8), Color(0xFFEBB82E)],
            recess: const [Color(0xFF4A3A16), Color(0xFF140E03)],
          ),
        _MedalFinish.silver => (
            rim: const [Color(0xFF596169), Color(0xFFF4F8FC), Color(0xFFC9D2DC)],
            recess: const [Color(0xFF333941), Color(0xFF0F1216)],
          ),
        _MedalFinish.tarnished => (
            rim: const [Color(0xFF3A3D42), Color(0xFFC2C8D0), Color(0xFF9198A3)],
            recess: const [Color(0xFF2B2D31), Color(0xFF101113)],
          ),
      };

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2;
    final rect = Rect.fromCircle(center: c, radius: r);
    final p = _palette;
    final dark = p.rim[0], bright = p.rim[1], mid = p.rim[2];

    // Outer metallic rim: a sweep gradient alternating dark/bright gives the
    // reflective, faceted look of a struck coin rather than a flat gradient.
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = SweepGradient(
          transform: const GradientRotation(-0.785398), // light from top-left
          colors: [dark, mid, bright, mid, dark, mid, bright, mid, dark],
          stops: const [0, .12, .25, .37, .5, .62, .75, .87, 1],
        ).createShader(rect),
    );

    // A thin darker groove just inside the edge - the raised fluted rim of a medal.
    canvas.drawCircle(
      c,
      r - r * 0.04,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.05
        ..color = dark.withValues(alpha: 0.5),
    );

    // Recessed inner disc (where the glyph sits), darker and radially lit.
    final innerR = r * 0.70;
    final innerRect = Rect.fromCircle(center: c, radius: innerR);
    canvas.drawCircle(
      c,
      innerR,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.3, -0.45),
          radius: 0.95,
          colors: p.recess,
        ).createShader(innerRect),
    );

    // Bevel around the recess: bright top-left, dark bottom-right, so the
    // centre reads as genuinely sunken.
    canvas.drawCircle(
      c,
      innerR,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.055
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [bright.withValues(alpha: 0.9), dark.withValues(alpha: 0.65)],
        ).createShader(innerRect),
    );

    // Glossy sheen over the whole medal from the top-left.
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.5, -0.62),
          radius: 0.72,
          colors: [
            Colors.white.withValues(alpha: earned ? 0.34 : 0.12),
            Colors.white.withValues(alpha: 0),
          ],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_MedalPainter old) =>
      old.finish != finish || old.earned != earned;
}
