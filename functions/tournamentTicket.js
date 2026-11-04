const {getFirestore} = require("firebase-admin/firestore");
const {HttpsError} = require("firebase-functions/v2/https");
const {qualifyingWeek} = require("./weeklyQualifier");
const {spendPoints, spendableBalance} = require("./clipGrants");
const {isSubscriber, isInTrial, readMonetizationConfig} =
  require("./entitlement");

/**
 * THE TRY-OUT TICKET - the weekly ENTRY PASS into the Main Stage.
 *
 * The developer's framing (2026-11-04): "if you want to be in the tournament
 * you've got to buy a ticket. You can still compete in regular ranked play,
 * you're just not going to get picked up without a ticket - and you've got to
 * get it by the deadline." So the ticket is a weekly entry fee, paid in points
 * (a few days of play affords it), and holding one is the SIGNAL that you
 * actually mean to compete this period. It is "buy into the QUALIFYING, never
 * onto the FINALS" from the locked economy model: among ticket-holders, pure
 * skill (weekly Elo gain) still picks the top-4 - the ticket buys you a spot in
 * the race, not a spot on the stage.
 *
 * WHERE THE GATE BITES: at the CUTOFF SNAPSHOT only, never the live board. You
 * keep playing ranked and keep appearing on the running standings as normal -
 * you simply are not drawn into the frozen field (skill seats, alternates, the
 * lottery wildcard) unless you hold a ticket for that period. Gating the live
 * board instead would make it look empty early in the week (nobody's bought in
 * yet), which is the exact cold-start "dead app" look this project fights
 * everywhere else. The Home ticket banner is what nudges a strong non-ticketed
 * player to buy before the deadline.
 *
 * THE WILDCARD BYPASSES THIS. The 4th seat is its own paid path (the wildcard
 * auction's entry fee IS that player's ticket), so the auction resolver still
 * sees the UNFILTERED standings - requiring a wildcard bidder to ALSO hold a
 * try-out ticket would double-charge for the same thing (getting in).
 *
 * MEMBERS (subscriber OR in trial) claim it FREE - "the subscription skips the
 * grind." They still CLAIM it (a free tap), because the claim is the
 * intent signal: an auto-entered subscriber who isn't actually trying this
 * week would clog the field with a no-show. Everyone in the holders collection
 * meant to be there, however they got in - which also keeps the snapshot cheap
 * (one subcollection read, no per-user subscription check at the costly stage).
 *
 * CADENCE-NEUTRAL, like the judge apply fee: the ticket keys off
 * qualifyingWeek().cutoffDayKey - the single "current qualifying period"
 * definition the standings snapshot and the applicant collection also use. One
 * ticket per period, whatever the cadence (weekly now, maybe monthly later),
 * with no change here. "week" in names/ids is cosmetic. The DEADLINE is that
 * cutoff: once it passes, qualifyingWeek(now) rolls to the next period, so
 * buying "now" buys the NEXT period's ticket - a closed week can never be
 * bought into retroactively, and the snapshot for the closed week reads that
 * week's holders only.
 *
 * Gated on config/tournament.enabled AND tryoutTicketEnabled, both off by
 * default. With the tournament live but ticketing OFF, eligibility stays OPEN
 * (today's behaviour) - a graceful launch ramp (run the tournament first with
 * open eligibility, add the ticket gate later). Price is a placeholder in
 * config/tournament, per the advisor-review record.
 */

const TICKET_PRICE_DEFAULT = 200; // ~a few days of play; placeholder

/** The ticket gate: BOTH the tournament master switch and the ticket
 * sub-switch must be literally true. Anything missing/garbled reads as OFF
 * (eligibility stays open), never fail-open into a surprise paywall. */
function resolveTicketGate(cfg) {
  return !!(cfg && cfg.enabled === true && cfg.tryoutTicketEnabled === true);
}

/** The points entry price, bounds-checked from config/tournament. */
function resolveTicketPrice(cfg) {
  const n = Number(cfg && cfg.tryoutTicketPrice);
  if (Number.isFinite(n) && n >= 1 && n <= 1_000_000) return Math.floor(n);
  return TICKET_PRICE_DEFAULT;
}

/**
 * Filter a standings array to the ticket-holders, when the gate is on. Pure,
 * so the snapshot's eligibility rule can be tested without Firestore.
 *
 * - gate OFF  -> standings unchanged (open eligibility, today's behaviour).
 * - gate ON   -> only uids in `holderUids` survive, order preserved.
 */
function eligibleStandings(standings, holderUids, gate) {
  if (!gate) return standings || [];
  const held = new Set(holderUids || []);
  return (standings || []).filter((s) => s && held.has(s.uid));
}

/** All ticket-holder uids for a period (the field that may be picked up). */
async function collectTicketHolders(db, weekKey) {
  const snap = await db.collection("tournamentTickets").doc(weekKey)
      .collection("holders").get();
  const uids = [];
  snap.forEach((d) => uids.push(d.id));
  return uids;
}

/**
 * Secure THIS period's try-out ticket. The period is resolved from the clock
 * here, so the client only asks to buy - it can't buy into some other week.
 *
 * Idempotent: an existing holder doc short-circuits (no second charge), and
 * spendPoints itself is idempotent on its ledger key, so a mid-call retry
 * can't double-charge even if the holder write failed after the spend.
 */
async function secureTournamentTicket(auth) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const db = getFirestore();
  const nowMs = Date.now();

  const [userSnap, cfgSnap, monetCfg] = await Promise.all([
    db.collection("users").doc(auth.uid).get(),
    db.collection("config").doc("tournament").get(),
    readMonetizationConfig(db),
  ]);
  const user = userSnap.data() || {};
  if ((user.accountStatus || "active") !== "active") {
    throw new HttpsError("permission-denied", "This account can't enter.");
  }
  const cfg = cfgSnap.data();
  if (!resolveTicketGate(cfg)) {
    // Defensive - the client self-gates on getTournamentTicketState, so this
    // should never be reached in normal use.
    throw new HttpsError("failed-precondition",
        "Tournament tickets aren't on right now.");
  }

  const weekKey = qualifyingWeek(nowMs).cutoffDayKey;
  const ref = db.collection("tournamentTickets").doc(weekKey)
      .collection("holders").doc(auth.uid);
  if ((await ref.get()).exists) {
    return {ok: true, held: true, alreadyHeld: true, weekKey};
  }

  const member = isSubscriber(user, nowMs) ||
    isInTrial(user, nowMs, monetCfg.trialDays);
  const price = member ? 0 : resolveTicketPrice(cfg);

  let charged = false;
  if (price > 0) {
    const spend = await spendPoints(auth.uid, {
      reason: "tournamentTicket", sourceId: weekKey, amount: price,
    });
    if (spend.spent === 0 && spend.reason === "insufficient") {
      throw new HttpsError("failed-precondition",
          `A tournament ticket costs ${price} points - ` +
          `you have ${spend.balance}.`,
          {reason: "insufficient", price, balance: spend.balance});
    }
    charged = spend.spent > 0; // false on a duplicate (already paid this period)
  }
  await ref.set({
    uid: auth.uid, at: nowMs, member,
    ...(charged ? {paidAt: nowMs, paid: price} : {}),
  }, {merge: true});
  return {ok: true, held: true, weekKey, price, charged, member};
}

/**
 * This player's ticket state, for the Home nudge banner. Fails nowhere - it's
 * read-only - but the client treats a thrown/absent result as "hide the
 * banner" (a broken fetch must never look like a locked tournament).
 */
async function getTournamentTicketState(auth) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const db = getFirestore();
  const nowMs = Date.now();

  const [userSnap, cfgSnap, monetCfg] = await Promise.all([
    db.collection("users").doc(auth.uid).get(),
    db.collection("config").doc("tournament").get(),
    readMonetizationConfig(db),
  ]);
  const user = userSnap.data() || {};
  const cfg = cfgSnap.data();
  const enabled = resolveTicketGate(cfg);
  const week = qualifyingWeek(nowMs);
  const weekKey = week.cutoffDayKey;

  let held = false;
  if (enabled) {
    held = (await db.collection("tournamentTickets").doc(weekKey)
        .collection("holders").doc(auth.uid).get()).exists;
  }
  const member = isSubscriber(user, nowMs) ||
    isInTrial(user, nowMs, monetCfg.trialDays);
  return {
    enabled,
    held,
    member,
    price: member ? 0 : resolveTicketPrice(cfg),
    balance: spendableBalance(user),
    weekKey,
    cutoffMs: week.cutoffMs,
  };
}

module.exports = {
  secureTournamentTicket,
  getTournamentTicketState,
  collectTicketHolders,
  // Pure, exported for the sweep + tests.
  resolveTicketGate,
  resolveTicketPrice,
  eligibleStandings,
  TICKET_PRICE_DEFAULT,
};
