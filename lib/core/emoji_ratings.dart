/// Per-player emoji ratings - the audience-feedback ecosystem that replaced
/// the Best-Round feature and the freeform reactions (developer's call,
/// 2026-09-23).
///
/// MIRRORS functions/emojiRatings.js - the keys, order, meanings, the
/// nickname logic and its thresholds must stay in step with the server, which
/// is the authority (it validates the ballot and tallies the counts). If one
/// side changes, change both.
library;

class EmojiRating {
  const EmojiRating(this.key, this.emoji, this.label, this.blurb, this.positive);

  final String key;
  final String emoji;
  final String label;
  final String blurb;

  /// Fire and Clever are the two to chase; Boring and Trash are to avoid.
  final bool positive;
}

/// The four ratings, in display order (positives first).
const List<EmojiRating> kEmojiRatings = [
  EmojiRating('fire', '\u{1F525}', 'Fire', 'Overall great performance', true),
  EmojiRating('clever', '\u{1F9E0}', 'Clever', 'Smart / original material', true),
  EmojiRating('boring', '\u{1F971}', 'Boring', "Didn't entertain me", false),
  EmojiRating('trash', '\u{1F4A9}', 'Trash', 'Overall bad performance', false),
];

/// The emoji character for a rating key, or empty if unknown.
String emojiCharFor(String key) {
  for (final r in kEmojiRatings) {
    if (r.key == key) return r.emoji;
  }
  return '';
}

/// Reads one rating's count off an emojiCounts map, tolerating a
/// missing/partial map.
int emojiCountOf(Map<String, dynamic>? counts, String key) {
  final v = counts?[key];
  return v is num && v > 0 ? v.toInt() : 0;
}

/// Total ratings a player has received.
int emojiTotalOf(Map<String, dynamic>? counts) {
  var t = 0;
  for (final r in kEmojiRatings) {
    t += emojiCountOf(counts, r.key);
  }
  return t;
}

/// Whole-number percentages per rating, summing to ~100 (largest-remainder
/// rounding so they add up). Returns all-zero when there are no ratings yet.
Map<String, int> emojiPercentsOf(Map<String, dynamic>? counts) {
  final total = emojiTotalOf(counts);
  final out = {for (final r in kEmojiRatings) r.key: 0};
  if (total == 0) return out;
  // Largest-remainder: floor each, then hand the leftover points to the
  // biggest fractional parts, so the row always reads as 100%.
  final exact = <String, double>{};
  final floors = <String, int>{};
  var used = 0;
  for (final r in kEmojiRatings) {
    final e = emojiCountOf(counts, r.key) * 100 / total;
    exact[r.key] = e;
    floors[r.key] = e.floor();
    used += floors[r.key]!;
  }
  var remaining = 100 - used;
  final byFrac = kEmojiRatings.toList()
    ..sort((a, b) => (exact[b.key]! - exact[b.key]!.floor())
        .compareTo(exact[a.key]! - exact[a.key]!.floor()));
  for (final r in byFrac) {
    if (remaining <= 0) break;
    floors[r.key] = floors[r.key]! + 1;
    remaining--;
  }
  return floors;
}

const int kEmojiNicknameMin = 12;

/// A fun, auto-derived nickname from a player's emoji mix. Mirrors
/// nicknameFor in functions/emojiRatings.js. Null until there's enough signal.
String? emojiNicknameOf(Map<String, dynamic>? counts) {
  final c = {for (final r in kEmojiRatings) r.key: emojiCountOf(counts, r.key)};
  final total = c.values.fold(0, (s, v) => s + v);
  if (total < kEmojiNicknameMin) return null;

  // Polarizing: killed it for some (fire), terrible for others (trash).
  if (c['fire']! >= total / 4 && c['trash']! >= total / 4) return 'Love / Hate';

  final ranked = c.keys.toList()..sort((a, b) => c[b]!.compareTo(c[a]!));
  final t1 = ranked[0], t2 = ranked[1];
  const nicks = {
    'fire': {'clever': 'The Headliner', 'boring': 'All Flash', 'trash': 'Hit or Miss', 'fire': 'On Fire'},
    'clever': {'fire': 'The Mastermind', 'boring': 'Too Smart for the Room', 'trash': 'Cult Favourite', 'clever': 'Big Brain'},
    'boring': {'fire': 'Slow Burn', 'clever': 'Dry', 'trash': 'Human Ambien', 'boring': 'The Snooze'},
    'trash': {'fire': 'Trainwreck', 'clever': 'Misunderstood', 'boring': 'Dumpster Fire', 'trash': 'The Stinker'},
  };
  return nicks[t1]?[t2] ??
      kEmojiRatings.firstWhere((r) => r.key == t1).label;
}

/// One tier of an emoji "badge of honour". MIRRORS BADGE_TIERS in
/// functions/emojiRatings.js - ids, thresholds and titles must match.
class EmojiBadgeTier {
  const EmojiBadgeTier(this.id, this.at, this.title);

  /// Stable id (matches the server), e.g. 'fire_2'.
  final String id;

  /// The emoji count at which this tier is earned.
  final int at;
  final String title;
}

/// Badge tiers for the two POSITIVE emojis only - you chase 🔥 and 🧠, there
/// are no badges for being boring or trash. PLACEHOLDER thresholds, tuned
/// server-side; keep in step with BADGE_TIERS in functions/emojiRatings.js.
const Map<String, List<EmojiBadgeTier>> kEmojiBadgeTiers = {
  'fire': [
    EmojiBadgeTier('fire_1', 10, 'Spark'),
    EmojiBadgeTier('fire_2', 50, 'Blaze'),
    EmojiBadgeTier('fire_3', 150, 'Inferno'),
  ],
  'clever': [
    EmojiBadgeTier('clever_1', 10, 'Bright'),
    EmojiBadgeTier('clever_2', 50, 'Brainiac'),
    EmojiBadgeTier('clever_3', 150, 'Mastermind'),
  ],
};

/// The display state of one emoji's badge track: the highest tier earned (or
/// null), the next tier still to earn (or null when maxed), and the live count.
class EmojiBadgeSlot {
  const EmojiBadgeSlot({
    required this.emojiKey,
    required this.emoji,
    required this.count,
    required this.earnedTier,
    required this.nextTier,
  });

  /// 'fire' or 'clever'.
  final String emojiKey;
  final String emoji;
  final int count;

  /// Highest earned tier, or null if none earned yet.
  final EmojiBadgeTier? earnedTier;

  /// Next tier still to earn, or null once every tier is earned.
  final EmojiBadgeTier? nextTier;

  bool get earned => earnedTier != null;
  bool get isMaxed => nextTier == null;

  /// The tier to display: the highest earned, else the first (locked) tier.
  EmojiBadgeTier get displayTier =>
      earnedTier ?? kEmojiBadgeTiers[emojiKey]!.first;
}

/// One slot per positive emoji, in display order (fire, then clever).
List<EmojiBadgeSlot> emojiBadgeSlots(Map<String, dynamic>? counts) {
  final slots = <EmojiBadgeSlot>[];
  for (final entry in kEmojiBadgeTiers.entries) {
    final key = entry.key;
    final tiers = entry.value;
    final count = emojiCountOf(counts, key);
    EmojiBadgeTier? earned;
    EmojiBadgeTier? next;
    for (final tier in tiers) {
      if (count >= tier.at) {
        earned = tier;
      } else {
        next ??= tier;
      }
    }
    slots.add(EmojiBadgeSlot(
      emojiKey: key,
      emoji: emojiCharFor(key),
      count: count,
      earnedTier: earned,
      nextTier: next,
    ));
  }
  return slots;
}
