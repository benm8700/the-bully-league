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
function applyEloChange(ratingSelf, ratingOpponent, actualScore) {
  const k = kFactorForRating(ratingSelf);
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
  GOAT_TITLE,
  GOAT_POOL_SIZE,
  GOAT_ELIGIBLE_MIN_MATCHES,
  kFactorForRating,
  expectedScore,
  applyEloChange,
  computeBaseRankTitle,
};
