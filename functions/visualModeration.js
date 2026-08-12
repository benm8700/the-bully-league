const vision = require("@google-cloud/vision");
const {getStorage} = require("firebase-admin/storage");

const client = new vision.ImageAnnotatorClient();

// Cloud Vision's SafeSearch returns a likelihood band per category
// (UNKNOWN/VERY_UNLIKELY/UNLIKELY/POSSIBLE/LIKELY/VERY_LIKELY) rather than
// a score - reject at LIKELY or above, matching CLAUDE.md's Content
// Policy & Moderation scope: nudity/explicit physical acts, NOT language
// (the free-speech policy stays untouched - this is visual-only).
const REJECT_LEVELS = new Set(["LIKELY", "VERY_LIKELY"]);

/**
 * Runs Google Cloud Vision SafeSearch on an already-uploaded Storage
 * object and returns an approve/reject verdict. Used for profile photos
 * (Build Order step 9a) - NOT live match video, which is a separate,
 * currently-blocked problem (see functions/index.js's moderatePhoto doc
 * comment and CLAUDE.md's step 9a status note).
 */
async function moderateImage(storagePath) {
  const bucket = getStorage().bucket();
  const gcsUri = `gs://${bucket.name}/${storagePath}`;

  const [result] = await client.safeSearchDetection(gcsUri);
  const safeSearch = result.safeSearchAnnotation;
  if (!safeSearch) {
    return {approved: false, reason: "Could not analyze this image - try a different photo."};
  }

  if (REJECT_LEVELS.has(safeSearch.adult)) {
    return {approved: false, reason: "This photo was flagged for adult content."};
  }
  if (REJECT_LEVELS.has(safeSearch.racy)) {
    return {approved: false, reason: "This photo was flagged for suggestive content."};
  }
  if (REJECT_LEVELS.has(safeSearch.violence)) {
    return {approved: false, reason: "This photo was flagged for violent content."};
  }

  return {approved: true};
}

module.exports = {moderateImage};
