const vision = require("@google-cloud/vision");
const {getStorage} = require("firebase-admin/storage");

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

module.exports = {moderateImage, moderateImageContent};
