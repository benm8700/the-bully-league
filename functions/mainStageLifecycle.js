/**
 * Main Stage tournament lifecycle - the pure decision core.
 *
 * This is the deterministic brain of the weekly finals' lifecycle, sitting
 * between the frozen qualifier snapshot and the (parked) live stage. It owns the
 * state-machine decisions - what the fresh tournament doc looks like, who is
 * confirmed, what the field + panel resolve to at the 4pm lock, whether to
 * cancel, and whether a callout is legal - as pure functions over plain data.
 *
 * The Firestore wiring (mainStageTournament.js) is a thin transaction shell over
 * these. Modelling it this way is the project's standing discipline: the lock
 * and callout rules are exactly the kind of thing that is a nightmare to verify
 * live but trivial to pin down here, and the lifecycle only ever RUNS behind the
 * config/tournament.enabled failsafe, so these pure tests are the main guarantee
 * it is correct long before a real show is staged.
 */

const {assembleMainStage} = require("./mainStageAssembly");
const {createBracket} = require("./mainStageBracket");

// Fewest confirmed players worth staging a finals with. Below this the show is
// cancelled rather than run as a walkover - a 1-person "bracket" is not a
// tournament, and (once prizes/belt ride on it) must never be won unopposed.
const MIN_FIELD = 2;
const PANEL_SIZE = 5;

/**
 * The invite status map for a fresh tournament: every finalist AND alternate
 * starts "pending". Alternates must confirm too - the whole point of the 4pm
 * lock is that a declining finalist is replaced by an alternate who ALREADY
 * said yes, with no 6pm scramble.
 */
function initialInvites(finalists, alternates) {
  const invites = {};
  for (const uid of [...finalists, ...alternates]) {
    if (uid) invites[uid] = "pending";
  }
  return invites;
}

/** uids whose invite is "accepted", preserving no particular order (the caller
 * passes seed-ordered finalists/alternates to resolveFinalists separately). */
function confirmedFrom(invites = {}) {
  return Object.keys(invites).filter((uid) => invites[uid] === "accepted");
}

/**
 * Shape the tournament document created from a qualifier snapshot.
 * `snapshot` is stats/weeklyQualifierSnapshot: {tournamentDayKey, finalists,
 * alternates, judgePool} where finalists/alternates are [{uid, gain,...}] and
 * judgePool is [{uid, judged}]. We store the UID ARRAYS (seed order) the pure
 * cores consume, plus the raw snapshot ranks for display.
 */
function buildMainStageDoc({snapshot, nowMs, lockAtMs, showAtMs}) {
  const finalists = (snapshot.finalists || []).map((f) => f.uid).filter(Boolean);
  const alternates = (snapshot.alternates || []).map((a) => a.uid)
      .filter(Boolean);
  const judgePool = (snapshot.judgePool || []).map((j) => j.uid).filter(Boolean);
  return {
    format: "mainstage",
    createdBy: "auto",
    status: "accepting", // accepting -> locked -> live -> completed | cancelled
    cutoffDayKey: snapshot.tournamentDayKey,
    finalists, // seed order (highest weekly Elo gain first)
    alternates, // seed order
    judgePool, // most-judged-this-week, for panel autofill
    handPickedJudges: [], // the founder's picks, set before the lock
    invites: initialInvites(finalists, alternates),
    field: null, // locked field (resolveFinalists) - set at the 4pm lock
    judges: null, // the 5-seat panel - set at the lock
    judgeShortfall: 0,
    bracket: null, // set when the #1 calls someone out, live on stage
    winnerId: null,
    lockAtMs, // Thu 4pm Pacific - field + panel freeze
    showAtMs, // Thu 6pm Pacific - the stage opens
    createdAt: nowMs,
  };
}

/**
 * The outcome of the 4pm lock: resolve the confirmed field and the 5-seat
 * panel from the current doc, and decide whether to cancel for lack of players.
 * Pure wrapper over assembleMainStage (no `pick` yet - the bracket is built
 * live at callout, not at the lock).
 *   exclude - banned/flagged uids to keep off the panel (gathered by the caller)
 * Returns {field, full, judges, judgeShortfall, cancel}.
 */
function lockOutcome({
  finalists = [],
  alternates = [],
  invites = {},
  judgePool = [],
  handPicked = [],
  exclude = [],
  minField = MIN_FIELD,
  panelSize = PANEL_SIZE,
} = {}) {
  const confirmed = confirmedFrom(invites);
  const a = assembleMainStage({
    finalists, alternates, confirmed, handPicked, judgePool, exclude,
    pick: null, panelSize,
  });
  return {
    field: a.field,
    full: a.full,
    judges: a.judges,
    judgeShortfall: a.judgeShortfall,
    cancel: a.field.length < minField,
  };
}

/**
 * Validate and apply a finalist/alternate's invite response.
 * Returns {ok, error, status} - `status` is the new value to store for the
 * caller. Only an invited player may respond, and only while "accepting".
 */
function inviteResponse(doc, callerUid, accept) {
  if (!doc || doc.status !== "accepting") {
    return {ok: false, error: "This tournament isn't taking responses."};
  }
  const invites = doc.invites || {};
  if (!(callerUid in invites)) {
    return {ok: false, error: "You're not on this tournament's invite list."};
  }
  return {ok: true, status: accept ? "accepted" : "declined"};
}

/**
 * Firestore can't store an array that DIRECTLY contains another array, and the
 * pure bracket's `rounds` is exactly that ([[semi, semi], [final]]). So at the
 * storage boundary each round's match array is wrapped in a `{matches: [...]}`
 * map (an array of maps, each holding an array - which Firestore allows). The
 * pure core keeps its natural array-of-arrays shape; only the wiring converts.
 * This is the array-nesting cousin of the documented "Firestore can't address
 * array elements by dotted path" lesson, and it only shows up on a real write.
 */
function storeBracket(bracket) {
  if (!bracket) return bracket;
  return {...bracket, rounds: bracket.rounds.map((r) => ({matches: r}))};
}

/** Inverse of storeBracket: back to the pure core's array-of-arrays shape. */
function loadBracket(stored) {
  if (!stored) return stored;
  return {...stored, rounds: stored.rounds.map((r) => r.matches)};
}

/**
 * Validate the #1 seed's callout and build the bracket.
 * Returns {ok, error, bracket}. Only field[0] (the highest-ranked confirmed
 * player) may call out, only while "locked", and the pick is validated by
 * createBracket (must be another finalist).
 */
function calloutResult(doc, callerUid, pickUid) {
  if (!doc || doc.status !== "locked") {
    return {ok: false, error: "The callout isn't open right now."};
  }
  const field = doc.field || [];
  if (field[0] !== callerUid) {
    return {ok: false, error: "Only the #1 seed makes the callout."};
  }
  try {
    return {ok: true, bracket: createBracket(field, pickUid)};
  } catch (e) {
    return {ok: false, error: e.message};
  }
}

module.exports = {
  MIN_FIELD,
  PANEL_SIZE,
  initialInvites,
  confirmedFrom,
  buildMainStageDoc,
  lockOutcome,
  inviteResponse,
  calloutResult,
  storeBracket,
  loadBracket,
};
