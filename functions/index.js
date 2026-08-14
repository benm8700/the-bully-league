const {onCall, HttpsError} = require("firebase-functions/v2/https");
const {onSchedule} = require("firebase-functions/v2/scheduler");
const {defineSecret} = require("firebase-functions/params");
const {initializeApp} = require("firebase-admin/app");
const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {getAuth} = require("firebase-admin/auth");
const {finalizeMatch, VOTE_WINDOW_MS} = require("./matchFinalization");
const {generateBracket, debugAdvanceRound, DEFAULT_MIN_ENTRANTS} = require("./tournament");
const {moderateImage, moderateImageContent} = require("./visualModeration");
const {generateToken, AGORA_APP_ID} = require("./agoraToken");
const {onVoteCast} = require("./voteCount");
const {
  enterQueue,
  leaveQueue,
  pollMatchmaking,
  completeMatch,
  startMatchRecording,
  getActiveMatch,
  setMatchReady,
  skipMatch,
  getSkipAllowance,
  getRankedUnlock,
} = require("./matchmaking");

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
const agoraAppCertificate = defineSecret("AGORA_APP_CERTIFICATE");

// Agora Cloud Recording uses a RESTful API credential pair that is
// SEPARATE from the App ID / App Certificate above, plus an HMAC key pair
// so Agora can write recordings directly into the project's Cloud Storage
// bucket. All four stay server-side, same as every other secret here.
const agoraCustomerId = defineSecret("AGORA_CUSTOMER_ID");
const agoraCustomerSecret = defineSecret("AGORA_CUSTOMER_SECRET");
const recordingStorageKey = defineSecret("RECORDING_STORAGE_ACCESS_KEY");
const recordingStorageSecret = defineSecret("RECORDING_STORAGE_SECRET_KEY");
const recordingSecrets = [
  agoraAppCertificate,
  agoraCustomerId,
  agoraCustomerSecret,
  recordingStorageKey,
  recordingStorageSecret,
];

/**
 * Assembles the recording credentials from secrets at call time.
 *
 * Returns partially-empty values rather than throwing when recording
 * isn't configured yet: the callers treat that as "don't record" and let
 * the match proceed normally, which is what should happen while the
 * credentials are still being set up.
 */
function recordingCreds(channelName) {
  const {generateRecorderToken} = require("./agoraToken");
  const {RECORDER_UID} = require("./cloudRecording");
  const certificate = agoraAppCertificate.value();
  return {
    appId: AGORA_APP_ID,
    customerId: agoraCustomerId.value(),
    customerSecret: agoraCustomerSecret.value(),
    token: certificate && channelName ?
      generateRecorderToken(certificate, channelName, RECORDER_UID) : "",
    storage: {
      // Firebase's default bucket for this project - the same one profile
      // photos already use.
      bucket: `${process.env.GCLOUD_PROJECT || "the-bully-league"}.firebasestorage.app`,
      accessKey: recordingStorageKey.value(),
      secretKey: recordingStorageSecret.value(),
    },
  };
}

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
 * Gates the debug/admin tournament-bracket functions below - see CLAUDE.md's
 * Security & Compliance Baseline, which flagged these as callable by ANY
 * signed-in user with no admin check. There's still no real admin-role UI
 * (Firebase console remains the actual admin tool for V1, per CLAUDE.md's
 * Admin/moderation tooling notes), so this just reads the caller's own
 * users/{uid}.isAdmin field - a field firestore.rules protects the same way
 * as accountStatus (client can create it only as false, can never change
 * it), so flipping it to true requires a manual Firebase console edit.
 */
async function requireAdmin(auth) {
  if (!auth) {
    throw new HttpsError("unauthenticated", "Must be signed in.");
  }
  const snap = await getFirestore().collection("users").doc(auth.uid).get();
  if (!snap.exists || snap.data().isAdmin !== true) {
    throw new HttpsError("permission-denied", "Admin only.");
  }
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

  // Match documents now exist from PAIRING time onward (see
  // functions/matchmaking.js), so a match can legitimately exist while
  // it's still being played or after it was abandoned. Only a finished
  // contest is votable.
  if (match.status !== "completed") {
    throw new HttpsError(
        "failed-precondition",
        match.status === "pending" ?
          "This match is still in progress." :
          "This match didn't finish, so there's nothing to vote on.",
    );
  }

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
/**
 * Enforces CLAUDE.md's Video Retention Policy - raw footage is deleted
 * after 7 days, published highlights are kept. Daily is frequent enough
 * for a 7-day window and keeps the storage-listing cost trivial.
 *
 * This is a compliance obligation, not housekeeping: the retention window
 * is what bounds the recording consent players gave, and it's what the
 * published Privacy Policy promises happens to their footage.
 */
/**
 * Runaway-recording backstop. Agora's own maxIdleTime stops a recording
 * once the channel empties, but does nothing while clients are still
 * connected - so a wedged match or a client that never leaves would bill
 * recording minutes indefinitely. This is the only genuinely unbounded
 * cost path in the project, and a billing alert would only report it after
 * the money was spent.
 *
 * Every 10 minutes: frequent enough that the worst case is a few minutes
 * of extra recording (fractions of a cent), cheap enough to be free.
 */
exports.stopRunawayRecordings = onSchedule(
    {schedule: "every 10 minutes", secrets: recordingSecrets},
    async () => {
      const {stopRunawayRecordings} = require("./cloudRecording");
      const result = await stopRunawayRecordings(recordingCreds(null));
      if (result.stopped > 0 || result.running > 0) {
        console.log("stopRunawayRecordings:", JSON.stringify(result));
      }
    },
);

exports.purgeExpiredRecordings = onSchedule("every 24 hours", async () => {
  const {purgeExpiredRecordings} = require("./recordingRetention");
  const result = await purgeExpiredRecordings();
  console.log("purgeExpiredRecordings:", JSON.stringify(result));
});

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
 * verified without waiting a real day. Admin-gated (see requireAdmin above)
 * since force-finalizing any match early has real rating consequences.
 */
exports.debugFinalizeMatch = onCall(async (request) => {
  await requireAdmin(request.auth);
  const {matchId} = request.data || {};
  if (!matchId) {
    throw new HttpsError("invalid-argument", "matchId is required.");
  }
  return finalizeMatch(matchId, {force: true});
});

/**
 * Closes entrants and generates the round-1 bracket for a tournament -
 * see functions/tournament.js and CLAUDE.md's Build Order step 8 status
 * note. Real admin tooling for tournaments is the Firebase console (same
 * pattern as profile approval/report review); this is the action an admin
 * triggers to actually start a tournament, so it's admin-gated like the
 * other functions here.
 */
exports.generateTournamentBracket = onCall(async (request) => {
  await requireAdmin(request.auth);
  const {tournamentId} = request.data || {};
  if (!tournamentId) {
    throw new HttpsError("invalid-argument", "tournamentId is required.");
  }
  return generateBracket(tournamentId);
});

/**
 * DEV/TEST ONLY - resolves the current round with a coin flip per
 * matchup rather than a real match result, purely to prove bracket
 * advancement (byes, round generation, completion) works end to end.
 * See functions/tournament.js's debugAdvanceRound doc comment. Admin-gated
 * since it overwrites real bracket state.
 */
exports.debugAdvanceTournamentRound = onCall(async (request) => {
  await requireAdmin(request.auth);
  const {tournamentId} = request.data || {};
  if (!tournamentId) {
    throw new HttpsError("invalid-argument", "tournamentId is required.");
  }
  return debugAdvanceRound(tournamentId);
});

/**
 * DEV/TEST ONLY - creates a tournament document. Firestore rules block
 * direct client writes to tournaments/{id} (real creation is meant to go
 * through the Firebase console, per CLAUDE.md's Admin/moderation tooling
 * notes), so this exists purely so the app can be tested end to end
 * without console access. Admin-gated.
 */
exports.debugCreateTournament = onCall(async (request) => {
  await requireAdmin(request.auth);
  const {name, minEntrants} = request.data || {};
  if (!name) {
    throw new HttpsError("invalid-argument", "name is required.");
  }
  const db = getFirestore();
  const ref = await db.collection("tournaments").add({
    name,
    description: "Test tournament created via debugCreateTournament.",
    entryFee: null,
    prizeType: "points",
    prizeValue: 0,
    eligibleStates: [],
    format: "async",
    bracketType: "single_elimination",
    seeding: "random",
    withdrawalAllowedBeforeStart: true,
    minEntrants: minEntrants ?? DEFAULT_MIN_ENTRANTS,
    status: "open",
    bracket: null,
    winnerId: null,
    createdAt: FieldValue.serverTimestamp(),
  });
  return {tournamentId: ref.id};
});

/**
 * Runs Google Cloud Vision SafeSearch on an uploaded profile photo (Build
 * Order step 9a / CLAUDE.md's Content Policy & Moderation section) -
 * server-side because it's the natural place for any future provider
 * credentials to live, same "sensitive calls go through Cloud Functions"
 * pattern as castVote's Turnstile check. Restricted to the caller's own
 * uploads (storagePath must be under their own profile_photos/{uid}/
 * folder) as defense in depth alongside storage.rules, which already
 * enforces the same boundary at the Storage layer.
 *
 * This covers PROFILE PHOTOS only. Live match video moderation is
 * moderateMatchFrame below - a separate function since frames are never
 * uploaded to Storage (they're ephemeral, sent as inline base64 bytes).
 */
exports.moderatePhoto = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Must be signed in.");
  }
  const {storagePath} = request.data || {};
  if (!storagePath) {
    throw new HttpsError("invalid-argument", "storagePath is required.");
  }
  if (!storagePath.startsWith(`profile_photos/${request.auth.uid}/`)) {
    throw new HttpsError("permission-denied", "Can only moderate your own photos.");
  }
  return moderateImage(storagePath);
});

/**
 * Runs Google Cloud Vision SafeSearch on a sampled LIVE match video frame
 * (Build Order step 9a's live-video half, unblocked after correcting the
 * earlier "registerVideoFrameObserver is a stub" misdiagnosis - see
 * CLAUDE.md's step 3/9a status notes). The client samples the remote
 * participant's video every few seconds (AgoraVideoCallService's
 * remoteFrameSamples), converts I420 to JPEG (lib/core/services/
 * yuv_to_jpeg.dart), and sends it here as base64 - no Storage upload,
 * since a frame that passes moderation has no reason to be kept anywhere.
 */
exports.moderateMatchFrame = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Must be signed in.");
  }
  const {imageBase64} = request.data || {};
  if (!imageBase64) {
    throw new HttpsError("invalid-argument", "imageBase64 is required.");
  }
  return moderateImageContent(imageBase64);
});

/**
 * Generates a real, signed Agora RTC token server-side (functions/
 * agoraToken.js) - replaces the hardcoded 24h temp token used during early
 * Build Order testing (see CLAUDE.md's Agora toolchain notes: "A hardcoded
 * temp token was used only to verify connectivity works end to end... do
 * NOT ship that pattern"). The App Certificate needed to sign the token
 * can never be shipped to the client, so this is server-side for the same
 * reason castVote's Turnstile secret is - see Security & Compliance
 * Baseline's "route sensitive writes/calls through Cloud Functions"
 * pattern.
 *
 * The channel name IS now validated against real state, which it couldn't
 * be while both devices joined a hardcoded "test-channel". Exactly two
 * shapes are mintable:
 *   precheck_{uid}  - the caller's own solo pre-match camera/mic check,
 *                     so nobody can join anyone else's check.
 *   match_{matchId} - only if the caller is one of that match's two
 *                     players and the match hasn't finished yet.
 * Without this, any signed-in user could mint a token for any channel and
 * drop in on a stranger's match uninvited - a real eavesdropping hole
 * once channels stopped being a shared test room.
 */
exports.generateAgoraToken = onCall({secrets: [agoraAppCertificate]}, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Must be signed in.");
  }
  const {channelName} = request.data || {};
  if (!channelName) {
    throw new HttpsError("invalid-argument", "channelName is required.");
  }

  if (channelName !== `precheck_${request.auth.uid}`) {
    if (!channelName.startsWith("match_")) {
      throw new HttpsError("permission-denied", "Not a channel you can join.");
    }
    const matchId = channelName.slice("match_".length);
    const matchSnap = await getFirestore().collection("matches").doc(matchId).get();
    if (!matchSnap.exists) {
      throw new HttpsError("not-found", "Match not found.");
    }
    const match = matchSnap.data();
    if (request.auth.uid !== match.player1Id && request.auth.uid !== match.player2Id) {
      throw new HttpsError("permission-denied", "Not a participant in this match.");
    }
    if (match.status !== "pending") {
      throw new HttpsError("failed-precondition", "This match has already ended.");
    }
  }

  const token = generateToken(agoraAppCertificate.value(), channelName);
  return {token};
});

/**
 * Real matchmaking (Build Order step 4's missing half - see
 * functions/matchmaking.js for the queue design and why clients only ever
 * reach it through these callables). Replaces the hardcoded "test-channel"
 * both devices used to join.
 */
exports.enterMatchmakingQueue = onCall((request) => enterQueue(request.auth, request.data));
exports.pollMatchmaking = onCall((request) => pollMatchmaking(request.auth, request.data));
exports.leaveMatchmakingQueue = onCall((request) => leaveQueue(request.auth, request.data));

/**
 * Marks a paired match finished. Server-side because the match document
 * is now created at PAIRING time (status "pending") rather than written
 * by a client at verdict time - so flipping it to "completed" is what
 * admits it to the voting pipeline and, for ranked, eventually to real
 * rating changes. That has to be a participant-only, server-checked
 * action rather than an arbitrary client write.
 */
exports.completeMatch = onCall({secrets: recordingSecrets}, async (request) => {
  // The channel name is only known after loading the match, so creds are
  // assembled without a token here - stopping a recording doesn't need one.
  return completeMatch(request.auth, request.data, recordingCreds(null));
});

/**
 * Starts recording a match (CLAUDE.md's recording scope: ranked and
 * tournament only). Called once by the host device as the match begins.
 * See functions/cloudRecording.js for why this is server-side composite
 * recording rather than capture on the devices.
 */
exports.startMatchRecording = onCall({secrets: recordingSecrets}, async (request) => {
  const {getFirestore} = require("firebase-admin/firestore");
  const matchId = request.data?.matchId;
  // Channel name is needed to mint the recorder's token, so read it first.
  const snap = matchId ?
    await getFirestore().collection("matches").doc(matchId).get() : null;
  const channelName = snap?.data()?.channelName ?? null;
  return startMatchRecording(request.auth, request.data, recordingCreds(channelName));
});

/**
 * Pre-match bio reveal (CLAUDE.md's "Pre-match bio reveal" decision): each
 * player reads the other's profile "ammo" for up to a minute before the
 * match starts, and either can decline the pairing outright.
 */
/**
 * Lets a client that cold-started (after tapping a match-found push, say)
 * recover a match it was paired into but never collected - otherwise that
 * player is stranded on Home with a live pairing they can't reach.
 */
exports.getActiveMatch = onCall((request) => getActiveMatch(request.auth));

/**
 * User-initiated account and data deletion (CCPA - see CLAUDE.md's
 * Compliance / Account Management item, and functions/accountDeletion.js
 * for what is deleted, what is deliberately kept, and why).
 *
 * Server-side because it has to reach across Auth, Firestore, Cloud
 * Storage and the Realtime Database, and because a client cannot be
 * trusted to have actually removed anything.
 */
/**
 * Publishes a reviewed highlight so the website can play it, and takes it
 * back down again. Admin-only: this is the enforcement point for
 * CLAUDE.md's human review gate, and nothing else in the pipeline makes a
 * clip reachable. See functions/publishHighlight.js for why access is
 * granted by download token rather than by copying files.
 */
/**
 * Publishing and takedown are ONE callable with a flag rather than two
 * functions. That's partly because they're one decision with a direction,
 * but mainly for a practical reason: a separately-deployed
 * `unpublishHighlight` could not be granted its Cloud Run invoker binding
 * from this environment (every call returned a Cloud Run 401, and neither
 * a redeploy nor a delete-and-recreate reconciled it, unlike the other
 * functions here). Folding it into an endpoint that already has a working
 * binding sidesteps that entirely - and a takedown is far too important to
 * leave dependent on a console step someone might not have done.
 */
exports.publishHighlight = onCall(async (request) => {
  await requireAdmin(request.auth);
  const {publishHighlight, unpublishHighlight} = require("./publishHighlight");
  const matchId = request.data?.matchId;
  if (!matchId) throw new HttpsError("invalid-argument", "matchId is required.");
  // Defaults to publishing; pass published:false to take a clip down.
  const publish = request.data?.published !== false;
  return publish ? publishHighlight(matchId) : unpublishHighlight(matchId);
});

exports.deleteMyAccount = onCall({timeoutSeconds: 300}, async (request) => {
  const {deleteAccount} = require("./accountDeletion");
  return deleteAccount(request.auth);
});

/**
 * Renders a match's raw per-player recordings into one watchable vertical
 * clip (functions/highlightRender.js).
 *
 * Admin-only and on demand rather than automatic: most matches never
 * become highlights, so rendering every one would burn compute on clips
 * nobody posts. Rendering is also what the human review gate needs - a
 * reviewer cannot sensibly approve two unsynchronised HLS playlists.
 *
 * Resourced well above a normal callable because this is real media work:
 * it downloads the raw tracks, runs ffmpeg over a couple of minutes of
 * video, and uploads the result. /tmp is memory-backed on Cloud Functions,
 * so the working files count against the memory limit too.
 */
exports.renderMatchHighlight = onCall(
    {memory: "4GiB", cpu: 2, timeoutSeconds: 540},
    async (request) => {
      // Awaited deliberately - requireAdmin is async, and calling it
      // without awaiting would let a non-admin straight through while the
      // rejection surfaced as an unhandled promise.
      await requireAdmin(request.auth);
      const {renderMatchHighlight} = require("./highlightRender");
      const matchId = request.data?.matchId;
      if (!matchId) throw new HttpsError("invalid-argument", "matchId is required.");
      try {
        return await renderMatchHighlight(matchId);
      } catch (e) {
        throw new HttpsError("internal", e.message);
      }
    },
);

exports.setMatchReady = onCall((request) => setMatchReady(request.auth, request.data));
exports.skipMatch = onCall((request) => skipMatch(request.auth, request.data));
exports.getSkipAllowance = onCall((request) => getSkipAllowance(request.auth));

/**
 * The matches most in need of a vote, fewest-votes first.
 *
 * The liquidity half of the voting guardrails: weighting rating by vote
 * confidence is only fair if votes are actually gettable. Server-side
 * because the "have I already voted" check reads the ballots
 * subcollection, which clients are deliberately blocked from reading.
 */
exports.getMatchesNeedingVotes = onCall((request) => {
  const {getMatchesNeedingVotes} = require("./voteQueue");
  return getMatchesNeedingVotes(request.auth, request.data);
});

/**
 * Whether Ranked has unlocked for the caller, and how many exhibition
 * matches remain if not. CLAUDE.md asks for this progress to be visible
 * ("3 matches until Ranked unlocks") rather than a silent unlock.
 */
exports.getRankedUnlock = onCall((request) => getRankedUnlock(request.auth));

exports.onVoteCast = onVoteCast;
