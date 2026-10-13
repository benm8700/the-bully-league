const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {HttpsError} = require("firebase-functions/v2/https");
const {isRating} = require("./emojiRatings");

/**
 * LIVE CROWD REACTIONS for a Main Stage battle.
 *
 * The weekly Main Stage winner is decided by the 5-judge panel, NOT the crowd -
 * so a live spectator does not cast a winner vote. What they CAN do while
 * watching is react: rate each roaster with one emoji (which feeds that
 * roaster's permanent public emoji identity, exactly like a judge's rating in
 * castVote) and pick a non-binding Crowd Favourite.
 *
 * WHY A SEPARATE PATH FROM castVote. Emoji ratings normally ride the winner
 * vote (castVote bundles them), but the Main Stage crowd has no winner vote to
 * ride. So this is its own callable. It mirrors castVote's anti-fraud, because
 * emojiCounts is a public identity number (badges, nicknames, the Applause
 * board, the superlative awards all read it): the caller must hold a vote
 * session (or solve Turnstile) - done in the index.js wrapper, same as castVote
 * - and exactly ONE reaction per account per battle is recorded here. The
 * "changeable rating" the design calls for happens CLIENT-SIDE before submit;
 * the server write is one-shot, so a permanent public count can never drift.
 *
 * The Crowd Favourite is a LIVE, per-battle tally only (no permanent crown yet).
 * The design's permanent Crowd Favourite is the roaster who received the most
 * GIFTS, and gifting is not built; this vote-based favourite is the interim.
 */

/**
 * PURE. Whether this reaction may be recorded, or a refusal reason.
 *
 * Kept pure so the rules - which govern a write to a public identity number -
 * are pinned by tests rather than inferred from behaviour, the same discipline
 * as spectateProblem.
 *
 * @return {?string} a refusal reason, or null if the reaction is allowed
 */
function reactionProblem({match, uid, emojiRatings, favorite}) {
  if (!match) return "match-not-found";
  // Only a Main Stage battle is reactable - it is the one live event the crowd
  // turns up for. (An ordinary ranked match, a friend battle: nobody signed up
  // to perform for an audience, so no crowd reactions.)
  if (!match.mainStage || !match.mainStage.tournamentId) {
    return "not-a-live-battle";
  }
  // Participants use the judge/vote paths, not this one, and must never pump
  // their own or their opponent's identity counts.
  if (uid === match.player1Id || uid === match.player2Id) {
    return "you-are-playing";
  }
  // Reactions are open while the battle is live or just-finished, and CLOSE
  // once the result lands - so the Crowd Favourite is settled by the same
  // moment the winner is, and nobody reacts to a long-dead battle.
  if (match.status === "abandoned") return "not-a-live-battle";
  if (match.voteFinalized === true) return "reactions-closed";
  // One emoji per roaster, both required - a reaction that rated only one
  // player would be a hole in the identity data, the same rule castVote keeps.
  const r1 = emojiRatings && emojiRatings[match.player1Id];
  const r2 = emojiRatings && emojiRatings[match.player2Id];
  if (!isRating(r1) || !isRating(r2)) return "rate-both";
  // The Crowd Favourite pick must be one of the two roasters actually in it.
  if (favorite !== match.player1Id && favorite !== match.player2Id) {
    return "pick-favorite";
  }
  return null;
}

const MESSAGES = {
  "match-not-found": "That battle does not exist.",
  "not-a-live-battle": "Only a live Main Stage battle can be reacted to.",
  "you-are-playing": "You are in this battle - you can't react to it.",
  "reactions-closed": "Reactions are closed - the result has landed.",
  "rate-both": "Rate both roasters with an emoji first.",
  "pick-favorite": "Pick your crowd favourite - one of the two roasters.",
  "already-reacted": "You've already reacted to this battle.",
};

/**
 * Records the caller's one reaction to a Main Stage battle, in a single atomic
 * batch: their reactor record (the one-per-account guard), the two permanent
 * emojiCount increments, and the live Crowd Favourite tally. The auth +
 * session/Turnstile gate is the index.js wrapper's job (same as castVote), so
 * by here the caller is a verified human.
 */
async function recordLiveReaction(auth, data) {
  const {matchId, emojiRatings, favorite} = data || {};
  if (!matchId) {
    throw new HttpsError("invalid-argument", "matchId is required.");
  }
  const db = getFirestore();
  const matchSnap = await db.collection("matches").doc(matchId).get();
  const match = matchSnap.exists ? matchSnap.data() : null;

  const problem = reactionProblem({match, uid: auth.uid, emojiRatings, favorite});
  if (problem) {
    const code = problem === "match-not-found" ? "not-found" :
      problem === "you-are-playing" ? "permission-denied" :
        problem === "reactions-closed" ? "failed-precondition" : "invalid-argument";
    throw new HttpsError(code, MESSAGES[problem] ?? "You can't react to that.",
        {reason: problem});
  }

  const reactorRef = db.collection("liveReactions").doc(matchId)
      .collection("reactors").doc(auth.uid);
  if ((await reactorRef.get()).exists) {
    throw new HttpsError("already-exists", MESSAGES["already-reacted"],
        {reason: "already-reacted"});
  }

  const r1 = emojiRatings[match.player1Id];
  const r2 = emojiRatings[match.player2Id];

  const batch = db.batch();
  // The one-per-account record - its existence is the idempotency guard above,
  // and it lets the client know it has already reacted (to lock the picker and
  // reveal the tally).
  batch.set(reactorRef, {
    emoji: {[match.player1Id]: r1, [match.player2Id]: r2},
    favorite,
    at: FieldValue.serverTimestamp(),
  });
  // The two permanent identity counts. emojiCounts is server-only in
  // firestore.rules and this is the Admin SDK, so a client can never inflate
  // its own counts. One reaction per account means one increment per roaster.
  batch.set(db.collection("users").doc(match.player1Id),
      {emojiCounts: {[r1]: FieldValue.increment(1)}}, {merge: true});
  batch.set(db.collection("users").doc(match.player2Id),
      {emojiCounts: {[r2]: FieldValue.increment(1)}}, {merge: true});
  // The live Crowd Favourite tally for THIS battle. Readable only by someone
  // who has already reacted (firestore.rules), so the running favourite can't
  // bias a pick before it is made - the same hidden-until-you-act rule the
  // winner tally follows.
  batch.set(db.collection("liveReactions").doc(matchId), {
    player1Id: match.player1Id,
    player2Id: match.player2Id,
    favorites: {[favorite]: FieldValue.increment(1)},
    reactorCount: FieldValue.increment(1),
    updatedAt: FieldValue.serverTimestamp(),
  }, {merge: true});
  await batch.commit();

  return {ok: true};
}

module.exports = {reactionProblem, recordLiveReaction, MESSAGES};
