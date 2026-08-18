const {onCall, HttpsError} = require("firebase-functions/v2/https");
const {onSchedule} = require("firebase-functions/v2/scheduler");
const {defineSecret} = require("firebase-functions/params");
const {initializeApp} = require("firebase-admin/app");
const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {getAuth} = require("firebase-admin/auth");
const {finalizeMatch, VOTE_WINDOW_MS, voteWindowEndMs} = require("./matchFinalization");
const {generateBracket, debugAdvanceRound, DEFAULT_MIN_ENTRANTS} = require("./tournament");
const {moderateImage, moderateImageContent} = require("./visualModeration");
const {generateToken, AGORA_APP_ID} = require("./agoraToken");
const {onVoteCast} = require("./voteCount");
const {onReactionWritten} = require("./reactions");
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

/** The shortest gap allowed between one account's votes. Deliberately
 * modest: it exists to price up speed, not to ration honest judging, and
 * anything long enough to inconvenience a real judge would cost more
 * genuine votes than it saves fake ones. */
const MIN_VOTE_INTERVAL_MS = 4000;

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

  if (!matchId || !votedForPlayerId) {
    throw new HttpsError(
        "invalid-argument",
        "matchId and votedForPlayerId are required.",
    );
  }

  // Two ways to prove a human is behind this vote, and exactly one of them
  // must hold.
  //
  // A per-vote CAPTCHA suits the website, where someone arrives from a
  // shared clip, votes once and leaves. It is fatal in the app's feed,
  // where the design is to scroll from one battle to the next - a checkbox
  // between every video would make judging a chore, and votes are the
  // scarce resource this app runs on. So a session, bought with one solve,
  // covers a bounded run instead (see functions/voteSession.js).
  //
  // The session is tried FIRST so an app already holding one never pays
  // for a token it does not need, and the budget is spent inside a
  // transaction so a fast scroll cannot stretch it past its ceiling.
  const {spendVote} = require("./voteSession");
  const spent = await spendVote(voterId);
  if (!spent.ok) {
    if (!turnstileToken) {
      throw new HttpsError(
          "failed-precondition",
          "No active voting session. Complete the CAPTCHA to start one.",
      );
    }
    const turnstileOk = await verifyTurnstileToken(turnstileToken, turnstileSecret.value());
    if (!turnstileOk) {
      throw new HttpsError("permission-denied", "Turnstile verification failed.");
    }
  }

  const db = getFirestore();
  // One moment for the whole call, so the window check, the account-age
  // weighting and the vote-interval floor all agree about "now".
  //
  // THIS WAS MISSING, and it is worth recording why nothing caught it:
  // `now` was read further down without ever being declared, so castVote
  // threw a ReferenceError on EVERY call - in-app and website voting were
  // both dead. The core-loop regression writes ballots directly to
  // sidestep the CAPTCHA, so it exercised finalization and rating
  // without once going through this function. A path with no live check
  // is a path nobody is checking, however green the suite looks.
  const now = Date.now();
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

  if (Date.now() > voteWindowEndMs(match)) {
    throw new HttpsError("failed-precondition", "The 24-hour voting window for this match has closed.");
  }

  const ballotRef = db.collection("votes").doc(matchId).collection("ballots").doc(voterId);
  const ballotSnap = await ballotRef.get();
  if (ballotSnap.exists) {
    throw new HttpsError("already-exists", "You've already voted on this match.");
  }

  // A FLOOR ON VOTING SPEED, enforced here because the client-side
  // watch gate is friction rather than a boundary - a modified client
  // skips that in a line, and this is the half it cannot.
  //
  // It is not a rate limit on judging: nobody honest votes twice in four
  // seconds, because they have to watch two different battles in between.
  // It is aimed squarely at the only thing that makes random voting worth
  // doing, which is doing it fast.
  const voterRef = db.collection("users").doc(voterId);
  const lastVoteAtMs = Number((await voterRef.get()).data()?.lastVoteAtMs);
  if (Number.isFinite(lastVoteAtMs) && now - lastVoteAtMs < MIN_VOTE_INTERVAL_MS) {
    throw new HttpsError("failed-precondition",
        "Slow down - watch the battle before judging it.",
        {reason: "too-fast"});
  }

  const voterRecord = await getAuth().getUser(voterId);
  const accountAgeMs = now - new Date(voterRecord.metadata.creationTime).getTime();
  const weight = accountAgeMs >= ACCOUNT_AGE_FULL_WEIGHT_MS ? 1 : REDUCED_VOTE_WEIGHT;

  await voterRef.set({lastVoteAtMs: now}, {merge: true});
  await ballotRef.set({
    votedForPlayerId,
    weight,
    timestamp: FieldValue.serverTimestamp(),
  });

  // Paying for judgement is the point of the whole currency: votes are the
  // scarce resource this app runs on, and the people whose votes matter
  // most are competitive players who care nothing for cosmetics. Keyed by
  // match, so one ballot pays once however many times the call is retried.
  //
  // Doubled during the prime-time window, and applied to JUDGING as well
  // as battling - more judges then means more matches reach full vote
  // confidence, which is what makes the window the place where rating
  // actually moves.
  let pointsAwarded = 0;
  let pointsMultiplier = 1;
  let streak = null;
  let voteCapReached = false;
  let quests = null;
  try {
    const {awardPoints, pointsSettings, awardAmount} = require("./points");
    const rates = await pointsSettings();
    const {readEventWindowConfig, isWithinWindow} = require("./eventWindow");
    const cfgSnap = await db.collection("config").doc("eventWindow").get();
    const inWindow = isWithinWindow(new Date(), readEventWindowConfig(cfgSnap.data()));
    pointsMultiplier = inWindow ? rates.eventWindowMultiplier : 1;
    // CAPPED PER DAY, and this is the rule that stops judging being a
    // farm. Paying per vote with no ceiling means someone can tap random
    // winners as fast as the feed loads - and the real damage is not the
    // points, it is that careless votes are noise fed into the thing that
    // decides rating. Votes past the cap still count in full; only the
    // payment stops, because refusing the vote would punish the app's
    // most active judges for being active.
    const {pacificNow} = require("./eventWindow");
    const result = await awardPoints(voterId, {
      reason: "vote_cast",
      sourceId: matchId,
      amount: awardAmount(rates.voteCast, {multiplier: pointsMultiplier}),
      dailyCap: {
        dayKey: pacificNow(new Date()).dayKey,
        max: rates.votePointsPerDay,
      },
    });
    pointsAwarded = result.awarded;
    voteCapReached = result.reason === "daily-cap";

    // The daily streak, paid on the first vote of each day. Kept inside
    // this try because it is a reward, never a precondition: a streak
    // failure must not fail the vote that earned it.
    const {recordVoteForStreak} = require("./voteStreak");
    streak = await recordVoteForStreak(voterId, {multiplier: pointsMultiplier});

    // A vote is SPECTATOR activation - the smaller of the two referral
    // tiers. Run after the streak, because the streak write is what
    // proves this account has actually judged something.
    const {grantReferralIfEarned} = require("./referral");
    await grantReferralIfEarned(voterId, "spectator");

    const {recordQuestEvent} = require("./quests");
    quests = await recordQuestEvent(voterId, "votes");
  } catch (e) {
    console.error(`vote points for ${voterId} failed:`, e.message);
  }

  // Returned so the app can show the reward landing rather than leaving
  // the multiplier to be inferred. A bonus nobody notices motivates
  // nobody.
  // The streak goes back too, so the app can show a run landing rather
  // than leaving a silent bonus in the ledger. A reward nobody notices
  // motivates nobody.
  return {success: true, weight, pointsAwarded, pointsMultiplier, streak, quests, voteCapReached};
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

/**
 * Publishes how many people are queueing or mid-match, for the "N roasters
 * online now" counter (see functions/presence.js for why this is a fixed
 * scheduled job rather than a callable or an activity-driven write).
 *
 * Failure is logged and swallowed: a missing count renders nothing on the
 * client, which is the correct degraded state. A social-proof number is
 * never worth breaking Home over.
 */
exports.publishOnlineCount = onSchedule("every 1 minutes", async () => {
  const {publishOnlineCount} = require("./presence");
  try {
    const counts = await publishOnlineCount();
    if (counts.total > 0) console.log("publishOnlineCount:", JSON.stringify(counts));
  } catch (err) {
    console.error("publishOnlineCount failed:", err);
  }
});

/**
 * The daily window's "it's starting" push, plus a last call before it
 * closes. Polls every 5 minutes rather than firing on a 6pm cron, because
 * the hours live in Firestore and are provisional - see eventWindowPush.js.
 */
exports.sendEventWindowPush = onSchedule("every 5 minutes", async () => {
  const {sendEventWindowPush} = require("./eventWindowPush");
  try {
    const result = await sendEventWindowPush();
    if (!result.skipped) console.log("sendEventWindowPush:", JSON.stringify(result));
  } catch (err) {
    console.error("sendEventWindowPush failed:", err);
  }
});

/**
 * Turns finished matches into watchable clips without anyone clicking:
 * composite first (cheap), captions only for clips that earn them
 * (expensive). See functions/autoRender.js for why this is a sweep rather
 * than a trigger, and why the two stages are split.
 *
 * Needs the same resources as the manual render callable - this is real
 * media work, and /tmp is memory-backed on Cloud Functions so the working
 * files count against memory too.
 */
/**
 * Nudges people to judge battles that are close to closing with too few
 * votes - the scarce resource the whole ladder runs on.
 *
 * Every two hours rather than more often, and capped at one reminder per
 * person per day inside the sweep. Fatigue is the real risk here: a
 * repeated notification is how an app earns an OS-level block, which
 * silences every other category too.
 */
/**
 * Starts (or joins) the caller's current bracket matchup. Ordinary
 * matchmaking pairs out of a queue; a bracket matchup is two named
 * players who must face each other, so it needs its own path.
 */
exports.startTournamentMatch = onCall((request) => {
  const {startTournamentMatch} = require("./tournamentPlay");
  return startTournamentMatch(request.auth, request.data);
});

/**
 * Closes rounds whose window has expired. Without this the window is
 * decoration and a bracket stalls the first time somebody loses interest.
 */
/**
 * Tells players their round has opened, and warns anyone who has not
 * checked in before it closes.
 *
 * Justified more than any other notification here: every other one is an
 * invitation, but missing an async round window is a FORFEIT - out of a
 * tournament you paid to enter, without ever playing.
 */
exports.tournamentNotifications = onSchedule("every 30 minutes", async () => {
  const {sweepTournamentNotifications} = require("./tournamentNotify");
  try {
    const result = await sweepTournamentNotifications();
    if (result.notified > 0) {
      console.log("tournamentNotifications:", JSON.stringify(result));
    }
  } catch (err) {
    console.error("tournamentNotifications failed:", err);
  }
});

exports.tournamentForfeits = onSchedule("every 30 minutes", async () => {
  const {sweepTournamentForfeits} = require("./tournamentPlay");
  try {
    const result = await sweepTournamentForfeits();
    if (result.swept > 0) console.log("tournamentForfeits:", JSON.stringify(result));
  } catch (err) {
    console.error("tournamentForfeits failed:", err);
  }
});

exports.voteReminders = onSchedule("every 120 minutes", async () => {
  const {sweepVoteReminders} = require("./voteReminder");
  try {
    const result = await sweepVoteReminders();
    // Logged even when it sends nothing, so a scheduled job that quietly
    // never fires is distinguishable from one deciding not to.
    console.log("voteReminders:", JSON.stringify(result));
  } catch (err) {
    console.error("voteReminders failed:", err);
  }
});

exports.autoRenderHighlights = onSchedule(
    {schedule: "every 5 minutes", memory: "4GiB", cpu: 2, timeoutSeconds: 540},
    async () => {
      const {sweepRenders} = require("./autoRender");
      try {
        const result = await sweepRenders();
        if (result.rendered.length || result.captioned.length || result.failed.length) {
          console.log("autoRenderHighlights:", JSON.stringify(result));
        }
      } catch (err) {
        console.error("autoRenderHighlights failed:", err);
      }
    });

/**
 * Frees players left waiting on a standing challenge nobody answered.
 * Without it, one unanswered challenge quietly removes a willing player
 * from the pool - see functions/releaseChallenges.js.
 */
exports.releaseUnansweredChallenges = onSchedule("every 2 minutes", async () => {
  const {releaseUnansweredChallenges} = require("./releaseChallenges");
  try {
    const result = await releaseUnansweredChallenges();
    if (result.released.length > 0) {
      console.log("releaseUnansweredChallenges:", JSON.stringify(result));
    }
  } catch (err) {
    console.error("releaseUnansweredChallenges failed:", err);
  }
});

/**
 * Recomputes the all-time hall of fame. Daily is plenty - it is an
 * all-time list, and a battle that belongs in it will still belong
 * tomorrow.
 */
exports.rebuildHallOfFame = onSchedule("every 24 hours", async () => {
  const {rebuildHallOfFame} = require("./hallOfFame");
  try {
    console.log("rebuildHallOfFame:", JSON.stringify(await rebuildHallOfFame()));
  } catch (err) {
    console.error("rebuildHallOfFame failed:", err);
  }
});

exports.purgeExpiredRecordings = onSchedule("every 24 hours", async () => {
  const {purgeExpiredRecordings} = require("./recordingRetention");
  const result = await purgeExpiredRecordings();
  console.log("purgeExpiredRecordings:", JSON.stringify(result));
});

exports.finalizeExpiredMatches = onSchedule("every 60 minutes", async () => {
  // The body lives in finalizeSweep.js so it can actually be RUN. This
  // job threw on every run for the life of the project - a missing
  // composite index, swallowed by the scheduler's own error handling -
  // and the scan that exists to catch exactly that could not reach it
  // while it was inline here.
  const {sweepExpiredMatches} = require("./finalizeSweep");
  try {
    const result = await sweepExpiredMatches();
    console.log("finalizeExpiredMatches:", JSON.stringify(result));
  } catch (err) {
    console.error("finalizeExpiredMatches failed:", err);
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
/**
 * The single in-app feed: battles needing judgement first, then the
 * archive. Runs server-side because the clip URLs are short-lived signed
 * URLs and because ballots are deliberately not client-readable.
 */
/**
 * Buys a bounded run of votes with one CAPTCHA solve, so the feed does not
 * put a checkbox between every battle. See functions/voteSession.js.
 */
exports.startVoteSession = onCall({secrets: [turnstileSecret]}, (request) => {
  const {startVoteSession} = require("./voteSession");
  return startVoteSession(request.auth, request.data,
      (token) => verifyTurnstileToken(token, turnstileSecret.value()));
});

/** How much of the caller's session is left, so the client can
 * re-challenge BEFORE a vote is refused rather than after. */
exports.getVoteSession = onCall((request) => {
  const {getVoteSession} = require("./voteSession");
  return getVoteSession(request.auth);
});

/**
 * A participant objecting to their own footage being public. Two channels
 * behaving very differently - see functions/takedown.js.
 */
exports.requestTakedown = onCall((request) => {
  const {requestTakedown} = require("./takedown");
  return requestTakedown(request.auth, request.data);
});

/**
 * Claim the captioned, shareable version of one of your own battles -
 * included with a subscription, bought with points, or (once IAP exists)
 * purchased outright. See functions/clipGrants.js for why captions rather
 * than the clip itself are what is actually being sold.
 */
exports.requestMatchClip = onCall((request) => {
  const {requestMatchClip} = require("./clipGrants");
  return requestMatchClip(request.auth, request.data);
});

/**
 * Leaves a bio reveal whose opponent has walked away, without spending a
 * skip. This is what makes a long reveal window safe: the maximum only
 * ever bites when one player never taps Ready, so bounding that by
 * presence rather than by the clock lets the window be as long as wanted.
 */
/**
 * Hands over the file for a clip the caller is entitled to.
 *
 * The objection check inside is load-bearing: publishing already refuses
 * while an objection stands, but a self-serve download would walk around
 * that entirely, so the gate has to sit on every path that hands over
 * bytes.
 */
/** What this player may do right now, so the client can offer rather
 * than refuse after they have done the whole camera check. */
/** The rank change this player has not been shown yet. Asking marks it
 * seen, so the popup fires exactly once. */
/**
 * This player's own rating history and a form summary. Own history only:
 * someone else's trend is competitive information, and opponent rating is
 * deliberately hidden.
 */
/**
 * Finds other players by name. Server-side because none of its safety
 * rules - opt-out, two-way blocking, banned accounts - can be enforced by
 * a client query.
 */
/**
 * Blocking a specific person - a personal preference tool, not a
 * moderation action, and silent to the person blocked. Honoured by
 * matchmaking (two-way) and by the player directory.
 */
/**
 * Records who invited this player. Set once, before their first battle,
 * and the reward only lands when they actually play one - paying at
 * signup would make throwaway accounts directly profitable.
 */
/** Today's three quests and how far along they are. */
exports.getMyQuests = onCall((request) => {
  const {getMyQuests} = require("./quests");
  return getMyQuests(request.auth, request.data);
});

exports.setReferrer = onCall((request) => {
  const {setReferrer} = require("./referral");
  return setReferrer(request.auth, request.data);
});

exports.setBlocked = onCall((request) => {
  const {setBlocked} = require("./blocking");
  return setBlocked(request.auth, request.data);
});

/** The caller's own block list, named so it can actually be undone. */
exports.getBlockedPlayers = onCall((request) => {
  const {getBlockedPlayers} = require("./blocking");
  return getBlockedPlayers(request.auth);
});

exports.searchPlayers = onCall((request) => {
  const {searchPlayers} = require("./playerDirectory");
  return searchPlayers(request.auth, request.data);
});

exports.getMyRatingHistory = onCall((request) => {
  const {getMyRatingHistory} = require("./ratingHistory");
  return getMyRatingHistory(request.auth, request.data);
});

exports.getPendingRankChange = onCall((request) => {
  const {getPendingRankChange} = require("./rankChange");
  return getPendingRankChange(request.auth);
});

exports.getMyEntitlement = onCall((request) => {
  const {getMyEntitlement} = require("./entitlement");
  return getMyEntitlement(request.auth);
});

exports.getClipDownload = onCall((request) => {
  const {getClipDownload} = require("./clipGrants");
  return getClipDownload(request.auth, request.data);
});

exports.releaseUnresponsiveMatch = onCall((request) => {
  const {releaseUnresponsiveMatch} = require("./matchmaking");
  return releaseUnresponsiveMatch(request.auth, request.data);
});

/** What the client needs to render the request honestly: whether the
 * opt-out window is still open, and how many requests are left. */
exports.getTakedownOptions = onCall((request) => {
  const {getTakedownOptions} = require("./takedown");
  return getTakedownOptions(request.auth, request.data);
});

/**
 * Records calls on settled battles - a private guess against a result
 * already decided, never a ballot. See functions/judgeStats.js.
 */
exports.recordJudgeCalls = onCall((request) => {
  const {recordCalls} = require("./judgeStats");
  return recordCalls(request.auth, request.data);
});

exports.getWatchFeed = onCall((request) => {
  const {getWatchFeed} = require("./watchFeed");
  return getWatchFeed(request.auth, request.data);
});

exports.getMatchesNeedingVotes = onCall((request) => {
  const {getMatchesNeedingVotes} = require("./voteQueue");
  return getMatchesNeedingVotes(request.auth, request.data);
});

/**
 * Usernames. These are the ONLY writers of `username`/`usernameLower` -
 * firestore.rules refuses the client both fields, because a name that a
 * client could set at will is a filter that only inconveniences the
 * honest. See functions/username.js for why a permissive comedy app
 * filters names at all.
 *
 * checkUsername deliberately allows an unauthenticated caller: it is used
 * by the signup form BEFORE the account exists, so that a taken or
 * refused name never leaves someone holding an account they cannot
 * finish setting up. It reveals only whether a name is free, which every
 * signup form in the world reveals.
 */
exports.checkUsername = onCall((request) => {
  const {checkUsername} = require("./username");
  return checkUsername(request.data, request.auth);
});

exports.setUsername = onCall((request) => {
  const {setUsername} = require("./username");
  return setUsername(request.data, request.auth);
});

exports.getUsernameState = onCall((request) => {
  const {getUsernameState} = require("./username");
  return getUsernameState(request.auth);
});

/**
 * Friend battles: challenge a specific person rather than a stranger.
 * Free at every tier by decision, so none of these consult entitlement.
 */
exports.challengeFriend = onCall((request) => {
  const {challengeFriend} = require("./friendBattle");
  return challengeFriend(request.auth, request.data);
});

exports.respondToChallenge = onCall((request) => {
  const {respondToChallenge} = require("./friendBattle");
  return respondToChallenge(request.auth, request.data);
});

exports.getMyChallenges = onCall((request) => {
  const {getMyChallenges} = require("./friendBattle");
  return getMyChallenges(request.auth);
});

exports.getChallengeMatch = onCall((request) => {
  const {getChallengeMatch} = require("./friendBattle");
  return getChallengeMatch(request.auth, request.data);
});

/**
 * Day passes: 24 hours of anytime battling, bought with points.
 *
 * The points economy's recurring sink, and deliberately a taste of the
 * subscription rather than a substitute for it - see functions/dayPass.js.
 */
exports.buyDayPass = onCall((request) => {
  const {buyDayPass} = require("./dayPass");
  return buyDayPass(request.auth);
});

exports.getDayPassState = onCall((request) => {
  const {getDayPassState} = require("./dayPass");
  return getDayPassState(request.auth);
});

/**
 * LIVE tournaments. The async format is untouched; these only ever act on
 * tournaments marked format: "live".
 */
exports.checkInToTournament = onCall((request) => {
  const {checkInToTournament} = require("./liveTournament");
  return checkInToTournament(request.auth, request.data);
});

exports.settleLiveMatch = onCall((request) => {
  const {settleLiveMatch} = require("./liveTournament");
  return settleLiveMatch(request.auth, request.data);
});

/**
 * Starts live tournaments whose scheduled time has arrived, or cancels
 * them if too few people checked in.
 *
 * Every minute, because a scheduled show that starts up to half an hour
 * late is not a scheduled show. Cheap: it is one indexed query returning
 * the handful of open tournaments, and it writes nothing when there is
 * nothing to start.
 */
exports.advanceLiveTournaments = onSchedule("every 1 minutes", async () => {
  const {sweepLiveTournaments} = require("./liveTournament");
  try {
    const result = await sweepLiveTournaments();
    // Logged only when something happened - a sweep that reports every
    // quiet minute buries the one that mattered.
    if (result.acted.length > 0) {
      console.log("advanceLiveTournaments:", JSON.stringify(result));
    }
  } catch (err) {
    console.error("advanceLiveTournaments failed:", err);
  }
});

/**
 * Spectating a LIVE tournament match.
 *
 * Deliberately a narrower door than generateAgoraToken, which refuses a
 * token for any match the caller is not playing in - a rule that exists
 * to stop people dropping in on strangers' battles and must not be
 * reopened. See functions/spectator.js for the three conditions and why
 * the token is a SUBSCRIBER one.
 */
exports.watchLiveMatch = onCall({secrets: [agoraAppCertificate]},
    (request) => {
      const {watchLiveMatch} = require("./spectator");
      return watchLiveMatch(request.auth, request.data,
          agoraAppCertificate.value());
    });

exports.liveMatchesFor = onCall((request) => {
  const {liveMatchesFor} = require("./spectator");
  return liveMatchesFor(request.auth, request.data);
});

/**
 * The weekly recap, Sunday evening Pacific.
 *
 * Polled hourly rather than pinned to an exact cron, for the same reason
 * the event-window push is: the schedule is one source of drift and the
 * marker is keyed by Pacific week, so repeated firing inside the window
 * is harmless and a missed hour is recoverable.
 */
exports.weeklyRecap = onSchedule("every 60 minutes", async () => {
  const {sweepWeeklyRecap} = require("./weeklyRecap");
  try {
    const result = await sweepWeeklyRecap();
    if (!result.skipped) {
      console.log("weeklyRecap:", JSON.stringify(result));
    }
  } catch (err) {
    console.error("weeklyRecap failed:", err);
  }
});

/**
 * Closes a season: archives the standings, then pulls every rating
 * partway back toward the centre.
 *
 * ADMIN ONLY AND DELIBERATELY NOT SCHEDULED - a cron that silently
 * rewrites every player's rating on a timer is the most destructive
 * thing this codebase could contain. Supports dryRun.
 */
exports.runSeasonReset = onCall(async (request) => {
  const {runSeasonReset} = require("./seasonReset");
  return runSeasonReset(request.auth, request.data, {requireAdmin});
});

exports.onVoteCast = onVoteCast;
exports.onReactionWritten = onReactionWritten;
