const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {getStorage} = require("firebase-admin/storage");

/**
 * Enforces CLAUDE.md's Video Retention Policy: raw match recordings are
 * deleted after 7 days; only clips actually published as highlights are
 * kept.
 *
 * This is a real obligation rather than housekeeping. The retention
 * window is what bounds how long the recording consent the players gave
 * actually reaches (see the Recording Consent legal item), it's what the
 * published Privacy Policy tells users happens to their footage, and
 * unbounded video in Cloud Storage is the one cost line in this project
 * that grows forever rather than with usage.
 *
 * Seven days is deliberately longer than the 24-hour vote window, leaving
 * room for a report to be filed and reviewed against the footage before
 * it disappears.
 */

const RETENTION_DAYS = 7;
const RETENTION_MS = RETENTION_DAYS * 24 * 60 * 60 * 1000;

/** Recordings under this prefix belong to a match and are covered by the
 * retention window. Published highlights are copied elsewhere, so they're
 * never reachable by this sweep. */
const RECORDING_PREFIX = "match_recordings";

/** Rendered clips. Swept on the same schedule and by the same rule as raw
 * footage: a render that was never published is just as much a copy of two
 * people's faces as the source it came from, and leaving it indefinitely
 * would quietly outlive the retention window the Privacy Policy promises.
 * Published highlights are exempt, exactly as they are for raw footage. */
const HIGHLIGHT_PREFIX = "match_highlights";

/** The Main Stage JUDGES' debate recording. Raw footage of real people that is
 * never published as a clip on its own, so it is ALWAYS purged once expired -
 * there is no published-highlight exemption for it, unlike the battle footage. */
const DEBATE_PREFIX = "debate_recordings";

/**
 * Decides what to do with one match's recording. Pure, and separated from
 * the sweep so it can be tested directly - this is the code that
 * irreversibly deletes footage of real people, and the difference between
 * "purge" and "keep" is a promise made in the Privacy Policy.
 *
 * Returns "purge", "keep" (published highlight, retained deliberately) or
 * "skip" (nothing to do).
 */
function purgeDecision(matchData) {
  const recording = matchData?.recording;
  const highlight = matchData?.highlight;
  // Nothing was ever captured or rendered for this match.
  if (!recording && !highlight) return "skip";
  // Already swept, and no render appeared afterwards.
  if (recording?.purged && !highlight) return "skip";
  // An already-published highlight is retained on purpose - CLAUDE.md's
  // CCPA position is that a clip already public isn't retroactively
  // unpublished, so the sweep must not delete it either. Publication is
  // recorded on the highlight once one has been rendered, and on the
  // recording before that, so both are checked.
  if (highlight?.published === true || recording?.published === true) return "keep";
  return "purge";
}

/**
 * Deletes raw footage for matches older than the retention window.
 *
 * A match is skipped if its recording was published as a highlight - the
 * whole point of the policy is that posted clips survive and unposted raw
 * footage does not.
 *
 * Deletion is by storage prefix rather than by the stored file list,
 * because a recording that failed to stop cleanly can leave files behind
 * that were never recorded on the document. Sweeping the prefix catches
 * those too, which is exactly the case where footage would otherwise
 * linger indefinitely past its retention promise.
 */
async function purgeExpiredRecordings({now = Date.now(), dryRun = false} = {}) {
  const db = getFirestore();
  const cutoff = new Date(now - RETENTION_MS);

  const snap = await db
      .collection("matches")
      .where("createdAt", "<=", cutoff)
      .get();

  const bucket = getStorage().bucket();
  let purged = 0;
  let kept = 0;
  let skipped = 0;
  let debatePurged = 0;

  for (const doc of snap.docs) {
    const data = doc.data();

    // The judges' DEBATE raw footage is never published as a clip, so it is
    // ALWAYS deleted once expired - independent of whether the BATTLE highlight
    // was published and kept below. Marked purged so later sweeps skip it.
    if (data.debateRecording && !data.debateRecording.purged) {
      if (!dryRun) {
        await bucket.deleteFiles(
            {prefix: `${DEBATE_PREFIX}/${doc.id}/`, force: true});
        await doc.ref.set({
          debateRecording: {
            purged: true,
            purgedAt: FieldValue.serverTimestamp(),
            files: FieldValue.delete(),
          },
        }, {merge: true});
      }
      debatePurged++;
    }

    const decision = purgeDecision(data);
    if (decision === "skip") {
      skipped++;
      continue;
    }
    if (decision === "keep") {
      kept++;
      continue;
    }

    if (!dryRun) {
      // Both the raw per-player footage and any rendered clip. A render
      // is just as much a copy of two people's faces as its source.
      await bucket.deleteFiles({prefix: `${RECORDING_PREFIX}/${doc.id}/`, force: true});
      await bucket.deleteFiles({prefix: `${HIGHLIGHT_PREFIX}/${doc.id}/`, force: true});
      await doc.ref.set({
        recording: {
          purged: true,
          purgedAt: FieldValue.serverTimestamp(),
          // Keep the review/publish history, drop the pointer to bytes
          // that no longer exist so nothing tries to serve them.
          files: FieldValue.delete(),
        },
        ...(data.highlight ? {
          highlight: {purged: true, renditions: FieldValue.delete()},
        } : {}),
      }, {merge: true});
    }
    purged++;
  }

  return {purged, kept, skipped, debatePurged,
    cutoff: cutoff.toISOString(), dryRun};
}

module.exports = {
  purgeExpiredRecordings,
  purgeDecision,
  RETENTION_DAYS,
  RETENTION_MS,
  RECORDING_PREFIX,
  HIGHLIGHT_PREFIX,
  DEBATE_PREFIX,
};
