/**
 * The WILDCARD auction - the pure core.
 *
 * One extra Main Stage seat, on top of the SKILL qualifiers, won not by
 * rating but by a fixed-fee points AUCTION (see the Economy Model in
 * CLAUDE.md). The decided bracket shape (2026-11-03) is WILDCARD = 4th SEED:
 * the top THREE qualify by weekly Elo, and the auction winner takes the 4th
 * finalist slot. The seat buys a SHOT, never a WIN - the wildcard still has to
 * out-roast the real qualifiers live.
 *
 * WHY IT IS CLEAN (and not the pay-for-odds raffle that was rejected):
 *  - DETERMINISTIC: the highest bid wins, no chance - an auction, not a
 *    lottery. Ties break by who committed that amount FIRST, then uid, so the
 *    outcome is never arbitrary and never random.
 *  - A single FIXED entry fee to bid (everyone who bids pays it, once), then a
 *    sealed bid of any size; only the winner pays their bid. That is a buy-in
 *    auction, never an escalating "penny auction" (the pattern that drew real
 *    FTC heat), because the fee is one disclosed number, not per-bid.
 *
 * This module is PURE - no Firestore, no clock, no charging - so the winner
 * selection and the eligibility gate can be exercised with plain `node`, the
 * discipline that has repeatedly caught silent bugs here before a device. The
 * Firestore wiring (charge the fee on bid, charge the winner at close, inject
 * the winner as the 4th finalist) lives elsewhere and builds on this.
 *
 * Economy NUMBERS here (the entry fee, the bid floor, min games) are
 * PLACEHOLDERS, kept in config/tournament, per the advisor-review discipline -
 * see the economy-needs-advisor-review memory. The MECHANISM is decided.
 */

/**
 * Placeholder economy numbers. Live-tunable via config/tournament so they can
 * move without a release; these are the fallbacks and the bounds.
 *
 *   enabled    - the wildcard is off until the whole tournament system is.
 *   entryFee   - fixed points cost to place/keep a bid (charged once, on the
 *                first bid; non-refundable - it is the buy-in).
 *   bidFloor   - the smallest legal bid, so a 1-point "bid" can't squat the
 *                seat; also the minimum meaningful stake above the fee.
 *   minGames   - ranked matches played before you may bid, mirroring the
 *                qualifier's own floor so a brand-new account can't buy in.
 */
const WILDCARD_DEFAULTS = {
  enabled: false,
  entryFee: 100,
  bidFloor: 50,
  minGames: 5,
};

const WILDCARD_LIMITS = {
  entryFee: {min: 0, max: 1_000_000},
  bidFloor: {min: 1, max: 1_000_000},
  minGames: {min: 0, max: 1000},
};

const DENY = {
  disabled: "wildcard-disabled",
  notActive: "account-not-active",
  noIntro: "intro-required",
  noPhoto: "photo-required",
  tooFewGames: "too-few-games",
};

/** Bounds-check one config field, falling back per-field to the default - a
 * single bad hand-edited value in the console never discards the rest. */
function sanitiseWildcardConfig(raw) {
  const out = {...WILDCARD_DEFAULTS};
  if (!raw || typeof raw !== "object") return out;
  out.enabled = raw.enabled === true;
  for (const key of ["entryFee", "bidFloor", "minGames"]) {
    const v = Number(raw[key]);
    const {min, max} = WILDCARD_LIMITS[key];
    if (Number.isFinite(v) && v >= min && v <= max) out[key] = v;
  }
  return out;
}

/** Ranked matches this account has played, tolerating the two field names and
 * a missing value (a legacy account reads as 0, which only means it can't bid
 * until it plays - the safe direction). */
function rankedGamesOf(user) {
  const a = Number(user?.careerRankedMatches);
  if (Number.isFinite(a)) return Math.max(0, a);
  const b = Number(user?.rankedMatchesPlayed);
  return Number.isFinite(b) ? Math.max(0, b) : 0;
}

/**
 * May this account place a wildcard bid? Mirrors enterQueue's real-battle gate
 * (active, approved intro video AND face selfie) plus a min-games floor, so the
 * wildcard can't be a way onto the stage that skips the requirements every
 * other finalist met. PURE.
 *
 * An ABSENT accountStatus counts as active - every pre-ban account lacks the
 * field, and reading absence as "not active" would lock them all out (the
 * missing-field trap this project has hit repeatedly). Only an explicit
 * non-active value blocks.
 */
function wildcardBidEligibility(user, config = WILDCARD_DEFAULTS) {
  if (config.enabled !== true) {
    return {eligible: false, reason: DENY.disabled,
      message: "The wildcard isn't open right now."};
  }
  const status = user?.accountStatus ?? "active";
  if (status !== "active") {
    return {eligible: false, reason: DENY.notActive,
      message: "This account can't enter the wildcard."};
  }
  const intro = user?.profile?.introVideoUrl;
  if (typeof intro !== "string" || intro.length === 0) {
    return {eligible: false, reason: DENY.noIntro,
      message: "Record your intro video before bidding on the wildcard."};
  }
  const photo = user?.profile?.facePhotoUrl;
  if (typeof photo !== "string" || photo.length === 0) {
    return {eligible: false, reason: DENY.noPhoto,
      message: "Add your profile photo before bidding on the wildcard."};
  }
  if (rankedGamesOf(user) < config.minGames) {
    return {eligible: false, reason: DENY.tooFewGames,
      message: `Play ${config.minGames} ranked battles before bidding.`};
  }
  return {eligible: true, reason: null};
}

/** Whether a single bid is well-formed and clears the floor. PURE. */
function isValidBid(amount, config = WILDCARD_DEFAULTS) {
  const n = Number(amount);
  return Number.isFinite(n) && n >= config.bidFloor;
}

/**
 * Pick the winning bid. PURE and deterministic.
 *
 *   bids       - [{uid, amount, enteredAtMs}], one per bidder (the wiring
 *                keeps a single sealed bid per uid; a duplicate uid keeps the
 *                higher, then earlier).
 *   balanceOf  - optional {uid: spendableBalance}. When given, a bidder whose
 *                CURRENT balance no longer covers their bid is skipped and the
 *                seat falls to the next highest who can pay - because between
 *                bidding and close they may have spent those points elsewhere,
 *                and a winner who can't pay their bid isn't a winner.
 *   config     - for the bid floor.
 *
 * Returns {winnerUid, winningBid, ranked, skippedInsolvent}. No payable bid ->
 * {winnerUid: null} (the seat simply goes unsold; the field stays top-3 + an
 * empty 4th, which the assembly handles).
 *
 * Tie-break: higher amount, then EARLIER enteredAtMs (committing that amount
 * first wins - decisive, and deterministic), then uid.
 */
function resolveWildcardAuction(bids, {balanceOf = null, config = WILDCARD_DEFAULTS} = {}) {
  // Collapse to one bid per uid (highest, then earliest), tolerating a
  // malformed array defensively.
  const byUid = new Map();
  for (const b of bids || []) {
    if (!b || typeof b.uid !== "string" || !b.uid) continue;
    if (!isValidBid(b.amount, config)) continue;
    const amount = Number(b.amount);
    const enteredAtMs = Number.isFinite(Number(b.enteredAtMs)) ?
      Number(b.enteredAtMs) : Infinity;
    const cur = byUid.get(b.uid);
    if (!cur || amount > cur.amount ||
        (amount === cur.amount && enteredAtMs < cur.enteredAtMs)) {
      byUid.set(b.uid, {uid: b.uid, amount, enteredAtMs});
    }
  }

  const ranked = [...byUid.values()].sort((a, b) =>
    b.amount - a.amount ||
    a.enteredAtMs - b.enteredAtMs ||
    (a.uid < b.uid ? -1 : a.uid > b.uid ? 1 : 0));

  let winner = null;
  let skippedInsolvent = 0;
  for (const bid of ranked) {
    if (balanceOf) {
      const bal = Number(balanceOf[bid.uid]);
      // No balance known for a bidder is treated as solvent here: the wiring
      // validated affordability at bid time, and the charge itself is the
      // real gate - this skip only drops someone PROVABLY short now.
      if (Number.isFinite(bal) && bal < bid.amount) {
        skippedInsolvent++;
        continue;
      }
    }
    winner = bid;
    break;
  }

  return {
    winnerUid: winner ? winner.uid : null,
    winningBid: winner ? winner.amount : 0,
    ranked,
    skippedInsolvent,
  };
}

module.exports = {
  WILDCARD_DEFAULTS,
  WILDCARD_LIMITS,
  DENY,
  sanitiseWildcardConfig,
  rankedGamesOf,
  wildcardBidEligibility,
  isValidBid,
  resolveWildcardAuction,
};
