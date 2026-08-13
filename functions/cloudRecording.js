const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {getStorage} = require("firebase-admin/storage");

/**
 * Match recording via Agora Cloud Recording (Build Order step 11's
 * prerequisite - CLAUDE.md's Auto-Editing for Highlights and the whole
 * Instagram/TikTok content pipeline depend on there being footage at all,
 * and until now nothing anywhere captured any).
 *
 * WHY SERVER-SIDE CLOUD RECORDING rather than recording on the devices:
 *  - It survives a client crash, a backgrounded app, or a player force-
 *    quitting mid-match. Device-side recording loses exactly the matches
 *    most worth reviewing.
 *  - It costs the players no upload bandwidth or battery, which matters on
 *    mobile data.
 *  - Composite mode produces ONE side-by-side file, which is what a
 *    highlight clip actually needs. Recording each device separately would
 *    mean compositing two files later anyway.
 *
 * COST (see CLAUDE.md's Cost Planning, now calculated): composite HD
 * recording is about $0.015 per match on top of ~$0.020 of call. Only
 * ranked and tournament matches are recorded, per CLAUDE.md's recording
 * scope decision - exhibition matches never enter this path.
 *
 * The composite canvas below is deliberately kept inside the HD billing
 * band. Agora charges on aggregate resolution, so enlarging the canvas is
 * a pricing decision as much as a quality one: crossing 921,600 pixels
 * moves every recorded minute from $5.99 to $13.49 per thousand.
 *
 * Credentials: Agora's RESTful API uses a Customer ID / Customer Secret
 * pair, which is SEPARATE from the App ID and App Certificate already in
 * use. Both are Firebase secrets and never reach the client, same pattern
 * as the App Certificate and the Turnstile secret.
 */

const AGORA_API = "https://api.agora.io/v1/apps";

// Two 480x360 tiles side by side = 960x360 = 345,600 px, comfortably
// inside the HD band. Vertical-friendly framing for the eventual social
// clip is a later concern for the editing pipeline, not the raw capture.
const CANVAS = {width: 960, height: 360};
const TILE = {width: 480, height: 360};

/** The uid the recording bot joins as. Must not collide with a real
 * participant; the app joins with uid 0 (wildcard) and Agora assigns
 * real users low numbers, so a fixed high value is safe. */
const RECORDER_UID = "999999";

/** Placeholder written into the secrets before the real Agora RESTful
 * credentials exist, so the functions can be deployed and everything
 * downstream (schema, retention, review gate) is live and testable while
 * recording itself stays inert. */
const UNSET = "unset";

function isBlank(value) {
  return !value || value === UNSET;
}

/**
 * Whether recording is actually configured. Checked before every start so
 * an unconfigured deployment quietly skips recording instead of failing
 * matches - the match is what matters; the footage is secondary.
 */
function isRecordingConfigured(creds) {
  return !isBlank(creds?.customerId) &&
    !isBlank(creds?.customerSecret) &&
    !isBlank(creds?.storage?.bucket) &&
    !isBlank(creds?.storage?.accessKey) &&
    !isBlank(creds?.storage?.secretKey);
}

function authHeader(customerId, customerSecret) {
  return "Basic " + Buffer.from(`${customerId}:${customerSecret}`).toString("base64");
}

async function agoraPost(path, body, appId, customerId, customerSecret) {
  const res = await fetch(`${AGORA_API}/${appId}/${path}`, {
    method: "POST",
    headers: {
      "Authorization": authHeader(customerId, customerSecret),
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch {
    throw new Error(`Agora returned non-JSON (HTTP ${res.status}): ${text.slice(0, 200)}`);
  }
  if (!res.ok) {
    throw new Error(`Agora ${path} failed (HTTP ${res.status}): ${JSON.stringify(parsed)}`);
  }
  return parsed;
}

/**
 * Storage destination. Agora writes directly into the bucket, so it needs
 * its own credentials for it - an HMAC key pair, not the Firebase service
 * account. Vendor 6 is Google Cloud Storage in Agora's vendor enum.
 */
function storageConfig(config, matchId) {
  return {
    vendor: 6,
    region: 0, // Ignored for GCS, but the field is required.
    bucket: config.bucket,
    accessKey: config.accessKey,
    secretKey: config.secretKey,
    // Files land under match_recordings/{matchId}/ so retention and
    // review can find everything for a match without a manifest.
    fileNamePrefix: ["match_recordings", matchId],
  };
}

/**
 * Begins recording a match channel. Two calls, per Agora's protocol:
 * acquire a resource, then start against it.
 *
 * Returns the handle needed to stop it later. Never throws to the caller -
 * a recording failure must not take down a match that two people are
 * about to play, so the failure is recorded on the match document and the
 * match proceeds unrecorded.
 */
async function startRecording(matchId, channelName, creds) {
  const {appId, customerId, customerSecret, storage} = creds;
  try {
    const acquired = await agoraPost(
        "cloud_recording/acquire",
        {
          cname: channelName,
          uid: RECORDER_UID,
          clientRequest: {resourceExpiredHour: 24, scene: 0},
        },
        appId, customerId, customerSecret,
    );

    const started = await agoraPost(
        `cloud_recording/resourceid/${acquired.resourceId}/mode/mix/start`,
        {
          cname: channelName,
          uid: RECORDER_UID,
          clientRequest: {
            token: creds.token,
            recordingConfig: {
              channelType: 0, // Communication - matches how the app joins.
              streamTypes: 2, // Audio + video.
              videoStreamType: 0,
              maxIdleTime: 30, // Stop by itself if everyone leaves.
              subscribeUidGroup: 0,
              transcodingConfig: {
                width: CANVAS.width,
                height: CANVAS.height,
                fps: 15,
                bitrate: 800,
                mixedVideoLayout: 0,
                backgroundColor: "#000000",
              },
            },
            recordingFileConfig: {avFileType: ["hls", "mp4"]},
            storageConfig: storageConfig(storage, matchId),
          },
        },
        appId, customerId, customerSecret,
    );

    return {
      ok: true,
      resourceId: acquired.resourceId,
      sid: started.sid,
      startedAt: Date.now(),
    };
  } catch (e) {
    console.error(`startRecording failed for match ${matchId}:`, e.message);
    return {ok: false, error: e.message};
  }
}

/**
 * Stops a recording and returns the files Agora produced.
 *
 * Also best-effort: if this fails, Agora's own maxIdleTime stops the
 * recording once both players leave the channel, so the footage isn't
 * lost - only the file list is, which the query endpoint can recover.
 */
async function stopRecording(matchId, channelName, handle, creds) {
  const {appId, customerId, customerSecret} = creds;
  let stopError = null;
  try {
    await agoraPost(
        `cloud_recording/resourceid/${handle.resourceId}/sid/${handle.sid}/mode/mix/stop`,
        {
          cname: channelName,
          uid: RECORDER_UID,
          clientRequest: {async_stop: false},
        },
        appId, customerId, customerSecret,
    );
  } catch (e) {
    // An "already stopped" response is an entirely normal outcome, not a
    // failure: Agora's own maxIdleTime ends the recording shortly after
    // the channel empties, which can easily beat our stop request. The
    // footage is complete in that case. Rather than trying to classify
    // Agora's error codes, we let the bucket be the judge below - if the
    // files are there, the recording succeeded.
    stopError = e.message;
  }

  // Authoritative regardless of who actually ended the recording.
  const files = await listRecordedFiles(matchId);
  if (files.length > 0) {
    return {ok: true, files, stopError};
  }

  console.error(`stopRecording produced no files for match ${matchId}:`, stopError ?? "(no error)");
  return {ok: false, error: stopError ?? "no files were produced", files: []};
}

/**
 * Lists what actually landed in Cloud Storage for a match.
 *
 * This is the authoritative file list, deliberately preferred over the
 * one Agora returns from its stop call. The stop response is only
 * available when *our* stop request is the one that ended the recording -
 * but a recording can equally be ended by Agora's own maxIdleTime once
 * the channel empties, or by the runaway watchdog. Confirmed on a real
 * match: the footage finalized perfectly while the stop call came back
 * with Agora's "not recording" error, leaving the document claiming zero
 * files for a recording that had produced ten objects.
 *
 * Reading the bucket works in every one of those cases, because the
 * bucket is ours and the files are already there.
 */
async function listRecordedFiles(matchId) {
  try {
    const [objects] = await getStorage().bucket()
        .getFiles({prefix: `match_recordings/${matchId}/`});
    return objects.map((o) => ({
      path: o.name,
      sizeBytes: Number(o.metadata?.size ?? 0),
      contentType: o.metadata?.contentType ?? null,
      // The composited mp4 is what the highlight pipeline will want; the
      // .ts segments and .m3u8 playlist are HLS scaffolding around it.
      isComposite: o.name.endsWith(".mp4"),
    }));
  } catch (e) {
    console.error(`could not list recorded files for ${matchId}:`, e.message);
    return [];
  }
}

/**
 * Records the outcome of a start/stop attempt on the match document.
 *
 * `reviewStatus` starts at "pending" and is the gate CLAUDE.md requires
 * before anything is posted publicly: a human has to approve a clip, and
 * separately confirm it won't trip TikTok/Instagram/YouTube's own rules,
 * which are stricter than this app's internal speech policy. Nothing in
 * this pipeline publishes anything on its own.
 */
async function writeRecordingState(matchId, patch) {
  try {
    await getFirestore().collection("matches").doc(matchId).set(
        {recording: {...patch, updatedAt: FieldValue.serverTimestamp()}},
        {merge: true},
    );
  } catch (e) {
    console.error(`could not persist recording state for ${matchId}:`, e.message);
  }
}

/**
 * The longest a recording for this match could legitimately run, derived
 * from the settings actually stamped on that match rather than a fixed
 * guess.
 *
 * This matters because match timings are live-configurable (see
 * functions/matchSettings.js): a flat cap generous enough for a 10-round,
 * 120-second-turn configuration would be far too slack for the 3-round
 * default, while a cap tight enough for the default would cut off a
 * legitimately long tournament format. Deriving it means the watchdog can
 * never kill a real match, and can never let a stuck one bill forever.
 */
function maxRecordingSeconds(settings) {
  const s = settings ?? {};
  const rounds = s.roundCount ?? 3;
  const turn = s.roundLengthSeconds ?? 15;
  const countdown = s.countdownSeconds ?? 5;
  const reveal = s.bioRevealSeconds ?? 60;
  // Both players take a turn each round, each preceded by a countdown.
  const matchSeconds = rounds * 2 * (turn + countdown);
  // Slack for the verdict screen, the stop call, and network lag. Kept
  // deliberately modest: recording starts at host election, so joining is
  // already done by this point, and an over-generous cap means a wedged
  // recording costs MORE than a real match rather than less. Note the
  // watchdog polls on a schedule, so real-world stop time is this cap plus
  // up to one poll interval - tuning this below a couple of minutes buys
  // nothing.
  const SLACK_SECONDS = 120;
  return reveal + matchSeconds + SLACK_SECONDS;
}

/**
 * Force-stops recordings that have outlived any plausible match.
 *
 * This is the backstop for the one genuinely unbounded billing path.
 * Agora's own `maxIdleTime` handles the common case - it stops recording
 * shortly after the channel empties - but it does nothing while clients
 * are still connected. A match whose state machine wedged, or a client
 * that never leaves the channel, would otherwise keep billing recording
 * minutes indefinitely with nothing to notice.
 *
 * Alerts tell you after money is spent; this prevents the spend.
 */
async function stopRunawayRecordings(creds, {now = Date.now()} = {}) {
  const db = getFirestore();
  const snap = await db
      .collection("matches")
      .where("recording.status", "==", "recording")
      .get();

  let stopped = 0;
  let running = 0;

  for (const doc of snap.docs) {
    const match = doc.data();
    const startedAt = match.recording?.startedAt;
    if (typeof startedAt !== "number") continue;

    const ageSeconds = (now - startedAt) / 1000;
    if (ageSeconds <= maxRecordingSeconds(match.settings)) {
      running++;
      continue;
    }

    console.warn(
        `runaway recording on match ${doc.id}: ${Math.round(ageSeconds)}s old, force-stopping`,
    );
    const result = await stopRecording(doc.id, match.channelName, match.recording, creds);
    await writeRecordingState(doc.id, result.ok ?
      {status: "recorded", files: result.files, stoppedAt: now, forceStopped: true} :
      {status: "stop_failed", error: result.error, forceStopped: true});
    stopped++;
  }

  return {stopped, running, checked: snap.size};
}

module.exports = {
  startRecording,
  stopRecording,
  listRecordedFiles,
  stopRunawayRecordings,
  maxRecordingSeconds,
  writeRecordingState,
  isRecordingConfigured,
  UNSET,
  CANVAS,
  TILE,
  RECORDER_UID,
  storageConfig,
};
