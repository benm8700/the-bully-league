/**
 * Main Stage assembly - composes the pure cores into one tournament.
 *
 * Given the frozen snapshot (ranked finalists + alternates + the most-judged
 * pool), who confirmed, the founder's hand-picked judges, and - once it
 * happens live - the #1 seed's callout, this produces the full Main Stage:
 * the locked field, the 5-judge panel, and the bracket.
 *
 * It is pure glue over tested pieces (tournamentAcceptance, judgePanel,
 * mainStageBracket), and it exists mainly so the SEAMS between them are
 * exercised in one place - interface drift between these cores is exactly the
 * class of bug that has bitten this project before.
 */
const {resolveFinalists} = require("./tournamentAcceptance");
const {selectPanel} = require("./judgePanel");
const {createBracket} = require("./mainStageBracket");

/**
 * Assemble the tournament.
 *   finalists/alternates - ranked uid arrays from the snapshot (seed order).
 *   confirmed            - who confirmed they'll play (array or Set).
 *   handPicked           - founder's judge picks, in order (head judge first).
 *   judgePool            - most-judged pool: uids or [{uid, judged}].
 *   exclude              - banned/ineligible uids to keep off the panel.
 *   pick                 - the #1's callout opponent (null until it happens).
 *   panelSize            - default 5.
 * Returns {field, full, needed, top, judges, judgeShortfall, bracket,
 * bracketError}. The bracket is null until the field is full AND the #1 has
 * called someone out (a live moment), so the panel/field can be finalised at
 * the 4pm lock while the bracket waits for the stage.
 */
function assembleMainStage({
  finalists = [],
  alternates = [],
  confirmed = [],
  handPicked = [],
  judgePool = [],
  exclude = [],
  pick = null,
  panelSize = 5,
} = {}) {
  const {field, full, needed} = resolveFinalists({
    finalists, alternates, confirmed,
  });

  const poolUids = judgePool
      .map((j) => (typeof j === "string" ? j : j && j.uid))
      .filter((u) => typeof u === "string" && u);
  // Finalists can never judge; selectPanel enforces it, so the panel is safe
  // to finalise at the 4pm lock even before the bracket exists.
  const {judges, shortfall} = selectPanel({
    handPicked, rankedPool: poolUids, finalists: field, exclude, panelSize,
  });

  let bracket = null;
  let bracketError = null;
  if (full && pick != null) {
    try {
      bracket = createBracket(field, pick);
    } catch (e) {
      bracketError = e.message; // e.g. an illegal callout
    }
  }

  return {
    field,
    full,
    needed,
    top: field[0] || null, // the #1 who makes the callout
    judges,
    judgeShortfall: shortfall,
    bracket,
    bracketError,
  };
}

module.exports = {assembleMainStage};
