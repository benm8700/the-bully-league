/**
 * Persisting the in-match capture-quality summary, and using it.
 *
 * The client already watches its OWN camera and mic during a battle
 * (lib/core/services/capture_quality.dart) and warns the player when
 * they go dark or silent. Until now that judgement died with the screen:
 * nothing recorded it, so a clip that nobody could see or hear ranked
 * for captions exactly as well as a good one.
 *
 * WHAT THIS IS ALLOWED TO AFFECT, and what it must never touch. The
 * report is SELF-REPORTED by a client, so it is evidence about a video
 * file and nothing more. It deprioritises captioning - a spending
 * decision, where being wrong costs one clip that might have been
 * captioned. It must never touch rating, the result, the vote, or any
 * penalty against a player: acting punitively on a number a modified
 * client chooses would be trivially abusable, and CLAUDE.md's
 * quality-flag abuse safeguard exists precisely because a
 * quality-triggered consequence is a dodge waiting to be found.
 *
 * THE INCENTIVES HAPPEN TO BE SAFE, which is worth stating rather than
 * assuming. Under-reporting means claiming your capture was fine, which
 * is already the default for anyone who reports nothing - so lying that
 * way gains nothing. Over-reporting only demotes your own clip. There is
 * no direction in which a dishonest report profits the reporter.
 */

/** A battle is minutes long and an episode needs three consecutive bad
 * samples, so a handful is a lot and anything beyond this is either a
 * bug or a hostile client. Clamped rather than rejected: a nonsense
 * number should not cost the honest half of the report. */
const MAX_EPISODES = 50;

/** How far a thoroughly broken capture can push a clip down the caption
 * ranking. Deliberately a FLOOR rather than zero - a dark clip with
 * overwhelming votes may still be the best thing that happened all week,
 * and a hard exclusion would let one bad reading veto a real highlight. */
const MIN_QUALITY_FACTOR = 0.4;

/** Each episode costs this much of the factor, until the floor. */
const PENALTY_PER_EPISODE = 0.15;

/**
 * Cleans one player's self-reported summary.
 *
 * Returns null for anything unusable, so a malformed report is simply
 * absent rather than being recorded as zero episodes - "we have no
 * information" and "their capture was perfect" are different claims and
 * must not be conflated.
 */
function sanitiseQualityReport(raw) {
  if (!raw || typeof raw !== "object") return null;
  const clamp = (v) => {
    const n = Math.floor(Number(v));
    if (!Number.isFinite(n) || n < 0) return null;
    return Math.min(n, MAX_EPISODES);
  };
  const dark = clamp(raw.darkEpisodes);
  const quiet = clamp(raw.quietEpisodes);
  if (dark === null && quiet === null) return null;
  return {darkEpisodes: dark ?? 0, quietEpisodes: quiet ?? 0};
}

/**
 * How much a match's capture problems should discount its caption rank.
 *
 * 1.0 when nothing was reported or nothing went wrong, falling toward
 * MIN_QUALITY_FACTOR as episodes accumulate.
 *
 * COUNTS THE WORSE OF THE TWO PLAYERS, not the sum. A roast battle is
 * unwatchable if EITHER end is broken, and adding them would make two
 * mildly glitchy players look worse than one player who was invisible
 * throughout.
 *
 * A MISSING REPORT IS TREATED AS FINE, which is the only workable
 * default: most matches predate this, an older client sends nothing, and
 * reading silence as failure would demote every one of them.
 */
function qualityFactor(captureQuality) {
  if (!captureQuality || typeof captureQuality !== "object") return 1;
  let worst = 0;
  for (const report of Object.values(captureQuality)) {
    const clean = sanitiseQualityReport(report);
    if (!clean) continue;
    worst = Math.max(worst, clean.darkEpisodes + clean.quietEpisodes);
  }
  if (worst <= 0) return 1;
  return Math.max(MIN_QUALITY_FACTOR, 1 - worst * PENALTY_PER_EPISODE);
}

/**
 * Whether a match's capture was bad enough to be worth an admin's
 * attention, for CLAUDE.md's quality-flag abuse safeguard.
 *
 * Reported rather than acted on, deliberately. The safeguard's concern
 * is somebody faking bad capture to escape matches; that pattern is only
 * visible ACROSS matches, and no single match can prove it.
 */
function isNotablyBad(captureQuality) {
  return qualityFactor(captureQuality) <= MIN_QUALITY_FACTOR;
}

module.exports = {
  sanitiseQualityReport,
  qualityFactor,
  isNotablyBad,
  MAX_EPISODES,
  MIN_QUALITY_FACTOR,
  PENALTY_PER_EPISODE,
};
