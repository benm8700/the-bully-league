const {getFirestore} = require("firebase-admin/firestore");

/**
 * Match timing configuration (CLAUDE.md's `config/matchSettings` schema).
 *
 * WHY A FIRESTORE DOCUMENT RATHER THAN REMOTE CONFIG: CLAUDE.md allows
 * either ("Remote Config or Firestore doc - NOT hardcoded"). Firestore
 * wins here for three concrete reasons:
 *
 *  1. The settings are resolved SERVER-side, once, at pairing time, and
 *     stamped onto the match document. Both players therefore run the
 *     exact same round count and turn length no matter when either device
 *     last refreshed. With client-side Remote Config, two devices can hold
 *     different values (its fetches are throttled and cached), and the
 *     two halves of a match would silently disagree about how long a turn
 *     lasts - the kind of bug that shows up as "the timer felt wrong"
 *     rather than as an error.
 *  2. No new Flutter dependency, so no risk to the AGP/KGP pin that
 *     CLAUDE.md documents as fragile.
 *  3. Editing it is the same "admin uses the Firebase console" workflow
 *     already used for profile approval, report review and tournament
 *     creation - no new tooling or mental model.
 *
 * The developer's actual requirement is preserved either way: round
 * count/length can be retuned live, without shipping a new app version.
 *
 * Defaults below are the documented V1 values and are also the safety net
 * - if the document is missing or a field is malformed, a match still
 * runs on sane numbers rather than failing.
 */

const DEFAULTS = {
  roundCount: 3,
  roundLengthSeconds: 15,
  countdownSeconds: 5,
  bioRevealSeconds: 60,
  /**
   * Vote weight at which a result counts for full rating movement (see
   * voteConfidence in rating.js).
   *
   * Live-configurable for a specific reason: this is an ABSOLUTE number,
   * so as the app grows it stops binding. If the typical match one day
   * draws 200 votes, a 10-vote match is unusually thinly judged yet would
   * still earn full confidence - the guardrail would quietly switch
   * itself off. Raising this as volume grows keeps it meaningful without
   * shipping a new version.
   *
   * Deliberately NOT relative to other matches' vote counts: that would
   * make one player's rating movement depend on how popular other
   * people's matches were, which is both odd to explain and arguably
   * unfair. Ten independent judges is a real verdict whether or not some
   * other match drew two hundred.
   */
  fullConfidenceVotes: 10,
};

/** Bounds exist so a typo in the console can't brick live matches - a
 * roundCount of 0 would end a match before it began, and a
 * roundLengthSeconds of 9999 would strand two people in a turn for nearly
 * three hours. Out-of-range values fall back to the default for that
 * field rather than rejecting the whole document. */
const LIMITS = {
  roundCount: {min: 1, max: 10},
  roundLengthSeconds: {min: 5, max: 120},
  countdownSeconds: {min: 0, max: 30},
  bioRevealSeconds: {min: 0, max: 300},
  // At least 1 (0 would make every result count for nothing), and capped
  // well above any plausible per-match vote count so it can grow with the
  // platform without needing a code change.
  fullConfidenceVotes: {min: 1, max: 1000},
};

function sanitize(field, value, fallback) {
  if (typeof value !== "number" || !Number.isFinite(value)) return fallback;
  const rounded = Math.round(value);
  const {min, max} = LIMITS[field];
  if (rounded < min || rounded > max) return fallback;
  return rounded;
}

/**
 * Merges the stored document over the defaults, then the per-mode
 * override over that, sanitising every field as it goes.
 *
 * Exported separately from the Firestore read so the merge rules can be
 * tested directly - see test/matchSettings.test.js.
 */
function resolveSettings(doc, mode) {
  const base = doc ?? {};
  const perMode = (base.perMode ?? {})[mode] ?? {};
  const resolved = {};
  for (const field of Object.keys(DEFAULTS)) {
    const fallback = sanitize(field, base[field], DEFAULTS[field]);
    resolved[field] = sanitize(field, perMode[field], fallback);
  }
  return resolved;
}

/** Reads and resolves the settings for a mode. Never throws - a missing
 * or unreadable document falls back to defaults, because failing to read
 * config is not a reason to refuse someone a match. */
async function getMatchSettings(mode) {
  try {
    const snap = await getFirestore().collection("config").doc("matchSettings").get();
    return resolveSettings(snap.exists ? snap.data() : null, mode);
  } catch (e) {
    console.error("matchSettings read failed, using defaults:", e.message);
    return {...DEFAULTS};
  }
}

module.exports = {getMatchSettings, resolveSettings, DEFAULTS, LIMITS};
