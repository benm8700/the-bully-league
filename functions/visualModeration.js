const vision = require("@google-cloud/vision");
const {getStorage} = require("firebase-admin/storage");
const {spawn} = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const client = new vision.ImageAnnotatorClient();

// Cloud Vision's SafeSearch returns a likelihood band per category
// (UNKNOWN/VERY_UNLIKELY/UNLIKELY/POSSIBLE/LIKELY/VERY_LIKELY) rather than
// a score - reject at LIKELY or above, matching CLAUDE.md's Content
// Policy & Moderation scope: nudity/explicit physical acts, NOT language
// (the free-speech policy stays untouched - this is visual-only).
const REJECT_LEVELS = new Set(["LIKELY", "VERY_LIKELY"]);

function verdictFromSafeSearch(safeSearch, {failureReason}) {
  if (!safeSearch) {
    return {approved: false, reason: failureReason};
  }
  if (REJECT_LEVELS.has(safeSearch.adult)) {
    return {approved: false, reason: "Flagged for adult content."};
  }
  if (REJECT_LEVELS.has(safeSearch.racy)) {
    return {approved: false, reason: "Flagged for suggestive content."};
  }
  if (REJECT_LEVELS.has(safeSearch.violence)) {
    return {approved: false, reason: "Flagged for violent content."};
  }
  return {approved: true};
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
  return verdictFromSafeSearch(result.safeSearchAnnotation, {
    failureReason: "Could not analyze this image - try a different photo.",
  });
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
  return verdictFromSafeSearch(result.safeSearchAnnotation, {
    failureReason: "Could not analyze this frame.",
  });
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
      const verdict = verdictFromSafeSearch(result.safeSearchAnnotation, {
        failureReason: "Could not analyze this video.",
      });
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

module.exports = {moderateImage, moderateImageContent, moderateVideo};
