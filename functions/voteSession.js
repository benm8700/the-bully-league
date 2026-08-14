const {getFirestore, FieldValue, Timestamp} = require("firebase-admin/firestore");
const {HttpsError} = require("firebase-functions/v2/https");

/**
 * Verify once, then judge a run of battles.
 *
 * WHY THIS EXISTS. Voting used to demand a fresh CAPTCHA per ballot, which
 * is fine for the website - someone arrives from a shared clip, votes once,
 * leaves - and fatal in the app's feed, where the whole design is to scroll
 * from one battle to the next. A checkbox between every video would make
 * judging feel like a chore, and votes are the scarce resource this app
 * runs on.
 *
 * WHAT IT TRADES. A single solve now covers a bounded run of votes rather
 * than one. That is a real reduction in automation resistance, and it is
 * acceptable because CAPTCHA was never the main defence here: swinging a
 * match needs many distinct ACCOUNTS, since one ballot per account per
 * match is already enforced. Account scarcity is phone verification's job,
 * not CAPTCHA's. What remains is bounded by the two limits below.
 *
 * WHAT SUPERSEDES IT. Firebase App Check with Play Integrity attests that a
 * request came from a genuine unmodified app on a real device - invisible,
 * and far harder to farm than CAPTCHA solves. When that is enabled this
 * becomes redundant on mobile, and the session simply stops being needed.
 */

/** Long enough for a real judging run, short enough that a stolen session
 * is worth little. */
const SESSION_TTL_MS = 20 * 60 * 1000;

/** A hard ceiling on one solve. Deliberately not generous: it covers a
 * genuine sitting - more battles than most people will judge in a run -
 * while keeping the value of automating a single solve low. */
const SESSION_VOTE_BUDGET = 25;

function sessionRef(uid) {
  return getFirestore().collection("voteSessions").doc(uid);
}

/**
 * Whether a stored session can still be spent, given the clock.
 *
 * Pure, so expiry and budget rules are testable without Firestore.
 */
function sessionUsable(session, nowMs) {
  if (!session) return false;
  const expiresAtMs = session.expiresAt?.toMillis?.() ?? session.expiresAtMs ?? 0;
  if (nowMs >= expiresAtMs) return false;
  return (Number(session.votesRemaining) || 0) > 0;
}

/**
 * Opens a session after a real CAPTCHA solve.
 *
 * Overwrites any existing session rather than extending it, so budget
 * cannot be accumulated by solving repeatedly - each solve buys exactly
 * one session's worth, never more.
 */
async function startVoteSession(auth, data, verifyToken) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const token = data?.turnstileToken;
  if (!token) {
    throw new HttpsError("invalid-argument", "turnstileToken is required.");
  }
  if (!await verifyToken(token)) {
    throw new HttpsError("permission-denied", "CAPTCHA verification failed.");
  }

  const now = Date.now();
  const expiresAt = Timestamp.fromMillis(now + SESSION_TTL_MS);
  await sessionRef(auth.uid).set({
    votesRemaining: SESSION_VOTE_BUDGET,
    expiresAt,
    startedAt: FieldValue.serverTimestamp(),
  });

  return {
    votesRemaining: SESSION_VOTE_BUDGET,
    expiresAtMs: expiresAt.toMillis(),
  };
}

/**
 * Spends one vote from the caller's session, or reports that there isn't
 * a usable one.
 *
 * Spent in a TRANSACTION. Without it, two votes cast in quick succession
 * from a scrolling feed can both read the same remaining count and both
 * write budget-1, so a 25-vote session quietly stretches further than its
 * ceiling - which is the entire limit being circumvented by ordinary use
 * rather than by an attacker.
 */
async function spendVote(uid, nowMs = Date.now()) {
  const db = getFirestore();
  const ref = sessionRef(uid);
  try {
    return await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      const session = snap.exists ? snap.data() : null;
      if (!sessionUsable(session, nowMs)) return {ok: false};
      tx.update(ref, {votesRemaining: FieldValue.increment(-1)});
      return {ok: true, votesRemaining: (Number(session.votesRemaining) || 0) - 1};
    });
  } catch (e) {
    // A failed session read must not become a free vote.
    console.error(`spendVote failed for ${uid}:`, e.message);
    return {ok: false};
  }
}

/** How much of a session is left, for the client to know when to
 * re-challenge before the next vote rather than after a rejection. */
async function getVoteSession(auth) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const snap = await sessionRef(auth.uid).get();
  const session = snap.exists ? snap.data() : null;
  const usable = sessionUsable(session, Date.now());
  return {
    active: usable,
    votesRemaining: usable ? Number(session.votesRemaining) || 0 : 0,
    expiresAtMs: usable ? session.expiresAt?.toMillis?.() ?? 0 : 0,
  };
}

module.exports = {
  startVoteSession,
  getVoteSession,
  spendVote,
  sessionUsable,
  SESSION_TTL_MS,
  SESSION_VOTE_BUDGET,
};
