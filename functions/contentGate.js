/**
 * Whether a match is blocked from producing, delivering, or publishing a clip
 * because it was disqualified / flagged for inappropriate content (nudity,
 * explicit acts).
 *
 * This is the gate the live in-match visual moderation DOESN'T give us on its
 * own: the live detector samples a frame only every few seconds and can miss a
 * brief flash, and once a match is flagged (live, by a human report, or by a
 * post-hoc pass) its clip must never render, reach the owner's download, or go
 * public. Checked in autoRender (never render a flagged match), resolveClipGrant
 * (refuse the request), getClipDownload (refuse delivery), and publishHighlight
 * (refuse public posting).
 */
function isContentBlocked(match) {
  if (!match) return false;
  if (match.status === "disqualified") return true;
  if (match.disqualifyReason === "inappropriate-content") return true;
  if (match.contentViolation) return true;
  if (match.highlight && match.highlight.destroyedForContent === true) return true;
  return false;
}

module.exports = {isContentBlocked};
