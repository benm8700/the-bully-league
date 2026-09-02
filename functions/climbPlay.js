const crypto = require("crypto");
const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {HttpsError} = require("firebase-functions/v2/https");
const {
  STATUS,
  planPairings,
  applyResult,
  applyTie,
  markInMatch,
  resolveChampion,
  standingFor,
  isActive,
  climbForfeitDecision,
} = require("./climbTournament");
const {STARTING_RATING} = require("./rating");

/**
 * Wiring for the nightly "climb" tournament (CLAUDE.md's rolling
 * single-elimination format). The DECISIONS all live in the pure engine
 * (climbTournament.js, simulation-tested); this file is the plumbing: joining,
 * pairing same-tier climbers into real matches, applying a settled result, and
 * the sweep that force-resolves the endgame and crowns the champion.
 *
 * The whole climb state is an ARRAY on the tournament document
 * (`climb.climbers`), exactly like the bracket stores `bracket.rounds`, so a
 * pairing is a single-document transaction and can never double-book two
 * climbers. Clients never write it - they poll `climbPoll`, which does the
 * pairing server-side, the same shape as the matchmaking queue.
 */

/** The last stretch of the window: no new joins, and stranded waiters are
 * force-paired top-down so the event converges on a champion instead of
 * stalling. */
const RESOLVE_GRACE_MS = 5 * 60 * 1000;

/** A climb match nobody plays is forfeited after this, so one no-show cannot
 * freeze a climber (and everyone waiting behind them) in place. Judged only
 * on a match where the battle NEVER started (see climbForfeitDecision) - a
 * battle in progress is exempt, which is the bug the 2026-09-01 dry run
 * found: a real battle stays `pending` its whole duration and was being
 * killed at this timeout. */
const MATCH_TIMEOUT_MS = 8 * 60 * 1000;

/** Once BOTH players have readied the battle has started; heartbeats stop, so
 * presence can no longer be judged. Only after this long crash-safety window
 * (comfortably longer than the longest configured battle + a late ready) is a
 * both-ready match that never settled abandoned as a no-contest. */
const BATTLE_ABANDON_MS = 25 * 60 * 1000;

/** No heartbeat within this = walked away (mirrors matchmaking's
 * PRESENCE_STALE_MS for ordinary bio-reveals). */
const CLIMB_PRESENCE_STALE_MS = 75 * 1000;

/** Voting on a climb match closes fast so the winner climbs while the crowd is
 * still here - same idea as a live tournament. The chance to OBJECT to the
 * clip is untouched (a full day, via objectionWindowEndMs); this shortens
 * voting only. */
const CLIMB_VOTE_MS = 90 * 1000;

/** Two climbers meet at most once (single elimination eliminates the loser),
 * so a match id derived from the pair is unique for the tournament. Sorted so
 * both clients compute the same id and the same fixed Agora uids. */
function climbMatchId(tournamentId, a, b) {
  // Deterministic from the tournament + the sorted uid pair, but SHORT.
  // The obvious `c_${tournamentId}_${x}_${y}` embeds two 28-char Firebase
  // UIDs, producing an ~80-char id and a `match_`-prefixed Agora channel of
  // ~86 chars - over Agora's 64-BYTE channel-name limit, so joinChannel
  // fails with ERR_INVALID_APP_ID (-102). Every other match type uses a
  // short auto-id, which is why only the climb hit this. A 24-hex-char
  // (96-bit) hash is collision-safe and keeps the channel at ~32 chars.
  const [x, y] = [a, b].sort();
  const h = crypto.createHash("sha1")
      .update(`${tournamentId}_${x}_${y}`).digest("hex").slice(0, 24);
  return `c_${h}`;
}

function climbersOf(t) {
  return Array.isArray(t && t.climb && t.climb.climbers) ?
    t.climb.climbers : [];
}

function num(v) {
  const n = Number(v);
  return Number.isFinite(n) && n > 0 ? n : null;
}

function windowEndMsOf(t) {
  return num(t && (t.windowEndMs || (t.climb && t.climb.windowEndMs)));
}

function windowStartMsOf(t) {
  return num(t && (t.windowStartMs || t.startsAtMs ||
    (t.climb && t.climb.windowStartMs)));
}

/** Joins close in the final stretch (and after the window ends). */
function joinsClosed(t, nowMs) {
  const end = windowEndMsOf(t);
  return end !== null && nowMs >= end - RESOLVE_GRACE_MS;
}

function windowEnded(t, nowMs) {
  const end = windowEndMsOf(t);
  return end !== null && nowMs >= end;
}

/** In the resolve grace (or past the end): force-pair the survivors. */
function forceResolveNow(t, nowMs) {
  return joinsClosed(t, nowMs);
}

function isClimb(t) {
  return t && t.format === "climb";
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
 * Enter tonight's climb at 0 wins. You may join any time the window is live,
 * up until the final stretch. Losing once eliminates you for the night, so a
 * knocked-out player cannot re-enter to farm another run.
 */
async function joinClimb(auth, data) {
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
  if (!isClimb(t)) {
    throw new HttpsError("failed-precondition", "This isn't a climb event.");
  }
  if (!isRunning(t)) {
    throw new HttpsError("failed-precondition", "This tournament has ended.");
  }
  if (windowEnded(t, nowMs)) {
    throw new HttpsError("failed-precondition", "Tonight's climb has ended.");
  }
  if (joinsClosed(t, nowMs)) {
    throw new HttpsError("failed-precondition",
        "Joining has closed - watch the finals.");
  }
  const start = windowStartMsOf(t);
  if (start !== null && nowMs < start) {
    throw new HttpsError("failed-precondition", "The climb hasn't started yet.");
  }

  // MANDATORY intro video, same gate as ranked/tournament - a climb battle is
  // recorded and clip-eligible, and the opponent studies your intro. (Practice
  // is the only exemption, and this is not practice.)
  const userSnap = await db.collection("users").doc(uid).get();
  const profile = userSnap.data() && userSnap.data().profile;
  const introUrl = profile && profile.introVideoUrl;
  if (typeof introUrl !== "string" || introUrl.length === 0) {
    throw new HttpsError("failed-precondition",
        "Record your intro video before you battle - your opponent needs " +
        "something to work with.");
  }

  const outcome = await db.runTransaction(async (tx) => {
    const s = await tx.get(ref);
    const climbers = climbersOf(s.data());
    const mine = climbers.find((c) => c.uid === uid);
    if (mine) {
      if (mine.status === STATUS.eliminated) return {status: "eliminated"};
      return {status: "already-in"};
    }
    const next = [
      ...climbers,
      {uid, wins: 0, status: STATUS.waiting, joinedMs: nowMs,
        currentMatchId: null},
    ];
    tx.update(ref, {"climb.climbers": next});
    return {status: "joined"};
  });

  if (outcome.status === "eliminated") {
    throw new HttpsError("failed-precondition",
        "You were knocked out tonight - you're out until tomorrow.");
  }
  const climbers = climbersOf((await ref.get()).data());
  return {joined: true, standing: standingFor(climbers, uid)};
}

/**
 * A waiting climber asks to be paired. Polled repeatedly, like matchmaking.
 * Returns the caller's live state: their match if they are in one, an
 * elimination notice, or their standing while waiting.
 */
async function climbPoll(auth, data) {
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
  let climbers = climbersOf(t);
  let me = climbers.find((c) => c.uid === uid);
  if (!me) {
    throw new HttpsError("failed-precondition", "Join the climb first.");
  }

  // Already in a match - hand it back so the client (re)joins it.
  if (me.status === STATUS.inMatch && me.currentMatchId) {
    const m = await db.collection("matches").doc(me.currentMatchId).get();
    if (m.exists && m.data().status !== "completed" &&
        !m.data().voteFinalized) {
      return {state: "in_match", ...matchPairing({...m.data(), id: m.id}, uid),
        standing: standingFor(climbers, uid)};
    }
    // The match finished but the result has not been applied yet; report as
    // waiting - the next poll (after finalize) reflects the new tier.
    return {state: "waiting", standing: standingFor(climbers, uid)};
  }

  if (me.status === STATUS.eliminated) {
    return {state: "eliminated", standing: standingFor(climbers, uid)};
  }

  if (t.status === "completed") {
    return {state: "done", winnerUid: t.winnerId ?? null};
  }

  // Waiting: find a same-win-count opponent (force-resolve only in the final
  // stretch, so the survivors are funnelled together rather than stalling).
  const pairs = planPairings(climbers, {forceResolve: forceResolveNow(t, nowMs)});
  const mine = pairs.find((p) => p.includes(uid));
  if (mine) {
    const opponentUid = mine[0] === uid ? mine[1] : mine[0];
    await _createClimbMatch(db, ref, tournamentId, uid, opponentUid);
  }

  // Re-read: whether we just paired, or an opponent's poll paired us, the
  // fresh state is the source of truth (this is what resolves the race where
  // both players poll at once).
  const fresh = climbersOf((await ref.get()).data());
  me = fresh.find((c) => c.uid === uid);
  if (me && me.status === STATUS.inMatch && me.currentMatchId) {
    const m = await db.collection("matches").doc(me.currentMatchId).get();
    if (m.exists) {
      return {state: "in_match", ...matchPairing({...m.data(), id: m.id}, uid),
        standing: standingFor(fresh, uid)};
    }
  }
  return {state: "waiting", standing: standingFor(fresh, uid)};
}

/** Claims a pairing and creates its match, atomically. No-op if either
 * climber was already claimed (the opponent's poll won the race). */
async function _createClimbMatch(db, ref, tournamentId, a, b) {
  const {getMatchSettings} = require("./matchSettings");
  const settings = await getMatchSettings("tournament");
  // A UNIQUE id per pairing, NOT derived from the pair - because the TIE rule
  // (both advance) lets the same two players meet AGAIN at a higher tier, and a
  // pair-derived id would collide with their earlier match's already-finalized
  // doc and strand them `in_match` forever. Double-creation is prevented by the
  // transaction on the tournament doc below (the loser of the pairing race sees
  // both already in_match and aborts), so the id does not need to be
  // deterministic for that.
  const matchId = `c_${crypto.randomBytes(12).toString("hex")}`;
  const matchRef = db.collection("matches").doc(matchId);
  const [p1, p2] = [a, b].sort();

  await db.runTransaction(async (tx) => {
    const s = await tx.get(ref);
    const climbers = climbersOf(s.data());
    const ca = climbers.find((c) => c.uid === a);
    const cb = climbers.find((c) => c.uid === b);
    // Both must still be waiting AND at the same tier we planned on. If not,
    // someone else already paired one of them - abort cleanly.
    if (!ca || !cb) return;
    if (ca.status !== STATUS.waiting || cb.status !== STATUS.waiting) return;

    const existing = await tx.get(matchRef);
    // Read both players' current hidden Elo (all reads must precede writes in
    // a transaction) and STAMP it on the match. Gauntlet wins move Elo like
    // ranked - finalize reads live ratings for present players, but the stamp
    // is the fallback so a win still counts if the OPPONENT deletes their
    // account before the match finalizes (same pattern as ranked pairing).
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
        voteWindowMs: CLIMB_VOTE_MS,
        // The climb IS the Sixes and Sevens event and it is free to enter, so
        // unlike a paid bracket its matches DO count toward the daily 2x window
        // bonus - this is exactly "turning up to Sixes and Sevens".
        eventWindow: {qualified: true, name: s.data().name ?? "Sixes and Sevens"},
        origin: "climb",
        climb: {tournamentId},
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
    const updated = markInMatch(climbers, [a, b]).map((c) =>
      (c.uid === a || c.uid === b) ? {...c, currentMatchId: matchId} : c);
    tx.update(ref, {"climb.climbers": updated});
  });
}

/**
 * Apply a settled climb match to the ladder: winner climbs a tier and returns
 * to waiting, loser is eliminated. Called from finalizeMatch. Idempotent - a
 * retried finalize must not double-count.
 */
async function applyClimbResult(match, winnerId, matchId) {
  const tournamentId = match.climb && match.climb.tournamentId;
  if (!tournamentId) return {skipped: "not-a-climb-match"};
  if (!matchId) return {skipped: "no-match-id"};
  const loserId = winnerId === match.player1Id ?
    match.player2Id : match.player1Id;
  const db = getFirestore();
  const ref = db.collection("tournaments").doc(tournamentId);

  return db.runTransaction(async (tx) => {
    const s = await tx.get(ref);
    if (!s.exists) return {skipped: "no-tournament"};
    const t = s.data();
    const climbers = climbersOf(t);
    const winner = climbers.find((c) => c.uid === winnerId);
    // Guard idempotency: only apply while the pair is still on THIS match.
    if (!winner || winner.currentMatchId !== matchId ||
        winner.status !== STATUS.inMatch) {
      return {skipped: "already-applied"};
    }
    let next = applyResult(climbers, {winnerUid: winnerId, loserUid: loserId});
    next = next.map((c) =>
      (c.uid === winnerId || c.uid === loserId) ?
        {...c, currentMatchId: null} : c);

    const update = {"climb.climbers": next};
    const champ = resolveChampion(next, {
      joinsClosed: joinsClosed(t, Date.now()),
      windowEnded: windowEnded(t, Date.now()),
    });
    if (champ.done) {
      update.status = "completed";
      update.winnerId = champ.winnerUid;
      update["climb.championUid"] = champ.winnerUid;
    }
    tx.update(ref, update);
    return {applied: true, wins: winner.wins + 1, champion: champ.winnerUid};
  });
}

/**
 * Apply a TIED climb match: both climbers advance a tier and return to waiting
 * (the developer's tie rule, 2026-09-01 - a draw knocks nobody out). Called
 * from finalizeMatch when a climb match settles with NO winner. Idempotent -
 * only applies while BOTH are still on this match.
 */
async function applyClimbTie(match, matchId) {
  const tournamentId = match.climb && match.climb.tournamentId;
  if (!tournamentId) return {skipped: "not-a-climb-match"};
  if (!matchId) return {skipped: "no-match-id"};
  const db = getFirestore();
  const ref = db.collection("tournaments").doc(tournamentId);
  const p1 = match.player1Id;
  const p2 = match.player2Id;

  return db.runTransaction(async (tx) => {
    const s = await tx.get(ref);
    if (!s.exists) return {skipped: "no-tournament"};
    const t = s.data();
    const climbers = climbersOf(t);
    const c1 = climbers.find((c) => c.uid === p1);
    const c2 = climbers.find((c) => c.uid === p2);
    // Both must still be on THIS match (idempotency, same guard as a win).
    if (!c1 || !c2 ||
        c1.currentMatchId !== matchId || c2.currentMatchId !== matchId ||
        c1.status !== STATUS.inMatch || c2.status !== STATUS.inMatch) {
      return {skipped: "already-applied"};
    }
    let next = applyTie(climbers, {player1Id: p1, player2Id: p2});
    next = next.map((c) =>
      (c.uid === p1 || c.uid === p2) ? {...c, currentMatchId: null} : c);

    const update = {"climb.climbers": next};
    const champ = resolveChampion(next, {
      joinsClosed: joinsClosed(t, Date.now()),
      windowEnded: windowEnded(t, Date.now()),
    });
    if (champ.done) {
      update.status = "completed";
      update.winnerId = champ.winnerUid;
      update["climb.championUid"] = champ.winnerUid;
    }
    tx.update(ref, update);
    return {applied: true, tie: true, champion: champ.winnerUid};
  });
}

/**
 * The scheduled backstop for every running climb: force-resolve the endgame,
 * forfeit stale unplayed matches so one no-show cannot freeze the ladder, and
 * crown the champion at the window's end. Idempotent and best-effort per
 * tournament, so one malformed doc never stops the others.
 */
async function sweepClimb(nowMs = Date.now()) {
  const db = getFirestore();
  const snap = await db.collection("tournaments")
      .where("status", "in", ["open", "in_progress"]).get();

  const results = [];
  for (const doc of snap.docs) {
    if (!isClimb(doc.data())) continue;
    try {
      results.push(await _sweepOne(db, doc.ref, nowMs));
    } catch (e) {
      console.error(`climb sweep for ${doc.id} failed:`, e.message);
      results.push({tournamentId: doc.id, error: e.message});
    }
  }
  return {swept: results.length, results};
}

async function _sweepOne(db, ref, nowMs) {
  // 1. Move each in-match pair forward: settle a played battle whose vote
  // window has closed (which advances the ladder via applyClimbResult inside
  // finalizeMatch), or forfeit one that was never played and has timed out.
  // Nothing else settles climb matches - the live-settle sweep only looks at
  // format:"live", and the 24h expiry sweep is far too slow for a nightly
  // event.
  const {voteWindowEndMs, finalizeMatch} = require("./matchFinalization");
  const pre = climbersOf((await ref.get()).data());
  const handled = new Set();
  for (const c of pre) {
    if (c.status !== STATUS.inMatch || !c.currentMatchId) continue;
    if (handled.has(c.currentMatchId)) continue; // both climbers share it
    handled.add(c.currentMatchId);
    const mSnap = await db.collection("matches").doc(c.currentMatchId).get();
    if (!mSnap.exists) continue;
    const m = mSnap.data();
    if (m.voteFinalized) continue;

    // (a) Played, and voting has closed -> settle it. finalizeMatch calls
    // applyClimbResult, so the winner climbs and the loser is eliminated.
    if (m.status === "completed") {
      if (nowMs > voteWindowEndMs(m)) await finalizeMatch(c.currentMatchId);
      continue;
    }

    // (b) Not settled by (a). Decide whether to leave it alone or forfeit it,
    // keyed on whether the BATTLE STARTED (both readied) and on presence -
    // NOT on a fixed age-since-creation, which is what killed live battles.
    // See climbForfeitDecision.
    const createdMs = m.createdAt && typeof m.createdAt.toMillis === "function" ?
      m.createdAt.toMillis() : null;
    const decision = climbForfeitDecision({...m, createdMs}, nowMs, {
      matchTimeoutMs: MATCH_TIMEOUT_MS,
      battleAbandonMs: BATTLE_ABANDON_MS,
      presenceStaleMs: CLIMB_PRESENCE_STALE_MS,
    });
    if (decision.action === "wait") continue;
    const winnerId = decision.winnerUid;
    await mSnap.ref.set({status: "abandoned", voteFinalized: true,
      winnerId, completedAt: FieldValue.serverTimestamp()}, {merge: true});
    if (winnerId) {
      await applyClimbResult(m, winnerId, c.currentMatchId);
    } else {
      await db.runTransaction(async (tx) => {
        const s = await tx.get(ref);
        let cs = climbersOf(s.data());
        cs = cs.map((x) => (x.uid === m.player1Id || x.uid === m.player2Id) ?
          {...x, status: STATUS.eliminated, currentMatchId: null} : x);
        tx.update(ref, {"climb.climbers": cs});
      });
    }
  }

  // 2. Force-resolve + champion, in one transaction on the fresh state.
  return db.runTransaction(async (tx) => {
    const s = await tx.get(ref);
    const t = s.data();
    if (!isRunning(t)) return {tournamentId: ref.id, skipped: "not-running"};
    const climbers = climbersOf(t);

    const champ = resolveChampion(climbers, {
      joinsClosed: joinsClosed(t, nowMs),
      windowEnded: windowEnded(t, nowMs),
    });
    if (champ.done) {
      // A real winner completes it; an empty field at window end is cancelled
      // rather than "completed" with nobody (e.g. a night nobody showed up).
      if (champ.winnerUid) {
        tx.update(ref, {
          status: "completed",
          winnerId: champ.winnerUid,
          "climb.championUid": champ.winnerUid,
        });
        return {tournamentId: ref.id, completed: true,
          winnerUid: champ.winnerUid};
      }
      tx.update(ref, {status: "cancelled", cancelledReason: "no-climbers"});
      return {tournamentId: ref.id, cancelled: true};
    }

    // Not done: if we are in the resolve stretch and there are stranded
    // waiters with no same-count pair, force-pair the top survivors so the
    // ladder converges. Actual match creation happens after the tx (it needs
    // its own writes), so here we just report what to pair.
    if (forceResolveNow(t, nowMs)) {
      const same = planPairings(climbers, {forceResolve: false});
      const forced = planPairings(climbers, {forceResolve: true});
      if (same.length === 0 && forced.length > 0) {
        return {tournamentId: ref.id, forcePair: forced};
      }
    }
    return {tournamentId: ref.id, active: climbers.filter(isActive).length};
  }).then(async (r) => {
    if (r.forcePair) {
      for (const [a, b] of r.forcePair) {
        await _createClimbMatch(db, ref, ref.id, a, b);
      }
    }
    return r;
  });
}

module.exports = {
  joinClimb,
  climbPoll,
  applyClimbResult,
  applyClimbTie,
  sweepClimb,
  // Exported for tests / reuse.
  climbMatchId,
  climbersOf,
  joinsClosed,
  windowEnded,
  forceResolveNow,
  isClimb,
  RESOLVE_GRACE_MS,
  MATCH_TIMEOUT_MS,
  CLIMB_VOTE_MS,
};
