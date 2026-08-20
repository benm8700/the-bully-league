const {RANK_TIERS, GOAT_TITLE, GOAT_POOL_SIZE, STARTING_RATING} =
  require("./rating");

/**
 * The Laugh Meter (CLAUDE.md's Display decision).
 *
 * The Elo number is invisible plumbing; what a player sees is a gauge
 * that fills toward the next rank, labelled with the rank title. The
 * exact thresholds stay HIDDEN - the decision is explicit that the
 * criteria are not shown but a partial progress indicator is, which is
 * why this returns a fraction and a mood rather than "38 rating to go".
 *
 * SERVED RATHER THAN COMPUTED ON THE CLIENT, deliberately. The ladder
 * lives here, and this project has already been bitten by duplicating it:
 * the rank-change copy was first written client-side with a hand-copied
 * tier order that omitted Headliner, which would have called a promotion
 * a demotion for anyone near it. One definition, one place.
 *
 * THE PART THAT TOOK THOUGHT: promotion needs BOTH a rating threshold and
 * a minimum number of ranked matches, so progress is two-dimensional. A
 * meter showing only rating would sit visually FULL while the player
 * stubbornly failed to promote - which reads as a broken gauge, not as a
 * missing requirement. So the fill always shows whichever constraint is
 * actually binding, and says which one it is.
 */

/** How the meter is described when it cannot honestly show progress. */
const GOAT_STATE = "goat";
const CONTENDER_STATE = "contender";
const CLIMBING_STATE = "climbing";

/** The tier a title sits at, or -1. */
function tierIndexOf(title) {
  return RANK_TIERS.findIndex((t) => t.title === title);
}

/** Progress between two bounds, clamped, with a degenerate span treated
 * as already complete rather than as a division by zero. */
function fraction(value, from, to) {
  if (!(to > from)) return 1;
  const p = (value - from) / (to - from);
  return Math.max(0, Math.min(1, p));
}

/**
 * The whole meter for one player.
 *
 * Pure, so every branch is testable without Firestore - including the
 * ones that are awkward to reach in real data, like a player sitting at
 * Hall of Famer or holding a GOAT slot.
 *
 * @param {object} user the account
 * @return {object} what the gauge should show
 */
function laughMeter(user) {
  const rating = Number(user?.rating);
  const safeRating = Number.isFinite(rating) ? rating : STARTING_RATING;
  const played = Number(user?.rankedMatchesPlayed);
  const safePlayed = Number.isFinite(played) && played > 0 ?
    Math.floor(played) : 0;
  const title = user?.rankTitle ?? RANK_TIERS[0].title;

  // GOAT is the one rank that is a live leaderboard POSITION rather than
  // a threshold, so there is no "next" to fill toward and no honest
  // progress to show. The meter is simply full, and the copy talks about
  // holding the slot rather than climbing - a player here can be demoted
  // without ever losing, purely because somebody else rose.
  if (title === GOAT_TITLE) {
    return {
      title,
      state: GOAT_STATE,
      fill: 1,
      nextTitle: null,
      binding: null,
      matchesRemaining: 0,
      caption: `Top ${GOAT_POOL_SIZE} in the world. Someone is coming for it.`,
    };
  }

  const index = tierIndexOf(title);
  // An unknown or absent title is treated as the floor rather than as an
  // error: every account predating the field reads that way, and a
  // broken-looking gauge is a worse answer than a modest one.
  const current = index >= 0 ? index : 0;
  const next = RANK_TIERS[current + 1] ?? null;

  if (!next) {
    // Hall of Famer. The only thing above is GOAT, which cannot be
    // reached by crossing a number - so showing a fill toward it would be
    // inventing progress that does not exist.
    return {
      title,
      state: CONTENDER_STATE,
      fill: 1,
      nextTitle: GOAT_TITLE,
      binding: "leaderboard",
      matchesRemaining: 0,
      caption: `Only the top ${GOAT_POOL_SIZE} rated players hold GOAT. ` +
        "Out-rank one of them.",
    };
  }

  const here = RANK_TIERS[current];
  const byRating = fraction(safeRating, here.minRating, next.minRating);
  const byMatches = fraction(safePlayed, here.minMatches, next.minMatches);

  // THE BINDING CONSTRAINT WINS. Showing the rating alone would leave a
  // player who has the rating but not the matches staring at a full bar
  // that never promotes them.
  const fill = Math.min(byRating, byMatches);
  const binding = byMatches < byRating ? "matches" : "rating";
  const matchesRemaining = Math.max(0, next.minMatches - safePlayed);

  return {
    title,
    state: CLIMBING_STATE,
    fill,
    nextTitle: next.title,
    binding,
    // Only meaningful when matches are what is holding them back. Stated
    // plainly in that case because it is actionable and reveals nothing
    // about the RATING thresholds, which are the part deliberately
    // hidden - "play two more" helps; "38 rating to go" would not.
    matchesRemaining: binding === "matches" ? matchesRemaining : 0,
    caption: binding === "matches" ?
      matchesCaption(matchesRemaining, next.title) :
      ratingCaption(fill, next.title),
  };
}

function matchesCaption(remaining, nextTitle) {
  if (remaining <= 0) return `${nextTitle} is within reach.`;
  return `${remaining} more ranked ${remaining === 1 ? "battle" : "battles"} ` +
    `before ${nextTitle} is on the table.`;
}

/**
 * Qualitative, never numeric.
 *
 * A percentage would let anyone back-compute the thresholds the hidden-
 * criteria decision exists to keep hidden, and it would turn a mood into
 * a spreadsheet.
 */
function ratingCaption(fill, nextTitle) {
  if (fill >= 0.85) return `${nextTitle} is close.`;
  if (fill >= 0.5) return `Halfway to ${nextTitle}.`;
  if (fill >= 0.15) return `Climbing toward ${nextTitle}.`;
  return `${nextTitle} is a long way off. Go win something.`;
}

module.exports = {
  laughMeter,
  GOAT_STATE,
  CONTENDER_STATE,
  CLIMBING_STATE,
};
