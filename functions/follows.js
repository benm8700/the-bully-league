const {onDocumentCreated, onDocumentDeleted} =
  require("firebase-functions/v2/firestore");
const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {HttpsError} = require("firebase-functions/v2/https");

/**
 * Fame: the follower system, and the app's second axis.
 *
 * Rank answers "how good are you"; fame answers "how much of a draw are
 * you." They are deliberately DIFFERENT axes (skill vs popularity), which is
 * why a public follower count and a Fame board are wanted here even though a
 * second SKILL/title ladder is not - see CLAUDE.md's fame notes and the
 * one-status-ladder rule.
 *
 * WHAT MAKES FAME UN-FARMABLE IN V1: it carries no rewards, no currency and
 * no gameplay power. The honest payoff of followers is that they are your
 * live CROWD - they get pushed when you battle in the gauntlet and show up to
 * watch - plus the visible count, the board, and milestone recognition. A
 * farmed follow that never watches adds nothing real, so there is little
 * reason to farm.
 *
 * SHAPE: a follow is a client-written own-doc at
 * `follows/{targetUid}/followers/{followerUid}` (firestore.rules makes it
 * own-write only, so one account can only ever add one follower to a target).
 * The authoritative `followerCount` on the target's user doc is maintained
 * HERE by triggers, never client-writable, so the Fame board cannot be
 * inflated beyond one-per-account.
 */

/** Follower counts that earn a celebratory popup, ascending. Placeholders in
 * the same sense as the rank thresholds - tune once there is real volume. */
const MILESTONES = [10, 50, 100, 500, 1000];

/** On-brand fame lines, one per milestone. Celebratory, a little cocky -
 * this is the roadmap to fame, and crossing a rung should feel like arriving.
 */
const MILESTONE_COPY = {
  10: "10 followers. You have a following now. Small, loyal, easily disappointed.",
  50: "50 followers. That is a room. A small, weird room, but a room.",
  100: "100 followers. Triple digits. You are officially somebody's favourite.",
  500: "500 followers. That is a crowd. People show up to watch YOU now.",
  1000: "1,000 followers. Four figures. You are not a player any more, you are a draw.",
};

/** The highest milestone this count has crossed, or 0 if none. PURE. */
function milestoneFor(count) {
  let best = 0;
  for (const m of MILESTONES) {
    if (count >= m) best = m;
  }
  return best;
}

/** Adjust a target's followerCount by delta, floored at 0. In a transaction
 * so two rapid follows/unfollows cannot read the same value and lose one. */
async function _bumpFollowerCount(targetUid, delta) {
  const db = getFirestore();
  const ref = db.collection("users").doc(targetUid);
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) return; // target deleted; nothing to maintain
    const current = Number(snap.data().followerCount) || 0;
    tx.update(ref, {followerCount: Math.max(0, current + delta)});
  });
}

exports.onFollowCreated = onDocumentCreated(
    "follows/{targetUid}/followers/{followerUid}",
    async (event) => {
      const {targetUid, followerUid} = event.params;
      if (targetUid === followerUid) return; // self-follow guard (rules also block)
      try {
        await _bumpFollowerCount(targetUid, +1);
      } catch (e) {
        console.error("onFollowCreated failed:", e.message);
      }
    });

exports.onFollowDeleted = onDocumentDeleted(
    "follows/{targetUid}/followers/{followerUid}",
    async (event) => {
      const {targetUid} = event.params;
      try {
        await _bumpFollowerCount(targetUid, -1);
      } catch (e) {
        console.error("onFollowDeleted failed:", e.message);
      }
    });

/**
 * The pending fame-milestone popup for the caller, mirroring
 * getPendingRankChange: compute the highest milestone the current follower
 * count has crossed, and return it only if it exceeds the last one shown.
 *
 * The FIRST look records the current milestone SILENTLY (like a brand-new
 * account's rank), so shipping this never retroactively fires a popup for a
 * count someone already had.
 */
async function getPendingFameMilestone(auth) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const db = getFirestore();
  const ref = db.collection("users").doc(auth.uid);
  const snap = await ref.get();
  const user = snap.data() || {};
  const count = Number(user.followerCount) || 0;
  const reached = milestoneFor(count);

  const seen = user.lastSeenFameMilestone;
  if (seen === undefined || seen === null) {
    // Record silently on first look - no retroactive celebration.
    await ref.update({lastSeenFameMilestone: reached});
    return {milestone: null};
  }
  if (reached <= Number(seen)) return {milestone: null};

  // Mark seen BEFORE returning, so a popup never replays on every launch.
  await ref.update({lastSeenFameMilestone: reached});
  return {milestone: reached, count, line: MILESTONE_COPY[reached] || null};
}

/** The uids following a performer (read server-side; the followers list is
 * not client-readable). Bounded so one wildly-followed account cannot make a
 * single notification job read unboundedly. */
async function _followerUidsOf(targetUid, limit = 2000) {
  const db = getFirestore();
  const snap = await db.collection("follows").doc(targetUid)
      .collection("followers").limit(limit).get();
  return snap.docs.map((d) => d.id);
}

/**
 * Notify a performer's followers that they are battling in tonight's
 * gauntlet - the payoff that makes followers worth wanting: your fans get
 * pulled in to watch you perform live.
 *
 * DEDUPED once per performer per tournament (their first pairing that night),
 * claimed BEFORE sending, so a followed comedian never blasts their fans
 * every round into muting the whole category. Best-effort: a push failing
 * must never affect the pairing that triggered it.
 */
async function notifyFollowersOfGauntletPairing(tournamentId, performerUids) {
  if (!tournamentId || !Array.isArray(performerUids)) return;
  const db = getFirestore();
  const {sendToUsers} = require("./notifications");
  for (const uid of performerUids) {
    try {
      const markerRef = db.collection("tournaments").doc(tournamentId)
          .collection("fameNotified").doc(uid);
      // Claim the marker transactionally; if it already exists this
      // performer's followers were already told tonight.
      const claimed = await db.runTransaction(async (tx) => {
        const m = await tx.get(markerRef);
        if (m.exists) return false;
        tx.set(markerRef, {at: FieldValue.serverTimestamp()});
        return true;
      });
      if (!claimed) continue;

      const followers = await _followerUidsOf(uid);
      if (followers.length === 0) continue;
      const perf = (await db.collection("users").doc(uid).get()).data() || {};
      const name = perf.username || "Someone you follow";
      await sendToUsers(followers, {
        title: `${name} is up now`,
        body: `${name} is battling in tonight's tournament. Come watch.`,
        category: "followed_performer",
        data: {type: "gauntlet", tournamentId, performerUid: uid},
      });
    } catch (e) {
      console.error(`notifyFollowersOfGauntletPairing ${uid} failed:`, e.message);
    }
  }
}

/**
 * Notify both participants' followers that a new clip of them has been
 * published - the "new video dropped" trigger. Naturally rare, since
 * publishing is a deliberate human gate. Deduped by a flag on the match so a
 * re-publish does not re-notify. Best-effort.
 */
async function notifyFollowersOfClip(matchId, participantUids) {
  if (!matchId || !Array.isArray(participantUids)) return;
  const db = getFirestore();
  const {sendToUsers} = require("./notifications");
  const matchRef = db.collection("matches").doc(matchId);
  try {
    const claimed = await db.runTransaction(async (tx) => {
      const m = await tx.get(matchRef);
      if (!m.exists) return false;
      if (m.data().fameClipNotified === true) return false;
      tx.update(matchRef, {fameClipNotified: true});
      return true;
    });
    if (!claimed) return;
  } catch (e) {
    console.error(`notifyFollowersOfClip claim ${matchId} failed:`, e.message);
    return;
  }
  for (const uid of participantUids) {
    if (!uid) continue;
    try {
      const followers = await _followerUidsOf(uid);
      if (followers.length === 0) continue;
      const perf = (await db.collection("users").doc(uid).get()).data() || {};
      const name = perf.username || "Someone you follow";
      await sendToUsers(followers, {
        title: `${name} dropped a new clip`,
        body: `A new battle of ${name}'s just went up. Go watch it.`,
        category: "followed_performer",
        data: {type: "clip", matchId, performerUid: uid},
      });
    } catch (e) {
      console.error(`notifyFollowersOfClip ${uid} failed:`, e.message);
    }
  }
}

module.exports.getPendingFameMilestone = getPendingFameMilestone;
module.exports.notifyFollowersOfGauntletPairing = notifyFollowersOfGauntletPairing;
module.exports.notifyFollowersOfClip = notifyFollowersOfClip;
module.exports.milestoneFor = milestoneFor;
module.exports.MILESTONES = MILESTONES;
module.exports.MILESTONE_COPY = MILESTONE_COPY;
