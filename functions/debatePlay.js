const {getFirestore} = require("firebase-admin/firestore");
const {HttpsError} = require("firebase-functions/v2/https");
const {
  startDebateRecording,
  writeRecordingState,
  isRecordingConfigured,
} = require("./cloudRecording");

/**
 * Starting the Main Stage JUDGES' DEBATE recording.
 *
 * Client-triggered by a seated judge as they go on camera (a fire-and-forget
 * call), so it must be race-safe: the five judges all arrive at once, so the
 * first to claim it records and everyone else no-ops. There is deliberately NO
 * matching "stop" call - the runaway-recording watchdog stops a debate
 * recording once the verdict lands or it outruns the judge window (see
 * stopRunawayRecordings), which keeps all the recording credentials in one
 * place instead of spreading them onto the vote path.
 */

async function requireSeatedJudge(db, matchId, uid) {
  const matchSnap = await db.collection("matches").doc(matchId).get();
  const match = matchSnap.exists ? matchSnap.data() : null;
  if (!match || !match.mainStage || !match.mainStage.tournamentId) {
    throw new HttpsError("failed-precondition", "Not a Main Stage battle.");
  }
  const t = await db.collection("tournaments")
      .doc(match.mainStage.tournamentId).get();
  const panel = (t.exists && Array.isArray(t.data().judges)) ?
    t.data().judges : [];
  if (!panel.includes(uid)) {
    throw new HttpsError("permission-denied",
        "Only seated judges start the table recording.");
  }
  return match;
}

async function startDebate(auth, data, creds) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const matchId = data && data.matchId;
  if (!matchId) {
    throw new HttpsError("invalid-argument", "matchId is required.");
  }
  const db = getFirestore();
  const match = await requireSeatedJudge(db, matchId, auth.uid);

  // Only during the DEBATE: the battle is over and the verdict is not yet in.
  if (match.status !== "completed" || match.judgeWinnerId) {
    return {started: false, reason: "not-in-debate"};
  }
  // Unconfigured (credentials still placeholder) means "don't record" - the
  // same graceful no-op the battle recording uses - WITHOUT claiming, so it can
  // record once the credentials are set.
  if (!isRecordingConfigured(creds)) {
    return {started: false, reason: "unconfigured"};
  }

  // Claim in a transaction: the first judge to arrive sets debateRecording and
  // records; the others see it present and no-op.
  const matchRef = db.collection("matches").doc(matchId);
  const claimed = await db.runTransaction(async (tx) => {
    const m = (await tx.get(matchRef)).data();
    if (m.debateRecording) return false;
    tx.set(matchRef,
        {debateRecording: {status: "starting", claimedAt: Date.now()}},
        {merge: true});
    return true;
  });
  if (!claimed) return {started: false, reason: "already"};

  const channelName = `judges_${matchId}`;
  const result = await startDebateRecording(matchId, channelName, creds);
  await writeRecordingState(matchId, result.ok ? {
    status: "recording",
    resourceId: result.resourceId,
    sid: result.sid,
    startedAt: result.startedAt,
  } : {
    status: "start_failed",
    error: result.error,
  }, "debateRecording");
  return {started: result.ok};
}

module.exports = {startDebate};
