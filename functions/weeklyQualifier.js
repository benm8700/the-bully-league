/**
 * Weekly tournament QUALIFIER - the pure core.
 *
 * The weekly Main Stage is fed by a week of ordinary ranked play (see the
 * Tournament model decision record in CLAUDE.md). A player's standing is their
 * WEEKLY ELO GAIN - the sum of their rating changes over the week - NOT raw
 * wins. Elo already folds wins, losses AND opponent strength into one
 * principled number and is farm-proof by construction (beating weak opponents
 * gains ~0), so a wins/win-ratio blend would just be a worse, gameable
 * reinvention of it.
 *
 * This module is PURE (no Firestore, no clock of its own) so the boundary math
 * and the aggregation can be exercised with plain `node` - the discipline that
 * has repeatedly caught silent bugs here before they reached a device. The
 * Firestore wiring (a collection-group read of ratingHistory feeding
 * computeStandings) lives elsewhere.
 */
const {pacificNow, pacificWallClockToUtcMs} = require("./eventWindow");

const DEFAULT_MIN_GAMES = 5;

// Modes that do NOT move the competitive ladder, so they never count toward
// qualifying. Everything else - ranked, tournament, climb, swiss, elite - is
// real ladder play and DOES count, which is how a strong Main Stage run feeds
// next week's qualifying per the decision record. A denylist (not an
// allowlist) so a future ladder-moving mode is included by default rather than
// silently dropped.
const NON_LADDER_MODES = new Set(["friend", "exhibition", "practice"]);

const THURSDAY = 4; // 0=Sun .. 6=Sat

function pad(n) {
  return String(n).padStart(2, "0");
}

/** Calendar arithmetic on a YYYY-MM-DD key (UTC, since a bare date has no tz
 * of its own); n may be negative. */
function addDaysKey(dayKey, n) {
  const [y, m, d] = dayKey.split("-").map(Number);
  const dt = new Date(Date.UTC(y, m - 1, d + n));
  return `${dt.getUTCFullYear()}-${pad(dt.getUTCMonth() + 1)}-` +
    `${pad(dt.getUTCDate())}`;
}

/** Weekday (0=Sun..6=Sat) of a Pacific calendar day key. */
function weekdayOf(dayKey) {
  const [y, m, d] = dayKey.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, d)).getUTCDay();
}

/**
 * The qualifying week containing `nowMs`.
 *
 * It CLOSES at "Wednesday 11:59pm PST", represented as the following
 * Thursday 00:00 Pacific - the exclusive upper bound, so a battle finished at
 * Wed 23:59 counts and one at Thu 00:00 belongs to next week. The window is
 * [startMs, cutoffMs), exactly 7 Pacific days - which is 169 hours, not 168,
 * across the November fall-back. That hour is the silent-wrong-answer case
 * this math exists to get right: a leaderboard quietly an hour off looks
 * completely normal until someone's matches land in the wrong week.
 *
 * cutoffDayKey is the Thursday the Main Stage runs; the cutoff instant is its
 * 00:00. On a Thursday that 00:00 has already passed, so we roll to the next
 * Thursday - the finals that evening (6pm) then land in, and feed, NEXT week.
 */
function qualifyingWeek(nowMs) {
  const {dayKey} = pacificNow(new Date(nowMs));
  let daysAhead = (THURSDAY - weekdayOf(dayKey) + 7) % 7;
  if (daysAhead === 0) daysAhead = 7; // on Thursday, this week's 00:00 is gone
  const cutoffDayKey = addDaysKey(dayKey, daysAhead);
  const startDayKey = addDaysKey(cutoffDayKey, -7);
  return {
    startDayKey,
    cutoffDayKey,
    startMs: pacificWallClockToUtcMs(startDayKey, 0, 0),
    cutoffMs: pacificWallClockToUtcMs(cutoffDayKey, 0, 0),
  };
}

/**
 * The week that has most recently CLOSED as of nowMs: [cutoff - 7d, cutoff),
 * where cutoff is the Thursday 00:00 Pacific at or before now. The snapshot job
 * runs just after a cutoff and uses this to freeze the final standings of the
 * week that just ended.
 *
 * Invariant with qualifyingWeek: the current week starts exactly where the
 * most-recently-closed week ended, so qualifyingWeek(now).startMs ===
 * mostRecentlyClosedWeek(now).cutoffMs (pinned by a test).
 */
function mostRecentlyClosedWeek(nowMs) {
  const {dayKey} = pacificNow(new Date(nowMs));
  const daysBack = (weekdayOf(dayKey) - THURSDAY + 7) % 7; // 0 if today is Thu
  const cutoffDayKey = addDaysKey(dayKey, -daysBack);
  const startDayKey = addDaysKey(cutoffDayKey, -7);
  return {
    startDayKey,
    cutoffDayKey,
    startMs: pacificWallClockToUtcMs(startDayKey, 0, 0),
    cutoffMs: pacificWallClockToUtcMs(cutoffDayKey, 0, 0),
  };
}

/** Coerce a ratingHistory `at` (Firestore Timestamp, millis, or Date) to ms. */
function toMs(at) {
  if (at == null) return NaN;
  if (typeof at === "number") return at;
  if (typeof at.toMillis === "function") return at.toMillis();
  if (at instanceof Date) return at.getTime();
  if (typeof at.seconds === "number") return at.seconds * 1000;
  if (typeof at._seconds === "number") return at._seconds * 1000;
  return NaN;
}

/**
 * Rank players by weekly Elo gain from their ratingHistory entries.
 *
 * Pure: hand it the week's entries ({uid, delta, mode, at}) and the window.
 * - Only ladder-moving modes count (NON_LADDER_MODES excluded).
 * - Only entries within [startMs, cutoffMs) count.
 * - Eligibility floor: >= minGames completed ladder matches that week, so a
 *   tiny-sample lucky run can't take a Main Stage slot.
 * - Malformed entries are SKIPPED, never counted as a zero (no-information and
 *   zero-gain are different claims).
 * - Order is deterministic: most Elo gained, then more games (more proven),
 *   then uid, so a tie never ranks arbitrarily.
 */
function computeStandings(entries, opts = {}) {
  const {startMs, cutoffMs, minGames = DEFAULT_MIN_GAMES} = opts;
  const byUid = new Map();
  for (const e of entries || []) {
    if (!e || typeof e.uid !== "string" || !e.uid) continue;
    if (NON_LADDER_MODES.has(e.mode)) continue;
    const at = toMs(e.at);
    if (!Number.isFinite(at)) continue;
    if (Number.isFinite(startMs) && at < startMs) continue;
    if (Number.isFinite(cutoffMs) && at >= cutoffMs) continue;
    const delta = Number(e.delta);
    if (!Number.isFinite(delta)) continue;
    const cur = byUid.get(e.uid) || {uid: e.uid, gain: 0, games: 0};
    cur.gain += delta;
    cur.games += 1;
    byUid.set(e.uid, cur);
  }
  return [...byUid.values()]
      .filter((p) => p.games >= minGames)
      .sort((a, b) =>
        b.gain - a.gain ||
        b.games - a.games ||
        (a.uid < b.uid ? -1 : a.uid > b.uid ? 1 : 0));
}

/** The top N of a standings array (finalists, or finalists + alternates). */
function topN(standings, n) {
  return standings.slice(0, Math.max(0, n));
}

module.exports = {
  qualifyingWeek,
  mostRecentlyClosedWeek,
  computeStandings,
  topN,
  toMs,
  addDaysKey,
  weekdayOf,
  DEFAULT_MIN_GAMES,
  NON_LADDER_MODES,
};
