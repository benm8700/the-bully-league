const {getFirestore} = require("firebase-admin/firestore");
const {HttpsError} = require("firebase-functions/v2/https");
const {buildFirstRound, DEFAULT_MIN_ENTRANTS} = require("./tournament");

/**
 * LIVE tournaments: everyone online at once, the crowd votes, the bracket
 * moves on.
 *
 * WHY LIVE AT ALL, when an async bracket already works. Async solved the
 * scheduling problem and created a worse one: a tournament that takes four
 * days to resolve is not an event, and nobody watches it. Live turns the
 * bracket into a show.
 *
 * AND IT FIXES THE APP'S HARDEST PROBLEM AS A SIDE EFFECT. Judging
 * liquidity is thin everywhere else - a match closes with a handful of
 * ballots and vote confidence discounts the result accordingly. A live
 * tournament has the audience ALREADY ASSEMBLED, so a minute of a full
 * room can carry more ballots than a quiet day does. Live voting is not a
 * compromise forced by the format; it is the best-judged thing in the app.
 *
 * The async format stays exactly as it was. This is a second format, not a
 * replacement - format: "live" selects it.
 *
 * THE ONE THING THAT MUST NOT BE COPIED FROM THE VOTE WINDOW: the chance
 * to object to a clip. Voting here closes in about a minute; the objection
 * window stays a full day (see objectionWindowEndMs in
 * matchFinalization.js). Tying them together would have given a player
 * sixty seconds to decide whether video of themselves may be published.
 */

/** How long before the start players may check in. Long enough to gather
 * a crowd, short enough that checking in still means "I am here now"
 * rather than "I was here at some point this afternoon". */
const DEFAULT_CHECKIN_LEAD_MS = 15 * 60 * 1000;

/** How long a live round stays open before unplayed matchups forfeit.
 * Minutes, not the async format's hours - a live bracket that waits an
 * hour for one person has stopped being live for everybody else. */
const DEFAULT_LIVE_ROUND_MS = 10 * 60 * 1000;
const LIVE_ROUND_LIMITS = {min: 2 * 60 * 1000, max: 60 * 60 * 1000};

/** How long the crowd gets to vote on a live match. */
const DEFAULT_LIVE_VOTE_MS = 90 * 1000;
const LIVE_VOTE_LIMITS = {min: 30 * 1000, max: 10 * 60 * 1000};

/**
 * Reads a bounded per-tournament override.
 *
 * These documents are hand-edited in the Firebase console with nothing
 * validating them in between - the same rule every other config in this
 * project follows. A zero-length round would forfeit a bracket the instant
 * it opened.
 */
function bounded(raw, fallback, limits) {
  const n = Number(raw);
  return Number.isFinite(n) && n >= limits.min && n <= limits.max ?
    n : fallback;
}

function liveRoundMs(tournament) {
  return bounded(tournament?.liveRoundMs, DEFAULT_LIVE_ROUND_MS,
      LIVE_ROUND_LIMITS);
}

function liveVoteMs(tournament) {
  return bounded(tournament?.liveVoteMs, DEFAULT_LIVE_VOTE_MS,
      LIVE_VOTE_LIMITS);
}

function checkInLeadMs(tournament) {
  return bounded(tournament?.checkInLeadMs, DEFAULT_CHECKIN_LEAD_MS,
      {min: 60 * 1000, max: 6 * 60 * 60 * 1000});
}

/**
 * Epoch millis this tournament starts, or null if it has no start time.
 *
 * A live tournament without one can never begin, which the sweep treats as
 * "leave it alone" rather than guessing a time - starting a scheduled
 * event at an unscheduled moment is worse than not starting it.
 */
function startsAtMs(tournament) {
  const raw = tournament?.startsAtMs;
  if (typeof raw?.toMillis === "function") return raw.toMillis();
  const n = Number(raw);
  return Number.isFinite(n) && n > 0 ? n : null;
}

function isLive(tournament) {
  return tournament?.format === "live";
}

/**
 * Whether check-in is open, and why not if it is not.
 *
 * Pure, so the whole schedule is testable without a clock or Firestore.
 */
function checkInState(tournament, nowMs) {
  if (!isLive(tournament)) return "not-live";
  if (tournament.status !== "open") return "not-open";
  const start = startsAtMs(tournament);
  if (start === null) return "no-start-time";
  if (nowMs < start - checkInLeadMs(tournament)) return "too-early";
  if (nowMs >= start) return "closed";
  return "open";
}

/**
 * What the sweep should do with a live tournament right now.
 *
 * THE BRACKET IS BUILT FROM WHO CHECKED IN, not from everyone who entered.
 * Building from all entrants and forfeiting the absentees would produce a
 * bracket largely made of byes - a first round where most matchups are
 * walkovers is not a show, and it wastes the time of the people who did
 * turn up. They get a real bracket instead.
 *
 * The golden parachute is reused unchanged: too few present means cancel
 * and refund, exactly as too few entrants does. Someone who paid and did
 * not appear is covered by the existing no-show rule.
 *
 * Pure.
 */
function startDecision({tournament, checkedInCount, nowMs}) {
  if (!isLive(tournament)) return {action: "skip", reason: "not-live"};
  if (tournament.status !== "open") return {action: "skip", reason: "not-open"};
  const start = startsAtMs(tournament);
  if (start === null) return {action: "skip", reason: "no-start-time"};
  if (nowMs < start) return {action: "wait", reason: "not-yet"};

  // A bracket needs two players whatever the configured minimum says -
  // there is no matchup to build below that.
  const min = Math.max(tournament.minEntrants ?? DEFAULT_MIN_ENTRANTS, 2);
  if (checkedInCount < min) {
    return {
      action: "cancel", reason: "too-few-checked-in", checkedInCount, min,
    };
  }
  return {action: "start", checkedInCount};
}

/** The window a live round runs for. Same shape as the async version so
 * the bracket structure stays identical, just measured in minutes. */
function liveRoundWindow(tournament, startMs) {
  return {
    windowStartMs: startMs,
    windowEndMs: startMs + liveRoundMs(tournament),
  };
}

/**
 * Record that a player is present for a live tournament.
 *
 * Presence is the whole premise of the format, so this is a real gate
 * rather than a formality: miss it and the bracket is built without you.
 */
async function checkInToTournament(auth, data) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const {tournamentId} = data || {};
  if (!tournamentId) {
    throw new HttpsError("invalid-argument", "tournamentId is required.");
  }
  const db = getFirestore();
  const nowMs = Date.now();
  const ref = db.collection("tournaments").doc(tournamentId);
  const snap = await ref.get();
  if (!snap.exists) throw new HttpsError("not-found", "Tournament not found.");
  const tournament = snap.data();

  const entrantRef = ref.collection("entrants").doc(auth.uid);
  if (!(await entrantRef.get()).exists) {
    throw new HttpsError("failed-precondition",
        "You have not entered this one.");
  }

  const state = checkInState(tournament, nowMs);
  if (state !== "open") {
    const messages = {
      "not-live": "This tournament is not a live event.",
      "not-open": "This tournament has already started.",
      "no-start-time": "This tournament has no start time yet.",
      "too-early": "Check-in is not open yet. Come back nearer the start.",
      "closed": "Check-in has closed.",
    };
    throw new HttpsError("failed-precondition",
        messages[state] ?? "You cannot check in right now.", {reason: state});
  }

  await entrantRef.set({checkedInAtMs: nowMs}, {merge: true});
  return {checkedIn: true, startsAtMs: startsAtMs(tournament)};
}

/**
 * Starts one live tournament whose time has come, or cancels it.
 *
 * Returns what it did, so the sweep can log something meaningful - a
 * scheduled job with no visible output is how the MODES export bug hid for
 * as long as it did.
 */
async function startLiveTournament(tournamentId) {
  const db = getFirestore();
  const ref = db.collection("tournaments").doc(tournamentId);
  const snap = await ref.get();
  if (!snap.exists) return {tournamentId, action: "skip", reason: "not-found"};
  const tournament = snap.data();
  const nowMs = Date.now();

  const entrants = await ref.collection("entrants").get();
  const checkedIn = entrants.docs
      .filter((d) => Number(d.data()?.checkedInAtMs) > 0)
      .map((d) => d.id);

  const decision = startDecision({
    tournament, checkedInCount: checkedIn.length, nowMs,
  });
  if (decision.action !== "start" && decision.action !== "cancel") {
    return {tournamentId, ...decision};
  }
  if (decision.action === "cancel") {
    await ref.update({
      status: "cancelled",
      cancelledReason: "too-few-checked-in",
      checkedInCount: checkedIn.length,
    });
    return {tournamentId, ...decision};
  }

  const firstRound = Object.assign(
      {roundNumber: 1, matchups: buildFirstRound(checkedIn)},
      liveRoundWindow(tournament, nowMs));
  await ref.update({
    status: "in_progress",
    startedAtMs: nowMs,
    checkedInCount: checkedIn.length,
    bracket: {rounds: [firstRound]},
  });
  return {tournamentId, action: "start", checkedInCount: checkedIn.length};
}

/**
 * Settles a live match whose short voting window has closed.
 *
 * CLIENT-NUDGED, SERVER-VERIFIED. The scheduled sweep is the backstop, but
 * a sweep running once a minute means a live audience can wait a minute
 * past the countdown hitting zero for a result they are watching for -
 * which is exactly the wrong place to feel slow. So the client asks the
 * moment its own timer expires, and the server independently checks the
 * window really has passed before doing anything. Nobody can rush a result
 * by asking early.
 */
async function settleLiveMatch(auth, data) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const {matchId} = data || {};
  if (!matchId) {
    throw new HttpsError("invalid-argument", "matchId is required.");
  }
  const db = getFirestore();
  const snap = await db.collection("matches").doc(matchId).get();
  if (!snap.exists) throw new HttpsError("not-found", "Match not found.");
  const match = snap.data();

  const {voteWindowEndMs, finalizeMatch} = require("./matchFinalization");
  if (match.voteFinalized) return {settled: true, alreadyDone: true};
  if (Date.now() <= voteWindowEndMs(match)) {
    // Not an error - the client's clock is simply a moment ahead. Telling
    // it when the window closes lets it retry once rather than poll.
    return {
      settled: false, reason: "window-open",
      windowEndMs: voteWindowEndMs(match),
    };
  }
  const result = await finalizeMatch(matchId);
  return {settled: true, result};
}

/**
 * Starts every live tournament whose time has come.
 *
 * Queried by status rather than by start time so it needs no extra index -
 * there are never many open tournaments, and a missing composite index is
 * how a scheduled sweep silently does nothing (see voteReminders).
 */
async function sweepLiveTournaments() {
  const db = getFirestore();
  const open = await db.collection("tournaments")
      .where("status", "==", "open").get();

  const results = [];
  for (const doc of open.docs) {
    if (!isLive(doc.data())) continue;
    try {
      const outcome = await startLiveTournament(doc.id);
      // Only report the ones that did something. A sweep that logs every
      // tournament it looked at buries the one that mattered.
      if (outcome.action === "start" || outcome.action === "cancel") {
        results.push(outcome);
      }
    } catch (e) {
      console.error(`live tournament ${doc.id} failed to start:`, e.message);
      results.push({tournamentId: doc.id, action: "error", error: e.message});
    }
  }
  return {examined: open.size, acted: results};
}

module.exports = {
  checkInToTournament,
  startLiveTournament,
  settleLiveMatch,
  sweepLiveTournaments,
  // Pure, exported for tests.
  checkInState,
  startDecision,
  liveRoundWindow,
  liveRoundMs,
  liveVoteMs,
  checkInLeadMs,
  startsAtMs,
  isLive,
  DEFAULT_CHECKIN_LEAD_MS,
  DEFAULT_LIVE_ROUND_MS,
  DEFAULT_LIVE_VOTE_MS,
};
