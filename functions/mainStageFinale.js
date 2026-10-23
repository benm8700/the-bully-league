const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {HttpsError} = require("firebase-functions/v2/https");

/**
 * The Main Stage FINALE celebration - the "glory" moment when the weekly finals
 * crown a champion.
 *
 * When a Main Stage tournament completes, EVERY player who was in the bracket
 * earns a one-shot placement popup the next time they open the app: Champion,
 * Finalist (lost the final), Semifinalist (lost a semi), and so on by how deep
 * they got. The runner-up also gets a permanent `Runner-Up` award badge, via the
 * server-only `tournamentRunnerUps` counter - the mirror of the champion's
 * `tournamentWins` (see belt.js).
 *
 * Scoped to `format === "mainstage"`: "a bracket with named finalists" is what
 * makes clean placements meaningful. Other formats (swiss/climb) crown a
 * champion with no single opposite number.
 *
 * The finale is a DISCRETE event, not a crossing, so unlike the fame-milestone
 * popup (a "seen marker") this writes a `pendingTournamentFinale` payload that
 * getPendingTournamentFinale returns once and DELETES - fire-and-clear.
 */

/** Rounds as a plain array-of-matchups, tolerant of both storage shapes: the
 * lifecycle stores each round as `{matches:[...]}` (Firestore cannot hold an
 * array directly inside an array), the pure core returns a raw `[...]`. */
function roundsOf(after) {
  const b = after && after.bracket;
  if (!b || !Array.isArray(b.rounds)) return [];
  return b.rounds.map((r) =>
    Array.isArray(r) ? r : (r && Array.isArray(r.matches) ? r.matches : []));
}

/**
 * PURE. The runner-up of a completed Main Stage bracket = the loser of the
 * final. Returns null if the final is not a clean two-finalist match won by
 * `winnerId`. Kept for back-compat; placementsOf supersedes it.
 */
function runnerUpOf(after) {
  const rounds = roundsOf(after);
  const champion = after && after.winnerId;
  if (!champion || rounds.length === 0) return null;
  const matches = rounds[rounds.length - 1];
  const fm = matches && matches[0];
  if (!fm || fm.a == null || fm.b == null) return null;
  if (fm.a !== champion && fm.b !== champion) return null; // champion not in it
  return fm.a === champion ? fm.b : fm.a;
}

/** A label + ordinal place for a player eliminated `roundsFromFinal` rounds
 * before the final (0 = lost the final itself). */
function depthPlacement(roundsFromFinal) {
  if (roundsFromFinal <= 0) return {place: 2, label: "Finalist"};
  if (roundsFromFinal === 1) return {place: 3, label: "Semifinalist"};
  if (roundsFromFinal === 2) return {place: 5, label: "Quarterfinalist"};
  // Deeper brackets (8+ wide): "Round of N", tied place.
  return {place: (1 << roundsFromFinal) + 1, label: `Round of ${1 << (roundsFromFinal + 1)}`};
}

/**
 * PURE. Every bracket participant's finish, keyed by uid:
 *   {place, label, totalPlayers}
 * - the champion (winnerId) is 1st / "Champion";
 * - the other player in the final is 2nd / "Finalist";
 * - everyone else is placed by the round they were eliminated in (ties share a
 *   place, e.g. both semifinalists are 3rd / "Semifinalist").
 * Needs `after.field` (the locked roster). Returns {} on a malformed doc.
 */
function placementsOf(after) {
  const rounds = roundsOf(after);
  const champion = after && after.winnerId;
  const players = (after && Array.isArray(after.field)) ?
    after.field.filter((u) => typeof u === "string" && u) : [];
  if (rounds.length === 0 || players.length === 0 || !champion) return {};
  const lastRound = rounds.length - 1;

  const out = {};
  for (const uid of players) {
    // How far this player got = the highest round they appear in.
    let hiR = -1;
    for (let r = 0; r < rounds.length; r++) {
      for (const m of rounds[r]) {
        if (m && (m.a === uid || m.b === uid)) hiR = Math.max(hiR, r);
      }
    }
    if (hiR < 0) continue; // not actually in the bracket
    if (uid === champion) {
      out[uid] = {place: 1, label: "Champion", totalPlayers: players.length};
    } else {
      const d = depthPlacement(lastRound - hiR);
      out[uid] = {place: d.place, label: d.label, totalPlayers: players.length};
    }
  }
  return out;
}

/**
 * Record the finale for a just-completed Main Stage tournament: stamp the
 * pending placement celebration on EVERY participant and bump the runner-up's
 * lifetime counter. Best-effort and idempotent via a `finaleRecorded` flag on
 * the tournament doc, claimed in the same transaction.
 */
async function recordMainStageFinale(db, tournamentId, after, nowMs = Date.now()) {
  if (!after || after.format !== "mainstage") {
    return {recorded: false, reason: "not-mainstage"};
  }
  const champion = after.winnerId;
  if (!champion) return {recorded: false, reason: "no-winner"};
  const name = after.name || "the Main Stage";
  const places = placementsOf(after);
  const uids = Object.keys(places);
  if (uids.length === 0) return {recorded: false, reason: "no-field"};

  const tRef = db.collection("tournaments").doc(tournamentId);
  const refs = uids.map((u) => db.collection("users").doc(u));

  return db.runTransaction(async (tx) => {
    const tSnap = await tx.get(tRef);
    if (!tSnap.exists) return {recorded: false, reason: "gone"};
    if (tSnap.data().finaleRecorded === true) {
      return {recorded: false, reason: "already"};
    }
    // All reads before any writes (Firestore transaction rule).
    const snaps = await Promise.all(refs.map((r) => tx.get(r)));
    for (let i = 0; i < uids.length; i++) {
      if (!snaps[i].exists) continue;
      const p = places[uids[i]];
      const update = {
        pendingTournamentFinale: {
          place: p.place,
          label: p.label,
          totalPlayers: p.totalPlayers,
          tournamentId,
          name,
          at: nowMs,
        },
      };
      if (p.place === 2) update.tournamentRunnerUps = FieldValue.increment(1);
      tx.update(refs[i], update);
    }
    tx.update(tRef, {finaleRecorded: true});
    return {recorded: true, champion, placements: uids.length};
  });
}

/**
 * The pending finale celebration for the caller, cleared on read so it fires
 * exactly once. Returns {finale: null} when there is nothing to show.
 */
async function getPendingTournamentFinale(auth) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const db = getFirestore();
  const ref = db.collection("users").doc(auth.uid);
  const snap = await ref.get();
  const p = (snap.data() || {}).pendingTournamentFinale;
  if (!p || typeof p.place !== "number") return {finale: null};
  // Clear BEFORE returning so a celebration never replays on every launch.
  await ref.update({pendingTournamentFinale: FieldValue.delete()});
  return {
    finale: {
      place: p.place,
      label: p.label || null,
      totalPlayers: typeof p.totalPlayers === "number" ? p.totalPlayers : null,
      name: p.name || null,
      tournamentId: p.tournamentId || null,
    },
  };
}

module.exports = {
  runnerUpOf,
  placementsOf,
  recordMainStageFinale,
  getPendingTournamentFinale,
};
