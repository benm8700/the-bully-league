const {getFirestore, FieldValue} = require("firebase-admin/firestore");

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
  try {
    const stopped = await agoraPost(
        `cloud_recording/resourceid/${handle.resourceId}/sid/${handle.sid}/mode/mix/stop`,
        {
          cname: channelName,
          uid: RECORDER_UID,
          clientRequest: {async_stop: false},
        },
        appId, customerId, customerSecret,
    );
    const files = (stopped.serverResponse?.fileList ?? []).map((f) => ({
      fileName: f.fileName,
      trackType: f.trackType,
      sliceStartTime: f.sliceStartTime ?? null,
    }));
    return {ok: true, files};
  } catch (e) {
    console.error(`stopRecording failed for match ${matchId}:`, e.message);
    return {ok: false, error: e.message};
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

module.exports = {
  startRecording,
  stopRecording,
  writeRecordingState,
  isRecordingConfigured,
  UNSET,
  CANVAS,
  TILE,
  RECORDER_UID,
  storageConfig,
};
