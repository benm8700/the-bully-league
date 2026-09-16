/// Earnable badges (achievements) - DESIGN per the 2026-09-15 grilling.
///
/// GUARDRAIL (one-status-ladder rule): badges are ACHIEVEMENTS, not a second
/// rank. They mark "you did X", never "you rank above Y" - so they must never
/// appear as an ordered ladder or on the Ranks board. They live on the profile
/// (a badge case) plus a single pinnable "featured" badge on the profile
/// header and the pre-match reveal.
///
/// V1 is deliberately limited to badges that derive from data ALREADY on the
/// user document (wins, career matches, vote streak), so earning is a pure
/// function of stats and backfill is automatic - no new counters, no backend
/// changes. Tournament / lifetime-votes / night-owl / recruiter badges need
/// small server counters and are a planned fast follow.
///
/// Badges are PURE RECOGNITION - earning one pays no points and has no
/// gameplay effect, so the earned set and the featured pick are plain client
/// state (like the equipped skin); nothing needs a server guard.
library;

/// Which already-tracked stat a badge keys off.
enum BadgeMetric { wins, battlesPlayed, voteStreakDays }

/// One badge definition. Tiered badges share a [family] and differ by [level]
/// and [threshold]; standalone badges have a null family and level 1.
class BadgeDef {
  const BadgeDef({
    required this.id,
    required this.title,
    required this.earnedDesc,
    required this.lockedHint,
    required this.metric,
    required this.threshold,
    required this.prestige,
    this.family,
    this.level = 1,
  });

  /// Unique id; also the art file base name: `assets/badges/<id>.png`.
  final String id;
  final String title;

  /// Shown when earned (past tense), e.g. "Won 50 battles".
  final String earnedDesc;

  /// Shown when locked, e.g. "Win 50 battles".
  final String lockedHint;

  final BadgeMetric metric;
  final int threshold;

  /// Higher = rarer/more impressive. Used to auto-pick the "best" earned
  /// badge as the default featured one.
  final int prestige;

  /// Tiered-family key, or null for a standalone badge.
  final String? family;

  /// 1-based tier within the family (1 for standalone).
  final int level;

  bool earnedBy(BadgeStats stats) => stats.value(metric) >= threshold;
}

/// The V1 badge catalogue, in a stable display order.
const List<BadgeDef> kBadges = [
  BadgeDef(
    id: 'first_blood',
    title: 'First Blood',
    earnedDesc: 'Won your first battle',
    lockedHint: 'Win your first battle',
    metric: BadgeMetric.wins,
    threshold: 1,
    prestige: 10,
  ),
  // Wins family (tiered).
  BadgeDef(
    id: 'wins_contender',
    title: 'Contender',
    earnedDesc: 'Won 10 battles',
    lockedHint: 'Win 10 battles',
    metric: BadgeMetric.wins,
    threshold: 10,
    prestige: 30,
    family: 'wins',
    level: 1,
  ),
  BadgeDef(
    id: 'wins_slayer',
    title: 'Slayer',
    earnedDesc: 'Won 50 battles',
    lockedHint: 'Win 50 battles',
    metric: BadgeMetric.wins,
    threshold: 50,
    prestige: 60,
    family: 'wins',
    level: 2,
  ),
  BadgeDef(
    id: 'wins_executioner',
    title: 'Executioner',
    earnedDesc: 'Won 150 battles',
    lockedHint: 'Win 150 battles',
    metric: BadgeMetric.wins,
    threshold: 150,
    prestige: 95,
    family: 'wins',
    level: 3,
  ),
  // Battles-played family (tiered).
  BadgeDef(
    id: 'battles_regular',
    title: 'Regular',
    earnedDesc: 'Played 25 battles',
    lockedHint: 'Play 25 battles',
    metric: BadgeMetric.battlesPlayed,
    threshold: 25,
    prestige: 25,
    family: 'battles',
    level: 1,
  ),
  BadgeDef(
    id: 'battles_veteran',
    title: 'Veteran',
    earnedDesc: 'Played 100 battles',
    lockedHint: 'Play 100 battles',
    metric: BadgeMetric.battlesPlayed,
    threshold: 100,
    prestige: 55,
    family: 'battles',
    level: 2,
  ),
  BadgeDef(
    id: 'loyal_juror',
    title: 'Loyal Juror',
    earnedDesc: 'Judged 7 days running',
    lockedHint: 'Vote 7 days in a row',
    metric: BadgeMetric.voteStreakDays,
    threshold: 7,
    prestige: 40,
  ),
];

BadgeDef? badgeById(String id) {
  for (final b in kBadges) {
    if (b.id == id) return b;
  }
  return null;
}

/// The stats a badge is evaluated against, read from the user document.
class BadgeStats {
  const BadgeStats({
    required this.wins,
    required this.battlesPlayed,
    required this.voteStreakDays,
  });

  final int wins;
  final int battlesPlayed;
  final int voteStreakDays;

  /// careerRankedMatches never resets (season reset zeroes rankedMatchesPlayed
  /// but keeps career), so it is the honest "battles played" for a lifetime
  /// badge; falls back for accounts predating that field.
  factory BadgeStats.fromUser(Map<String, dynamic>? user) {
    final u = user ?? const {};
    final streak = u['voteStreak'];
    final streakDays = streak is Map ? (streak['days'] as num?)?.toInt() ?? 0 : 0;
    return BadgeStats(
      wins: (u['wins'] as num?)?.toInt() ?? 0,
      battlesPlayed: (u['careerRankedMatches'] as num?)?.toInt() ??
          (u['rankedMatchesPlayed'] as num?)?.toInt() ??
          0,
      voteStreakDays: streakDays,
    );
  }

  int value(BadgeMetric m) => switch (m) {
        BadgeMetric.wins => wins,
        BadgeMetric.battlesPlayed => battlesPlayed,
        BadgeMetric.voteStreakDays => voteStreakDays,
      };
}

/// The set of badge ids that currently QUALIFY for these stats (live).
Set<String> qualifyingBadgeIds(BadgeStats stats) =>
    {for (final b in kBadges) if (b.earnedBy(stats)) b.id};

/// The displayed earned set: badges are earned AND KEPT, so this unions the
/// sticky stored set (`badges.earned` on the user doc) with whatever currently
/// qualifies. That keeps e.g. Loyal Juror earned even after a vote streak dips
/// below 7, while still surfacing a freshly-qualifying badge before the
/// stored set has been written.
Set<String> resolveEarnedIds(Map<String, dynamic>? user) {
  final stored = <String>{};
  final badges = user?['badges'];
  if (badges is Map) {
    final e = badges['earned'];
    if (e is List) stored.addAll(e.whereType<String>());
  }
  return stored..addAll(qualifyingBadgeIds(BadgeStats.fromUser(user)));
}

/// The stored featured badge id, or null.
String? storedFeaturedId(Map<String, dynamic>? user) {
  final badges = user?['badges'];
  if (badges is Map) {
    final f = badges['featured'];
    if (f is String && f.isNotEmpty) return f;
  }
  return null;
}

/// The default "featured" badge: the highest-prestige EARNED badge, or null.
BadgeDef? bestEarnedBadge(Set<String> earnedIds) {
  BadgeDef? best;
  for (final b in kBadges) {
    if (earnedIds.contains(b.id) &&
        (best == null || b.prestige > best.prestige)) {
      best = b;
    }
  }
  return best;
}

/// The badge to feature: the stored pin if it is (still) earned, else the best.
BadgeDef? featuredBadge(Map<String, dynamic>? user) {
  final earned = resolveEarnedIds(user);
  final pinned = storedFeaturedId(user);
  if (pinned != null && earned.contains(pinned)) {
    final def = badgeById(pinned);
    if (def != null) return def;
  }
  return bestEarnedBadge(earned);
}

/// A display slot in the badge case: one per standalone badge, and one per
/// tiered family (showing the highest earned tier, or tier 1 when locked,
/// with progress toward the next tier).
class BadgeSlot {
  const BadgeSlot({
    required this.def,
    required this.earned,
    required this.current,
    required this.goal,
  });

  /// The def to display (highest earned tier of a family, else its first tier).
  final BadgeDef def;
  final bool earned;

  /// Progress toward [goal] (the next unearned threshold), for the progress
  /// readout on tiered badges. When maxed, current == goal.
  final int current;
  final int goal;

  bool get isMaxed => current >= goal;
}

/// Builds the ordered list of display slots for the badge case. [earnedIds] is
/// the sticky earned set (see resolveEarnedIds); [stats] supplies live progress
/// numbers.
List<BadgeSlot> badgeSlots(BadgeStats stats, Set<String> earnedIds) {
  final slots = <BadgeSlot>[];
  final seenFamilies = <String>{};
  for (final b in kBadges) {
    if (b.family != null) {
      if (!seenFamilies.add(b.family!)) continue; // one slot per family
      final tiers = kBadges.where((x) => x.family == b.family).toList()
        ..sort((a, c) => a.level.compareTo(c.level));
      // Highest earned tier, or the first tier when none earned.
      BadgeDef display = tiers.first;
      BadgeDef? nextUnearned;
      for (final t in tiers) {
        if (earnedIds.contains(t.id)) {
          display = t;
        } else {
          nextUnearned ??= t;
        }
      }
      final goalDef = nextUnearned ?? tiers.last;
      slots.add(BadgeSlot(
        def: display,
        earned: earnedIds.contains(display.id),
        current: stats.value(b.metric),
        goal: goalDef.threshold,
      ));
    } else {
      slots.add(BadgeSlot(
        def: b,
        earned: earnedIds.contains(b.id),
        current: stats.value(b.metric),
        goal: b.threshold,
      ));
    }
  }
  return slots;
}
