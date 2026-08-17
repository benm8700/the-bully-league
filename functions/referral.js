const {getFirestore} = require("firebase-admin/firestore");
const {HttpsError} = require("firebase-functions/v2/https");

/**
 * Referrals: who invited whom, and when that is worth paying for.
 *
 * DECIDED, IN THE SCHEMA, AND ENTIRELY UNIMPLEMENTED until now.
 * `referredByUserId` and `referralRewardGranted` have been in CLAUDE.md's
 * user model from the start, and a `referral` rate has sat in
 * `pointsSettings` alongside the streak rate that was also unearnable -
 * nothing wrote either field or paid the rate.
 *
 * THE ANTI-ABUSE DESIGN IS THE WHOLE POINT, and it is CLAUDE.md's:
 * the reward triggers on ACTIVATION, never on signup. Paying at signup
 * makes throwaway accounts directly profitable, which is the one thing a
 * referral programme must not do. Requiring a completed match means an
 * abuser has to actually play a battle against a real opponent for every
 * fake account, which is far more effort than the reward is worth.
 *
 * Attribution is captured ONCE, at signup, and never changes - so a
 * referrer renaming themselves later (allowed, with a cooldown) does not
 * break or re-point anything.
 */

/**
 * TWO TIERS, per CLAUDE.md: a smaller reward when a referred friend
 * becomes an active SPECTATOR (casts their first vote), and the full
 * reward when they become an active BATTLER (plays their first match).
 *
 * They are ADDITIVE milestones rather than alternatives, because they
 * measure different things: someone who only ever judges is genuinely
 * worth something (votes are the scarce resource), and someone who goes
 * on to battle is worth more. Paying the second instead of the first
 * would mean a friend who watched and voted for a month earned their
 * referrer less than one who played once and vanished.
 *
 * Deliberately NOT satisfied by merely existing. Signing up, filling in a
 * profile and queueing all leave both false, which is what stops
 * throwaway accounts being profitable.
 *
 * Pure, so the rule is testable without Firestore.
 */
const TIERS = {
  battler: {
    flag: "referralRewardGranted",
    rate: "referral",
    ledger: "referral",
  },
  spectator: {
    flag: "referralSpectatorGranted",
    rate: "referralSpectator",
    ledger: "referralSpectator",
  },
};

function referralOutcome(user, referredUid, tier = "battler") {
  const spec = TIERS[tier];
  if (!spec) return {owed: false, reason: "unknown-tier"};

  const referrer = user?.referredByUserId;
  if (!referrer) return {owed: false, reason: "no-referrer"};
  if (user[spec.flag] === true) {
    return {owed: false, reason: "already-granted"};
  }
  // Belt and braces - setReferrer refuses this too, but a hand-edited
  // document must not be able to pay someone for inviting themselves.
  if (referrer === referredUid) return {owed: false, reason: "self-referral"};

  if (tier === "battler") {
    const played = (Number(user.rankedMatchesPlayed) || 0) +
      (Number(user.exhibitionMatchesPlayed) || 0);
    if (played < 1) return {owed: false, reason: "not-activated"};
  } else {
    // A vote is the spectator's activation. `voteStreak` is written on
    // every vote, so its presence is the cheapest honest proof that this
    // account has actually judged something.
    if (!user.voteStreak?.dayKey) {
      return {owed: false, reason: "not-activated"};
    }
  }

  return {owed: true, referrerId: referrer, tier, spec};
}

/**
 * Records who invited this player.
 *
 * Set once and never changed: attribution that could be rewritten later
 * would let someone re-point a referral after the fact, and there is no
 * legitimate reason to change who invited you.
 */
async function setReferrer(auth, data) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const raw = data?.username;
  if (typeof raw !== "string" || raw.trim().length < 2) {
    throw new HttpsError("invalid-argument", "A username is required.");
  }
  const wanted = raw.trim().toLowerCase();

  const db = getFirestore();
  const meRef = db.collection("users").doc(auth.uid);
  const meSnap = await meRef.get();
  const me = meSnap.data() ?? {};

  if (me.referredByUserId) {
    throw new HttpsError("failed-precondition",
        "You've already said who invited you.", {reason: "already-set"});
  }
  // Anyone who has already played is past the point where an invite is
  // plausibly being recorded, and allowing it later would let people
  // attach a referrer retroactively once they knew it paid.
  const played = (Number(me.rankedMatchesPlayed) || 0) +
    (Number(me.exhibitionMatchesPlayed) || 0);
  if (played > 0) {
    throw new HttpsError("failed-precondition",
        "You can only add this before your first battle.",
        {reason: "too-late"});
  }

  // Resolved through the same lowercase field the player directory uses.
  const found = await db.collection("users")
      .where("usernameLower", "==", wanted).limit(1).get();
  if (found.empty) {
    throw new HttpsError("not-found", "No player by that name.",
        {reason: "not-found"});
  }
  const referrerId = found.docs[0].id;
  if (referrerId === auth.uid) {
    throw new HttpsError("invalid-argument", "You can't invite yourself.",
        {reason: "self-referral"});
  }

  await meRef.set({referredByUserId: referrerId}, {merge: true});
  return {referrer: found.docs[0].data().username ?? "Unknown"};
}

/**
 * Pays the referrer if this player has just become active.
 *
 * Best-effort: a referral failure must never fail the match that earned
 * it. Idempotent twice over - the `referralRewardGranted` flag, and the
 * points ledger keyed by the referred player's uid, so even a lost flag
 * cannot pay the same referral twice.
 */
async function grantReferralIfEarned(referredUid, tier = "battler") {
  try {
    const db = getFirestore();
    const ref = db.collection("users").doc(referredUid);
    const snap = await ref.get();
    const outcome = referralOutcome(snap.data(), referredUid, tier);
    if (!outcome.owed) return {granted: false, reason: outcome.reason};
    const {flag, rate, ledger} = outcome.spec;

    // Claimed before paying, so two matches finishing at once cannot both
    // see an ungranted referral.
    const claimed = await db.runTransaction(async (tx) => {
      const fresh = await tx.get(ref);
      if (fresh.data()?.[flag] === true) return false;
      tx.set(ref, {[flag]: true}, {merge: true});
      return true;
    });
    if (!claimed) return {granted: false, reason: "already-granted"};

    const {awardPoints, pointsSettings, awardAmount} = require("./points");
    const rates = await pointsSettings();
    const result = await awardPoints(outcome.referrerId, {
      reason: ledger,
      // Keyed by the person referred, so one invite pays exactly once per
      // tier however many times this runs.
      sourceId: referredUid,
      amount: awardAmount(rates[rate]),
    });
    return {granted: true, referrerId: outcome.referrerId, tier,
      awarded: result.awarded};
  } catch (e) {
    console.error(`referral for ${referredUid} failed:`, e.message);
    return {granted: false, reason: "error"};
  }
}

module.exports = {setReferrer, grantReferralIfEarned, referralOutcome};
