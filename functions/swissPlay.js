const crypto = require("crypto");
const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {HttpsError} = require("firebase-functions/v2/https");
const S = require("./swissTournament");
const {climbForfeitDecision} = require("./climbTournament");
const {STARTING_RATING} = require("./rating");

/**
 * Wiring for the Daily Gauntlet's SWISS "most wins" format (the pure engine is
 * swissTournament.js, simulation-tested). This file is the plumbing: async
 * all-day signup, presence-based live pairing during the window, applying a
 * settled result, and the sweep that forfeits no-shows and crowns the champion.
 *
 * TWO THINGS DIFFER FROM THE OLD CLIMB WIRING, both because of async signup:
 *  1. SIGNUP is all-day (any time before the window opens), separate from
 *     battling. The entrant list is the roster people study during the day; it
 *     locks when the window opens.
 *  2. PAIRING IS PRESENCE-GATED. The field contains day-old signups who may
 *     never turn up at 6pm, so pairing only ever considers entrants who are
 *     actively polling right now (a `swiss.presence` map keyed by uid). Without
 *     this, a live player would be paired against a ghost and waste a battle
 *     slot waiting for a no-show to time out.
 *
 * Entrants live as an ARRAY on the tournament doc (`swiss.entrants`), like the
 * climb's `climb.climbers`, so a pairing is a single-doc transaction that can
 * never double-book. Presence is a separate MAP (`swiss.presence`) so a poll
 * updates one field by path rather than rewriting the whole array.
 */

const SWISS_MAX_ROUNDS = 8; // soft safety cap; the one-hour window is the real one
const SWISS_VOTE_MS = 90 * 1000; // fast vote so the next round starts while hot
const PRESENCE_STALE_MS = 20 * 1000; // no poll within this = not at their screen
const RESOLVE_GRACE_MS = 5 * 60 * 1000; // final stretch: allow rematches to drain

// Reused forfeit constants (same battle/no-show timings as the climb).
const MATCH_TIMEOUT_MS = 8 * 60 * 1000;
const BATTLE_ABANDON_MS = 25 * 60 * 1000;
const CLIMB_PRESENCE_STALE_MS = 75 * 1000;

function entrantsOf(t) {
  return Array.isArray(t && t.swiss && t.swiss.entrants) ? t.swiss.entrants : [];
}
function presenceOf(t) {
  return (t && t.swiss && t.swiss.presence) || {};
}
function num(v) {
  const n = Number(v);
  return Number.isFinite(n) && n > 0 ? n : null;
}
function windowStartMsOf(t) {
  return num(t && (t.windowStartMs || t.startsAtMs ||
    (t.swiss && t.swiss.windowStartMs)));
}
function windowEndMsOf(t) {
  return num(t && (t.windowEndMs || (t.swiss && t.swiss.windowEndMs)));
}
function windowLive(t, nowMs) {
  const start = windowStartMsOf(t);
  const end = windowEndMsOf(t);
  return start !== null && end !== null && nowMs >= start && nowMs < end;
}
function windowEnded(t, nowMs) {
  const end = windowEndMsOf(t);
  return end !== null && nowMs >= end;
}
/** Signups are open until the window starts (the field locks at 6pm). */
function signupsOpen(t, nowMs) {
  const start = windowStartMsOf(t);
  return t.status === "open" && (start === null || nowMs < start);
}
/** Final stretch: relax rematch avoidance so the field battles to the finish. */
function allowRematchNow(t, nowMs) {
  const end = windowEndMsOf(t);
  return end !== null && nowMs >= end - RESOLVE_GRACE_MS;
}
function isSwiss(t) {
  return t && t.format === "swiss";
}
function isRunning(t) {
  return t && (t.status === "open" || t.status === "in_progress");
}

/** The pairing shape the client's match flow already understands. */
function matchPairing(match, uid) {
  return {
    matchId: match.id || match.matchId,
    channelName: match.channelName,
    opponentId: match.player1Id === uid ? match.player2Id : match.player1Id,
    mode: match.mode,
    settings: match.settings,
    agoraUid: match.player1Id === uid ? 1 : 2,
  };
}

/**
 * Sign up for tonight's Daily Gauntlet - any time during the day, up until the
 * window opens. Signing up adds you to the roster everyone studies; you don't
 * battle until 6pm. Enter at 0-0.
 */
async function signUpGauntlet(auth, data) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const {tournamentId} = data || {};
  if (!tournamentId) {
    throw new HttpsError("invalid-argument", "tournamentId is required.");
  }
  const db = getFirestore();
  const uid = auth.uid;
  const nowMs = Date.now();
  const ref = db.collection("tournaments").doc(tournamentId);

  const snap = await ref.get();
  if (!snap.exists) throw new HttpsError("not-found", "Tournament not found.");
  const t = snap.data();
  if (!isSwiss(t)) {
    throw new HttpsError("failed-precondition", "This isn't a gauntlet event.");
  }
  if (!signupsOpen(t, nowMs)) {
    throw new HttpsError("failed-precondition",
        "Sign-ups have closed for tonight - the field is locked.");
  }

  // Same mandatory intro-video gate as ranked/tournament: a gauntlet battle is
  // recorded and clip-eligible, and your opponents study your intro all day.
  const userSnap = await db.collection("users").doc(uid).get();
  const profile = userSnap.data() && userSnap.data().profile;
  const introUrl = profile && profile.introVideoUrl;
  if (typeof introUrl !== "string" || introUrl.length === 0) {
    throw new HttpsError("failed-precondition",
        "Record your intro video before you sign up - your opponents study " +
        "it all day.");
  }
  // Stamp the hidden Elo so pairing seeds by closest rank (see byScore). Read
  // once at signup; a later rating drift over the day is negligible for one
  // night's pairing.
  const rating = (userSnap.data() || {}).rating ?? STARTING_RATING;

  await db.runTransaction(async (tx) => {
    const s = await tx.get(ref);
    const entrants = entrantsOf(s.data());
    if (entrants.some((e) => e.uid === uid)) return; // already signed up
    const next = [...entrants, {
      uid, wins: 0, losses: 0, opponents: [], rating,
      status: S.STATUS.waiting, joinedMs: nowMs, currentMatchId: null,
    }];
    tx.update(ref, {"swiss.entrants": next});
  });

  const entrants = entrantsOf((await ref.get()).data());
  return {signedUp: true, standing: S.standingFor(entrants, uid),
    fieldSize: entrants.length};
}

/**
 * A signed-up player polls during the window to be paired. Records presence
 * (so ghosts aren't paired), then pairs the caller with the nearest-record
 * present opponent they haven't faced. Returns their live state.
 */
async function gauntletPoll(auth, data) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const {tournamentId} = data || {};
  if (!tournamentId) {
    throw new HttpsError("invalid-argument", "tournamentId is required.");
  }
  const db = getFirestore();
  const uid = auth.uid;
  const nowMs = Date.now();
  const ref = db.collection("tournaments").doc(tournamentId);

  const snap = await ref.get();
  if (!snap.exists) throw new HttpsError("not-found", "Tournament not found.");
  const t = snap.data();
  let entrants = entrantsOf(t);
  let me = entrants.find((e) => e.uid === uid);
  if (!me) throw new HttpsError("failed-precondition", "Sign up first.");

  // Record presence by path (no array rewrite). Best-effort.
  await ref.update({[`swiss.presence.${uid}`]: nowMs}).catch(() => {});

  // Already flagged in a match. Three cases:
  //  - genuinely live -> hand it back so the client (re)joins the battle;
  //  - completed but not yet finalized -> wait for the sweep to settle it
  //    (applying the result is what frees the entrant);
  //  - DEAD (missing, abandoned, disqualified, or vote-finalized with our
  //    result never applied) -> heal our OWN entry back to waiting so pairing
  //    can pick us up again. This is the catch-all for a match settled
  //    OUTSIDE the gauntlet's own paths - e.g. releaseUnresponsive or a
  //    bio-reveal end, which abandon the match but know nothing about swiss
  //    entrants. Without it the entrant is stranded in_match forever on a
  //    dead match, can never be re-paired, and the client only ever sees its
  //    own dead battle ("you are in this battle - open it from the bracket").
  if (me.status === S.STATUS.inMatch && me.currentMatchId) {
    const m = await db.collection("matches").doc(me.currentMatchId).get();
    const md = m.exists ? m.data() : null;
    const live = md && md.status !== "completed" &&
      md.status !== "abandoned" && md.status !== "disqualified" &&
      !md.voteFinalized;
    if (live) {
      return {state: "in_match", ...matchPairing({...md, id: m.id}, uid),
        standing: S.standingFor(entrants, uid)};
    }
    const dead = !md || md.voteFinalized === true ||
      md.status === "abandoned" || md.status === "disqualified";
    if (!dead) {
      // Completed, awaiting finalize: the sweep settles it and frees us.
      return {state: "waiting", standing: S.standingFor(entrants, uid)};
    }
    await _healStrandedEntrant(db, ref, uid, me.currentMatchId);
    // Re-read so the pairing pass below sees us as a waiting entrant.
    entrants = entrantsOf((await ref.get()).data());
    me = entrants.find((e) => e.uid === uid);
    if (!me) return {state: "waiting", standing: []};
  }

  if (t.status === "completed") {
    return {state: "done", winnerUid: t.winnerId ?? null,
      standing: S.standingFor(entrants, uid)};
  }
  if (me.status === S.STATUS.done) {
    return {state: "done_playing", standing: S.standingFor(entrants, uid)};
  }
  if (!windowLive(t, nowMs)) {
    // Signed up but the battling window isn't open yet (or has ended).
    return {state: windowEnded(t, nowMs) ? "ended" : "not_started",
      standing: S.standingFor(entrants, uid),
      windowStartMs: windowStartMsOf(t)};
  }

  // Pair among PRESENT waiting entrants only, so day-old absent signups are
  // never handed a live opponent.
  const presence = {...presenceOf(t), [uid]: nowMs};
  const presentWaiting = entrants.filter((e) =>
    e.status === S.STATUS.waiting &&
    Number(presence[e.uid]) > nowMs - PRESENCE_STALE_MS);
  const pairs = S.planPairings(presentWaiting, {
    allowRematch: allowRematchNow(t, nowMs), maxRounds: SWISS_MAX_ROUNDS,
  });
  const mine = pairs.find((p) => p.includes(uid));
  if (mine) {
    const opponentUid = mine[0] === uid ? mine[1] : mine[0];
    await _createSwissMatch(db, ref, tournamentId, uid, opponentUid);
  }

  // Re-read - whether we paired or an opponent's poll paired us, fresh state
  // is the truth (resolves the both-poll-at-once race).
  const fresh = entrantsOf((await ref.get()).data());
  me = fresh.find((e) => e.uid === uid);
  if (me && me.status === S.STATUS.inMatch && me.currentMatchId) {
    const m = await db.collection("matches").doc(me.currentMatchId).get();
    if (m.exists) {
      return {state: "in_match", ...matchPairing({...m.data(), id: m.id}, uid),
        standing: S.standingFor(fresh, uid)};
    }
  }
  return {state: "waiting", standing: S.standingFor(fresh, uid)};
}

/** Claims a pairing and creates its match atomically. No-op if either entrant
 * was already claimed (the opponent's poll won the race). */
async function _createSwissMatch(db, ref, tournamentId, a, b) {
  const {getMatchSettings} = require("./matchSettings");
  const settings = await getMatchSettings("tournament");
  const matchId = `s_${crypto.randomBytes(12).toString("hex")}`;
  const matchRef = db.collection("matches").doc(matchId);
  const [p1, p2] = [a, b].sort();

  const created = await db.runTransaction(async (tx) => {
    const s = await tx.get(ref);
    const entrants = entrantsOf(s.data());
    const ea = entrants.find((e) => e.uid === a);
    const eb = entrants.find((e) => e.uid === b);
    if (!ea || !eb) return false;
    if (ea.status !== S.STATUS.waiting || eb.status !== S.STATUS.waiting) {
      return false;
    }
    const existing = await tx.get(matchRef);
    const [uP1, uP2] = await Promise.all([
      tx.get(db.collection("users").doc(p1)),
      tx.get(db.collection("users").doc(p2)),
    ]);
    const p1Rating = (uP1.data() || {}).rating ?? STARTING_RATING;
    const p2Rating = (uP2.data() || {}).rating ?? STARTING_RATING;
    if (!existing.exists) {
      tx.set(matchRef, {
        player1Id: p1,
        player2Id: p2,
        player1Rating: p1Rating,
        player2Rating: p2Rating,
        mode: "tournament",
        settings,
        voteWindowMs: SWISS_VOTE_MS,
        eventWindow: {qualified: true,
          name: s.data().name ?? "Daily Gauntlet"},
        origin: "swiss",
        swiss: {tournamentId},
        status: "pending",
        channelName: `match_${matchId}`,
        createdAt: FieldValue.serverTimestamp(),
        completedAt: null,
        voteFinalized: false,
        winnerId: null,
        voteCount: 0,
        readyPlayerIds: [],
        arrivedAt: {},
      });
    }
    const next = S.markInMatch(entrants, [a, b]).map((e) =>
      (e.uid === a || e.uid === b) ? {...e, currentMatchId: matchId} : e);
    tx.update(ref, {"swiss.entrants": next});
    return !existing.exists;
  });

  if (created) {
    // Best-effort fame push: a followed comedian is up now, come watch.
    try {
      const {notifyFollowersOfGauntletPairing} = require("./follows");
      await notifyFollowersOfGauntletPairing(tournamentId, [p1, p2]);
    } catch (e) {
      console.error("gauntlet follower notify failed:", e.message);
    }
  }
}

/**
 * Reset a stranded entrant (flagged in_match on a dead match) back to
 * waiting so pairing can pick them up again. Heals only the CALLER's own
 * entry - each player heals themselves on their own poll, so neither ever
 * mutates the other's state. Idempotent: only acts while the entrant is
 * still on THIS match. The 0-0 record and opponents list are untouched: an
 * abandoned no-contest never played, so nothing about it should score.
 */
async function _healStrandedEntrant(db, ref, uid, matchId) {
  await db.runTransaction(async (tx) => {
    const s = await tx.get(ref);
    if (!s.exists) return;
    const entrants = entrantsOf(s.data());
    const me = entrants.find((e) => e.uid === uid);
    if (!me || me.currentMatchId !== matchId ||
        me.status !== S.STATUS.inMatch) {
      return;
    }
    const next = entrants.map((e) => e.uid === uid ?
      {...e, status: S.STATUS.waiting, currentMatchId: null} : e);
    tx.update(ref, {"swiss.entrants": next});
  });
}

/** Champion check + write, shared by result/tie application. */
function _championUpdate(t, next, nowMs) {
  const update = {"swiss.entrants": next};
  const champ = S.resolveChampion(next, {windowEnded: windowEnded(t, nowMs)});
  if (champ.done) {
    update.status = "completed";
    update.winnerId = champ.winnerUid;
    update["swiss.championUid"] = champ.winnerUid;
  }
  return {update, champ};
}

/**
 * Apply a settled gauntlet match. Called from finalizeMatch. Winner +1 win,
 * loser +1 loss, both back to waiting (non-elimination). Idempotent - only
 * applies while the pair is still on THIS match.
 */
async function applySwissResult(match, winnerId, matchId) {
  const tournamentId = match.swiss && match.swiss.tournamentId;
  if (!tournamentId) return {skipped: "not-a-swiss-match"};
  if (!matchId) return {skipped: "no-match-id"};
  const loserId = winnerId === match.player1Id ?
    match.player2Id : match.player1Id;
  const db = getFirestore();
  const ref = db.collection("tournaments").doc(tournamentId);

  return db.runTransaction(async (tx) => {
    const s = await tx.get(ref);
    if (!s.exists) return {skipped: "no-tournament"};
    const t = s.data();
    const entrants = entrantsOf(t);
    const winner = entrants.find((e) => e.uid === winnerId);
    if (!winner || winner.currentMatchId !== matchId ||
        winner.status !== S.STATUS.inMatch) {
      return {skipped: "already-applied"};
    }
    let next = S.applyResult(entrants, {winnerUid: winnerId, loserUid: loserId},
        {maxRounds: SWISS_MAX_ROUNDS});
    next = next.map((e) =>
      (e.uid === winnerId || e.uid === loserId) ?
        {...e, currentMatchId: null} : e);
    const {update, champ} = _championUpdate(t, next, Date.now());
    tx.update(ref, update);
    return {applied: true, champion: champ.winnerUid};
  });
}

/** Apply a TIED gauntlet match (draw / zero votes): neither scores, both back
 * to waiting. Called from finalizeMatch when a swiss match settles with no
 * winner. Idempotent. */
async function applySwissTie(match, matchId) {
  const tournamentId = match.swiss && match.swiss.tournamentId;
  if (!tournamentId) return {skipped: "not-a-swiss-match"};
  if (!matchId) return {skipped: "no-match-id"};
  const db = getFirestore();
  const ref = db.collection("tournaments").doc(tournamentId);
  const p1 = match.player1Id;
  const p2 = match.player2Id;

  return db.runTransaction(async (tx) => {
    const s = await tx.get(ref);
    if (!s.exists) return {skipped: "no-tournament"};
    const t = s.data();
    const entrants = entrantsOf(t);
    const c1 = entrants.find((e) => e.uid === p1);
    const c2 = entrants.find((e) => e.uid === p2);
    if (!c1 || !c2 || c1.currentMatchId !== matchId ||
        c2.currentMatchId !== matchId ||
        c1.status !== S.STATUS.inMatch || c2.status !== S.STATUS.inMatch) {
      return {skipped: "already-applied"};
    }
    let next = S.applyTie(entrants, {player1Id: p1, player2Id: p2});
    next = next.map((e) =>
      (e.uid === p1 || e.uid === p2) ? {...e, currentMatchId: null} : e);
    const {update, champ} = _championUpdate(t, next, Date.now());
    tx.update(ref, update);
    return {applied: true, tie: true, champion: champ.winnerUid};
  });
}

/**
 * Scheduled backstop for every running gauntlet: settle played matches whose
 * vote window has closed, forfeit stale unplayed ones (a no-show hands the
 * win to whoever showed up; a double no-show drops both), and crown the
 * champion at the window's end. Best-effort per tournament.
 */
async function sweepGauntlet(nowMs = Date.now()) {
  const db = getFirestore();
  const snap = await db.collection("tournaments")
      .where("status", "in", ["open", "in_progress"]).get();
  const results = [];
  for (const doc of snap.docs) {
    if (!isSwiss(doc.data())) continue;
    try {
      results.push(await _sweepOne(db, doc.ref, nowMs));
    } catch (e) {
      console.error(`gauntlet sweep for ${doc.id} failed:`, e.message);
      results.push({tournamentId: doc.id, error: e.message});
    }
  }
  return {swept: results.length, results};
}

async function _sweepOne(db, ref, nowMs) {
  const {voteWindowEndMs, finalizeMatch} = require("./matchFinalization");
  const pre = entrantsOf((await ref.get()).data());
  const handled = new Set();

  for (const e of pre) {
    if (e.status !== S.STATUS.inMatch || !e.currentMatchId) continue;
    if (handled.has(e.currentMatchId)) continue; // both entrants share it
    handled.add(e.currentMatchId);

    const mRef = db.collection("matches").doc(e.currentMatchId);
    const mSnap = await mRef.get();
    if (!mSnap.exists) continue;
    const match = mSnap.data();

    if (match.status === "completed" && !match.voteFinalized) {
      // Played out: settle once the short vote window has closed. finalize
      // routes the result back through applySwissResult/applySwissTie.
      if (nowMs >= voteWindowEndMs(match)) {
        await finalizeMatch(e.currentMatchId).catch((err) =>
          console.error(`gauntlet finalize ${e.currentMatchId}:`, err.message));
      }
      continue;
    }
    if (match.status === "completed") continue; // already finalized

    // Not completed: judge a possible no-show. createdMs from the Timestamp.
    const createdMs = match.createdAt && typeof match.createdAt.toMillis ===
      "function" ? match.createdAt.toMillis() : Number(match.createdMs);
    const decision = climbForfeitDecision({...match, createdMs}, nowMs, {
      matchTimeoutMs: MATCH_TIMEOUT_MS,
      battleAbandonMs: BATTLE_ABANDON_MS,
      presenceStaleMs: CLIMB_PRESENCE_STALE_MS,
    });
    if (decision.action !== "forfeit") continue;

    await _forfeitSwissMatch(db, ref, match, e.currentMatchId, decision.winnerUid);
  }

  // Crown the champion if the window has ended (or everyone is done).
  const post = entrantsOf((await ref.get()).data());
  const champ = S.resolveChampion(post, {windowEnded: windowEnded(
      (await ref.get()).data() || {}, nowMs)});
  if (champ.done) {
    const t = (await ref.get()).data();
    if (t && isRunning(t)) {
      await ref.update({
        status: champ.winnerUid ? "completed" : "cancelled",
        winnerId: champ.winnerUid,
        "swiss.championUid": champ.winnerUid,
      });
    }
  }
  return {tournamentId: ref.id, handled: handled.size};
}

/** Forfeit a stale match: present player wins (dropped opponent), or both
 * dropped on a double no-show. Also frees the match. Idempotent via the
 * currentMatchId guard. */
async function _forfeitSwissMatch(db, ref, match, matchId, winnerUid) {
  const p1 = match.player1Id;
  const p2 = match.player2Id;
  await db.runTransaction(async (tx) => {
    const s = await tx.get(ref);
    if (!s.exists) return;
    const t = s.data();
    const entrants = entrantsOf(t);
    const e1 = entrants.find((e) => e.uid === p1);
    const e2 = entrants.find((e) => e.uid === p2);
    if (!e1 || !e2 || e1.currentMatchId !== matchId ||
        e2.currentMatchId !== matchId) {
      return; // already handled
    }
    let next;
    if (winnerUid) {
      const loserUid = winnerUid === p1 ? p2 : p1;
      next = S.applyForfeit(entrants, {winnerUid, loserUid},
          {maxRounds: SWISS_MAX_ROUNDS});
    } else {
      next = S.applyDoubleNoShow(entrants, {player1Id: p1, player2Id: p2});
    }
    next = next.map((e) =>
      (e.uid === p1 || e.uid === p2) ? {...e, currentMatchId: null} : e);
    const {update} = _championUpdate(t, next, Date.now());
    // Free the match doc so nothing tries to re-settle it.
    tx.update(db.collection("matches").doc(matchId),
        {status: "abandoned", voteFinalized: true, winnerId: null});
    tx.update(ref, update);
  });
}

module.exports = {
  signUpGauntlet,
  gauntletPoll,
  applySwissResult,
  applySwissTie,
  sweepGauntlet,
  SWISS_MAX_ROUNDS,
  SWISS_VOTE_MS,
  entrantsOf,
  windowLive,
  windowEnded,
  signupsOpen,
};
