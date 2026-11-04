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
 *   handPicked   - uids the founder chose, IN PRIORITY ORDER (head-judge first,
 *                  then guests/celebrities). Applied before everything.
 *   paidSeats    - uids who BOUGHT a seat, in purchase order (first-come). Seated
 *                  after the hand-picks and before the autofill pool, but only up
 *                  to paidSeatCap AND never more than a minority of the panel
 *                  (floor((panelSize-1)/2)) - bought voices can't outnumber the
 *                  earned/hand-picked ones. A paid buyer who is a finalist or
 *                  banned (in `blocked`) is skipped here; the wiring refunds them.
 *   paidSeatCap  - how many paid seats are on sale (config); the minority bound
 *                  is applied on top, so the effective cap is the smaller.
 *   rankedPool   - the most-judged-this-week pool, already ordered desc.
 *   finalists    - the players in the bracket; never eligible to judge.
 *   exclude      - banned/flagged/ineligible uids to keep off the panel.
 *   panelSize    - default 5.
 * Returns {judges, shortfall, standby}. `shortfall` > 0 means not enough
 * eligible judges were available - the caller falls back to crowd voting rather
 * than leaving a result unjudged, never cancels.
 */
function selectPanel({
  handPicked = [],
  paidSeats = [],
  paidSeatCap = 0,
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
  // celebrity guest are locked before anything else).
  for (const uid of handPicked) add(uid);

  // Then the BOUGHT seats, capped to a minority of the panel. floor((5-1)/2)=2,
  // so at most 2 paid voices on a 5-seat panel however the config is set.
  const paidCeiling = Math.min(
      Math.max(0, paidSeatCap), Math.max(0, Math.floor((panelSize - 1) / 2)));
  let paidSeated = 0;
  for (const uid of paidSeats) {
    if (paidSeated >= paidCeiling) break;
    if (!uid || typeof uid !== "string") continue;
    if (seen.has(uid) || blocked.has(uid)) continue; // finalist/banned -> refund
    seen.add(uid);
    judges.push(uid);
    paidSeated++;
  }

  // Then the most-judged pool fills whatever seats remain.
  for (const uid of rankedPool) add(uid);

  // Standby: eligible pool judges NOT seated (beyond panelSize or because the
  // panel filled first). These backfill a judge who confirmed at the 4pm lock
  // but still no-shows at the live stage, so the panel keeps its 5 live votes
  // without anyone being hand-managed. Hand-picks are deliberately NOT standby:
  // a dropped hand-pick is someone who declined, not a fallback.
  const standby = [];
  for (const uid of rankedPool) {
    if (typeof uid !== "string" || !uid) continue;
    if (seen.has(uid) || blocked.has(uid)) continue;
    if (standby.includes(uid)) continue;
    standby.push(uid);
  }

  return {judges, shortfall: Math.max(0, panelSize - judges.length), standby};
}

module.exports = {selectPanel, DEFAULT_PANEL_SIZE};
