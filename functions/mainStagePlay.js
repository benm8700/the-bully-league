const crypto = require("crypto");
const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {loadBracket} = require("./mainStageLifecycle");
const {tallyJudgeVotes} = require("./mainStageJudging");
const {DEFAULTS: BATTLE_DEFAULTS, resolveGraceMs} = require("./mainStageBattle");

/**
 * Main Stage finals - playing a bracket battle and the live judge-panel
 * settlement (the lean model: players in a battle channel, judges watch as
 * spectators and cast OPEN votes, the 5-vote verdict settles the battle and
 * advances the #1-callout bracket). The deferred "judges'-video-table +
 * broadcast desk" is a later layer; this is the core loop.
 */

const STARTING_RATING = 1200;
// No judging deadline: a debate runs as long or short as it needs, and a battle
// settles when the panel reaches a verdict (a majority / early-decisive in
// castMainStageJudgeVote), never on a clock.

function httpsError(code, message) {
  const {HttpsError} = require("firebase-functions/v2/https");
  return new HttpsError(code, message);
}

function pairingFor(match, matchId, uid) {
  return {
    matchId,
    channelName: match.channelName,
    opponentId: match.player1Id === uid ? match.player2Id : match.player1Id,
    mode: match.mode,
    settings: match.settings,
    mainStageConfig: match.mainStageConfig,
    agoraUid: match.player1Id === uid ? 1 : 2,
  };
}

/**
 * Start (or rejoin) a Main Stage bracket battle. The two players of the
 * matchup are NAMED (not queued), so the match id is stored ON the bracket
 * matchup - whoever starts first creates it, the other rejoins the same one.
 * Returns the standard pairing the battle screen consumes.
 */
async function startMainStageBattle(auth, data) {
  if (!auth) throw httpsError("unauthenticated", "Must be signed in.");
  const {tournamentId} = data || {};
  const roundIdx = Math.trunc(Number(data?.roundIdx));
  const matchIdx = Math.trunc(Number(data?.matchIdx));
  if (!tournamentId || !Number.isFinite(roundIdx) || !Number.isFinite(matchIdx)) {
    throw httpsError("invalid-argument", "Missing tournamentId/roundIdx/matchIdx.");
  }
  const db = getFirestore();
  // Settings resolve outside the transaction (they do their own reads).
  const {getMatchSettings} = require("./matchSettings");
  const settings = await getMatchSettings("tournament");
  // The interrupt grace is console-tunable from config/tournament (bounds-
  // checked, falls back to the product default), resolved once at creation and
  // stamped on the match so both players run the same clock.
  const tcfg = (await db.collection("config").doc("tournament").get()).data() || {};
  const graceMs = resolveGraceMs(tcfg.mainStageGraceMs);
  const tRef = db.collection("tournaments").doc(tournamentId);

  const matchId = await db.runTransaction(async (tx) => {
    const t = (await tx.get(tRef)).data();
    if (!t || t.format !== "mainstage" || t.status !== "live" || !t.bracket) {
      throw httpsError("failed-precondition", "No live Main Stage bracket.");
    }
    const bracket = loadBracket(t.bracket); // core shape: rounds[][]
    const m = bracket.rounds[roundIdx] && bracket.rounds[roundIdx][matchIdx];
    if (!m) throw httpsError("failed-precondition", "No such matchup.");
    if (!m.a || !m.b) throw httpsError("failed-precondition", "Matchup not ready.");
    if (m.winner) throw httpsError("failed-precondition", "That battle is over.");
    if (auth.uid !== m.a && auth.uid !== m.b) {
      throw httpsError("permission-denied", "You're not in this matchup.");
    }
    if (m.matchId) {
      // Rejoin ONLY a battle that is still playable. Once completeMatch has
      // flipped it to completed/abandoned, its Agora token is refused (the
      // match has ended) and the matchup is awaiting the judges' verdict - so
      // handing the id back would strand the client on a dead channel with a
      // raw "failed-precondition". Block re-entry cleanly until it's resolved.
      const existing =
        (await tx.get(db.collection("matches").doc(m.matchId))).data();
      const stillPlayable = existing &&
        (existing.status === "pending" || existing.status === "in_progress");
      if (stillPlayable) return m.matchId; // genuine rejoin of a live battle
      throw httpsError("failed-precondition",
          "That battle has already been played - the judges are deciding it.");
    }

    const id = `ms_${crypto.randomBytes(12).toString("hex")}`;
    const [uA, uB] = await Promise.all([
      tx.get(db.collection("users").doc(m.a)),
      tx.get(db.collection("users").doc(m.b)),
    ]);
    const p1Rating = (uA.data() || {}).rating ?? STARTING_RATING;
    const p2Rating = (uB.data() || {}).rating ?? STARTING_RATING;

    tx.set(db.collection("matches").doc(id), {
      player1Id: m.a,
      player2Id: m.b,
      player1Rating: p1Rating,
      player2Rating: p2Rating,
      mode: "tournament", // ratable + enters finalize's tournament routing...
      mainStage: {tournamentId, roundIdx, matchIdx}, // ...which routes HERE
      mainStageConfig: {...BATTLE_DEFAULTS, graceMs}, // chess-clock timings for the UI
      settings,
      status: "pending",
      channelName: `match_${id}`, // short (ms_ + 24 hex) -> well under 64 bytes
      origin: "mainstage",
      createdAt: FieldValue.serverTimestamp(),
    });

    // Stamp the match id onto the bracket matchup so the opponent rejoins the
    // same doc. Firestore can't address array elements by dotted path, so
    // read-modify-write the whole stored bracket.
    const stored = t.bracket;
    const rounds = stored.rounds.map((r, ri) => ({
      ...r,
      matches: r.matches.map((mm, mi) =>
        (ri === roundIdx && mi === matchIdx) ? {...mm, matchId: id} : mm),
    }));
    tx.update(tRef, {bracket: {...stored, rounds}});
    return id;
  });

  // A battle is now on stage - pull the judges in to judge it (best-effort,
  // deduped per matchId so a rejoin doesn't re-push).
  try {
    const {notifyBattleOnStage} = require("./mainStageNotify");
    await notifyBattleOnStage(tournamentId, matchId);
  } catch (e) {
    console.error("notifyBattleOnStage failed:", e.message);
  }

  const match = (await db.collection("matches").doc(matchId).get()).data();
  return pairingFor(match, matchId, auth.uid);
}

// After the panel DECIDES, the result locks but the match does NOT end for
// another 30 seconds - the judges stay on camera and keep talking (a reaction
// beat, and good footage), then it settles. The decision is made the moment the
// panel decides; this is only the buffer before cameras stop. Tunable.
const SETTLE_BUFFER_MS = 30 * 1000;

/**
 * A seated judge casts (or changes) their OPEN vote for a finals battle. The
 * vote is public (the crowd sees each pick land live). When the panel's verdict
 * is decided, the winner is LOCKED (judgeWinnerId + judgeDecidedAtMs) but the
 * battle is NOT finalized yet - settleMainStageBattle does that after the 30s
 * grace, so the judges get a reaction beat on camera before it ends.
 */
async function castMainStageJudgeVote(auth, data) {
  if (!auth) throw httpsError("unauthenticated", "Must be signed in.");
  const {matchId, winnerUid} = data || {};
  if (!matchId || !winnerUid) {
    throw httpsError("invalid-argument", "Missing matchId or winnerUid.");
  }
  const db = getFirestore();
  const matchRef = db.collection("matches").doc(matchId);
  const votesCol = matchRef.collection("mainStageVotes");

  const outcome = await db.runTransaction(async (tx) => {
    const match = (await tx.get(matchRef)).data();
    if (!match || !match.mainStage) {
      throw httpsError("failed-precondition", "Not a Main Stage battle.");
    }
    if (match.judgeWinnerId) {
      return {decided: true, winner: match.judgeWinnerId, already: true};
    }
    // Voting happens during the DEBATE - after the battle ends, not while it is
    // still being fought. This is both the product rule (the crowd sees each
    // vote land live at the judges' table) and a real guard: without it a judge
    // voting mid-battle could tally-decide and flip the match to "completed",
    // ending the live battle for everyone early.
    if (match.status !== "completed") {
      throw httpsError("failed-precondition",
          "Voting opens when the battle ends, during the debate.");
    }
    if (winnerUid !== match.player1Id && winnerUid !== match.player2Id) {
      throw httpsError("invalid-argument", "Pick one of the two battlers.");
    }
    const t = (await tx.get(
        db.collection("tournaments").doc(match.mainStage.tournamentId))).data();
    const panel = (t && Array.isArray(t.judges)) ? t.judges : [];
    if (!panel.includes(auth.uid)) {
      throw httpsError("permission-denied", "Only seated judges vote here.");
    }
    // The head judge (founder) breaks a tie: the first seated hand-pick.
    const headJudge = (t.handPickedJudges || []).find((u) => panel.includes(u)) || null;

    const existing = await tx.get(votesCol);
    const votes = {};
    existing.forEach((d) => {
      votes[d.id] = d.data().winnerUid;
    });
    votes[auth.uid] = winnerUid; // this judge's new/updated pick

    tx.set(votesCol.doc(auth.uid), {
      winnerUid,
      at: FieldValue.serverTimestamp(),
    });

    const tally = tallyJudgeVotes(votes, panel, {headJudge});
    // LOCK the verdict on decision, but do NOT finalize/end here - stamp when it
    // was decided so the 30s grace can run (settleMainStageBattle finishes it).
    if (tally.decided && tally.winner) {
      tx.update(matchRef,
          {judgeWinnerId: tally.winner, judgeDecidedAtMs: Date.now()});
    }
    return {decided: tally.decided, winner: tally.winner,
      counts: tally.counts, cast: tally.cast};
  });

  return outcome;
}

/**
 * Finish a DECIDED finals battle once its 30s grace has elapsed: applies the
 * finals Elo and advances the bracket (finalize). Client-nudged when the grace
 * countdown hits zero, and backstopped by the sweep (settleDecidedBattles) in
 * case every client has left. The server re-checks the buffer, so a client
 * cannot end it early. Idempotent.
 */
async function settleMainStageBattle(auth, data) {
  if (!auth) throw httpsError("unauthenticated", "Must be signed in.");
  const {matchId} = data || {};
  if (!matchId) throw httpsError("invalid-argument", "Missing matchId.");
  const db = getFirestore();
  const match = (await db.collection("matches").doc(matchId).get()).data();
  if (!match || !match.mainStage) {
    throw httpsError("failed-precondition", "Not a Main Stage battle.");
  }
  if (match.voteFinalized) return {settled: true, already: true};
  if (!match.judgeWinnerId) return {settled: false, reason: "not-decided"};
  const decidedAt = Number(match.judgeDecidedAtMs) || 0;
  const remainingMs = decidedAt + SETTLE_BUFFER_MS - Date.now();
  if (remainingMs > 0) return {settled: false, remainingMs};
  const {finalizeMatch} = require("./matchFinalization");
  await finalizeMatch(matchId, {force: true});
  return {settled: true};
}

/**
 * Sweep backstop: finalize any mainstage battle that was DECIDED and whose 30s
 * grace has elapsed but was never settled (every client left before the nudge).
 * Only finishes battles the panel ALREADY decided - it never forces a verdict.
 *
 * Scans the LIVE mainstage tournaments' brackets (a handful) and reads each
 * started matchup's doc directly, so it needs no composite index and no stamped
 * voteFinalized field.
 */
async function settleDecidedBattles(db, now = Date.now()) {
  const snap = await db.collection("tournaments")
      .where("format", "==", "mainstage")
      .where("status", "==", "live").get();
  const out = [];
  const {finalizeMatch} = require("./matchFinalization");
  for (const d of snap.docs) {
    const t = d.data();
    if (!t.bracket) continue;
    const bracket = loadBracket(t.bracket); // core shape: rounds[][]
    for (const round of bracket.rounds) {
      for (const m of (round || [])) {
        if (!m || !m.matchId || m.winner != null) continue;
        const match = (await db.collection("matches").doc(m.matchId).get()).data();
        if (!match || match.voteFinalized || !match.judgeWinnerId) continue;
        const decidedAt = Number(match.judgeDecidedAtMs) || 0;
        if (!decidedAt || now < decidedAt + SETTLE_BUFFER_MS) continue;
        try {
          await finalizeMatch(m.matchId, {force: true});
          out.push(m.matchId);
        } catch (e) {
          console.error(`mainstage settle ${m.matchId}:`, e.message);
        }
      }
    }
  }
  return out;
}

module.exports = {
  startMainStageBattle,
  castMainStageJudgeVote,
  settleMainStageBattle,
  settleDecidedBattles,
  SETTLE_BUFFER_MS,
};
