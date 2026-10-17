const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {HttpsError} = require("firebase-functions/v2/https");
const {normalizeE164} = require("./phoneSignup");

/**
 * Challenge a specific person to a battle (CLAUDE.md's Friend Battles).
 *
 * WHY THIS MATTERS MORE THAN IT LOOKS, and especially now. Every other
 * way into a match pairs you with a stranger, which needs a stranger to
 * be awake and in the app. The private beta is a handful of friends -
 * the one group who emphatically DO want to battle each other on purpose,
 * and for whom random matchmaking is at its thinnest. This is the only
 * path that works reliably with five users.
 *
 * WHAT THE APP ADDS OVER JUST RINGING THEM UP, which is the real question
 * a friend battle has to answer: structure (a timed, mic-muted, judged
 * format rather than two people riffing), an outside verdict, a produced
 * clip, and a route into the feed. A video call gives none of those.
 *
 * THREE CONSTRAINTS, all decided rather than incidental:
 *   - It is FREE, at every tier. CLAUDE.md is explicit that this is not a
 *     premium feature. Challenging by USERNAME rather than through the
 *     player directory is what keeps that true - the directory is the
 *     subscriber feature, and knowing your friend's name is not.
 *   - It never touches rating. You pick your opponent, so counting it
 *     would be the collusion vector the ranked ladder is built to avoid.
 *   - It IS recorded, judged and clipped - the explicit exception to
 *     "exhibition is never recorded".
 */

/** How long an unanswered challenge stands. This is a "battle now?"
 * invitation, not an appointment: the whole design of this app avoids
 * asking two people to agree a time (see CLAUDE.md's Async Matchmaking
 * Revision, where scheduling was considered and rejected). An hour is
 * long enough to notice a push and come back, short enough that accepting
 * one never means walking into a match the other person has forgotten
 * about. */
const CHALLENGE_TTL_MS = 60 * 60 * 1000;

/** Outstanding challenges one person may have out at once.
 *
 * This is the anti-spam limit, and it is on the SENDER rather than the
 * recipient on purpose: capping what you can receive would let one
 * determined person fill your quota and block your actual friends. */
const MAX_OUTSTANDING = 3;

/** A challenge nobody could ever be told about is a challenge that will
 * never be answered - see the standing-challenge rule, where an entry with
 * no registered device turned out to poison the pool. Not fatal here (the
 * app shows incoming challenges on Home), so this is a warning rather than
 * a refusal. */
function isExpired(challenge, nowMs) {
  return nowMs >= (Number(challenge?.expiresAtMs) || 0);
}

/** Whether a challenge is still awaiting an answer at this moment. */
function isPending(challenge, nowMs) {
  return challenge?.status === "pending" && !isExpired(challenge, nowMs);
}

/**
 * Whether this pair may be matched at all.
 *
 * PURE, so the rules are testable without Firestore. Blocks are honoured
 * from EITHER side, exactly as matchmaking and the player directory do -
 * a block that only stopped the blocked person from initiating would be
 * useless, since the whole point is not to be put in front of them.
 */
function challengeProblem({fromUid, from, toUid, to, outstanding, nowMs}) {
  if (!to) return "We couldn't find that player.";
  if (fromUid === toUid) return "You can't challenge yourself.";
  if (to.accountStatus === "banned") {
    // Deliberately the same message as "no such player". Confirming that
    // a named account exists but is banned tells a stranger something
    // about that person which is none of their business.
    return "We couldn't find that player.";
  }
  const blockedByThem = (to.blockedUserIds ?? []).includes(fromUid);
  const blockedByMe = (from?.blockedUserIds ?? []).includes(toUid);
  if (blockedByThem || blockedByMe) {
    // Same message again, for the same reason - and here it matters more:
    // telling someone "they blocked you" invites exactly the retaliation
    // blocking exists to prevent, which is why blocking is silent.
    return "We couldn't find that player.";
  }
  if (outstanding >= MAX_OUTSTANDING) {
    return `You already have ${MAX_OUTSTANDING} challenges out. ` +
      "Wait for one to be answered.";
  }
  return null;
}

/** The match id a challenge turns into. Derived rather than generated, so
 * two taps cannot produce two documents for one challenge and leave each
 * player alone in a different channel. Same reasoning as tournament
 * matches. */
function friendMatchId(challengeId) {
  return `f_${challengeId}`;
}

/**
 * Challenging a phone number that has no account yet: stash a pending invite
 * keyed by the normalized number, and tell the client to text them a download
 * link. When they sign up and verify that number, finalizePhoneSignup finds
 * this record and mints the real challenge. De-duped per (from, number) so a
 * double-tap doesn't pile up invites.
 */
async function inviteByPhone(db, fromUid, phone, nowMs) {
  const fromSnap = await db.collection("users").doc(fromUid).get();
  const fromUsername = fromSnap.data()?.username ?? "A player";
  const existing = await db.collection("phoneChallenges")
      .where("fromUid", "==", fromUid)
      .where("phone", "==", phone)
      .where("status", "==", "pending")
      .limit(1).get();
  if (existing.empty) {
    await db.collection("phoneChallenges").add({
      fromUid, fromUsername, phone, status: "pending", createdAtMs: nowMs,
    });
  }
  return {needsInvite: true, phone, fromUsername};
}

/**
 * The people this user has recently challenged (distinct, newest first), so
 * the challenge screen can offer a tap-to-rechallenge quick-pick instead of
 * making them retype a name every time.
 */
async function getRecentChallengeTargets(auth) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const db = getFirestore();
  const snap = await db.collection("challenges")
      .where("fromUid", "==", auth.uid).get();
  // Sorted in memory by expiry (newest challenge expires latest) to avoid a
  // composite index; distinct target, capped.
  const sorted = snap.docs
      .map((d) => d.data())
      .filter((c) => c.toUid)
      .sort((a, b) => (Number(b.expiresAtMs) || 0) - (Number(a.expiresAtMs) || 0));
  const seen = new Set();
  const uids = [];
  for (const c of sorted) {
    if (seen.has(c.toUid)) continue;
    seen.add(c.toUid);
    uids.push(c.toUid);
    if (uids.length >= 8) break;
  }
  const people = await Promise.all(uids.map(async (id) => {
    const s = await db.collection("users").doc(id).get();
    return s.exists ? {uid: id, username: s.data()?.username ?? "Unknown"} : null;
  }));
  return {recent: people.filter((p) => p !== null)};
}

/**
 * Send a challenge to a player - by username, by uid (rematch), or by phone
 * number (resolving to an account, or falling back to an SMS invite).
 */
async function challengeFriend(auth, data) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");

  const db = getFirestore();
  const fromUid = auth.uid;
  const nowMs = Date.now();

  const username = typeof data?.username === "string" ? data.username.trim() : "";
  const toUidInput = typeof data?.toUid === "string" ? data.toUid.trim() : "";
  const phoneInput = typeof data?.phone === "string" ? data.phone.trim() : "";
  if (!username && !toUidInput && !phoneInput) {
    throw new HttpsError("invalid-argument", "Who do you want to challenge?");
  }

  // Resolve the target three ways:
  //  - toUid: a direct uid (used by Rematch, where we already know the person)
  //  - username: resolved through usernameLower (renames break nothing)
  //  - phone: an account on that number - or, if nobody is here yet, an SMS
  //    invite instead (finalizePhoneSignup turns a pending phoneChallenge into
  //    a real challenge the moment they sign up with that number).
  let target = null;
  if (toUidInput) {
    const snap = await db.collection("users").doc(toUidInput).get();
    target = snap.exists ? snap : null;
  } else if (username) {
    const found = await db.collection("users")
        .where("usernameLower", "==", username.toLowerCase())
        .limit(1).get();
    target = found.empty ? null : found.docs[0];
  } else {
    const phone = normalizeE164(phoneInput);
    if (!phone) {
      throw new HttpsError("invalid-argument",
          "That doesn't look like a valid phone number.");
    }
    const found = await db.collection("users")
        .where("phoneNumber", "==", phone).limit(1).get();
    if (found.empty) return inviteByPhone(db, fromUid, phone, nowMs);
    target = found.docs[0];
  }

  const [fromSnap, outstandingSnap] = await Promise.all([
    db.collection("users").doc(fromUid).get(),
    db.collection("challenges")
        .where("fromUid", "==", fromUid)
        .where("status", "==", "pending")
        .get(),
  ]);

  const outstanding = outstandingSnap.docs
      .filter((d) => !isExpired(d.data(), nowMs)).length;

  const problem = challengeProblem({
    fromUid,
    from: fromSnap.data() ?? {},
    toUid: target?.id ?? null,
    to: target?.data() ?? null,
    outstanding,
    nowMs,
  });
  if (problem) throw new HttpsError("failed-precondition", problem);

  // One live challenge per pair. Re-sending is a no-op that returns the
  // existing one rather than an error - tapping twice because the first
  // did not visibly do anything is normal, and two identical challenges
  // in someone's list is just confusing.
  const existing = outstandingSnap.docs.find(
      (d) => d.data().toUid === target.id && !isExpired(d.data(), nowMs));
  if (existing) {
    return {challengeId: existing.id, alreadySent: true,
      expiresAtMs: existing.data().expiresAtMs};
  }

  const ref = db.collection("challenges").doc();
  await ref.set({
    fromUid,
    toUid: target.id,
    fromUsername: fromSnap.data()?.username ?? "A player",
    status: "pending",
    createdAt: FieldValue.serverTimestamp(),
    expiresAtMs: nowMs + CHALLENGE_TTL_MS,
  });

  // Best-effort, exactly like the match-found push: a challenge that
  // cannot be pushed is still visible on Home, so a failed send must
  // never fail the challenge.
  try {
    const {sendToUsers} = require("./notifications");
    await sendToUsers([target.id], {
      category: "match_found",
      title: `${fromSnap.data()?.username ?? "Someone"} challenged you`,
      body: "They want to battle you specifically. Open the app.",
      data: {kind: "challenge", challengeId: ref.id},
    });
  } catch (e) {
    console.error("challenge push failed:", e.message);
  }

  return {challengeId: ref.id, alreadySent: false,
    expiresAtMs: nowMs + CHALLENGE_TTL_MS};
}

/**
 * Accept or decline a challenge sent to you.
 *
 * Accepting creates the match; declining just closes it. There is no
 * penalty either way and no skip is spent - a skip is for declining a
 * stranger the matchmaker chose for you, and refusing a specific person
 * who asked is a different thing entirely.
 */
async function respondToChallenge(auth, data) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const {challengeId, accept} = data || {};
  if (!challengeId) {
    throw new HttpsError("invalid-argument", "challengeId is required.");
  }

  const db = getFirestore();
  const uid = auth.uid;
  const nowMs = Date.now();
  const ref = db.collection("challenges").doc(challengeId);
  const snap = await ref.get();
  if (!snap.exists) throw new HttpsError("not-found", "Challenge not found.");
  const challenge = snap.data();

  if (challenge.toUid !== uid) {
    throw new HttpsError("permission-denied", "That isn't your challenge.");
  }
  if (!isPending(challenge, nowMs)) {
    throw new HttpsError("failed-precondition",
        isExpired(challenge, nowMs) ?
          "That challenge expired." : "That challenge is already answered.");
  }

  if (accept !== true) {
    await ref.update({status: "declined", respondedAt: nowMs});
    return {accepted: false};
  }

  const {getMatchSettings} = require("./matchSettings");
  const settings = await getMatchSettings("friend");
  const matchId = friendMatchId(challengeId);
  const matchRef = db.collection("matches").doc(matchId);

  await db.runTransaction(async (tx) => {
    const existing = await tx.get(matchRef);
    if (existing.exists) return;
    tx.set(matchRef, {
      // The challenger is player1, so both clients agree on the fixed
      // Agora uids without negotiating.
      player1Id: challenge.fromUid,
      player2Id: uid,
      mode: "friend",
      settings,
      // Never counts toward the daily window bonus: that bonus is for
      // turning up to Sixes and Sevens and battling whoever is there, and
      // a pre-arranged battle with a friend is not that.
      eventWindow: {qualified: false, name: null},
      origin: "challenge",
      challengeId,
      status: "pending",
      channelName: `match_${matchId}`,
      createdAt: FieldValue.serverTimestamp(),
      completedAt: null,
      voteFinalized: false,
      winnerId: null,
      voteCount: 0,
      readyPlayerIds: [],
    });
  });

  await ref.update({status: "accepted", respondedAt: nowMs, matchId});

  // Tells the challenger their challenge was taken up, which is the whole
  // point of having sent it - without this they would have to keep
  // checking.
  try {
    const {sendToUsers} = require("./notifications");
    const me = await db.collection("users").doc(uid).get();
    await sendToUsers([challenge.fromUid], {
      category: "match_found",
      title: `${me.data()?.username ?? "They"} accepted`,
      body: "Your battle is ready. Open the app.",
      data: {kind: "challenge_accepted", matchId},
    });
  } catch (e) {
    console.error("challenge-accepted push failed:", e.message);
  }

  return {accepted: true, matchId};
}

/**
 * Challenges waiting for me, and the ones I have sent.
 *
 * Expiry is applied on READ rather than by a scheduled sweep. A challenge
 * lives an hour and is only ever looked at by the two people involved, so
 * a sweep would be a job running every few minutes to tidy something
 * nobody can see - the cost of a filter here is nothing by comparison.
 */
async function getMyChallenges(auth) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const db = getFirestore();
  const uid = auth.uid;
  const nowMs = Date.now();

  // A THIRD query for challenges the target has ACCEPTED - without it the
  // challenger never learns their challenge was taken up. Accepting moves
  // the challenge from "pending" to "accepted", so it drops out of the
  // outgoing-pending list entirely; the challenger's "Waiting on X" simply
  // vanishes with no way into the match that was just created for them.
  // This is the client half of getChallengeMatch, which exists precisely so
  // "the acceptor's opponent can join the match they never explicitly
  // started". Same fromUid+status equality shape as the pending query, so
  // it needs no new index. Bounded by isExpired to the last hour, so it does
  // not read every friend battle the user has ever started - fine at beta
  // scale; revisit if a user accumulates many in an hour.
  const [incoming, outgoing, accepted] = await Promise.all([
    db.collection("challenges")
        .where("toUid", "==", uid).where("status", "==", "pending").get(),
    db.collection("challenges")
        .where("fromUid", "==", uid).where("status", "==", "pending").get(),
    db.collection("challenges")
        .where("fromUid", "==", uid).where("status", "==", "accepted").get(),
  ]);

  const live = (snap) => snap.docs
      .filter((d) => !isExpired(d.data(), nowMs))
      .map((d) => ({id: d.id, ...d.data()}));

  // ONE challenge per other-person, each direction. Even though a re-send is
  // deduped at creation, a stale state can still leave more than one around -
  // most commonly an "accepted" challenge whose battle is long over sitting
  // alongside a fresh "pending" one, which is the "multiple challenges between
  // the same two users" the developer saw. Keep the latest-expiring (newest).
  const newestPer = (list, keyField) => {
    const byKey = new Map();
    for (const c of list) {
      const prev = byKey.get(c[keyField]);
      if (!prev ||
          (Number(c.expiresAtMs) || 0) > (Number(prev.expiresAtMs) || 0)) {
        byKey.set(c[keyField], c);
      }
    }
    return [...byKey.values()];
  };

  const incomingLive = newestPer(live(incoming), "fromUid");
  const outgoingLive = newestPer(live(outgoing), "toUid");

  // An accepted challenge stays "accepted" forever on its own - nothing closes
  // it when its match ends. So surface only the ones whose match is STILL
  // joinable, and CLOSE the rest authoritatively: when the battle is over,
  // mark the challenge "completed" so it drops out of the "accepted" query
  // entirely (no dead "Battle now" lingering, and no repeated match read on
  // later calls). This is the single place that covers every settle path -
  // completeMatch, the both-left abandon, a forfeit - because it keys off the
  // match's own status rather than hooking each. Best-effort: a failed close
  // just means it gets filtered on read again next time.
  const acceptedCandidates = newestPer(live(accepted), "toUid");
  const acceptedLive = [];
  await Promise.all(acceptedCandidates.map(async (c) => {
    const mid = c.matchId ?? friendMatchId(c.id);
    const ms = await db.collection("matches").doc(mid).get();
    const status = ms.data()?.status;
    if (status === "pending" || status === "in_progress") {
      acceptedLive.push(c);
    } else {
      await db.collection("challenges").doc(c.id)
          .update({status: "completed", closedAtMs: nowMs})
          .catch(() => {});
    }
  }));

  // Names are resolved here rather than trusted from the challenge, for
  // the outgoing directions at least - the target may have renamed
  // themselves since.
  const names = new Map();
  const uids = [...new Set(
      [...outgoingLive, ...acceptedLive].map((c) => c.toUid))];
  await Promise.all(uids.map(async (id) => {
    const s = await db.collection("users").doc(id).get();
    names.set(id, s.data()?.username ?? "Unknown");
  }));

  return {
    incoming: incomingLive.map((c) => ({
      challengeId: c.id,
      // fromUid lets a client match an incoming challenge to a specific
      // opponent (the rematch flow needs this to know a challenge is from the
      // person it just battled, not some other pending challenge).
      fromUid: c.fromUid,
      fromUsername: c.fromUsername ?? "A player",
      expiresAtMs: c.expiresAtMs,
    })),
    outgoing: outgoingLive.map((c) => ({
      challengeId: c.id,
      toUid: c.toUid,
      toUsername: names.get(c.toUid) ?? "Unknown",
      expiresAtMs: c.expiresAtMs,
    })),
    // The challenger's way into an accepted battle - only while it is live.
    accepted: acceptedLive.map((c) => ({
      challengeId: c.id,
      // toUid so the rematch poll can confirm the accepted battle is against
      // the opponent it is waiting on.
      toUid: c.toUid,
      toUsername: names.get(c.toUid) ?? "Unknown",
      matchId: c.matchId ?? friendMatchId(c.id),
    })),
  };
}

/**
 * The pairing shape for a challenge already accepted, so the acceptor's
 * opponent can join the match they never explicitly started.
 */
async function getChallengeMatch(auth, data) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const {matchId} = data || {};
  if (!matchId) {
    throw new HttpsError("invalid-argument", "matchId is required.");
  }
  const db = getFirestore();
  const snap = await db.collection("matches").doc(matchId).get();
  if (!snap.exists) throw new HttpsError("not-found", "Match not found.");
  const match = snap.data();
  const uid = auth.uid;
  if (match.player1Id !== uid && match.player2Id !== uid) {
    throw new HttpsError("permission-denied", "That isn't your battle.");
  }
  return {
    matchId,
    channelName: match.channelName,
    opponentId: match.player1Id === uid ? match.player2Id : match.player1Id,
    mode: match.mode,
    settings: match.settings,
    agoraUid: match.player1Id === uid ? 1 : 2,
    status: match.status,
  };
}

module.exports = {
  challengeFriend,
  respondToChallenge,
  getMyChallenges,
  getChallengeMatch,
  getRecentChallengeTargets,
  // Exported for tests.
  challengeProblem,
  isPending,
  isExpired,
  friendMatchId,
  CHALLENGE_TTL_MS,
  MAX_OUTSTANDING,
};
