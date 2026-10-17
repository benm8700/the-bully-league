const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {HttpsError} = require("firebase-functions/v2/https");

/**
 * Records the signing-in user's VERIFIED phone number and attaches any
 * challenges that were aimed at that number before the account existed.
 *
 * WHY THIS IS A CLOUD FUNCTION rather than a client write. The phone number
 * is read from `auth.token.phone_number` - a claim Firebase only puts on the
 * token once a phone credential is genuinely linked (the client refreshes its
 * token right before calling this). So the server trusts the number without
 * trusting the client: a modified app cannot write a number it never verified.
 * `phoneNumber`/`phoneVerifiedAt` are server-only in firestore.rules for the
 * same reason the rating fields are - this is the only path that sets them.
 *
 * WHY attribution is by phone number (not a deep link). Deferred deep-linking
 * is dead (Firebase Dynamic Links is gone), so the invite loop pins a pending
 * challenge to a phone NUMBER; when that number verifies here, the challenge
 * is matched to the new account. The number is the attribution key.
 *
 * Idempotent and best-effort: safe to call on every signup finalize, and a
 * re-call just re-writes the same number and attaches nothing new.
 */

/** Normalize to the same digits-with-plus shape on both the invite side and
 * here, so the lookup key always matches. Firebase already hands us E.164. */
function normalizeE164(raw) {
  if (typeof raw !== "string") return null;
  const trimmed = raw.trim();
  const hasPlus = trimmed.startsWith("+");
  const digits = trimmed.replace(/\D/g, "");
  if (digits.length < 8 || digits.length > 15) return null;
  // Trust an explicit +; otherwise assume US (matches the client normalizer).
  if (hasPlus) return `+${digits}`;
  if (digits.length === 10) return `+1${digits}`;
  if (digits.length === 11 && digits.startsWith("1")) return `+${digits}`;
  // Match the client normalizer exactly: a bare number that is neither 10
  // digits nor 1+10 is rejected rather than guessed. (The real finalize path
  // always gets an already-+ E.164 from the token, so this only guards the
  // invite side's typed input from drifting apart from the client.)
  return null;
}

/** Attached challenges get a generous window: the person just installed and
 * may finish onboarding (intro video etc.) before they battle, so the hour a
 * live challenge gets would be gone before they could use it. */
const ATTACHED_CHALLENGE_TTL_MS = 7 * 24 * 60 * 60 * 1000;

async function finalizePhoneSignup(auth) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const phone = normalizeE164(auth.token && auth.token.phone_number);
  if (!phone) {
    // No verified phone on the token. Not fatal to the account; the client
    // treats this as best-effort, so report it rather than throwing hard.
    return {recorded: false, reason: "no-verified-phone", attached: 0};
  }

  const db = getFirestore();
  const uid = auth.uid;
  const nowMs = Date.now();

  // 1) Record the verified number on the user doc (server-trusted).
  await db.collection("users").doc(uid).set({
    phoneNumber: phone,
    phoneVerifiedAt: FieldValue.serverTimestamp(),
  }, {merge: true});

  // 2) Attach any pending invite-challenges aimed at this number. Each becomes
  //    a real challenge from the inviter to this new account. (The invite loop
  //    that WRITES phoneChallenges is built separately; until then this finds
  //    nothing and is a cheap no-op.)
  let attached = 0;
  try {
    const pending = await db.collection("phoneChallenges")
        .where("phone", "==", phone)
        .where("status", "==", "pending")
        .limit(25)
        .get();
    for (const doc of pending.docs) {
      const pc = doc.data() || {};
      // Never attribute a challenge to the invitee themselves.
      if (!pc.fromUid || pc.fromUid === uid) {
        await doc.ref.update({status: "void", resolvedAtMs: nowMs}).catch(() => {});
        continue;
      }
      const chRef = db.collection("challenges").doc();
      // One transaction per invite: claim the pending record and mint the real
      // challenge together, so a double finalize can't attach the same one twice.
      // eslint-disable-next-line no-await-in-loop
      const minted = await db.runTransaction(async (tx) => {
        const fresh = await tx.get(doc.ref);
        if (!fresh.exists || fresh.data().status !== "pending") return false;
        tx.update(doc.ref, {
          status: "attached",
          claimedByUid: uid,
          resolvedAtMs: nowMs,
        });
        tx.set(chRef, {
          fromUid: pc.fromUid,
          toUid: uid,
          fromUsername: pc.fromUsername || "A player",
          status: "pending",
          createdAtMs: nowMs,
          expiresAtMs: nowMs + ATTACHED_CHALLENGE_TTL_MS,
          fromPhoneInvite: true,
        });
        return true;
      });
      if (minted) attached++;
    }
  } catch (_) {
    // Attaching is best-effort; recording the number is the part that matters.
  }

  return {recorded: true, phone, attached};
}

module.exports = {finalizePhoneSignup, normalizeE164, ATTACHED_CHALLENGE_TTL_MS};
