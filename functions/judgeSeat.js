/**
 * The PAID JUDGE-PANEL SEAT - the pure core.
 *
 * A Main Stage panel has 5 seats (see the Tournament model record in CLAUDE.md).
 * The founder HAND-PICKS seats (the head-judge seat, celebrity guests), and the
 * rest AUTOFILL from the most-judged-that-week pool. The locked economy model
 * (2026-11-03) adds a third route: a player may BUY a seat for a FIXED points
 * price. Decided shape, and every clause here is a guardrail from that model:
 *
 *  - FIXED PRICE, not an auction. The wildcard is the auction (one scarce seat,
 *    highest bid); a panel seat is a plain ticket - buy it, it's yours, and once
 *    the paid seats sell out no more are sold (first-come). NEVER pay-for-odds.
 *  - BOUGHT SEATS STAY A MINORITY of the panel. At most `floor((panelSize-1)/2)`
 *    are ever seated (2 of 5), so paid voices can never outnumber the earned +
 *    hand-picked ones. The config count is additionally capped there.
 *  - FOUNDER / CELEBRITY SEATS ARE RESERVED. Hand-picks are seated FIRST; paid
 *    seats take priority only over the most-judged autofill pool.
 *  - BUYERS MUST BE ACTIVE JUDGES. Eligibility mirrors the spirit of the pool
 *    (you have actually judged) via a min lifetime-votes floor, plus active and
 *    not banned - so a seat can't be a way onto the panel that skips judging.
 *  - CONFLICT OF INTEREST KEPT. A finalist can never judge a tournament they
 *    compete in. The purchase can't know the finalists yet (standings freeze at
 *    the week's cutoff), so a buyer who then qualifies is DROPPED at the lock
 *    (selectPanel blocks finalists) and REFUNDED by the wiring. Pure here;
 *    the refund is in judgeSeatPlay.js.
 *
 * PURE - no Firestore, no clock, no charging - so the eligibility gate and the
 * minority math are exercised with plain `node`, the discipline that has caught
 * silent bugs here before a device. Economy NUMBERS (price, seat count, the vote
 * floor) are PLACEHOLDERS in config/tournament, per the advisor-review record.
 */

const JUDGE_SEAT_DEFAULTS = {
  enabled: false,
  price: 500, // points for one seat
  seats: 2, // how many seats are buyable (the minority cap)
  minVotes: 10, // lifetime battles judged before you may buy
};

const JUDGE_SEAT_LIMITS = {
  price: {min: 1, max: 1_000_000},
  // Hard-capped at 2: with a 5-seat panel that is the largest count that stays
  // a minority. selectPanel enforces the real minority bound too, so this is
  // belt-and-braces against a hand-edited config.
  seats: {min: 0, max: 2},
  minVotes: {min: 0, max: 1_000_000},
};

const DENY = {
  disabled: "seats-disabled",
  notActive: "account-not-active",
  tooFewVotes: "too-few-votes",
  soldOut: "sold-out",
  alreadyHolds: "already-holds-seat",
};

/** Bounds-check one config field, falling back per-field to the default so a
 * single bad hand-edited value never discards the rest. */
function sanitiseJudgeSeatConfig(raw) {
  const out = {...JUDGE_SEAT_DEFAULTS};
  if (!raw || typeof raw !== "object") return out;
  out.enabled = raw.enabled === true;
  for (const key of ["price", "seats", "minVotes"]) {
    const v = Number(raw[key]);
    const {min, max} = JUDGE_SEAT_LIMITS[key];
    if (Number.isFinite(v) && v >= min && v <= max) out[key] = v;
  }
  return out;
}

/** Lifetime battles judged, tolerating a missing field (a legacy account reads
 * as 0, which only means it can't buy until it judges - the safe direction). */
function votesCastOf(user) {
  const v = Number(user?.votesCast);
  return Number.isFinite(v) ? Math.max(0, v) : 0;
}

/**
 * May this account BUY a panel seat right now? PURE.
 *
 * Deliberately does NOT check whether the buyer is a finalist: standings aren't
 * frozen until the week's cutoff, so that conflict is resolved at the lock (the
 * buyer is dropped from the panel and refunded). At purchase time the gate is
 * active + not banned + has actually judged enough to be a real "active judge".
 *
 * An ABSENT accountStatus counts as active (every pre-ban account lacks the
 * field - the missing-field trap this project has hit repeatedly). Only an
 * explicit non-active value blocks.
 */
function judgeSeatEligibility(user, config = JUDGE_SEAT_DEFAULTS) {
  if (config.enabled !== true) {
    return {eligible: false, reason: DENY.disabled,
      message: "Panel seats aren't on sale right now."};
  }
  const status = user?.accountStatus ?? "active";
  if (status !== "active") {
    return {eligible: false, reason: DENY.notActive,
      message: "This account can't buy a panel seat."};
  }
  if (votesCastOf(user) < config.minVotes) {
    return {eligible: false, reason: DENY.tooFewVotes,
      message: `Judge ${config.minVotes} battles before buying a seat.`};
  }
  return {eligible: true, reason: null};
}

/** The real ceiling on bought seats: whatever config says, never more than a
 * minority of the panel. floor((panelSize-1)/2) = 2 for a 5-seat panel. */
function maxPaidSeats(config = JUDGE_SEAT_DEFAULTS, panelSize = 5) {
  const minorityCeiling = Math.max(0, Math.floor((panelSize - 1) / 2));
  return Math.min(config.seats, minorityCeiling);
}

/** Seats still for sale given how many are already bought. */
function seatsRemaining(soldCount, config = JUDGE_SEAT_DEFAULTS, panelSize = 5) {
  return Math.max(0, maxPaidSeats(config, panelSize) - (Number(soldCount) || 0));
}

module.exports = {
  JUDGE_SEAT_DEFAULTS,
  JUDGE_SEAT_LIMITS,
  DENY,
  sanitiseJudgeSeatConfig,
  votesCastOf,
  judgeSeatEligibility,
  maxPaidSeats,
  seatsRemaining,
};
