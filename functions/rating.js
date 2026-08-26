/**
 * Chess-style Elo rating + 10-rank tier ladder, per CLAUDE.md's Ranking
 * System section. All thresholds/K-factor bands below are PLACEHOLDER
 * numbers - CLAUDE.md explicitly says these "need real tuning once
 * analytics data exists" and were never decided precisely. Picked so that
 * the starting rating (1200) lands at rank 5 of 10 ("Door Guy") once a
 * player has enough ranked matches to be promoted past Average Joe -
 * satisfies the "start in the middle of the ladder" requirement.
 */

const STARTING_RATING = 1200;
const RATING_FLOOR = 100;

// Ranks 1-9 (fixed thresholds). GOAT (rank 10) is NOT here - it's a live
// top-5-by-rating leaderboard position, not a threshold (see CLAUDE.md's
// "IMPORTANT EXCEPTION" note).
const RANK_TIERS = [
  {title: "Average Joe", minRating: 0, minMatches: 0},
  {title: "Open Micer", minRating: 1000, minMatches: 3},
  {title: "Class Clown", minRating: 1080, minMatches: 6},
  {title: "The Funny Friend", minRating: 1150, minMatches: 9},
  {title: "Door Guy", minRating: 1200, minMatches: 12},
  {title: "Regular", minRating: 1300, minMatches: 15},
  {title: "Headliner", minRating: 1450, minMatches: 20},
  {title: "Legend", minRating: 1600, minMatches: 25},
  {title: "Hall of Famer", minRating: 1800, minMatches: 30},
];

/**
 * The XP ladder - the VISIBLE progression, decided 2026-08-25.
 *
 * Titles are earned by accumulating XP and KEPT: XP only ever rises (it is
 * the career-points total, see functions/points.js), so a player's title
 * only ever rises with it. This is the deliberate opposite of the Elo
 * ladder above, which floats up and down. The retention argument is that
 * you are always working toward the next title and can never be knocked
 * back down to grind it again - a losing streak costs rating, never a
 * title you already earned.
 *
 * ELO IS NOT GONE - it is now HIDDEN. It still drives matchmaking (so
 * pairing stays skill-appropriate) and it still decides GOAT (below). What
 * changed is that Elo no longer drives the nine earned titles and is no
 * longer shown to the player.
 *
 * XP SOURCES are ranked/tournament play, the win bonus, capped judging,
 * and the daily engagement bonuses - i.e. exactly what already credits
 * career points, minus casual (exhibition) and friend battles, which no
 * longer pay. See the awardPoints title hook in points.js.
 *
 * THRESHOLDS ARE PLACEHOLDERS, like the Elo thresholds and the point
 * rates. The curve steepens deliberately (50, 100, 200, 350, 500, 800,
 * 1200, 1800) so the top stays scarce, but the absolute numbers want
 * tuning against real earning rates once there is analytics data. New
 * players start at Average Joe (0 XP) and climb - unlike the old Elo
 * placement that started mid-ladder, because XP only moves upward.
 */
const XP_TIERS = [
  {title: "Average Joe", minXp: 0},
  {title: "Open Micer", minXp: 50},
  {title: "Class Clown", minXp: 150},
  {title: "The Funny Friend", minXp: 350},
  {title: "Door Guy", minXp: 700},
  {title: "Regular", minXp: 1200},
  {title: "Headliner", minXp: 2000},
  {title: "Legend", minXp: 3200},
  {title: "Hall of Famer", minXp: 5000},
];

/** XP at which a player is eligible to be swapped into a GOAT slot - the
 * top of the earned ladder. Mirrors the old "must otherwise qualify for
 * Hall of Famer" rule, now measured in XP rather than matches. */
const GOAT_ELIGIBLE_MIN_XP = XP_TIERS[XP_TIERS.length - 1].minXp;

/**
 * The earned title for a given XP total (ranks 1-9). Does NOT apply the
 * GOAT overlay, which is a live top-5 Elo position resolved by
 * syncGoatTier. Because XP only rises, this only ever returns a higher
 * title over time.
 */
function computeTitleFromXp(xp) {
  const value = Number.isFinite(Number(xp)) ? Number(xp) : 0;
  let title = XP_TIERS[0].title;
  for (const tier of XP_TIERS) {
    if (value >= tier.minXp) title = tier.title;
  }
  return title;
}

const GOAT_TITLE = "GOAT";
const GOAT_POOL_SIZE = 5;
// Only players who'd otherwise qualify for Hall of Famer are even eligible
// to be swapped in as GOAT - prevents a low-sample-size account with a
// lucky streak from briefly topping the leaderboard by rating alone.
const GOAT_ELIGIBLE_MIN_MATCHES = RANK_TIERS[RANK_TIERS.length - 1].minMatches;

/** Variable K-factor: higher for newer/lower-rated players (faster early
 * movement), lower for high-rated players (every win has to be earned) -
 * see CLAUDE.md's K-factor notes. Banded by rating directly rather than by
 * computed tier, to avoid a circular dependency between the two. */
function kFactorForRating(rating) {
  if (rating >= 1600) return 16;
  if (rating >= 1200) return 28;
  return 40;
}

/**
 * Vote weight at which a result is treated as fully evidenced.
 *
 * PLACEHOLDER, like the rank thresholds - wants tuning once there's real
 * voting volume to look at.
 */
const FULL_CONFIDENCE_WEIGHT = 10;

/**
 * How much a result should be trusted, given how many people actually
 * judged it. Scales the K-factor, so a thinly-judged match moves rating
 * proportionally less.
 *
 * WHY THIS RATHER THAN A MINIMUM-VOTE THRESHOLD. Requiring N votes before
 * a match counts creates a cliff: below it nothing happens, above it the
 * full swing, so there's an incentive to farm exactly enough votes and no
 * reason to care beyond that. Worse, at private-beta volume most matches
 * would close under the threshold, nobody's rating would move, nobody
 * would climb, and the prestige loop the whole ranking system exists to
 * drive would never start - protecting the ladder by switching it off.
 *
 * Scaling instead means every match counts for something, proportional to
 * the evidence behind it. It also blunts collusion without banning
 * anything: at the time this was written a single friendly vote moved 14
 * points at 1200 rating, and 29 such wins reached the Headliner
 * threshold. Under this curve that same climb needs roughly ten times as
 * many matches.
 *
 * It becomes a no-op at real volume, which is the point - it's a
 * correction for thin evidence, not a permanent damper.
 */
function voteConfidence(totalWeight, fullConfidenceWeight = FULL_CONFIDENCE_WEIGHT) {
  if (!Number.isFinite(totalWeight) || totalWeight <= 0) return 0;
  const target = Number.isFinite(fullConfidenceWeight) && fullConfidenceWeight > 0 ?
    fullConfidenceWeight : FULL_CONFIDENCE_WEIGHT;
  return Math.min(1, totalWeight / target);
}

/** Standard Elo expected-score formula. */
function expectedScore(ratingSelf, ratingOpponent) {
  return 1 / (1 + Math.pow(10, (ratingOpponent - ratingSelf) / 400));
}

/**
 * Returns the new rating for a player given the match outcome.
 * actualScore: 1 for win, 0 for loss. Ties are NOT passed through this
 * function at all - CLAUDE.md decided ties cause zero rating change for
 * either player, not the standard Elo 0.5-0.5 treatment.
 */
function applyEloChange(ratingSelf, ratingOpponent, actualScore, confidence = 1) {
  // Two multipliers on K, for two different kinds of uncertainty: the
  // rating band covers how settled this PLAYER is, and confidence covers
  // how settled this RESULT is. Defaults to 1 so existing callers and
  // tests that don't care about vote volume behave exactly as before.
  const k = kFactorForRating(ratingSelf) * Math.max(0, Math.min(1, confidence));
  const expected = expectedScore(ratingSelf, ratingOpponent);
  const newRating = ratingSelf + k * (actualScore - expected);
  return Math.max(RATING_FLOOR, Math.round(newRating));
}

/** Rank title for ranks 1-9 only (fixed thresholds) - does NOT apply the
 * GOAT top-5 override, which needs a cross-user query (see
 * syncGoatTier in index.js). */
function computeBaseRankTitle(rating, rankedMatchesPlayed) {
  let title = RANK_TIERS[0].title;
  for (const tier of RANK_TIERS) {
    if (rating >= tier.minRating && rankedMatchesPlayed >= tier.minMatches) {
      title = tier.title;
    }
  }
  return title;
}

module.exports = {
  STARTING_RATING,
  RATING_FLOOR,
  RANK_TIERS,
  XP_TIERS,
  GOAT_TITLE,
  GOAT_POOL_SIZE,
  GOAT_ELIGIBLE_MIN_MATCHES,
  GOAT_ELIGIBLE_MIN_XP,
  kFactorForRating,
  voteConfidence,
  FULL_CONFIDENCE_WEIGHT,
  expectedScore,
  applyEloChange,
  computeBaseRankTitle,
  computeTitleFromXp,
};
