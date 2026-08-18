const {getFirestore} = require("firebase-admin/firestore");
const {HttpsError} = require("firebase-functions/v2/https");
const {isLive} = require("./liveTournament");

/**
 * Watching a live tournament match as a spectator.
 *
 * WHY THIS IS A SEPARATE, NARROWER DOOR than generateAgoraToken. That
 * function deliberately refuses a token for any match the caller is not
 * playing in - a fix made precisely to stop anyone dropping in on a
 * stranger's live battle uninvited. Spectating must not reopen that hole,
 * so it is allowed only where being watched is the entire point:
 *
 *   1. the match belongs to a tournament,
 *   2. that tournament is format "live",
 *   3. and it is in_progress right now.
 *
 * An ordinary ranked match, a friend battle, or an async tournament match
 * is never spectatable. Somebody who entered a live tournament chose to
 * perform in front of an audience; nobody else did.
 *
 * AND THE TOKEN IS A SUBSCRIBER TOKEN, which is the part that actually
 * enforces it. A publisher token would let a "spectator" broadcast their
 * own camera into somebody else's bracket match. A subscriber token can
 * only ever consume - the same reason the recording bot gets one.
 *
 * WHY AGORA RATHER THAN A CDN. Cloudflare Stream would be far cheaper per
 * viewer at scale, but it needs a paid vendor account before a single
 * event has run, and Agora is already integrated. At beta scale this is
 * roughly $6 for a tournament with fifty viewers. It scales badly past a
 * few hundred, so this is a decision to revisit once a real event draws a
 * crowd - which is why the client keeps playback behind an interface.
 */

/** Spectators join with high uids so they can never collide with the
 * players' fixed 1 and 2, or with the recorder. Derived from the uid so
 * one account rejoining is the same Agora participant rather than an
 * accumulating crowd of ghosts. */
function spectatorUid(uid) {
  let hash = 0;
  for (let i = 0; i < String(uid).length; i++) {
    hash = (hash * 31 + String(uid).charCodeAt(i)) % 1_000_000;
  }
  // Well clear of 1, 2 and the recorder's fixed uid.
  return 1000 + hash;
}

/**
 * Whether this match may be watched by someone who is not in it.
 *
 * PURE, so the rule can be tested without Firestore - and this is a rule
 * about who may watch video of real people, so it is worth pinning
 * exactly rather than inferring from behaviour.
 *
 * @return {?string} a refusal reason, or null if watching is allowed
 */
function spectateProblem({match, tournament, uid}) {
  if (!match) return "match-not-found";
  // Participants use the ordinary player path - they need a publisher
  // token, not this one.
  if (uid === match.player1Id || uid === match.player2Id) {
    return "you-are-playing";
  }
  if (match.mode !== "tournament") return "not-a-tournament-match";
  if (!match.tournament?.tournamentId) return "not-a-tournament-match";
  if (!tournament) return "tournament-not-found";
  if (!isLive(tournament)) return "not-a-live-event";
  if (tournament.status !== "in_progress") return "not-running";
  // Once a match is over there is nothing to watch live - the clip is the
  // way to see it, and that path has its own consent and takedown rules.
  if (match.status !== "pending" && match.status !== "in_progress") {
    return "already-finished";
  }
  return null;
}

const MESSAGES = {
  "match-not-found": "That battle does not exist.",
  "you-are-playing": "You are in this battle - open it from the bracket.",
  "not-a-tournament-match": "Only live tournament battles can be watched.",
  "tournament-not-found": "That tournament does not exist.",
  "not-a-live-event": "That tournament is not a live event.",
  "not-running": "That tournament is not running right now.",
  "already-finished": "That battle has finished. Watch the clip instead.",
};

/**
 * Mints a subscriber token for watching a live tournament match.
 *
 * The certificate is passed in rather than read here, so it stays in the
 * secret-holding layer (index.js) exactly like every other Agora token.
 */
async function watchLiveMatch(auth, data, appCertificate) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const {matchId} = data || {};
  if (!matchId) {
    throw new HttpsError("invalid-argument", "matchId is required.");
  }

  const db = getFirestore();
  const matchSnap = await db.collection("matches").doc(matchId).get();
  const match = matchSnap.exists ? matchSnap.data() : null;

  let tournament = null;
  const tournamentId = match?.tournament?.tournamentId;
  if (tournamentId) {
    const tSnap = await db.collection("tournaments").doc(tournamentId).get();
    tournament = tSnap.exists ? tSnap.data() : null;
  }

  const problem = spectateProblem({match, tournament, uid: auth.uid});
  if (problem) {
    throw new HttpsError("permission-denied",
        MESSAGES[problem] ?? "You cannot watch that.", {reason: problem});
  }

  if (!appCertificate) {
    // Same shape as the rest of the Agora paths: unconfigured is reported
    // rather than papered over, because a token that does not work looks
    // identical to a broken stream from the client's side.
    throw new HttpsError("failed-precondition",
        "Live viewing is not configured.", {reason: "unconfigured"});
  }

  const {RtcTokenBuilder, RtcRole} = require("agora-token");
  const {AGORA_APP_ID} = require("./agoraToken");
  const uid = spectatorUid(auth.uid);
  const EXPIRE_SECONDS = 3600;
  const token = RtcTokenBuilder.buildTokenWithUid(
      AGORA_APP_ID,
      appCertificate,
      match.channelName,
      uid,
      // SUBSCRIBER is the enforcement, not a detail. A publisher token
      // would let a spectator broadcast their own camera into somebody
      // else's bracket match.
      RtcRole.SUBSCRIBER,
      EXPIRE_SECONDS,
      EXPIRE_SECONDS,
  );

  const [p1, p2] = await Promise.all([
    db.collection("users").doc(match.player1Id).get(),
    db.collection("users").doc(match.player2Id).get(),
  ]);

  return {
    channelName: match.channelName,
    token,
    agoraUid: uid,
    player1Id: match.player1Id,
    player2Id: match.player2Id,
    // Sent with the token so the viewer can label the vote buttons the
    // moment the battle ends, rather than fetching names during the
    // ninety seconds when every round trip is visible.
    player1Name: p1.data()?.username ?? "Player 1",
    player2Name: p2.data()?.username ?? "Player 2",
    tournamentId,
  };
}

/**
 * What is watchable in a live tournament right now.
 *
 * Returns the current round's matches that are actually being played, so
 * the client can offer a list rather than requiring somebody to already
 * know a match id.
 */
async function liveMatchesFor(auth, data) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const {tournamentId} = data || {};
  if (!tournamentId) {
    throw new HttpsError("invalid-argument", "tournamentId is required.");
  }
  const db = getFirestore();
  const tSnap = await db.collection("tournaments").doc(tournamentId).get();
  if (!tSnap.exists) throw new HttpsError("not-found", "Tournament not found.");
  const tournament = tSnap.data();
  if (!isLive(tournament) || tournament.status !== "in_progress") {
    return {matches: []};
  }

  const rounds = tournament.bracket?.rounds ?? [];
  const round = rounds[rounds.length - 1];
  if (!round?.matchups) return {matches: []};

  const {tournamentMatchId} = require("./tournamentPlay");
  // Names resolved here rather than by the client, which would otherwise
  // do two document reads per matchup just to draw a list.
  const names = new Map();
  const nameOf = async (uid) => {
    if (!uid) return null;
    if (names.has(uid)) return names.get(uid);
    const snap = await db.collection("users").doc(uid).get();
    const name = snap.data()?.username ?? "Unknown";
    names.set(uid, name);
    return name;
  };
  const out = [];
  for (const [i, m] of round.matchups.entries()) {
    // A settled matchup is over, and a bye was never played.
    if (m.winnerId || !m.player1Id || !m.player2Id) continue;
    const id = tournamentMatchId(tournamentId, round.roundNumber, i);
    const snap = await db.collection("matches").doc(id).get();
    if (!snap.exists) continue;
    const match = snap.data();
    if (match.status !== "pending" && match.status !== "in_progress") continue;
    out.push({
      matchId: id,
      player1Id: match.player1Id,
      player2Id: match.player2Id,
      player1Name: await nameOf(match.player1Id),
      player2Name: await nameOf(match.player2Id),
      roundNumber: round.roundNumber,
      // Both players present means it is actually under way rather than
      // waiting for someone to arrive.
      live: Object.keys(match.arrivedAt ?? {}).length >= 2,
    });
  }
  return {matches: out, roundNumber: round.roundNumber};
}

module.exports = {
  watchLiveMatch,
  liveMatchesFor,
  spectateProblem,
  spectatorUid,
  MESSAGES,
};
