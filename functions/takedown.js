const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {HttpsError} = require("firebase-functions/v2/https");
const {voteWindowEndMs} = require("./matchFinalization");

/**
 * A participant's objection to their own match footage being public.
 *
 * TWO CHANNELS, DELIBERATELY BEHAVING DIFFERENTLY. This split is the whole
 * design and everything else follows from it:
 *
 *   PREFERENCE - "I'd rather this wasn't posted." A deadline applies (the
 *   end of the voting window) and a monthly cap applies. Deciding BEFORE
 *   the result is known means the choice is made on "am I comfortable with
 *   this being public" rather than "I lost, delete it".
 *
 *   HARM - "this is hurting me." Harassment, brigading, doxxing, a factual
 *   claim dressed as a joke. NO deadline, NO cap, NO friction, ever. Harm
 *   surfaces weeks later precisely BECAUSE a clip spread, so a deadline
 *   here would deny the cases that matter most. Apple's Guideline 1.2
 *   requires an accessible flagging mechanism and GDPR consent-withdrawal
 *   cannot be gated, so obstructing this channel is a compliance problem as
 *   well as the wrong thing to do.
 *
 * Honoured UNCONDITIONALLY for your own footage - not at admin discretion.
 * It costs one clip, and it is a strong trust signal for an app whose whole
 * premise is letting a stranger humiliate you on camera. It is also a much
 * better answer to a store reviewer than "we review case by case".
 */

/** Preference requests per calendar month. Published openly like the skip
 * cap rather than being hidden friction. */
const PREFERENCE_CAP_PER_MONTH = 2;

/** Routing, not friction - it makes bad-faith use of the harm channel
 * visible without gating anyone at the moment of asking. */
const HARM_REASONS = ["harassment", "doxxing", "false_claim", "brigading", "other"];

function monthKey(nowMs) {
  return new Date(nowMs).toISOString().slice(0, 7);
}

/**
 * Whether a preference request is still in time.
 *
 * Pure, so the deadline is testable without Firestore.
 */
function preferenceWindowOpen(match, nowMs) {
  return nowMs < voteWindowEndMs(match);
}

/**
 * How many preference requests this user has left this month.
 *
 * A record from a previous month says nothing about this one.
 */
function preferenceRemaining(user, nowMs, cap = PREFERENCE_CAP_PER_MONTH) {
  const record = user?.takedowns;
  if (!record || record.monthKey !== monthKey(nowMs)) return cap;
  return Math.max(0, cap - (Number(record.count) || 0));
}

/**
 * Whether a match may be published to a public audience.
 *
 * TWO independent blocks, both hard, both enforced in code rather than left
 * to an admin remembering:
 *
 *  1. ANY participant objection stops it, whichever channel it came from.
 *  2. Publishing is refused while the objection window is still open, so
 *     nothing can reach a public audience before both players have had
 *     their full chance to opt out. Collecting the objection BEFORE
 *     spending on a public post is also the honest answer to "it cost me
 *     money to post it" - the money is never spent on footage that cannot
 *     be used.
 *
 * Pure and exported, because a bug here publishes video of someone who
 * asked for it not to be.
 */
function publishBlockedReason(match, nowMs) {
  if (!match) return "not-found";
  const objections = match.objections;
  if (objections && Object.keys(objections).length > 0) {
    return "participant-objected";
  }
  if (preferenceWindowOpen(match, nowMs)) return "objection-window-open";
  return null;
}

/**
 * Records an objection, and revokes any existing publication immediately.
 *
 * Revocation is the point: a takedown that only prevented FUTURE publishing
 * would do nothing for the person whose clip is already out, which is
 * exactly when someone asks.
 */
async function requestTakedown(auth, data) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const {matchId, channel, reason} = data || {};
  if (!matchId) throw new HttpsError("invalid-argument", "matchId is required.");
  if (channel !== "preference" && channel !== "harm") {
    throw new HttpsError("invalid-argument", "channel must be preference or harm.");
  }
  if (channel === "harm" && !HARM_REASONS.includes(reason)) {
    throw new HttpsError("invalid-argument", `reason must be one of: ${HARM_REASONS.join(", ")}`);
  }

  const db = getFirestore();
  const nowMs = Date.now();
  const matchRef = db.collection("matches").doc(matchId);
  const matchSnap = await matchRef.get();
  if (!matchSnap.exists) throw new HttpsError("not-found", "Match not found.");
  const match = matchSnap.data();

  // Only the people IN a battle may object to it. Anyone else who has a
  // problem with a clip uses the ordinary report flow.
  if (auth.uid !== match.player1Id && auth.uid !== match.player2Id) {
    throw new HttpsError("permission-denied", "Only the players in a battle can request this.");
  }

  const userRef = db.collection("users").doc(auth.uid);
  if (channel === "preference") {
    if (!preferenceWindowOpen(match, nowMs)) {
      throw new HttpsError(
          "failed-precondition",
          "The opt-out window for this battle has closed. If the clip is " +
          "causing you harm, report it instead - that has no deadline.",
      );
    }
    const userSnap = await userRef.get();
    if (preferenceRemaining(userSnap.data(), nowMs) <= 0) {
      throw new HttpsError(
          "resource-exhausted",
          `You can opt out of ${PREFERENCE_CAP_PER_MONTH} battles a month. If a ` +
          "clip is causing you harm, report it instead - that is never limited.",
      );
    }
    const key = monthKey(nowMs);
    const current = userSnap.data()?.takedowns;
    await userRef.set({
      takedowns: {
        monthKey: key,
        count: current?.monthKey === key ? (Number(current.count) || 0) + 1 : 1,
      },
    }, {merge: true});
  }

  await matchRef.set({
    objections: {
      [auth.uid]: {
        channel,
        reason: reason ?? null,
        createdAt: FieldValue.serverTimestamp(),
      },
    },
  }, {merge: true});

  // Anyone who PAID for this clip must be made whole - the delivery rule
  // means nothing revocable is ever handed over, so this covers the buyer
  // whose clip was killed before it arrived. An in-app credit, never a
  // store refund. Best-effort: a refund failure must never block a
  // takedown, which is the urgent, rights-affecting half.
  try {
    const {refundClipGrants} = require("./clipGrants");
    await refundClipGrants(matchId, match, auth.uid);
  } catch (e) {
    console.error("clip refunds failed for", matchId, e.message);
  }

  // Revoke now if it is already out. Unconditional means unconditional.
  let revoked = false;
  if (match.highlight?.published === true) {
    const {unpublishHighlight} = require("./publishHighlight");
    await unpublishHighlight(matchId);
    revoked = true;
  }

  // The harm channel also routes into the existing moderation queue, so a
  // human sees it. Honour first, review after - the takedown has already
  // happened by this point and is not waiting on anyone.
  if (channel === "harm") {
    await db.collection("reports").add({
      reporterId: auth.uid,
      reportedUserId: auth.uid === match.player1Id ? match.player2Id : match.player1Id,
      matchId,
      reason: "inappropriate_content",
      details: `Clip takedown (harm): ${reason}`,
      status: "pending",
      createdAt: FieldValue.serverTimestamp(),
    });
  }

  return {ok: true, revoked, channel};
}

/** What the client needs to render the request UI honestly. */
async function getTakedownOptions(auth, data) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const {matchId} = data || {};
  if (!matchId) throw new HttpsError("invalid-argument", "matchId is required.");
  const db = getFirestore();
  const nowMs = Date.now();
  const [matchSnap, userSnap] = await Promise.all([
    db.collection("matches").doc(matchId).get(),
    db.collection("users").doc(auth.uid).get(),
  ]);
  if (!matchSnap.exists) throw new HttpsError("not-found", "Match not found.");
  const match = matchSnap.data();

  return {
    isParticipant: auth.uid === match.player1Id || auth.uid === match.player2Id,
    alreadyObjected: Boolean(match.objections?.[auth.uid]),
    preferenceOpen: preferenceWindowOpen(match, nowMs),
    preferenceRemaining: preferenceRemaining(userSnap.data(), nowMs),
    preferenceCap: PREFERENCE_CAP_PER_MONTH,
    published: match.highlight?.published === true,
    windowEndMs: voteWindowEndMs(match),
  };
}

module.exports = {
  requestTakedown,
  getTakedownOptions,
  publishBlockedReason,
  preferenceWindowOpen,
  preferenceRemaining,
  monthKey,
  PREFERENCE_CAP_PER_MONTH,
  HARM_REASONS,
};
