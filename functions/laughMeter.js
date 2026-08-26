const {XP_TIERS, GOAT_TITLE, GOAT_POOL_SIZE, computeTitleFromXp} =
  require("./rating");

/**
 * The Laugh Meter (CLAUDE.md's Display decision), now filling toward the
 * next XP title rather than the next Elo tier (2026-08-25).
 *
 * The player sees a gauge that fills toward the next earned title, labelled
 * with the current title. As of the XP ladder the fill is driven by career
 * XP (functions/points.js), NOT by the hidden Elo rating - which is exactly
 * why this is simpler than it was: XP is one dimension that only rises, so
 * there is no rating-versus-matches binding constraint to reconcile any
 * more, and no down direction to describe.
 *
 * SERVED RATHER THAN COMPUTED ON THE CLIENT, deliberately. The ladder lives
 * in rating.js, and this project has already been bitten by duplicating it:
 * the rank-change copy was first written client-side with a hand-copied
 * tier order that omitted Headliner, which would have called a promotion a
 * demotion for anyone near it. One definition, one place.
 *
 * NO NUMBERS. The exact XP thresholds stay HIDDEN - the decision is
 * explicit that the criteria are not shown but a partial progress indicator
 * is, which is why this returns a fraction and a mood rather than "180 XP to
 * go". Showing the raw XP would let anyone back-compute the thresholds one
 * match at a time.
 */

/** How the meter is described when it cannot honestly show progress. */
const GOAT_STATE = "goat";
const CONTENDER_STATE = "contender";
const CLIMBING_STATE = "climbing";

/** The XP tier a title sits at, or -1. */
function tierIndexOf(title) {
  return XP_TIERS.findIndex((t) => t.title === title);
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
 * Pure, so every branch is testable without Firestore - including the ones
 * that are awkward to reach in real data, like a player sitting at Hall of
 * Famer or holding a GOAT slot.
 *
 * @param {object} user the account
 * @return {object} what the gauge should show
 */
function laughMeter(user) {
  const xpRaw = Number(user?.points);
  const xp = Number.isFinite(xpRaw) && xpRaw > 0 ? xpRaw : 0;
  // The stored title is the source of truth (awardPoints keeps it in step
  // with XP, and syncGoatTier overlays GOAT), but fall back to deriving it
  // from XP for any account whose title has not been written yet.
  const title = user?.rankTitle ?? computeTitleFromXp(xp);

  // GOAT is the one rank that is a live leaderboard POSITION rather than a
  // threshold, so there is no "next" to fill toward and no honest progress
  // to show. The meter is simply full, and the copy talks about holding the
  // slot rather than climbing - a GOAT can be displaced without ever losing
  // a match, purely because somebody else's hidden rating rose past theirs.
  if (title === GOAT_TITLE) {
    return {
      title,
      state: GOAT_STATE,
      fill: 1,
      nextTitle: null,
      caption: `Top ${GOAT_POOL_SIZE} in the world. Someone is coming for it.`,
    };
  }

  const index = tierIndexOf(title);
  // An unknown or absent title is treated as the floor rather than as an
  // error: every account predating the field reads that way, and a
  // broken-looking gauge is a worse answer than a modest one.
  const current = index >= 0 ? index : 0;
  const next = XP_TIERS[current + 1] ?? null;

  if (!next) {
    // Hall of Famer. The only thing above is GOAT, which cannot be reached
    // by crossing an XP number - it is the top five by hidden skill - so
    // showing a fill toward it would be inventing progress that does not
    // exist. Point at the leaderboard instead.
    return {
      title,
      state: CONTENDER_STATE,
      fill: 1,
      nextTitle: GOAT_TITLE,
      caption: `Only the top ${GOAT_POOL_SIZE} hold GOAT. Out-battle one of them.`,
    };
  }

  const here = XP_TIERS[current];
  // Fill by the player's XP standing between this title and the next. When
  // the stored title lags the XP (a title write that has not landed yet),
  // clamp the fill to this band rather than letting it overflow.
  const fill = fraction(xp, here.minXp, next.minXp);

  return {
    title,
    state: CLIMBING_STATE,
    fill,
    nextTitle: next.title,
    caption: climbingCaption(fill, next.title),
  };
}

/**
 * Qualitative, never numeric.
 *
 * A percentage would let anyone back-compute the thresholds the hidden-
 * criteria decision exists to keep hidden, and it would turn a mood into a
 * spreadsheet.
 */
function climbingCaption(fill, nextTitle) {
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
