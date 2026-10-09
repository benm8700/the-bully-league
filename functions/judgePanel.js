/**
 * Main Stage judge panel selection - the pure core.
 *
 * The 5-seat panel (see the Tournament model decision record in CLAUDE.md) is
 * NOT a lottery: the founder HAND-PICKS any seats (the permanent head-judge
 * seat, friends, celebrity guests), and the remaining seats AUTOFILL from the
 * "most-judged-that-week" pool. A finalist can never judge (you can't judge a
 * tournament you're competing in), and banned/flagged/nuisance accounts are
 * excluded.
 *
 * Pure and deterministic: hand it the hand-picks, the ranked judge pool, who
 * the finalists are, and who's blocked, and it returns the panel. The data
 * (who judged most this week, who's eligible) is gathered elsewhere.
 */

const DEFAULT_PANEL_SIZE = 5;

/**
 * Build the panel.
 *   handPicked  - uids the founder chose, IN PRIORITY ORDER (head-judge first,
 *                 then guests/celebrities). Applied before the autofill.
 *   rankedPool  - the most-judged-this-week pool, already ordered desc.
 *   finalists   - the players in the bracket; never eligible to judge.
 *   exclude     - banned/flagged/ineligible uids to keep off the panel.
 *   panelSize   - default 5.
 * Returns {judges, shortfall}. `shortfall` > 0 means not enough eligible
 * judges were available - the caller falls back to crowd voting rather than
 * leaving a result unjudged, never cancels.
 */
function selectPanel({
  handPicked = [],
  rankedPool = [],
  finalists = [],
  exclude = [],
  panelSize = DEFAULT_PANEL_SIZE,
} = {}) {
  const blocked = new Set([...finalists, ...exclude]);
  const seen = new Set();
  const judges = [];
  const add = (uid) => {
    if (!uid || typeof uid !== "string") return;
    if (seen.has(uid) || blocked.has(uid)) return;
    if (judges.length >= panelSize) return;
    seen.add(uid);
    judges.push(uid);
  };
  // Hand-picks first, in the founder's order (so the head-judge seat and any
  // celebrity guest are locked before the autofill), then the most-judged pool.
  for (const uid of handPicked) add(uid);
  for (const uid of rankedPool) add(uid);
  return {judges, shortfall: Math.max(0, panelSize - judges.length)};
}

module.exports = {selectPanel, DEFAULT_PANEL_SIZE};
