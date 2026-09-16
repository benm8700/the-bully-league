import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import '../../screens/leaderboard/leaderboard_screen.dart';
import 'rank_badges.dart';

/// The Home Player Status card: one horizontal HUD panel carrying the
/// player's tier + rank badge + XP progress on the left, and their GLOBAL
/// RANK position on the right. Tappable (chevron) through to the Ranks board.
///
/// Visual target is the developer's approved reference (2026-09-14): a
/// crisp, dark, expensive-feeling card - near-black navy with a thin gold
/// border, a restrained gold edge glow, a larger illustrated rank badge, a
/// long slim bright-gold XP bar on a very dark track, and a prominent global
/// rank on the right. Deliberately COMPACT - this is a status HUD, and the
/// tournament hero below it stays the dominant element.
///
/// NUMBERS ARE SHOWN ON PURPOSE (career XP over the next title's threshold,
/// and the exact global position) - a deliberate softening of the
/// hidden-criteria rule, the developer's call to match the reference.
///
/// TWO SYSTEMS, ONE CARD:
///  - XP / nextXP / tier come from getLaughMeter (the ladder lives in
///    functions/rating.js; the client never re-derives the thresholds).
///  - GLOBAL RANK is a count aggregation of players out-rating me, +1 - the
///    same query the Ranks board uses. It reads the hidden Elo and shows
///    only the POSITION, never the rating. This is REAL data: a top-rated
///    account genuinely shows "#1"; it is not a placeholder.
///
/// THE RANK BADGE IS THE PLAYER'S ILLUSTRATED CREST. The developer-provided
/// PNGs in assets/ranks/ are mapped by tier title in rank_badges.dart and
/// rendered here at ~60px; a drawn gold shield stands in only if a tier has
/// no mapped asset or the image fails to load.
class PlayerStatusCard extends StatefulWidget {
  const PlayerStatusCard({
    super.key,
    required this.uid,
    this.fallbackTitle,
    this.fallbackPoints,
  });

  final String uid;
  final String? fallbackTitle;
  final num? fallbackPoints;

  @override
  State<PlayerStatusCard> createState() => _PlayerStatusCardState();
}

class _PlayerStatusCardState extends State<PlayerStatusCard> {
  Map<String, dynamic>? _meter;
  int? _rank;

  @override
  void initState() {
    super.initState();
    _loadMeter();
    _loadRank();
  }

  Future<void> _loadMeter() async {
    try {
      final r = await FirebaseFunctions.instance
          .httpsCallable('getLaughMeter')
          .call<Map<String, dynamic>>();
      if (mounted) setState(() => _meter = r.data);
    } catch (_) {
      // Quiet: the fallback title still renders the identity.
    }
  }

  Future<void> _loadRank() async {
    try {
      final db = FirebaseFirestore.instance;
      final doc = await db.collection('users').doc(widget.uid).get();
      final rating = doc.data()?['rating'] as num?;
      if (rating == null) return; // Never placed - no position to show.
      final ahead = await db
          .collection('users')
          .where('rating', isGreaterThan: rating)
          .count()
          .get();
      if (mounted) setState(() => _rank = (ahead.count ?? 0) + 1);
    } catch (_) {
      // Quiet: hide the rank column rather than error under it.
    }
  }

  static const _gold = Color(0xFFF4C838);

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    final meter = _meter;
    final title = (meter?['title'] as String?) ??
        widget.fallbackTitle ??
        'Average Joe';
    final xp = (meter?['xp'] as num?)?.toInt() ??
        widget.fallbackPoints?.toInt() ??
        0;
    final nextXp = (meter?['nextXp'] as num?)?.toInt();
    final fill = (meter?['fill'] as num?)?.toDouble().clamp(0.0, 1.0) ??
        (nextXp != null && nextXp > 0
            ? (xp / nextXp).clamp(0.0, 1.0)
            : 1.0);

    const gold = _gold;

    // Rank title + XP bar + XP number.
    final rankColumn = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Scale-to-fit rather than ellipsis: a longer rank title like
        // "Average Joe" or "The Funny Friend" was clipping to "Averag..." on
        // real phones where this column is narrower than the emulator. FittedBox
        // shrinks the one line to fit the available width instead of truncating.
        Align(
          alignment: Alignment.centerLeft,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              title,
              maxLines: 1,
              softWrap: false,
              style: text.titleMedium?.copyWith(
                fontSize: 19,
                fontWeight: FontWeight.w800,
                color: Colors.white, // strong white
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        _XpBar(fill: fill),
        const SizedBox(height: 4),
        Text(
          nextXp != null
              ? '${_comma(xp)} / ${_comma(nextXp)} XP'
              : '${_comma(xp)} XP',
          style: text.bodySmall?.copyWith(
            fontSize: 13,
            color: const Color(0xFFC2C2C2), // light gray
            fontWeight: FontWeight.w600,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );

    // Card content. Layered glows behind it: purple/plum illumination toward
    // the top-left and bottom-right EDGES (centre stays dark), then a warm
    // GOLD ambient glow behind the BADGE only (the badge is the one gold
    // element here). All clipped to the card by the ClipRRect above.
    final content = Stack(
      children: [
        // Very faint diagonal sheen - a whisper of light on the surface, not a
        // metallic stripe. Kept minimal so the card reads dark and quiet.
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.transparent,
                    const Color(0xFFD9A8FF).withValues(alpha: 0.02),
                    const Color(0xFFE7C6FF).withValues(alpha: 0.06),
                    const Color(0xFFD9A8FF).withValues(alpha: 0.02),
                    Colors.transparent,
                  ],
                  stops: const [0.0, 0.38, 0.5, 0.62, 1.0],
                ),
              ),
            ),
          ),
        ),
        // A single subtle plum accent glow at the top-left only (the purple is
        // an ACCENT, not the whole panel). The bottom-right glow was dropped so
        // the card stays predominantly near-black.
        Positioned(
          left: -30,
          top: -30,
          child: Container(
            width: 190,
            height: 150,
            decoration: const BoxDecoration(
              gradient: RadialGradient(
                center: Alignment.topLeft,
                radius: 1.0,
                colors: [Color(0x3D7C3AA6), Colors.transparent], // plum ~0.24
                stops: [0.0, 1.0],
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: Align(
              alignment: const Alignment(-0.9, 0.05),
              child: Container(
                width: 138,
                height: 138,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [gold.withValues(alpha: 0.22), Colors.transparent],
                    stops: const [0.0, 1.0],
                  ),
                ),
              ),
            ),
          ),
        ),
        Padding(
          // Tight vertical padding keeps this a compact HUD (~15% shorter than
          // before) even with the larger badge; the badge is the height driver.
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // The illustrated rank crest - the main visual element of the
                // HUD (progression badges are collectible rank emblems), so it
                // is the largest thing here even as everything else is quieted.
                RankBadge(title: title, size: 74),
                const SizedBox(width: 12),
                Expanded(child: rankColumn),
                if (_rank != null) ...[
                  const SizedBox(width: 8),
                  // Thin subtle vertical divider (a faint purple-gray).
                  Container(
                    width: 1,
                    margin: const EdgeInsets.symmetric(vertical: 3),
                    color: const Color(0xFFB48AD4).withValues(alpha: 0.22),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'GLOBAL RANK',
                        style: text.labelSmall?.copyWith(
                          color: const Color(0xFF8C8C8C), // muted gray
                          letterSpacing: 0.7,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        // Real data: the live count aggregation, not a
                        // placeholder (a top-rated account genuinely shows #1).
                        '#${_comma(_rank!)}',
                        style: text.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w900,
                          color: gold,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 2),
                  // A small, conventional, MUTED chevron - just a tap
                  // affordance, not a bright gold decorative element.
                  Icon(Icons.chevron_right,
                      color: Colors.white.withValues(alpha: 0.45), size: 18),
                ],
              ],
            ),
          ),
        ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const LeaderboardScreen()),
          ),
          // A thin PURPLE/MAGENTA frame with a restrained purple glow halo.
          // Replaces the gold border so the Player Status card reads as player
          // identity, distinct from the gold/amber Tournament event card. The
          // GOLD stays only on the data (badge glow, XP fill, rank number,
          // chevron). Drawn as a purple gradient fill inset by the border
          // thickness (Flutter has no native gradient/glowing border).
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              // Subtler purple border ring - a dimmer, less saturated plum than
              // the old bright magenta so the frame reads as a quiet accent.
              gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF6E3A94), Color(0xFF512873), Color(0xFF381C50)],
                stops: [0.0, 0.5, 1.0],
              ),
              boxShadow: [
                // Depth.
                const BoxShadow(
                  color: Colors.black,
                  blurRadius: 14,
                  offset: Offset(0, 6),
                ),
                // One very subtle purple edge glow - present for premium depth,
                // nowhere near a neon halo (reduced from the old bright glow).
                BoxShadow(
                  color: const Color(0xFFB44AD4).withValues(alpha: 0.14),
                  blurRadius: 14,
                  spreadRadius: -4,
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.all(1.5), // thin purple border
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: DecoratedBox(
                  // Rich near-black / very dark navy-purple base; the purple
                  // edge illumination and the gold badge glow are layered in
                  // `content`, and the centre stays predominantly dark.
                  decoration: const BoxDecoration(
                    // Near-black base with only a faint purple-navy cast at the
                    // top-left, falling to true near-black. The purple is an
                    // accent (reinforced by the single top-left glow above),
                    // not a bright panel - the card stays quieter than the
                    // Tournament artwork below it.
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Color(0xFF17122A),
                        Color(0xFF0C0A14),
                        Color(0xFF08070C),
                      ],
                      stops: [0.0, 0.5, 1.0],
                    ),
                  ),
                  child: content,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The XP progress track - thin, long, clean: a restrained gold fill on a
/// dark-gray rail, no glossy sheen or glow. Reads premium rather than like a
/// generic thick progress bar.
class _XpBar extends StatelessWidget {
  const _XpBar({required this.fill});

  final double fill;

  @override
  Widget build(BuildContext context) {
    const h = 7.0;
    final f = fill.clamp(0.0, 1.0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(h / 2),
      child: Stack(
        children: [
          // Track: a flat dark-gray rail. This full-width child sizes the bar.
          const SizedBox(
            width: double.infinity,
            height: h,
            child: ColoredBox(color: Color(0xFF2A2A2E)),
          ),
          // Restrained gold fill: a clean left-to-right gradient, no glow, no
          // white sheen - quiet and premium on a thin bar.
          Positioned.fill(
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: f,
              child: const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [Color(0xFFF2CE5A), Color(0xFFD9A21E)],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Thousands separators, so "1200" reads "1,200" like the reference.
String _comma(int n) {
  final s = n.abs().toString();
  final buf = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return buf.toString();
}
