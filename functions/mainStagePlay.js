const crypto = require("crypto");
const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {loadBracket} = require("./mainStageLifecycle");
const {tallyJudgeVotes} = require("./mainStageJudging");
const {DEFAULTS: BATTLE_DEFAULTS} = require("./mainStageBattle");

/**
 * Main Stage finals - playing a bracket battle and the live judge-panel
 * settlement (the lean model: players in a battle channel, judges watch as
 * spectators and cast OPEN votes, the 5-vote verdict settles the battle and
 * advances the #1-callout bracket). The deferred "judges'-video-table +
 * broadcast desk" is a later layer; this is the core loop.
 */

const STARTING_RATING = 1200;
// A generous live judging window; settlement normally lands the moment the
// panel is decided (all voted / early-decisive), but a stalled panel is force-
// closed at this deadline by a sweep (not built yet - see the note in index).
const JUDGE_WINDOW_MS = 12 * 60 * 1000;

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
    if (m.matchId) return m.matchId; // already created - rejoin it

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
      mainStageConfig: {...BATTLE_DEFAULTS}, // chess-clock timings for the UI
      settings,
      judgeWindowMs: JUDGE_WINDOW_MS,
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

  const match = (await db.collection("matches").doc(matchId).get()).data();
  return pairingFor(match, matchId, auth.uid);
}

/**
 * A seated judge casts (or changes) their OPEN vote for a finals battle. The
 * vote is public (the crowd sees the tally live). When the panel's verdict is
 * decided, the winner is stamped and the battle is finalized (force), which
 * applies the finals Elo and advances the bracket.
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
    if (tally.decided) {
      tx.update(matchRef, {judgeWinnerId: tally.winner, status: "completed"});
    }
    return {decided: tally.decided, winner: tally.winner,
      counts: tally.counts, cast: tally.cast};
  });

  // Settle OUTSIDE the vote transaction: finalize applies the finals Elo and
  // routes to recordBattleResult (bracket advance). force, because there is no
  // community vote window for a finals battle.
  if (outcome.decided && !outcome.already && outcome.winner) {
    try {
      const {finalizeMatch} = require("./matchFinalization");
      await finalizeMatch(matchId, {force: true});
    } catch (e) {
      console.error(`mainstage finalize ${matchId} failed:`, e.message);
    }
  }
  return outcome;
}

module.exports = {
  startMainStageBattle,
  castMainStageJudgeVote,
  JUDGE_WINDOW_MS,
};
