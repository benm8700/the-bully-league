const {getFirestore} = require("firebase-admin/firestore");
const {HttpsError} = require("firebase-functions/v2/https");

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
  // An everyday match BOTH players opted into being watched live (set at
  // pairing from the recording-consent opt-in). The opt-in IS the consent, so
  // no tournament is required - it just has to still be in progress.
  if (match.liveWatchable === true) {
    if (match.status !== "pending" && match.status !== "in_progress") {
      return "already-finished";
    }
    return null;
  }
  if (match.mode !== "tournament") return "not-a-tournament-match";
  // A Main Stage finals battle carries its tournament id under `mainStage` -
  // that is what makes it a live event somebody signed up to perform in.
  if (!match.mainStage?.tournamentId) {
    return "not-a-tournament-match";
  }
  if (!tournament) return "tournament-not-found";
  // The Main Stage weekly finals are the one live event you can watch - its
  // battles are the whole show, so the crowd (and the judges) must be able to
  // watch them. (The nightly gauntlet and old live brackets were retired.)
  if (tournament.format !== "mainstage") {
    return "not-a-live-event";
  }
  if (tournament.status !== "live") return "not-running";
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
  "no-debate-yet": "The judges haven't started their table yet.",
  "debate-over": "The verdict is already in.",
};

/** The Agora uid a judge at panel index i publishes with on the judges' table
 * channel. Kept well clear of the battlers' 1/2, the recorder's 999999, and the
 * spectator range (1000+). The crowd maps a remote uid back to a judge via
 * (uid - JUDGE_SEAT_UID_BASE) into the panel array. Mirrored client-side. */
const JUDGE_SEAT_UID_BASE = 11;

/**
 * Whether the Main Stage JUDGES' video table may be watched right now. PURE.
 *
 * The table exists only during the DEBATE - the battle is over but the panel
 * has not landed a verdict yet. Unlike the battle, a battler MAY watch it: they
 * are no longer performing, and watching the panel decide their fate is exactly
 * the point.
 */
function judgesTableProblem({match, tournament}) {
  if (!match) return "match-not-found";
  if (!match.mainStage || !match.mainStage.tournamentId) {
    return "not-a-tournament-match";
  }
  if (!tournament) return "tournament-not-found";
  if (tournament.format !== "mainstage") return "not-a-live-event";
  if (tournament.status !== "live") return "not-running";
  if (match.status !== "completed") return "no-debate-yet";
  if (match.judgeWinnerId) return "debate-over";
  return null;
}

/**
 * Mints a SUBSCRIBER token for the crowd to watch the judges' video table
 * (channel `judges_<matchId>`), plus the seated panel (in seat order) and the
 * head judge so the client can label the tiles. The judges themselves publish
 * here via generateAgoraToken's judges_ branch; this is the watch-only door.
 */
async function watchJudgesTable(auth, data, appCertificate) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const {matchId} = data || {};
  if (!matchId) {
    throw new HttpsError("invalid-argument", "matchId is required.");
  }
  const db = getFirestore();
  const matchSnap = await db.collection("matches").doc(matchId).get();
  const match = matchSnap.exists ? matchSnap.data() : null;
  let tournament = null;
  const tid = match && match.mainStage && match.mainStage.tournamentId;
  if (tid) {
    const tSnap = await db.collection("tournaments").doc(tid).get();
    tournament = tSnap.exists ? tSnap.data() : null;
  }
  const problem = judgesTableProblem({match, tournament});
  if (problem) {
    throw new HttpsError("permission-denied",
        MESSAGES[problem] ?? "You cannot watch that.", {reason: problem});
  }
  if (!appCertificate) {
    throw new HttpsError("failed-precondition",
        "Live viewing is not configured.", {reason: "unconfigured"});
  }
  const {RtcTokenBuilder, RtcRole} = require("agora-token");
  const {AGORA_APP_ID} = require("./agoraToken");
  const uid = spectatorUid(auth.uid);
  const channelName = `judges_${matchId}`;
  const token = RtcTokenBuilder.buildTokenWithUid(
      AGORA_APP_ID, appCertificate, channelName, uid,
      RtcRole.SUBSCRIBER, 3600, 3600);
  const panel = Array.isArray(tournament.judges) ? tournament.judges : [];
  const headJudge =
    (tournament.handPickedJudges || []).find((u) => panel.includes(u)) || null;
  return {channelName, token, agoraUid: uid, judges: panel, headJudge,
    seatUidBase: JUDGE_SEAT_UID_BASE, matchId};
}

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
  const tournamentId = match?.mainStage?.tournamentId;
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
 * The everyday matches that are LIVE and watchable right now - i.e. both
 * players opted in (liveWatchable) and the match is still in progress. Feeds
 * the Watch tab's "Live now" row. Excludes the caller's own matches (they're
 * playing, not spectating).
 *
 * Queries the single-field liveWatchable index and filters status in code,
 * because a finished opted-in match keeps liveWatchable=true (the field is a
 * record of consent, not of live state). Bounded by a small limit - fine at
 * beta scale; a dedicated liveNow flag cleared on completion is the scaling
 * fix if the opted-in back catalogue ever grows large.
 */
async function getLiveWatchableMatches(auth) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const db = getFirestore();
  const snap = await db.collection("matches")
      .where("liveWatchable", "==", true)
      .limit(40)
      .get();

  const live = [];
  for (const doc of snap.docs) {
    const m = doc.data();
    if (m.status !== "pending" && m.status !== "in_progress") continue;
    if (auth.uid === m.player1Id || auth.uid === m.player2Id) continue;
    live.push({matchId: doc.id, p1: m.player1Id, p2: m.player2Id});
  }

  const ids = [...new Set(live.flatMap((x) => [x.p1, x.p2]))];
  const names = {};
  await Promise.all(ids.map(async (id) => {
    const u = await db.collection("users").doc(id).get();
    names[id] = u.data()?.username ?? "Roaster";
  }));

  return {
    matches: live.map((x) => ({
      matchId: x.matchId,
      player1Name: names[x.p1] ?? "Roaster",
      player2Name: names[x.p2] ?? "Roaster",
    })),
  };
}

module.exports = {
  watchLiveMatch,
  watchJudgesTable,
  getLiveWatchableMatches,
  spectateProblem,
  judgesTableProblem,
  spectatorUid,
  JUDGE_SEAT_UID_BASE,
  MESSAGES,
};
