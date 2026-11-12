const vision = require("@google-cloud/vision");
const {getStorage} = require("firebase-admin/storage");
const {spawn} = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const client = new vision.ImageAnnotatorClient();

// Cloud Vision's SafeSearch returns a likelihood band per category
// (UNKNOWN/VERY_UNLIKELY/UNLIKELY/POSSIBLE/LIKELY/VERY_LIKELY) rather than
// a score. This is VISUAL-only moderation (nudity/explicit physical acts).
// It never touches LANGUAGE - the free-speech content policy is absolute:
// slurs and any/all spoken language are allowed by design and nothing in
// this codebase ever moderates what is said.
//
// Two strictness levels, deliberately different:
//  - PROFILE PHOTOS + INTRO VIDEOS (pre-publication, reliable, store-critical
//    nudity gate): reject at LIKELY or above across adult/racy/violence.
//  - LIVE IN-MATCH FRAMES: reject ONLY blatant nudity (adult == VERY_LIKELY).
//    This was loosened hard (developer's call, 2026-09-14) after the live
//    detector false-fired on an ordinary face/gesture/dark room and
//    auto-ended a real battle. Dropping the "racy" and "violence" categories
//    removes that entire false-positive class - those are what trip on a
//    lit face, a lunge at the camera, or a dim room - while the single
//    unambiguous VERY_LIKELY-adult band still catches actual exposure in a
//    random-stranger video app (the Omegle-style legal/store exposure).
const REJECT_LEVELS = new Set(["LIKELY", "VERY_LIKELY"]);
const LIVE_FRAME_REJECT_LEVELS = new Set(["VERY_LIKELY"]);
const LIVE_FRAME_CATEGORIES = ["adult"];
const ALL_CATEGORIES = ["adult", "racy", "violence"];

const CATEGORY_REASON = {
  adult: "Flagged for adult content.",
  racy: "Flagged for suggestive content.",
  violence: "Flagged for violent content.",
};

function verdictFromSafeSearch(safeSearch, {
  failureReason,
  rejectLevels = REJECT_LEVELS,
  categories = ALL_CATEGORIES,
  approveOnMissing = false,
}) {
  if (!safeSearch) {
    // Pre-publication gates (photos/intro) reject an unreadable image so an
    // un-analysable file can't slip through. The LIVE path fails OPEN
    // instead: a transient empty result must never auto-end a real battle.
    return approveOnMissing ? {approved: true} : {approved: false, reason: failureReason};
  }
  for (const category of categories) {
    if (rejectLevels.has(safeSearch[category])) {
      return {approved: false, reason: CATEGORY_REASON[category]};
    }
  }
  return {approved: true};
}

/**
 * The LIVE in-match frame policy, named so it is testable in one place and
 * cannot silently drift. Rejects ONLY blatant nudity (adult == VERY_LIKELY),
 * drops racy/violence entirely, and FAILS OPEN on a missing/unreadable frame.
 * This is the fix (developer's call, 2026-09-14) for the false-fire that
 * auto-ended a real battle on an ordinary lit face / dark room - so a test
 * pins it, because a future re-tightening would reintroduce that exact bug.
 */
function liveFrameVerdict(safeSearch) {
  return verdictFromSafeSearch(safeSearch, {
    failureReason: "Could not analyze this frame.",
    rejectLevels: LIVE_FRAME_REJECT_LEVELS,
    categories: LIVE_FRAME_CATEGORIES,
    approveOnMissing: true,
  });
}

/**
 * The PRE-PUBLICATION policy (profile photos + intro videos): the strict,
 * store-critical nudity gate. Rejects adult/racy/violence at LIKELY or above,
 * and FAILS CLOSED on a missing/unreadable image so an un-analysable file can
 * never slip through. Named alongside liveFrameVerdict so the two strictness
 * levels sit side by side and are pinned together.
 */
function prepublishVerdict(safeSearch, failureReason) {
  return verdictFromSafeSearch(safeSearch, {failureReason});
}

/** The profile-selfie policy: blatant nudity only, fails CLOSED. */
function selfieVerdict(safeSearch) {
  return verdictFromSafeSearch(safeSearch, {
    failureReason: "Could not read this photo - try taking it again.",
    rejectLevels: LIVE_FRAME_REJECT_LEVELS,
    categories: LIVE_FRAME_CATEGORIES,
  });
}

/**
 * Runs Google Cloud Vision SafeSearch on an already-uploaded Storage
 * object and returns an approve/reject verdict. Used for profile photos
 * (Build Order step 9a).
 */
async function moderateImage(storagePath) {
  const bucket = getStorage().bucket();
  const gcsUri = `gs://${bucket.name}/${storagePath}`;

  const [result] = await client.safeSearchDetection(gcsUri);
  return prepublishVerdict(result.safeSearchAnnotation,
      "Could not analyze this image - try a different photo.");
}

/**
 * Moderates a mandatory profile SELFIE: the same strict nudity gate as any
 * photo, AND a face check so it is actually a clear photo of the person's face
 * (it shows in the bio reveal + player directory when battling). Reuses the
 * same Cloud Vision client - no new dependency - for both the SafeSearch and
 * the face detection. Returns {approved} / {approved:false, reason}.
 */
async function moderateFacePhoto(storagePath) {
  const bucket = getStorage().bucket();
  const gcsUri = `gs://${bucket.name}/${storagePath}`;

  // 1. Nudity (fails CLOSED on an unreadable image). SELFIE RULE (2026-11-10):
  // only blatant nudity (adult == VERY_LIKELY), the same band live battle
  // frames use. The strict prepublish rule (LIKELY+ on adult/racy/violence)
  // flagged an ordinary close-up face as "adult content" on a real sign-up;
  // a selfie is a tight crop of skin, which is exactly what trips "racy" and
  // low-confidence "adult". The face check below still has to pass.
  const [ss] = await client.safeSearchDetection(gcsUri);
  const nudity = selfieVerdict(ss.safeSearchAnnotation);
  if (!nudity.approved) {
    const a = ss.safeSearchAnnotation || {};
    console.warn("selfie rejected", storagePath,
        JSON.stringify({adult: a.adult, racy: a.racy, violence: a.violence}));
    return nudity;
  }

  // 2. Must contain a clear face.
  const [fd] = await client.faceDetection(gcsUri);
  const faces = (fd.faceAnnotations || []).filter(
      (f) => (f.detectionConfidence ?? 0) >= 0.5);
  if (faces.length === 0) {
    return {
      approved: false,
      reason: "We couldn't see your face clearly. Center your face, find good " +
        "light, and try again.",
    };
  }
  return {approved: true};
}

/**
 * Same as moderateImage, but for image bytes that were never uploaded to
 * Storage - used for live match video frames (Build Order step 9a's
 * live-video half). Frames are sampled every few seconds client-side
 * (see AgoraVideoCallService's remoteFrameSamples), converted from raw
 * I420 to JPEG, and sent here as base64 - ephemeral moderation checks,
 * not content worth persisting anywhere.
 */
async function moderateImageContent(base64Content) {
  const [result] = await client.safeSearchDetection({
    image: {content: Buffer.from(base64Content, "base64")},
  });
  // Live in-match frames use the loosened rule: blatant nudity only
  // (adult == VERY_LIKELY), no racy/violence. See liveFrameVerdict.
  return liveFrameVerdict(result.safeSearchAnnotation);
}

/**
 * STRICT SafeSearch on a raw frame (prepublish policy), for scanning a clip's
 * frames before it can be delivered or posted - the backstop for what the live
 * sampler misses (it samples ~every 4s on only the blatant-nudity band). Same
 * strictness as a profile photo, so a posted clip can't carry what a photo
 * can't. Returns {approved, reason?}. See functions/clipContentScan.js.
 */
async function moderateFrameStrict(base64Content) {
  const [result] = await client.safeSearchDetection({
    image: {content: Buffer.from(base64Content, "base64")},
  });
  return prepublishVerdict(result.safeSearchAnnotation,
      "Could not analyze this frame.");
}

/**
 * Moderates a "tell me about yourself" intro video (mandatory, User Profile
 * System). A video cannot be handed straight to SafeSearch, so ffmpeg
 * (already a dependency, used by the highlight renderer) samples ~one frame
 * every ten seconds and each frame is run through the same SafeSearch check
 * as a profile photo. The FIRST bad frame rejects the whole video - one
 * exposed frame is enough, and there is no reason to keep analysing.
 *
 * Screening happens ASYNCHRONOUSLY at upload, which is the whole safety
 * advantage of a recorded intro over a live stranger video chat: a stored
 * file can be checked frame by frame before anyone ever sees it, rather than
 * hoping a live sampler catches a flash between samples.
 */
async function moderateVideo(storagePath) {
  const bucket = getStorage().bucket();
  const workDir = fs.mkdtempSync(path.join(os.tmpdir(), "intromod-"));
  const localVideo = path.join(workDir, "intro.mp4");
  try {
    await bucket.file(storagePath).download({destination: localVideo});

    const ffmpegPath = require("ffmpeg-static");
    await new Promise((resolve, reject) => {
      // fps=1/10 => one frame per 10s; cap at 8 so a mis-tagged long file
      // can never spawn hundreds of SafeSearch calls. round=up ceils the
      // output frame count, so ANY decodable clip yields at least one frame
      // - without it a short clip (< ~10s) rounds to zero frames and is
      // wrongly reported as unreadable.
      const proc = spawn(ffmpegPath, [
        "-i", localVideo,
        "-vf", "fps=1/10:round=up",
        "-frames:v", "8",
        path.join(workDir, "f_%03d.jpg"),
      ]);
      let err = "";
      proc.stderr.on("data", (d) => {
        err += d.toString();
      });
      proc.on("close", (code) =>
        code === 0 ? resolve() : reject(new Error("ffmpeg failed: " + err)));
      proc.on("error", reject);
    });

    const frames = fs.readdirSync(workDir)
        .filter((f) => f.endsWith(".jpg")).sort();
    if (frames.length === 0) {
      // No decodable frames - refuse rather than approve an unreadable file.
      return {approved: false,
        reason: "Could not read this video - try re-recording."};
    }

    for (const f of frames) {
      const content = fs.readFileSync(path.join(workDir, f));
      const [result] = await client.safeSearchDetection({image: {content}});
      const verdict = prepublishVerdict(result.safeSearchAnnotation,
          "Could not analyze this video.");
      if (!verdict.approved) return verdict;
    }
    return {approved: true};
  } finally {
    try {
      fs.rmSync(workDir, {recursive: true, force: true});
    } catch (_) {
      // best-effort temp cleanup
    }
  }
}

module.exports = {
  selfieVerdict,
  moderateImage, moderateFacePhoto, moderateImageContent, moderateVideo,
  moderateFrameStrict,
  // Exported for the pure regression test (functions/test/visualModeration.test.js).
  verdictFromSafeSearch, liveFrameVerdict, prepublishVerdict,
};
