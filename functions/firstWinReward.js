const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {getAuth} = require("firebase-admin/auth");

/**
 * $5 FIRST RANKED WIN (decided 2026-11-09, developer's call - see CLAUDE.md
 * "Marketing - Friend Challenges as the Growth Engine").
 *
 * The rule, exactly as decided:
 *   - A new player's FIRST ranked win earns a $5 gift card.
 *   - The battle must be COMPLETED before the 7-day deadline, which runs from
 *     the moment the account was created, to the minute. The money is only
 *     awarded once the crowd's voting has closed and the verdict is final -
 *     so a battle finished at 6d 23h 59m still counts even though its verdict
 *     lands the next day.
 *   - One per verified phone number, forever (deleting the account and signing
 *     up again with the same number does not pay twice).
 *   - A total budget, hard-capped in config; once spent, nothing more is paid.
 *
 * Where the money goes: a `prizeFulfillments` record (prizeType "gift_card"),
 * the same queue tournament prizes use. The winner claims it in the app with
 * their email, and the admin sends the gift card and marks it fulfilled from
 * the dashboard. Nothing is paid automatically.
 *
 * Anti-staging (the cheat: two friends queue at once on a quiet night, get
 * paired in "ranked", and one throws the battle):
 *   - Only a CROWD-JUDGED win counts. A forfeit win (opponent left) is the
 *     easiest thing to stage, so it never pays.
 *   - No payout if the two players have any friend-challenge history, either
 *     direction, or share a device (an FCM token in common).
 * A win that is refused for staging does NOT use up the chance - the next
 * clean ranked win inside the 7 days still pays.
 *
 * Ships OFF (`config/firstWinReward.enabled` absent or false).
 */

const DAY_MS = 24 * 60 * 60 * 1000;

const DEFAULTS = Object.freeze({
  enabled: false,
  amountUsd: 5,
  budgetUsd: 500,
  windowDays: 7,
});

/** Bounds-checked per field, like every other hand-edited config doc. */
function parseConfig(raw) {
  const x = raw && typeof raw === "object" ? raw : {};
  const num = (v, lo, hi, d) => {
    const n = Number(v);
    return Number.isFinite(n) && n >= lo && n <= hi ? n : d;
  };
  return {
    enabled: x.enabled === true,
    amountUsd: num(x.amountUsd, 1, 100, DEFAULTS.amountUsd),
    budgetUsd: num(x.budgetUsd, 0, 100000, DEFAULTS.budgetUsd),
    windowDays: num(x.windowDays, 1, 60, DEFAULTS.windowDays),
  };
}

async function readConfig(db = getFirestore()) {
  try {
    const snap = await db.collection("config").doc("firstWinReward").get();
    return parseConfig(snap.exists ? snap.data() : null);
  } catch (e) {
    console.error("could not read config/firstWinReward:", e.message);
    return parseConfig(null); // disabled
  }
}

/** The exact moment the window closes for an account created at signupMs. */
function deadlineMs(signupMs, windowDays) {
  return signupMs + windowDays * DAY_MS;
}

/** The "phone key" used as the one-per-number document id. */
function phoneKey(phone) {
  const digits = String(phone || "").replace(/[^0-9]/g, "");
  return digits.length >= 8 ? `p${digits}` : null;
}

function sharesDevice(a, b) {
  const ta = Array.isArray(a?.fcmTokens) ? a.fcmTokens : [];
  const tb = new Set(Array.isArray(b?.fcmTokens) ? b.fcmTokens : []);
  return ta.some((t) => typeof t === "string" && t && tb.has(t));
}

/**
 * PURE. Whether this finalized match pays the winner the first-win reward.
 * Returns {ok: true} or {ok: false, reason}. Everything that needs Firestore
 * is passed in, so every rule is testable.
 */
function eligibility({
  config, match, winnerId, winner, opponent, signupMs, completedAtMs,
  alreadyRewarded, pairHasHistory,
}) {
  if (!config?.enabled) return {ok: false, reason: "disabled"};
  if (!match || match.mode !== "ranked") return {ok: false, reason: "not-ranked"};
  if (!winnerId) return {ok: false, reason: "no-winner"};
  if (match.forfeitWinnerId) return {ok: false, reason: "forfeit"};
  if (alreadyRewarded) return {ok: false, reason: "already-rewarded"};
  if (!phoneKey(winner?.phoneNumber)) return {ok: false, reason: "no-phone"};
  if (!Number.isFinite(signupMs) || signupMs <= 0) {
    return {ok: false, reason: "no-signup-time"};
  }
  if (!Number.isFinite(completedAtMs) || completedAtMs <= 0) {
    return {ok: false, reason: "no-completion-time"};
  }
  // Completed AT or before the deadline counts; one millisecond after does not.
  if (completedAtMs > deadlineMs(signupMs, config.windowDays)) {
    return {ok: false, reason: "past-deadline"};
  }
  if (pairHasHistory) return {ok: false, reason: "friend-history"};
  if (sharesDevice(winner, opponent)) return {ok: false, reason: "shared-device"};
  return {ok: true};
}

/** Any challenge between these two players, either direction, ever. */
async function pairHasChallengeHistory(db, a, b) {
  const [ab, ba] = await Promise.all([
    db.collection("challenges").where("fromUid", "==", a)
        .where("toUid", "==", b).limit(1).get(),
    db.collection("challenges").where("fromUid", "==", b)
        .where("toUid", "==", a).limit(1).get(),
  ]);
  return !ab.empty || !ba.empty;
}

/**
 * Called by finalizeMatch once a verdict is final. Best-effort and idempotent:
 * the reward record is keyed by phone number and created in a transaction
 * that also charges the budget, so a re-run (the hourly sweep re-examining a
 * match) can never pay twice or overspend.
 */
async function maybeAwardFirstWin(matchId, match, winnerId, {db = getFirestore(),
  nowMs = Date.now()} = {}) {
  if (!winnerId || match?.mode !== "ranked") return {awarded: false, reason: "not-ranked"};
  const config = await readConfig(db);
  if (!config.enabled) return {awarded: false, reason: "disabled"};

  const opponentId = winnerId === match.player1Id ? match.player2Id : match.player1Id;
  const [winnerSnap, opponentSnap] = await Promise.all([
    db.collection("users").doc(winnerId).get(),
    db.collection("users").doc(opponentId).get(),
  ]);
  const winner = winnerSnap.data() ?? {};
  const opponent = opponentSnap.data() ?? {};

  // Account creation time from Firebase Auth, NOT the user doc - the client
  // writes the doc at signup, and a tamperable start time is a tamperable
  // deadline.
  let signupMs = NaN;
  try {
    const rec = await getAuth().getUser(winnerId);
    signupMs = Date.parse(rec.metadata.creationTime);
  } catch (e) {
    console.error(`first-win: auth lookup for ${winnerId} failed:`, e.message);
  }

  const key = phoneKey(winner.phoneNumber);
  const rewardRef = key ? db.collection("firstWinRewards").doc(key) : null;
  const alreadyRewarded = winner.firstWinReward != null ||
    (rewardRef ? (await rewardRef.get()).exists : false);
  const pairHasHistory = await pairHasChallengeHistory(db, winnerId, opponentId);
  const completedAtMs = match.completedAt?.toMillis?.() ?? NaN;

  const verdict = eligibility({
    config, match, winnerId, winner, opponent, signupMs, completedAtMs,
    alreadyRewarded, pairHasHistory,
  });
  if (!verdict.ok) {
    if (verdict.reason !== "already-rewarded" && verdict.reason !== "past-deadline") {
      console.log(`first-win: ${matchId} -> ${winnerId} not paid (${verdict.reason})`);
    }
    return {awarded: false, reason: verdict.reason};
  }

  const budgetRef = db.collection("stats").doc("firstWinReward");
  const prizeRef = db.collection("prizeFulfillments").doc(`firstwin_${key}`);
  const amount = config.amountUsd;
  const result = await db.runTransaction(async (tx) => {
    const [reward, budget] = await Promise.all([tx.get(rewardRef), tx.get(budgetRef)]);
    if (reward.exists) return {awarded: false, reason: "already-rewarded"};
    const spent = Number(budget.data()?.committedUsd) || 0;
    if (spent + amount > config.budgetUsd) {
      tx.set(budgetRef, {exhausted: true, exhaustedAtMs: nowMs}, {merge: true});
      return {awarded: false, reason: "budget-exhausted"};
    }
    tx.set(rewardRef, {
      uid: winnerId, matchId, amountUsd: amount, completedAtMs,
      signupMs, awardedAtMs: nowMs, prizeId: prizeRef.id,
    });
    tx.set(budgetRef, {
      committedUsd: spent + amount,
      count: FieldValue.increment(1),
      budgetUsd: config.budgetUsd,
    }, {merge: true});
    tx.set(prizeRef, {
      tournamentId: null,
      tournamentName: "First ranked win",
      winnerUid: winnerId,
      winnerUsername: winner.username ?? null,
      prize: `a $${amount} gift card`,
      prizeType: "gift_card",
      amountUsd: amount,
      matchId,
      status: "owed",
      wonAtMs: nowMs,
      createdAt: FieldValue.serverTimestamp(),
    });
    tx.update(db.collection("users").doc(winnerId), {
      firstWinReward: {amountUsd: amount, matchId, awardedAtMs: nowMs,
        prizeId: prizeRef.id},
    });
    return {awarded: true};
  });

  if (result.awarded) {
    try {
      const {sendToUsers} = require("./notifications");
      await sendToUsers([winnerId], {
        title: `💵 You won $${amount}!`,
        body: "The crowd picked you. Tap to claim your gift card.",
        category: "prize_won",
        data: {type: "prize_won", fulfillmentId: prizeRef.id},
      });
      const admins = await db.collection("users").where("isAdmin", "==", true).get();
      if (!admins.empty) {
        await sendToUsers(admins.docs.map((d) => d.id), {
          title: "Gift card to send",
          body: `$${amount} first ranked win → ${winner.username ?? winnerId}`,
          category: "prize_won",
          data: {type: "admin_prize"},
        });
      }
    } catch (e) {
      console.error("first-win push failed:", e.message);
    }
  }
  return result;
}

module.exports = {
  DEFAULTS,
  parseConfig,
  readConfig,
  deadlineMs,
  phoneKey,
  sharesDevice,
  eligibility,
  maybeAwardFirstWin,
};
