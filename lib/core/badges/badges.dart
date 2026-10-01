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

/// Which already-tracked stat a badge keys off. The `top*` metrics are the
/// permanent "ever been #1 in an emoji" awards: they read 1/0 from the
/// server-set `emojiTopAwards` flags (see functions/emojiTopAwards.js) rather
/// than a counter, so threshold 1 means "flag is set".
enum BadgeMetric {
  wins,
  battlesPlayed,
  voteStreakDays,
  topFire,
  topClever,
  topBoring,
  topTrash,
}

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
    this.emoji,
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

  /// For the emoji superlative awards: the glyph to render in the medallion
  /// (there is no PNG for these). Null for ordinary PNG/icon badges.
  final String? emoji;

  bool earnedBy(BadgeStats stats) => stats.value(metric) >= threshold;
}

/// The four emoji superlative award ids. They are earned ONLY from the
/// server-set `emojiTopAwards` flag - never from the client-writable
/// `badges.earned` set - so a client cannot inject them to fake being #1.
const Set<String> kEmojiAwardIds = {
  'emoji_top_fire',
  'emoji_top_clever',
  'emoji_top_boring',
  'emoji_top_trash',
};

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
    // id kept stable (earned badges store it); title renamed off "Regular"
    // so it no longer collides with the Regular RANK tier shown right above
    // it on the profile.
    id: 'battles_regular',
    title: 'Road Dog',
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
  // Emoji superlative awards - permanent "ever been #1 in the whole league for
  // this emoji". Earned-and-kept via the server-set emojiTopAwards flag. Two to
  // chase (🔥/🧠), two worn for self-aware comedy (🥱/💩).
  BadgeDef(
    id: 'emoji_top_fire',
    title: 'The Inferno',
    earnedDesc: 'Held the most 🔥 in the league',
    lockedHint: 'Be #1 for 🔥 in the league',
    metric: BadgeMetric.topFire,
    threshold: 1,
    prestige: 90,
    emoji: '🔥',
  ),
  BadgeDef(
    id: 'emoji_top_clever',
    title: 'The Mastermind',
    earnedDesc: 'Held the most 🧠 in the league',
    lockedHint: 'Be #1 for 🧠 in the league',
    metric: BadgeMetric.topClever,
    threshold: 1,
    prestige: 90,
    emoji: '🧠',
  ),
  BadgeDef(
    id: 'emoji_top_boring',
    title: 'The Snooze',
    earnedDesc: 'Held the most 🥱 in the league',
    lockedHint: 'Be #1 for 🥱 in the league',
    metric: BadgeMetric.topBoring,
    threshold: 1,
    prestige: 15,
    emoji: '🥱',
  ),
  BadgeDef(
    id: 'emoji_top_trash',
    title: 'Biggest Shit Bag',
    earnedDesc: 'Held the most 💩 in the league',
    lockedHint: 'Be #1 for 💩 in the league',
    metric: BadgeMetric.topTrash,
    threshold: 1,
    prestige: 15,
    emoji: '💩',
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
    this.topFire = false,
    this.topClever = false,
    this.topBoring = false,
    this.topTrash = false,
  });

  final int wins;
  final int battlesPlayed;
  final int voteStreakDays;

  /// The permanent "ever been #1 in this emoji" award flags, from the
  /// server-set `emojiTopAwards` map.
  final bool topFire;
  final bool topClever;
  final bool topBoring;
  final bool topTrash;

  /// careerRankedMatches never resets (season reset zeroes rankedMatchesPlayed
  /// but keeps career), so it is the honest "battles played" for a lifetime
  /// badge; falls back for accounts predating that field.
  factory BadgeStats.fromUser(Map<String, dynamic>? user) {
    final u = user ?? const {};
    final streak = u['voteStreak'];
    final streakDays = streak is Map ? (streak['days'] as num?)?.toInt() ?? 0 : 0;
    final awards = u['emojiTopAwards'];
    bool flag(String k) => awards is Map && awards[k] == true;
    return BadgeStats(
      wins: (u['wins'] as num?)?.toInt() ?? 0,
      battlesPlayed: (u['careerRankedMatches'] as num?)?.toInt() ??
          (u['rankedMatchesPlayed'] as num?)?.toInt() ??
          0,
      voteStreakDays: streakDays,
      topFire: flag('fire'),
      topClever: flag('clever'),
      topBoring: flag('boring'),
      topTrash: flag('trash'),
    );
  }

  int value(BadgeMetric m) => switch (m) {
        BadgeMetric.wins => wins,
        BadgeMetric.battlesPlayed => battlesPlayed,
        BadgeMetric.voteStreakDays => voteStreakDays,
        BadgeMetric.topFire => topFire ? 1 : 0,
        BadgeMetric.topClever => topClever ? 1 : 0,
        BadgeMetric.topBoring => topBoring ? 1 : 0,
        BadgeMetric.topTrash => topTrash ? 1 : 0,
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
  // `badges.earned` is client-writable, so the emoji superlative awards must
  // NOT be grantable through it - they come solely from the server-set
  // emojiTopAwards flag (via qualifyingBadgeIds below). Strip any a client
  // tried to inject.
  stored.removeAll(kEmojiAwardIds);
  return stored..addAll(qualifyingBadgeIds(BadgeStats.fromUser(user)));
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
