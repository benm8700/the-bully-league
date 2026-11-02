const path = require("path");
const {spawn} = require("child_process");

/**
 * Scans a battle's recording for nudity/explicit content BEFORE a captioned
 * (deliverable / postable) clip can be handed out - the backstop for what the
 * LIVE in-match sampler misses.
 *
 * WHY THIS EXISTS: the live detector samples a frame only every ~4 seconds and
 * only auto-ends on blatant nudity (adult == VERY_LIKELY), to avoid false
 * positives killing real battles. A brief flash - especially at the very end of
 * a match - slips through. Owner clip delivery is now instant and un-reviewed,
 * so without a check on the OUTPUT a missed flash could be rendered and handed
 * over. This scans the finished recording densely, strictly, before it's
 * deliverable.
 *
 * COST is contained: it runs ONLY on captioned renders (clips someone requested
 * / a subscriber / a feature), never on every battle's stage-1 render. A few
 * frames per player, ~1-2c per requested clip.
 *
 * PER-PLAYER, so it also ATTRIBUTES: the two battlers record as separate uids
 * (1 and 2), so whichever player's own stream trips is the one disqualified -
 * which is what lets My Battles say WHO got disqualified.
 */

/** Frames sampled per player. A handful spread across the match catches a flash
 * while keeping the SafeSearch cost ~1-2c per clip. */
const FRAMES_PER_PLAYER = 6;

/** Grab the frame a little into each segment (segments are a few seconds). */
const FRAME_AT_SEC = 0.8;

/** Spread n picks evenly across an array (fewer items -> take them all). */
function pickSpread(arr, n) {
  if (arr.length <= n) return [...arr];
  const out = [];
  for (let i = 0; i < n; i++) out.push(arr[Math.floor((i * arr.length) / n)]);
  return out;
}

/** Extract a single JPEG frame from a local media file to a base64 string, or
 * null if it can't be decoded (a truncated segment must not block the clip). */
function extractFrameBase64(ffmpegPath, inputPath, atSec) {
  return new Promise((resolve) => {
    const proc = spawn(ffmpegPath, [
      "-ss", String(atSec), "-i", inputPath,
      "-frames:v", "1", "-f", "image2", "-c:v", "mjpeg", "pipe:1",
    ]);
    const chunks = [];
    proc.stdout.on("data", (d) => chunks.push(d));
    proc.stderr.on("data", () => {}); // drain so the pipe never stalls
    proc.on("error", () => resolve(null));
    proc.on("close", (code) => {
      if (code !== 0 || chunks.length === 0) return resolve(null);
      resolve(Buffer.concat(chunks).toString("base64"));
    });
  });
}

/**
 * Scans the per-player video segments (already downloaded to workDir by the
 * render) for inappropriate content. Returns the first player that trips.
 *
 * `moderate(base64)` is the strict frame check (visualModeration.moderateFrameStrict),
 * injected so the whole function is testable without Cloud Vision. A failed scan
 * on one frame is skipped, never treated as a block - a block must be a real
 * positive, not a transient error.
 *
 * @returns {Promise<{blocked:boolean, reportedUid?:string, reason?:string}>}
 */
async function scanRecordingForContent(
    timeline, workDir, ffmpegPath, moderate, extract = extractFrameBase64) {
  for (const uid of timeline.uids) {
    const segs = timeline.segments.filter(
        (s) => s.uid === uid && s.kind === "video");
    for (const seg of pickSpread(segs, FRAMES_PER_PLAYER)) {
      const local = path.join(workDir, seg.path.split("/").pop());
      const b64 = await extract(ffmpegPath, local, FRAME_AT_SEC);
      if (!b64) continue;
      let verdict;
      try {
        verdict = await moderate(b64);
      } catch (_) {
        continue;
      }
      if (verdict && verdict.approved === false) {
        return {blocked: true, reportedUid: uid, reason: verdict.reason || "nudity"};
      }
    }
  }
  return {blocked: false};
}

module.exports = {
  scanRecordingForContent, pickSpread, extractFrameBase64,
  FRAMES_PER_PLAYER,
};
