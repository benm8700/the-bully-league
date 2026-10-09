/**
 * Main Stage acceptance / alternate resolution - the pure core.
 *
 * At the Wednesday-midnight snapshot the top 4 (finalists) and the next 4
 * (alternates) are posted and must CONFIRM by Thursday 4pm. Whoever doesn't
 * confirm (declined, no response, or chose a judge seat over playing) is
 * replaced by the highest-ranked alternate who DID confirm. The field locks at
 * 4pm so there's no 6pm scramble. See the Tournament model decision record.
 *
 * Pure and deterministic: hand it the ranked finalists, the ranked alternates,
 * and who confirmed as a PLAYER; it returns the locked field in seed order.
 * Re-seeding is implicit: confirmed finalists keep their order (they out-rank
 * everyone), then promoted alternates follow in their order - so field[0] is
 * always the highest-ranked confirmed player, i.e. the #1 who gets the callout.
 */

/**
 * Resolve the locked field.
 *   finalists  - the top seeds, in rank order (normally 4).
 *   alternates - the next seeds, in rank order (normally 4).
 *   confirmed  - uids who confirmed they'll play (array or Set).
 *   size       - target field size (defaults to finalists.length, i.e. 4).
 * Returns {field, full, needed}:
 *   field  - the locked players, in seed order (highest-ranked first).
 *   full   - whether the target size was reached.
 *   needed - how many short (caller decides to run smaller or cancel).
 */
function resolveFinalists({finalists = [], alternates = [], confirmed = [],
  size} = {}) {
  const ok = confirmed instanceof Set ? confirmed : new Set(confirmed);
  const target = typeof size === "number" ? size : finalists.length;
  const field = [];
  const seen = new Set();
  const take = (uid) => {
    if (!uid || seen.has(uid)) return;
    if (!ok.has(uid)) return; // only confirmed players
    if (field.length >= target) return;
    seen.add(uid);
    field.push(uid);
  };
  // Confirmed finalists keep their seed order; then promote confirmed
  // alternates in rank order to fill the vacated slots.
  for (const uid of finalists) take(uid);
  for (const uid of alternates) take(uid);
  return {
    field,
    full: field.length === target,
    needed: Math.max(0, target - field.length),
  };
}

module.exports = {resolveFinalists};
