/**
 * Per-player emoji ratings - the audience-feedback ecosystem that replaced
 * the Best-Round feature and the freeform clip reactions (developer's call,
 * 2026-09-23).
 *
 * At the end of a battle every judge picks ONE emoji for EACH player, right
 * after choosing the winner. Those pile up per player (users.emojiCounts) and
 * become the player's identity: profile flair, badges of honour to chase, a
 * "Hottest" board, and an auto-derived nickname from their emoji mix.
 *
 * This is deliberately a SECOND status axis alongside the skill rank - the
 * developer chose it knowing it overrides the one-status-ladder and
 * no-public-negatives guardrails. Kept a PURE module so the whole thing is
 * unit-testable without Firestore.
 */

/**
 * The four ratings, with meanings fixed by the developer. Two to chase, two
 * to avoid. Order is the display order (positives first).
 */
const RATINGS = {
  fire: {emoji: "\u{1F525}", label: "Fire", blurb: "Overall great performance", positive: true},
  clever: {emoji: "\u{1F9E0}", label: "Clever", blurb: "Smart / original material", positive: true},
  boring: {emoji: "\u{1F971}", label: "Boring", blurb: "Didn't entertain me", positive: false},
  trash: {emoji: "\u{1F4A9}", label: "Trash", blurb: "Overall bad performance", positive: false},
};

/** The rating keys, in display order. */
const RATING_KEYS = Object.keys(RATINGS);

/** Whether a string is one of the allowed rating keys. */
function isRating(key) {
  return typeof key === "string" && Object.prototype.hasOwnProperty.call(RATINGS, key);
}

/** A zeroed count map, so callers never deal with undefined keys. */
function emptyCounts() {
  const c = {};
  for (const k of RATING_KEYS) c[k] = 0;
  return c;
}

/** Reads an emojiCounts map off a user doc, tolerating a missing/partial map. */
function countsOf(user) {
  const raw = (user && user.emojiCounts) || {};
  const c = emptyCounts();
  for (const k of RATING_KEYS) {
    const n = Number(raw[k]);
    if (Number.isFinite(n) && n > 0) c[k] = Math.floor(n);
  }
  return c;
}

const NICKNAME_MIN_RATINGS = 12;

/**
 * A fun, auto-derived nickname from a player's emoji mix. Pure and
 * deterministic. Returns null until there's enough signal
 * (NICKNAME_MIN_RATINGS), so a nickname means something rather than being
 * assigned on a single vote.
 *
 * It reads the two most-received emojis (top1, top2) plus a "polarizing"
 * special case (strong on BOTH a positive and a negative), which is a real
 * comedic identity - loved by some, hated by others.
 */
function nicknameFor(user) {
  const c = countsOf(user);
  const total = RATING_KEYS.reduce((s, k) => s + c[k], 0);
  if (total < NICKNAME_MIN_RATINGS) return null;

  // Polarizing means the EXTREMES: some judges thought you killed it (fire),
  // others thought you were terrible (trash). Boring is "meh", not hate, so it
  // does not count here - a clever-but-boring player is dry, not divisive.
  if (c.fire >= total / 4 && c.trash >= total / 4) {
    return "Love / Hate";
  }

  const ranked = RATING_KEYS.slice().sort((a, b) => c[b] - c[a]);
  const t1 = ranked[0];
  const t2 = ranked[1];

  // Keyed by the dominant emoji, refined by the runner-up.
  const NICKS = {
    fire: {clever: "The Headliner", boring: "All Flash", trash: "Hit or Miss", fire: "On Fire"},
    clever: {fire: "The Mastermind", boring: "Too Smart for the Room", trash: "Cult Favourite", clever: "Big Brain"},
    boring: {fire: "Slow Burn", clever: "Dry", trash: "Human Ambien", boring: "The Snooze"},
    trash: {fire: "Trainwreck", clever: "Misunderstood", boring: "Dumpster Fire", trash: "The Stinker"},
  };
  return (NICKS[t1] && NICKS[t1][t2]) || RATINGS[t1].label;
}

/**
 * Badge tiers for ALL FOUR emojis (developer's call, 2026-09-28: "I want all
 * the badges in the profile, not just the good ones"). You CHASE 🔥/🧠 and you
 * DODGE 🥱/💩 - the negatives are marks worn for self-aware comedy, not honours,
 * so the client renders them in a tarnished (non-gold) medallion. Tiers are
 * thresholds of that emoji's count; PLACEHOLDER numbers, to tune against real
 * earning rates like every other economy figure.
 */
const BADGE_TIERS = {
  fire: [
    {at: 10, id: "fire_1", title: "Spark"},
    {at: 50, id: "fire_2", title: "Blaze"},
    {at: 150, id: "fire_3", title: "Inferno"},
  ],
  clever: [
    {at: 10, id: "clever_1", title: "Bright"},
    {at: 50, id: "clever_2", title: "Brainiac"},
    {at: 150, id: "clever_3", title: "Mastermind"},
  ],
  boring: [
    {at: 10, id: "boring_1", title: "Snoozer"},
    {at: 50, id: "boring_2", title: "Sleeper"},
    {at: 150, id: "boring_3", title: "Comatose"},
  ],
  trash: [
    {at: 10, id: "trash_1", title: "Rotten"},
    {at: 50, id: "trash_2", title: "Dumpster"},
    {at: 150, id: "trash_3", title: "Biohazard"},
  ],
};

/** The emoji badges a player has earned, given their counts. */
function earnedEmojiBadges(user) {
  const c = countsOf(user);
  const ids = [];
  for (const key of Object.keys(BADGE_TIERS)) {
    for (const tier of BADGE_TIERS[key]) {
      if (c[key] >= tier.at) ids.push(tier.id);
    }
  }
  return ids;
}

module.exports = {
  RATINGS,
  RATING_KEYS,
  isRating,
  emptyCounts,
  countsOf,
  nicknameFor,
  NICKNAME_MIN_RATINGS,
  BADGE_TIERS,
  earnedEmojiBadges,
};
