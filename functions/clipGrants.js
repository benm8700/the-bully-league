const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {HttpsError} = require("firebase-functions/v2/https");
const {publishBlockedReason} = require("./takedown");
const {readMonetizationConfig, battleEntitlement} = require("./entitlement");
const {readEventWindowConfig} = require("./eventWindow");

/**
 * How a player gets the shareable version of their own battle.
 *
 * WHAT IS ACTUALLY BEING SOLD, and this corrects an earlier assumption.
 * Auto-render already gives EVERY recorded match a composited clip, and
 * that render costs about $0.003 - it exists because in-app judging needs
 * something to watch. The expensive step is transcription, roughly $0.066,
 * which is why captions are rationed to a weekly top-N.
 *
 * So the scarce, costly, genuinely valuable artifact is the CAPTIONED
 * clip - and captions are also exactly what makes a clip work on TikTok,
 * Reels and Shorts, where most viewing is muted. Selling that is honest:
 * it is the part that costs real money and the part worth posting.
 * Withholding the cheap uncaptioned render would be artificial scarcity,
 * and it would break judging.
 *
 *   Free           - every ranked match gets a clip, watchable in-app.
 *   Entitled       - the CAPTIONED, downloadable version.
 *
 * THREE WAYS TO BECOME ENTITLED, one code path:
 *   subscription - included, no charge, per CLAUDE.md's flagship perk
 *   points       - the free-tier route, and the points economy's first
 *                  real sink
 *   purchase     - pay-per-clip (not yet available; no IAP exists)
 *
 * WHY POINTS BUY THIS, of everything they could buy. CLAUDE.md records
 * that cosmetics were rejected outright - people are here for comedy,
 * status and prizes, not profile frames. A sink has to be something people
 * genuinely want AND something that costs the platform real money, or the
 * currency is monopoly money. A captioned clip of your own battle is both.
 * It is also the free-tier on-ramp to the flagship paid feature, so the
 * people grinding for it are pre-qualified subscribers.
 */

/** Points price of one captioned clip. In config, like every other
 * economy number, because CLAUDE.md is explicit that these need real
 * playtesting and an economy needing a release to tune never gets tuned. */
const DEFAULT_CLIP_POINTS_PRICE = 250;
const CLIP_PRICE_LIMITS = {min: 1, max: 100000};

const SOURCES = ["subscription", "points", "purchase"];

const DENY = {
  notParticipant: "not-participant",
  matchNotReady: "match-not-ready",
  alreadyGranted: "already-granted",
  subscriptionRequired: "subscription-required",
  insufficientPoints: "insufficient-points",
  paymentUnavailable: "payment-unavailable",
  unknownSource: "unknown-source",
};

async function readClipPointsPrice(db = getFirestore()) {
  try {
    const snap = await db.collection("config").doc("pointsSettings").get();
    const raw = Number(snap.data()?.clipPrice);
    return Number.isFinite(raw) &&
      raw >= CLIP_PRICE_LIMITS.min && raw <= CLIP_PRICE_LIMITS.max ?
      raw : DEFAULT_CLIP_POINTS_PRICE;
  } catch (e) {
    console.error("clip price read failed:", e.message);
    return DEFAULT_CLIP_POINTS_PRICE;
  }
}

/**
 * The spendable balance, tolerating accounts that predate it.
 *
 * TWO NUMBERS, DELIBERATELY. `points` is the CAREER total and only ever
 * increases - that is the progression ladder and the property points.js
 * exists to guarantee, and spending must not quietly turn it into a second
 * rating. `pointsBalance` is what is left to spend.
 *
 * An account with career points but no balance has simply never spent
 * anything, so its balance IS its career total. Reading a missing balance
 * as zero would confiscate every point earned before this feature - the
 * same missing-field trap as accountStatus and createdAt before it.
 */
function spendableBalance(user) {
  const balance = Number(user?.pointsBalance);
  if (Number.isFinite(balance)) return Math.max(0, balance);
  return Math.max(0, Number(user?.points) || 0);
}

/**
 * Whether this user may claim the captioned clip of this match, and what
 * it costs them.
 *
 * PURE, so the whole policy is testable without Firestore, ffmpeg, or
 * spending a penny on transcription.
 */
function resolveClipGrant({user, match, uid, source, price, entitlement}) {
  if (!SOURCES.includes(source)) {
    return {allowed: false, reason: DENY.unknownSource,
      message: "Unknown purchase method."};
  }
  if (!match || (match.player1Id !== uid && match.player2Id !== uid)) {
    // Participants only, and this is a safety boundary rather than a
    // pricing one: letting spectators buy clips of other people's battles
    // would mean selling video of person X to person Y, in an app where
    // somebody might fixate on a specific person.
    return {allowed: false, reason: DENY.notParticipant,
      message: "You can only get clips of your own battles."};
  }
  if (match.status !== "completed") {
    return {allowed: false, reason: DENY.matchNotReady,
      message: "That battle hasn't finished yet."};
  }
  if (match.clipGrants?.[uid]) {
    // Idempotent rather than an error: a retried tap must never charge
    // twice, and "you already have this" is the honest answer.
    return {allowed: false, reason: DENY.alreadyGranted, cost: 0,
      message: "This clip is already yours."};
  }

  if (source === "subscription") {
    // Trial users count - the trial is full access by definition.
    const included = entitlement?.state === "subscriber" ||
      entitlement?.state === "trial";
    return included ?
      {allowed: true, cost: 0, source} :
      {allowed: false, reason: DENY.subscriptionRequired,
        message: "Subscribe to get every ranked battle captioned."};
  }

  if (source === "points") {
    const balance = spendableBalance(user);
    return balance >= price ?
      {allowed: true, cost: price, source} :
      {allowed: false, reason: DENY.insufficientPoints, cost: price,
        message: `You need ${price} points - you have ${balance}.`};
  }

  // Pay-per-clip is decided but there is no IAP yet, and no Play Console
  // account to build one against. Refused explicitly rather than silently
  // treated as free.
  return {allowed: false, reason: DENY.paymentUnavailable,
    message: "Buying clips isn't available yet."};
}

/**
 * Whether a granted clip can actually be handed over yet.
 *
 * DELIVERY IS DEFERRED PAST THE OBJECTION WINDOW, by design and by the
 * developer's own decision. Buy at the end of the match, when the feeling
 * is strongest; receive once the other player's chance to object has
 * closed. Nothing revocable is ever delivered, so there is no refund
 * problem to solve - which matters because the refund support category was
 * deliberately removed, Apple and Google owning that process.
 *
 * Pure.
 */
function clipDeliverable(match, nowMs) {
  const blocked = publishBlockedReason(match, nowMs);
  if (blocked === "participant-objected") {
    return {deliverable: false, reason: "objected", refundable: true};
  }
  if (blocked === "objection-window-open") {
    return {deliverable: false, reason: "window-open", refundable: false};
  }
  if (blocked) return {deliverable: false, reason: blocked, refundable: false};
  if (match?.highlight?.captioned !== true) {
    return {deliverable: false, reason: "rendering", refundable: false};
  }
  return {deliverable: true, reason: null, refundable: false};
}

/**
 * Spends from the balance, leaving the career total untouched.
 *
 * Idempotent on `sourceId` for exactly the reason awardPoints is: this is
 * a retryable path reached by a tap that may be repeated, and a double
 * charge is far worse than a double credit.
 */
async function spendPoints(uid, {reason, sourceId, amount}) {
  const db = getFirestore();
  const userRef = db.collection("users").doc(uid);
  const entryRef = userRef.collection("pointsLedger").doc(`${reason}_${sourceId}`);

  return db.runTransaction(async (tx) => {
    const [entry, userSnap] = await Promise.all([
      tx.get(entryRef), tx.get(userRef),
    ]);
    if (entry.exists) return {spent: 0, reason: "duplicate"};
    const user = userSnap.data() ?? {};
    const balance = spendableBalance(user);
    if (balance < amount) {
      return {spent: 0, reason: "insufficient", balance};
    }
    tx.set(entryRef, {
      reason, sourceId, amount: -amount,
      createdAt: FieldValue.serverTimestamp(),
    });
    // Written absolutely, not as an increment: a legacy account whose
    // balance field does not exist yet must inherit its career total
    // rather than being incremented up from zero.
    tx.set(userRef, {pointsBalance: balance - amount}, {merge: true});
    return {spent: amount, balance: balance - amount};
  });
}

/**
 * Claim the captioned clip of one of your own battles.
 */
async function requestMatchClip(auth, data) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const {matchId, source} = data || {};
  if (!matchId) throw new HttpsError("invalid-argument", "matchId is required.");

  const db = getFirestore();
  const uid = auth.uid;
  const nowMs = Date.now();

  const [matchSnap, userSnap, price, monetization, windowConfig] =
    await Promise.all([
      db.collection("matches").doc(matchId).get(),
      db.collection("users").doc(uid).get(),
      readClipPointsPrice(db),
      readMonetizationConfig(db),
      db.collection("config").doc("eventWindow").get()
          .then((s) => readEventWindowConfig(s.data()))
          .catch(() => ({enabled: false})),
    ]);

  const match = matchSnap.exists ? matchSnap.data() : null;
  const user = userSnap.data() ?? {};
  // Reused so "is this person a subscriber" has exactly one definition.
  const entitlement = battleEntitlement({
    user, mode: "ranked", nowMs, windowConfig, config: monetization,
  });

  const verdict = resolveClipGrant({
    user, match, uid, source: source ?? "subscription", price, entitlement,
  });
  if (!verdict.allowed) {
    if (verdict.reason === DENY.alreadyGranted) {
      return {granted: true, alreadyOwned: true, cost: 0};
    }
    throw new HttpsError("failed-precondition", verdict.message,
        {reason: verdict.reason, price});
  }

  if (verdict.cost > 0) {
    const spend = await spendPoints(uid, {
      reason: "clip", sourceId: matchId, amount: verdict.cost,
    });
    if (spend.spent === 0 && spend.reason === "insufficient") {
      throw new HttpsError("failed-precondition",
          `You need ${verdict.cost} points - you have ${spend.balance}.`,
          {reason: DENY.insufficientPoints});
    }
  }

  // Recording the grant and requesting captions are one write, so a clip
  // can never be paid for without being queued to render.
  await db.collection("matches").doc(matchId).set({
    clipGrants: {
      [uid]: {
        source: verdict.source,
        cost: verdict.cost,
        grantedAt: FieldValue.serverTimestamp(),
      },
    },
    // The existing forced-caption path autoRender already honours, so a
    // granted clip jumps the weekly ranking instead of hoping to place in
    // it. Someone who paid must not depend on a popularity contest.
    highlight: {captionRequested: true},
  }, {merge: true});

  const delivery = clipDeliverable(match, nowMs);
  return {
    granted: true,
    cost: verdict.cost,
    source: verdict.source,
    deliverable: delivery.deliverable,
    // So the client can say "ready after voting closes" rather than
    // leaving someone wondering where their clip is.
    availableAfterMs: delivery.deliverable ? null : voteCloseHint(match),
  };
}

/** When the objection window closes, for client messaging only. */
function voteCloseHint(match) {
  const {voteWindowEndMs} = require("./matchFinalization");
  const end = voteWindowEndMs(match);
  return Number.isFinite(end) ? end : null;
}

module.exports = {
  requestMatchClip,
  resolveClipGrant,
  clipDeliverable,
  spendPoints,
  spendableBalance,
  readClipPointsPrice,
  DENY,
  SOURCES,
  DEFAULT_CLIP_POINTS_PRICE,
};
