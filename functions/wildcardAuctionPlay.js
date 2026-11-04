const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {HttpsError} = require("firebase-functions/v2/https");
const {qualifyingWeek} = require("./weeklyQualifier");
const {spendableBalance, spendPoints} = require("./clipGrants");
const {
  sanitiseWildcardConfig, wildcardBidEligibility, isValidBid,
  resolveWildcardAuction,
} = require("./wildcardAuction");

/**
 * The WILDCARD auction - the Firestore wiring around the pure core
 * (wildcardAuction.js). This is the "buy your way into the 4th Main Stage seat"
 * path the developer decided (2026-11-03): a fixed-fee points auction that
 * REPLACES the engagement lottery as the wildcard SELECTION, with the lottery
 * kept as the fallback inside wildCard.buildField when nobody bids.
 *
 *  - placeWildcardBid: during the qualifying week, an eligible player pays a
 *    FIXED entry fee once and leaves a sealed bid of any size (raisable). Only
 *    the winner is charged their bid, at the cutoff; losers keep all but the fee.
 *  - resolveAndChargeWildcardAuction: at the weekly cutoff (inside the snapshot
 *    sweep), the highest ELIGIBLE bidder who can still pay wins the seat and is
 *    charged their bid.
 *
 * All of it is gated behind config/tournament.enabled AND a separate
 * wildcardAuctionEnabled flag, so it deploys inert (no bids accepted, lottery
 * untouched) until BOTH are flipped - the same failsafe as the rest of the
 * tournament system. The economy NUMBERS (fee, floor, min games) are
 * placeholders in config/tournament, per the advisor-review discipline.
 */

/** Map config/tournament -> the pure auction config. The auction is live only
 * when the whole tournament is enabled AND the auction flag is on, so a
 * tournament can run with the lottery wildcard before the auction is switched
 * on. Bounds-checking and the per-field fallbacks live in the pure core. */
function readAuctionConfig(cfgData) {
  return sanitiseWildcardConfig({
    enabled: cfgData?.enabled === true &&
      cfgData?.wildcardAuctionEnabled === true,
    entryFee: cfgData?.wildcardEntryFee,
    bidFloor: cfgData?.wildcardBidFloor,
    minGames: cfgData?.wildcardMinGames,
  });
}

async function readTournamentConfigData(db) {
  try {
    return (await db.collection("config").doc("tournament").get()).data();
  } catch (e) {
    console.error("tournament config read failed:", e.message);
    return null;
  }
}

/**
 * Place or raise a sealed wildcard bid for the current qualifying week. Charges
 * the FIXED entry fee once (idempotent on the week key); the bid itself is only
 * charged if you win, at the cutoff.
 */
async function placeWildcardBid(auth, data) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const amount = Number(data?.amount);
  const db = getFirestore();
  const nowMs = Date.now();

  const cfgData = await readTournamentConfigData(db);
  const config = readAuctionConfig(cfgData);
  if (!config.enabled) {
    throw new HttpsError("failed-precondition",
        "The wildcard auction isn't open right now.");
  }

  // qualifyingWeek rolls to the next Thursday once a cutoff passes, so a bid is
  // always for the UPCOMING show - you can never bid on a week that has closed.
  const week = qualifyingWeek(nowMs);
  const weekKey = week.cutoffDayKey;

  const user = (await db.collection("users").doc(auth.uid).get()).data() ?? {};

  const elig = wildcardBidEligibility(user, config);
  if (!elig.eligible) {
    throw new HttpsError("failed-precondition", elig.message,
        {reason: elig.reason});
  }
  if (!isValidBid(amount, config)) {
    throw new HttpsError("invalid-argument",
        `Your bid must be at least ${config.bidFloor} points.`,
        {reason: "below-floor"});
  }
  const balance = spendableBalance(user);
  if (balance < amount) {
    throw new HttpsError("failed-precondition",
        `You need ${amount} points to back that bid - you have ${balance}.`,
        {reason: "insufficient-for-bid"});
  }

  // Charge the fixed entry fee ONCE - idempotent on the week key, so raising
  // your bid never charges it again. Non-refundable: it is the buy-in.
  let feeCharged = false;
  if (config.entryFee > 0) {
    const spend = await spendPoints(auth.uid, {
      reason: "wildcardFee", sourceId: weekKey, amount: config.entryFee,
    });
    if (spend.spent === 0 && spend.reason === "insufficient") {
      throw new HttpsError("failed-precondition",
          `You need ${config.entryFee} points for the entry fee - ` +
          `you have ${spend.balance}.`, {reason: "insufficient-for-fee"});
    }
    feeCharged = spend.spent > 0;
  }

  // Record the sealed bid. enteredAtMs is NOW on every write, so the tie-break
  // ("committed this amount first") reflects when the CURRENT amount was set.
  await db.collection("wildcardBids").doc(weekKey)
      .collection("bids").doc(auth.uid).set({
        uid: auth.uid, amount, enteredAtMs: nowMs, weekKey,
        updatedAt: FieldValue.serverTimestamp(),
      }, {merge: true});

  return {ok: true, amount, weekKey, feeCharged, entryFee: config.entryFee,
    bidFloor: config.bidFloor};
}

/** The caller's current auction state, for the bid UI. */
async function getWildcardAuctionState(auth) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const db = getFirestore();
  const nowMs = Date.now();
  const cfgData = await readTournamentConfigData(db);
  const config = readAuctionConfig(cfgData);
  const week = qualifyingWeek(nowMs);
  const weekKey = week.cutoffDayKey;

  if (!config.enabled) {
    return {enabled: false, weekKey, cutoffMs: week.cutoffMs};
  }
  const [userSnap, bidSnap] = await Promise.all([
    db.collection("users").doc(auth.uid).get(),
    db.collection("wildcardBids").doc(weekKey).collection("bids")
        .doc(auth.uid).get(),
  ]);
  const user = userSnap.data() ?? {};
  const elig = wildcardBidEligibility(user, config);
  const bid = bidSnap.exists ? bidSnap.data() : null;
  return {
    enabled: true,
    weekKey,
    cutoffMs: week.cutoffMs,
    entryFee: config.entryFee,
    bidFloor: config.bidFloor,
    eligible: elig.eligible,
    reason: elig.reason,
    message: elig.message || null,
    balance: spendableBalance(user),
    yourBid: bid ? bid.amount : null,
  };
}

/**
 * Resolve the wildcard auction for a CLOSED week and charge the winner. Called
 * from the snapshot sweep at the cutoff. Returns {auctionWinnerUid, winningBid};
 * a null winner means no eligible, payable bid - buildField then falls back to
 * the lottery.
 *
 *   standings - the week's qualified players [{uid,...}] (the 5-distinct-
 *               opponent floor already applied), so an eligible bidder is one
 *               in standings...
 *   skillUids - ...but NOT a top-3 skill seat.
 *
 * IDEMPOTENT: the resolved winner is stored on the parent wildcardBids/{week}
 * doc BEFORE charging. A re-run (snapshot write failed after the charge) reuses
 * the stored winner rather than re-resolving - which would otherwise see the
 * now-charged winner as "insolvent" and crown someone else. spendPoints is
 * itself idempotent on its ledger key, so the charge never doubles.
 */
async function resolveAndChargeWildcardAuction(
    db, weekKey, standings, skillUids, cfgData) {
  const config = readAuctionConfig(cfgData);
  if (!config.enabled) return {auctionWinnerUid: null, winningBid: 0};

  const parentRef = db.collection("wildcardBids").doc(weekKey);
  const parent = (await parentRef.get()).data();
  if (parent && parent.resolved === true) {
    // Already resolved in a prior run; re-attempt the charge (idempotent) in
    // case that run died between storing the winner and charging.
    if (parent.resolvedWinner && parent.resolvedBid > 0) {
      await spendPoints(parent.resolvedWinner, {
        reason: "wildcardBid", sourceId: weekKey, amount: parent.resolvedBid,
      }).catch((e) => console.error("wildcard re-charge:", e.message));
    }
    return {auctionWinnerUid: parent.resolvedWinner || null,
      winningBid: parent.resolvedBid || 0};
  }

  const standingsSet = new Set((standings || []).map((s) => s.uid));
  const bidsSnap = await parentRef.collection("bids").get();
  const eligibleBids = [];
  const uids = [];
  bidsSnap.forEach((d) => {
    const b = d.data();
    // Eligible = qualified that week AND not a top-3 skill seat. The bid-time
    // gate already checked active/intro/photo/min-games; qualifying can only be
    // known now, at the cutoff.
    if (!standingsSet.has(b.uid)) return;
    if (skillUids.has(b.uid)) return;
    eligibleBids.push({uid: b.uid, amount: b.amount, enteredAtMs: b.enteredAtMs});
    uids.push(b.uid);
  });

  // Current spendable balances, so a bidder who spent their points elsewhere
  // since bidding is skipped rather than crowned and unable to pay.
  const balanceOf = {};
  await Promise.all(uids.map(async (uid) => {
    const u = (await db.collection("users").doc(uid).get()).data() ?? {};
    balanceOf[uid] = spendableBalance(u);
  }));

  const {winnerUid, winningBid} =
    resolveWildcardAuction(eligibleBids, {balanceOf, config});

  // Store the resolution BEFORE charging - the idempotency anchor.
  await parentRef.set({
    resolved: true,
    resolvedWinner: winnerUid || null,
    resolvedBid: winningBid || 0,
    resolvedAt: FieldValue.serverTimestamp(),
  }, {merge: true});

  if (winnerUid && winningBid > 0) {
    const spend = await spendPoints(winnerUid, {
      reason: "wildcardBid", sourceId: weekKey, amount: winningBid,
    });
    // A race past the balance filter: the winner can't actually pay. Drop them
    // and let the lottery fallback in buildField fill the seat.
    if (spend.spent === 0 && spend.reason === "insufficient") {
      await parentRef.set({resolvedWinner: null, resolvedBid: 0,
        chargeFailed: winnerUid}, {merge: true});
      return {auctionWinnerUid: null, winningBid: 0};
    }
  }
  return {auctionWinnerUid: winnerUid || null, winningBid: winningBid || 0};
}

module.exports = {
  readAuctionConfig,
  placeWildcardBid,
  getWildcardAuctionState,
  resolveAndChargeWildcardAuction,
};
