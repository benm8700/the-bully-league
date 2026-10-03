const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {HttpsError} = require("firebase-functions/v2/https");
const {pacificNow} = require("./eventWindow");
const {RATINGS, RATING_KEYS, isRating, countsOf} = require("./emojiRatings");

/**
 * Spend points to clean up your NEGATIVE emoji ratings (🥱 Boring / 💩 Trash) -
 * a points sink that also softens the sting of the public negative counts the
 * emoji system deliberately exposes.
 *
 * WHY SERVER-ONLY. emojiCounts is a player's public identity (profile flair,
 * the APPLAUSE board, the superlative awards, the nickname) and is immutable to
 * clients in firestore.rules - tallied only by castVote via the Admin SDK. So a
 * removal cannot be a client write; it goes through this callable, which spends
 * points the same way the day pass and clip grant do (pointsBalance + an
 * idempotent ledger entry).
 *
 * EXTENSIBLE BY DESIGN. "Which emojis can be cleaned up" is DERIVED from the
 * shared RATINGS definition - any rating whose `positive` flag is false. Add a
 * new negative emoji to functions/emojiRatings.js (and its client mirror) and
 * it becomes removable here automatically, with no change to this file.
 *
 * THE HONESTY GUARDRAIL. Buying a clean image would make the Crowd-read
 * percentages, the APPLAUSE board and the superlative awards buyable rather
 * than earned. Two limits bound that: a per-emoji PRICE, and a DAILY CAP on how
 * many you can remove - both live config (config/pointsSettings), both
 * provisional like every other economy number. Already-earned superlative
 * awards are earned-and-kept, so scrubbing never removes an award you already
 * hold; it only lowers your live count.
 */

/** The negative rating keys - the ones a player may pay to clean up. */
function removableEmojiKeys() {
  return RATING_KEYS.filter((k) => RATINGS[k].positive === false);
}

/** Whether a key is a rating AND a negative one (so removable). */
function isRemovableEmoji(key) {
  return isRating(key) && RATINGS[key].positive === false;
}

/** How many removals this account has already used today (0 on a fresh day). */
function scrubUsedToday(user, dayKey) {
  const rec = user && user.emojiScrub;
  if (!rec || rec.day !== dayKey) return 0;
  return Math.max(0, Math.floor(Number(rec.count) || 0));
}

/** Spendable balance - a legacy account with no balance field inherits its
 * career total, matching dayPass/clipGrants (reading a missing balance as zero
 * would confiscate everything earned before spending existed). */
function spendableBalance(user) {
  const raw = Number(user && user.pointsBalance);
  return Number.isFinite(raw) ?
    Math.max(0, raw) : Math.max(0, Number((user && user.points) || 0));
}

/**
 * PURE. How many of an emoji a request can actually remove, and what it costs.
 * The removal is clamped by four independent ceilings so no single one can be
 * overrun: what was requested, what the player actually has, what the daily cap
 * still allows, and what the balance can afford. One price per emoji removed.
 */
function scrubPlan({current, requested, dailyRemaining, balance, price}) {
  const p = Math.max(1, Math.floor(Number(price) || 0));
  const want = Math.max(0, Math.floor(Number(requested) || 0));
  const cur = Math.max(0, Math.floor(Number(current) || 0));
  const rem = Math.max(0, Math.floor(Number(dailyRemaining) || 0));
  const bal = Math.max(0, Math.floor(Number(balance) || 0));
  const affordable = Math.floor(bal / p);
  const removed = Math.max(0, Math.min(want, cur, rem, affordable));
  return {removed, cost: removed * p};
}

/**
 * Spend points to remove up to `count` of one negative emoji.
 *
 * Idempotent on a client-supplied `requestId` so a retried tap never charges
 * twice; two genuinely separate taps carry different ids and both apply.
 */
async function scrubEmojiRating(auth, data) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const {emojiKey, count, requestId} = data || {};

  if (!isRemovableEmoji(emojiKey)) {
    throw new HttpsError("invalid-argument",
        "That rating can't be cleaned up.");
  }

  const {pointsSettings} = require("./points");
  const settings = await pointsSettings();
  if (settings.emojiScrubEnabled === false) {
    throw new HttpsError("failed-precondition",
        "Cleaning up ratings isn't available right now.", {reason: "disabled"});
  }
  const price = settings.emojiScrubPrice;
  const maxPerDay = settings.emojiScrubMaxPerDay;

  // Default to one if the client sends nothing sensible; clamp to the cap.
  let requested = Math.floor(Number(count));
  if (!Number.isFinite(requested) || requested < 1) requested = 1;
  requested = Math.min(requested, maxPerDay);

  const rid = (typeof requestId === "string" && requestId.length > 0 &&
      requestId.length <= 128) ?
    requestId :
    `auto_${Date.now()}_${Math.random().toString(36).slice(2)}`;

  const db = getFirestore();
  const userRef = db.collection("users").doc(auth.uid);
  const entryRef = userRef.collection("pointsLedger").doc(`emojiScrub_${rid}`);
  const dayKey = pacificNow(new Date()).dayKey;

  const result = await db.runTransaction(async (tx) => {
    const [entrySnap, userSnap] = await Promise.all([
      tx.get(entryRef), tx.get(userRef),
    ]);
    const user = userSnap.data() || {};

    if (entrySnap.exists) {
      // A retry of the same request - report what it already did, charge nothing.
      const e = entrySnap.data() || {};
      return {
        scrubbed: Number(e.removed) || 0, duplicate: true, emojiKey,
        newCount: countsOf(user)[emojiKey], balance: spendableBalance(user),
      };
    }

    const current = countsOf(user)[emojiKey];
    if (current <= 0) {
      return {scrubbed: 0, reason: "nothing-to-clean", emojiKey, newCount: 0};
    }
    const used = scrubUsedToday(user, dayKey);
    const dailyRemaining = Math.max(0, maxPerDay - used);
    if (dailyRemaining <= 0) {
      return {scrubbed: 0, reason: "daily-cap", maxPerDay};
    }
    const balance = spendableBalance(user);
    const plan = scrubPlan({current, requested, dailyRemaining, balance, price});
    if (plan.removed <= 0) {
      const reason = balance < price ? "insufficient" : "none";
      return {scrubbed: 0, reason, balance, price};
    }

    const newCount = current - plan.removed;
    tx.set(entryRef, {
      reason: "emojiScrub", sourceId: rid, amount: -plan.cost,
      emojiKey, removed: plan.removed, createdAt: FieldValue.serverTimestamp(),
    });
    tx.set(userRef, {
      // Absolute, like every other spend: a legacy account with no balance
      // field inherits its career total rather than decrementing from zero.
      pointsBalance: balance - plan.cost,
      // merge:true deep-merges the map, so only this emoji's count changes.
      emojiCounts: {[emojiKey]: newCount},
      emojiScrub: {day: dayKey, count: used + plan.removed},
    }, {merge: true});

    return {
      scrubbed: plan.removed, cost: plan.cost, emojiKey, newCount,
      balance: balance - plan.cost,
      dailyRemaining: dailyRemaining - plan.removed,
    };
  });

  if (result.scrubbed <= 0 && result.reason) {
    const messages = {
      "nothing-to-clean": "There's nothing to clean up here.",
      "daily-cap": "You've hit today's cleanup limit. Try again tomorrow.",
      "insufficient":
        `Cleaning up costs ${price} points each - you don't have enough.`,
      "none": "Nothing to clean up right now.",
    };
    throw new HttpsError("failed-precondition",
        messages[result.reason] || "Couldn't clean that up.",
        {reason: result.reason});
  }
  return result;
}

/** What the client needs to render the cleanup sheet honestly. */
async function getEmojiScrubState(auth) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const db = getFirestore();
  const {pointsSettings} = require("./points");
  const [snap, settings] = await Promise.all([
    db.collection("users").doc(auth.uid).get(),
    pointsSettings(),
  ]);
  const user = snap.data() || {};
  const dayKey = pacificNow(new Date()).dayKey;
  const used = scrubUsedToday(user, dayKey);
  const all = countsOf(user);
  const counts = {};
  for (const k of removableEmojiKeys()) counts[k] = all[k];
  return {
    enabled: settings.emojiScrubEnabled !== false,
    price: settings.emojiScrubPrice,
    maxPerDay: settings.emojiScrubMaxPerDay,
    dailyRemaining: Math.max(0, settings.emojiScrubMaxPerDay - used),
    balance: spendableBalance(user),
    counts,
  };
}

module.exports = {
  scrubEmojiRating,
  getEmojiScrubState,
  scrubPlan,
  removableEmojiKeys,
  isRemovableEmoji,
  scrubUsedToday,
};
