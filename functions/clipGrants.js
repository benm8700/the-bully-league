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

/** What a client may ASK for. "free" is deliberately absent - the first
 * free clip is something the server grants when it applies, never
 * something a client can claim. */
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
 * Has this account already taken its one free clip?
 *
 * Only an explicit `true` counts. Every account predating this feature
 * has no such field, and reading a missing field as "used" would quietly
 * deny the free clip to the entire existing userbase - the same
 * missing-field trap as accountStatus, createdAt and pointsBalance before
 * it, which this project has now hit four times.
 */
function hasUsedFreeClip(user) {
  return user?.freeClipUsed === true;
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

  // THE FIRST ONE IS FREE, and this is distribution rather than
  // generosity. Every clip a player posts is acquisition nobody paid for,
  // and at 250 points almost nobody in a private beta ever reaches one -
  // so with no free clip the app would learn nothing about whether clips
  // spread, which is the entire growth thesis. Everyone gets to experience
  // having a clip and posting it once; that is what creates the desire to
  // buy the next.
  //
  // Checked AFTER the subscription branch on purpose: a subscriber or
  // trial user already gets every clip included, so spending their free
  // one there would silently burn it for nothing. It is only consumed
  // where it actually saves someone something.
  if (!hasUsedFreeClip(user)) {
    return {allowed: true, cost: 0, source: "free"};
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
 * Takes this account's one free clip, if it still has it.
 *
 * @return {Promise<boolean>} true if this call is the one that took it
 */
async function claimFreeClip(uid) {
  const db = getFirestore();
  const ref = db.collection("users").doc(uid);
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (hasUsedFreeClip(snap.data() ?? {})) return false;
    tx.set(ref, {freeClipUsed: true}, {merge: true});
    return true;
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

  let verdict = resolveClipGrant({
    user, match, uid, source: source ?? "subscription", price, entitlement,
  });

  // Claimed in a transaction rather than trusted from the read above,
  // because two taps on two different battles in the same instant would
  // otherwise each see an unused free clip and both take it.
  if (verdict.allowed && verdict.source === "free") {
    const claimed = await claimFreeClip(uid);
    if (!claimed) {
      // Somebody's other request won it. Re-decide as an ordinary
      // purchase rather than handing out a second free clip.
      verdict = resolveClipGrant({
        user: {...user, freeClipUsed: true}, match, uid,
        source: source ?? "subscription", price, entitlement,
      });
    }
  }

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

/**
 * Makes buyers whole when an objection kills a clip they paid for.
 *
 * The delivery rule already means nothing revocable is ever handed over,
 * so this is the remaining case: someone bought a clip, and before it
 * could be delivered the other player objected. They must not simply lose
 * what they paid.
 *
 * AN IN-APP CREDIT, NEVER A STORE REFUND. The refund support category was
 * deliberately removed because Apple and Google own that process, so a
 * refund path here could only route someone somewhere we cannot help.
 * A credit makes them whole immediately and without leaving the app.
 *
 *   points   - refunded straight to the spendable balance
 *   purchase - becomes a clip credit, spendable on any future battle
 *
 * The objecting player is never refunded: they caused the revocation, and
 * a refund would turn objecting into a way to get clips free. Idempotent
 * on the ledger id, so a repeated takedown never pays twice.
 */
async function refundClipGrants(matchId, match, objectorUid) {
  const grants = match?.clipGrants;
  if (!grants) return {refunded: 0};

  const db = getFirestore();
  let refunded = 0;
  for (const [uid, grant] of Object.entries(grants)) {
    if (uid === objectorUid) continue;
    if (grant?.refundedAt) continue;
    const cost = Number(grant?.cost) || 0;

    try {
      if (grant?.source === "points" && cost > 0) {
        const userRef = db.collection("users").doc(uid);
        const entryRef = userRef.collection("pointsLedger")
            .doc(`clipRefund_${matchId}`);
        await db.runTransaction(async (tx) => {
          const [entry, userSnap] = await Promise.all([
            tx.get(entryRef), tx.get(userRef),
          ]);
          if (entry.exists) return;
          tx.set(entryRef, {
            reason: "clipRefund", sourceId: matchId, amount: cost,
            createdAt: FieldValue.serverTimestamp(),
          });
          // Absolute, not an increment, for the same reason spendPoints
          // is: a legacy account with no balance field must inherit its
          // career total rather than starting from zero.
          tx.set(userRef, {
            pointsBalance: spendableBalance(userSnap.data() ?? {}) + cost,
          }, {merge: true});
        });
      } else if (grant?.source === "free") {
        // Give the free clip BACK. Losing your one free clip to somebody
        // else's objection - having never received anything - is exactly
        // the unfairness this whole function exists to prevent, and it
        // would land on a brand-new player at the first battle they ever
        // tried to keep.
        await db.collection("users").doc(uid)
            .set({freeClipUsed: false}, {merge: true});
      } else if (grant?.source === "purchase") {
        await db.collection("users").doc(uid)
            .set({clipCredits: FieldValue.increment(1)}, {merge: true});
      } else {
        // A subscription grant cost nothing, so there is nothing to
        // return - they simply get their next one as usual.
        continue;
      }
      await db.collection("matches").doc(matchId).set({
        clipGrants: {[uid]: {refundedAt: FieldValue.serverTimestamp()}},
      }, {merge: true});
      refunded++;
    } catch (e) {
      // Never let a refund failure block a takedown. The takedown is the
      // urgent, rights-affecting half; the refund can be retried.
      console.error(`clip refund for ${uid} on ${matchId} failed:`, e.message);
    }
  }
  return {refunded};
}

/** How long a download link lives. Short, because this is an unpublished
 * clip: a permanent URL would escape the review gate entirely and could be
 * passed to anyone. Long enough to survive a slow mobile download. */
const DOWNLOAD_URL_TTL_MS = 60 * 60 * 1000;

/**
 * Hands over the file for a clip this player is entitled to.
 *
 * THE OBJECTION CHECK HERE IS THE POINT, not a formality. Publishing
 * already refuses while an objection stands, but a self-serve download
 * would walk straight around that and let someone post a clip their
 * opponent had explicitly objected to. The gate has to live on every path
 * that hands over bytes, and this is one.
 *
 * Signed URLs rather than a Firebase download token, deliberately: a token
 * mints a PERMANENT public URL, which for an unreviewed clip means anyone
 * it is forwarded to has it forever, and revoking it later would be the
 * only way back. Signing keeps `storage.rules` denying clients all read on
 * match_highlights/** and makes this callable the only door.
 */
async function getClipDownload(auth, data) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const {matchId} = data || {};
  if (!matchId) throw new HttpsError("invalid-argument", "matchId is required.");

  const db = getFirestore();
  const uid = auth.uid;
  const snap = await db.collection("matches").doc(matchId).get();
  const match = snap.exists ? snap.data() : null;

  if (!match || (match.player1Id !== uid && match.player2Id !== uid)) {
    throw new HttpsError("permission-denied",
        "You can only download clips of your own battles.");
  }
  const grant = match.clipGrants?.[uid];
  if (!grant) {
    throw new HttpsError("failed-precondition",
        "You haven't got this clip yet.", {reason: "no-grant"});
  }
  // A refunded grant is NOT the same as never having bought it, and saying
  // so matters: telling someone who paid, and whose clip was then taken
  // down, that they "haven't got this clip yet" reads as the purchase
  // having silently failed. They are owed the actual reason and the fact
  // that they were already made whole.
  if (grant.refundedAt) {
    throw new HttpsError("failed-precondition",
        "This clip was taken down at the other player's request, and your " +
        "points have been returned.", {reason: "refunded"});
  }

  const delivery = clipDeliverable(match, Date.now());
  if (!delivery.deliverable) {
    const message = delivery.reason === "objected" ?
      "This clip was taken down at the other player's request. " +
        "Your points have been returned." :
      delivery.reason === "window-open" ?
        "Your clip unlocks once voting closes." :
        "Your clip is still being prepared.";
    throw new HttpsError("failed-precondition", message,
        {reason: delivery.reason});
  }

  const {getStorage} = require("firebase-admin/storage");
  const bucket = getStorage().bucket();
  const expires = Date.now() + DOWNLOAD_URL_TTL_MS;
  const urls = {};
  for (const [name, rendition] of Object.entries(match.highlight?.renditions ?? {})) {
    if (!rendition?.path) continue;
    try {
      const [url] = await bucket.file(rendition.path).getSignedUrl({
        action: "read",
        expires,
        // Makes the browser and the OS save it rather than stream it -
        // this endpoint exists so people can post the file elsewhere.
        promptSaveAs: `bully-league-${matchId}-${name}.mp4`,
      });
      urls[name] = url;
    } catch (e) {
      // One unavailable shape must not deny the other. Vertical is the
      // one people actually post.
      console.error(`could not sign ${rendition.path}:`, e.message);
    }
  }

  if (Object.keys(urls).length === 0) {
    throw new HttpsError("internal", "Couldn't prepare your download.");
  }
  return {urls, expiresAtMs: expires, captioned: match.highlight?.captioned === true};
}

/** When the objection window closes, for client messaging only. */
function voteCloseHint(match) {
  // The objection window, because that is what delivery actually waits
  // for - a live tournament decides its winner in a minute but a clip
  // still cannot be handed over until the other player's full chance to
  // object has passed.
  const {objectionWindowEndMs} = require("./matchFinalization");
  const end = objectionWindowEndMs(match);
  return Number.isFinite(end) ? end : null;
}

module.exports = {
  requestMatchClip,
  getClipDownload,
  DOWNLOAD_URL_TTL_MS,
  refundClipGrants,
  resolveClipGrant,
  clipDeliverable,
  spendPoints,
  spendableBalance,
  hasUsedFreeClip,
  readClipPointsPrice,
  DENY,
  SOURCES,
  DEFAULT_CLIP_POINTS_PRICE,
};
