import 'package:flutter/material.dart';

/// Illustrated rank-tier badges (developer-provided PNGs in assets/ranks/),
/// mapped by the tier TITLE the backend returns (functions/rating.js's
/// XP_TIERS + GOAT). Keyed on the title string so the card never re-derives
/// the ladder.
///
/// The 9th tier was renamed "Hall of Famer" -> "Featured Talent" (developer's
/// call, 2026-09-14) so the tier title matches the badge art; the rename
/// lives in functions/rating.js (XP_TIERS + RANK_TIERS) and rankChange.js.
const Map<String, String> _rankBadgeAssets = {
  'Average Joe': 'assets/ranks/rank_02_average_joe.png',
  'Open Micer': 'assets/ranks/rank_01_open_micer.png',
  'Class Clown': 'assets/ranks/rank_03_class_clown.png',
  'The Funny Friend': 'assets/ranks/rank_04_funny_friend.png',
  'Door Guy': 'assets/ranks/rank_05_door_guy.png',
  'Regular': 'assets/ranks/rank_06_regular.png',
  'Headliner': 'assets/ranks/rank_07_headliner.png',
  'Legend': 'assets/ranks/rank_09_legend.png',
  'Featured Talent': 'assets/ranks/rank_08_featured_talent.png',
  'GOAT': 'assets/ranks/rank_10_goat.png',
};

/// The badge asset path for a tier title, or null when the title is unknown.
String? rankBadgeAsset(String? title) =>
    title == null ? null : _rankBadgeAssets[title];

/// The rank's position on the ladder as a ROMAN NUMERAL, counting UP (Average
/// Joe = I ... Featured Talent = IX). Shown next to the title ("DOOR GUY · V")
/// so the climb reads as a ladder, not a bag of random names.
///
/// Deliberately keyed by title (same no-drift pattern as the badge map) and
/// deliberately HIDES THE CEILING: there is no "/9", and GOAT has NO numeral -
/// it's the live throne ABOVE the numbered ladder, so the top stays a mystery.
/// Order mirrors functions/rating.js's XP_TIERS; an unknown title -> null
/// (just the title, no numeral) rather than a wrong number.
const Map<String, String> _rankTierNumerals = {
  'Average Joe': 'I',
  'Open Micer': 'II',
  'Class Clown': 'III',
  'The Funny Friend': 'IV',
  'Door Guy': 'V',
  'Regular': 'VI',
  'Headliner': 'VII',
  'Legend': 'VIII',
  'Featured Talent': 'IX',
  // GOAT: intentionally absent - unnumbered throne above the ladder.
};

/// The Roman-numeral rung for a tier title, or null for GOAT / unknown titles.
String? rankTierNumeral(String? title) =>
    title == null ? null : _rankTierNumerals[title];

/// The ladder in order, for deriving a tier's position (bronze/silver/gold
/// banding of the numeral). GOAT is deliberately absent - it has no numeral.
const List<String> _tierOrder = [
  'Average Joe', 'Open Micer', 'Class Clown', 'The Funny Friend', 'Door Guy',
  'Regular', 'Headliner', 'Legend', 'Featured Talent',
];

/// Metal colour for the rung numeral, so the climb reads at a glance: BRONZE
/// for I-III, SILVER for IV-VI, GOLD for VII-IX. Null for GOAT/unknown (no
/// numeral there). Developer's call 2026-10-16 - "looks better the higher you
/// get."
Color? rankTierColor(String? title) {
  if (title == null) return null;
  final i = _tierOrder.indexOf(title);
  if (i < 0) return null;
  if (i <= 2) return const Color(0xFFCD7F32); // bronze
  if (i <= 5) return const Color(0xFFC8CED4); // silver
  return const Color(0xFFF4C838); // gold
}

/// Renders a player's rank badge: the illustrated PNG for their tier.
///
/// The production badge PNGs are standardized 512x512 with TRANSPARENT
/// backgrounds and their own padding + glow baked in, so this renders them
/// clean and lets the card show through:
///  - BoxFit.contain (never cover), so the whole badge and its glow are
///    always shown, aspect ratio preserved, nothing cropped.
///  - NO added background, NO circle/square/ClipOval behind it, NO extra glow
///    - the transparency shows the surface behind the badge naturally.
///  - Centered within its square [size] box, which also leaves room for the
///    badge's own glow.
///
/// Falls back to a drawn gold shield crest only when the tier has no mapped
/// asset or the image fails to load, so the slot is never empty.
class RankBadge extends StatelessWidget {
  const RankBadge({super.key, required this.title, this.size = 66});

  final String? title;
  final double size;

  static const _gold = Color(0xFFF4C838);

  @override
  Widget build(BuildContext context) {
    final asset = rankBadgeAsset(title);
    if (asset == null) {
      return SizedBox(
        width: size,
        height: size,
        child: Center(child: _ShieldFallback(gold: _gold)),
      );
    }
    return Image.asset(
      asset,
      width: size,
      height: size,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
      errorBuilder: (_, _, _) => SizedBox(
        width: size,
        height: size,
        child: Center(child: _ShieldFallback(gold: _gold)),
      ),
    );
  }
}

/// Drawn gold shield crest - the stand-in when a tier has no illustrated
/// badge yet (or the PNG fails to load). Reads as an earned crest rather than
/// a generic Material medal.
class _ShieldFallback extends StatelessWidget {
  const _ShieldFallback({required this.gold});

  final Color gold;

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        ShaderMask(
          shaderCallback: (rect) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFFDEFB8), Color(0xFFF4C838), Color(0xFFB9820E)],
            stops: [0.0, 0.55, 1.0],
          ).createShader(rect),
          child: const Icon(Icons.shield, size: 50, color: Colors.white),
        ),
        const Padding(
          padding: EdgeInsets.only(bottom: 6),
          child:
              Icon(Icons.military_tech, size: 20, color: Color(0xFF3A2A00)),
        ),
      ],
    );
  }
}
