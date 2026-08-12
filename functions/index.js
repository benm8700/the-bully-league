const {onCall, HttpsError} = require("firebase-functions/v2/https");
const {onSchedule} = require("firebase-functions/v2/scheduler");
const {defineSecret} = require("firebase-functions/params");
const {initializeApp} = require("firebase-admin/app");
const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {getAuth} = require("firebase-admin/auth");
const {finalizeMatch, VOTE_WINDOW_MS} = require("./matchFinalization");

// Modular admin SDK API, not the classic admin.firestore()/admin.auth()
// namespace - firebase-admin v14's classic namespace requires "firebase-
// admin" alone to also register submodules, which doesn't happen just from
// require("firebase-admin"), so admin.firestore() throws "is not a
// function". The modular imports below are the currently-recommended
// pattern anyway and sidestep this entirely. Confirmed live: this exact
// TypeError surfaced in production logs after the Cloud Run 401/IAM issue
// (see CLAUDE.md's castVote deployment notes) was fixed.
initializeApp();

const turnstileSecret = defineSecret("TURNSTILE_SECRET_KEY");

const ACCOUNT_AGE_FULL_WEIGHT_MS = 24 * 60 * 60 * 1000;
const REDUCED_VOTE_WEIGHT = 0.5;

async function verifyTurnstileToken(token, secret) {
  const params = new URLSearchParams({secret, response: token});
  const response = await fetch("https://challenges.cloudflare.com/turnstile/v0/siteverify", {
    method: "POST",
    headers: {"Content-Type": "application/x-www-form-urlencoded"},
    body: params.toString(),
  });
  const result = await response.json();
  return result.success === true;
}

/**
 * Casts a vote on a completed match. Server-side because it must:
 * (a) verify the Turnstile token with the secret key, which can never be
 *     shipped to the client (see CLAUDE.md's Judging / CAPTCHA-gate note -
 *     switched from Google reCAPTCHA v2 after live testing showed its
 *     image-grid challenges are high-friction for real users),
 * (b) enforce the 24h voting window and one-vote-per-account server-side,
 *     rather than trusting client-side checks a modified client could skip
 *     (same "route sensitive writes through Cloud Functions" pattern used
 *     elsewhere per CLAUDE.md's Security & Compliance Baseline).
 */
exports.castVote = onCall({secrets: [turnstileSecret]}, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Must be signed in to vote.");
  }
  const voterId = request.auth.uid;
  const {matchId, votedForPlayerId, turnstileToken} = request.data || {};

  if (!matchId || !votedForPlayerId || !turnstileToken) {
    throw new HttpsError(
        "invalid-argument",
        "matchId, votedForPlayerId, and turnstileToken are required.",
    );
  }

  const turnstileOk = await verifyTurnstileToken(turnstileToken, turnstileSecret.value());
  if (!turnstileOk) {
    throw new HttpsError("permission-denied", "Turnstile verification failed.");
  }

  const db = getFirestore();
  const matchRef = db.collection("matches").doc(matchId);
  const matchSnap = await matchRef.get();
  if (!matchSnap.exists) {
    throw new HttpsError("not-found", "Match not found.");
  }
  const match = matchSnap.data();

  if (voterId === match.player1Id || voterId === match.player2Id) {
    throw new HttpsError("permission-denied", "Match participants can't vote on their own match.");
  }
  if (votedForPlayerId !== match.player1Id && votedForPlayerId !== match.player2Id) {
    throw new HttpsError("invalid-argument", "votedForPlayerId must be one of the two match players.");
  }

  const createdAtMs = match.createdAt?.toMillis?.() ?? 0;
  const now = Date.now();
  if (now - createdAtMs > VOTE_WINDOW_MS) {
    throw new HttpsError("failed-precondition", "The 24-hour voting window for this match has closed.");
  }

  const ballotRef = db.collection("votes").doc(matchId).collection("ballots").doc(voterId);
  const ballotSnap = await ballotRef.get();
  if (ballotSnap.exists) {
    throw new HttpsError("already-exists", "You've already voted on this match.");
  }

  const voterRecord = await getAuth().getUser(voterId);
  const accountAgeMs = now - new Date(voterRecord.metadata.creationTime).getTime();
  const weight = accountAgeMs >= ACCOUNT_AGE_FULL_WEIGHT_MS ? 1 : REDUCED_VOTE_WEIGHT;

  await ballotRef.set({
    votedForPlayerId,
    weight,
    timestamp: FieldValue.serverTimestamp(),
  });

  return {success: true, weight};
});

/**
 * Production path (Build Order step 6): sweeps for ranked/tournament
 * matches whose 24h voting window has closed and applies Elo rating
 * changes - see functions/matchFinalization.js and CLAUDE.md's Ranking
 * System section. Runs hourly; finalizing a given match is a no-op if
 * already done (voteFinalized flag), so re-running on overlap is safe.
 */
exports.finalizeExpiredMatches = onSchedule("every 60 minutes", async () => {
  const db = getFirestore();
  const cutoff = new Date(Date.now() - VOTE_WINDOW_MS);
  const snap = await db
      .collection("matches")
      .where("createdAt", "<=", cutoff)
      .where("voteFinalized", "==", false)
      .get();

  for (const doc of snap.docs) {
    try {
      await finalizeMatch(doc.id);
    } catch (e) {
      console.error(`finalizeExpiredMatches: failed for match ${doc.id}`, e);
    }
  }
});

/**
 * DEV/TEST ONLY - bypasses the 24h window so the rating pipeline can be
 * verified without waiting a real day. Not gated behind any admin check
 * because no admin-role system exists yet (see CLAUDE.md's Admin/
 * moderation tooling notes, which defer to the Firebase console for V1).
 * Must be removed or properly access-controlled before real launch -
 * anyone signed in can currently force-finalize any match early.
 */
exports.debugFinalizeMatch = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Must be signed in.");
  }
  const {matchId} = request.data || {};
  if (!matchId) {
    throw new HttpsError("invalid-argument", "matchId is required.");
  }
  return finalizeMatch(matchId, {force: true});
});
