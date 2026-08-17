const {getFirestore} = require("firebase-admin/firestore");
const {HttpsError} = require("firebase-functions/v2/https");

/**
 * Blocking a specific person.
 *
 * THIS WAS DECIDED LONG AGO AND NEVER REACHABLE. `blockedUserIds` is
 * honoured by matchmaking (two-way, so a block works from either side)
 * and by the player directory, but nothing in the app ever wrote it - so
 * both systems were enforcing a list that could only ever be empty. A
 * safety control that exists only in the data model protects nobody.
 *
 * CLAUDE.md is explicit that this is a PERSONAL PREFERENCE TOOL, not a
 * moderation action: it is separate from reporting, needs no
 * justification, and carries no consequence for the person blocked. It
 * simply means those two are never paired again and cannot find each
 * other.
 *
 * SILENT BY DESIGN. The blocked person is never told. Announcing it
 * invites exactly the retaliation the block exists to prevent, and every
 * mature platform treats it the same way.
 */

/**
 * A ceiling on the list, for a mundane reason rather than a policy one:
 * `blockedUserIds` lives on the user document, which is read on every
 * entitlement check, every queue entry and every Home load. An unbounded
 * array would make all of those progressively more expensive.
 *
 * High enough that no honest user will ever notice it.
 */
const MAX_BLOCKED = 200;

/**
 * The new block list, given the current one.
 *
 * Pure, so the rules are testable without Firestore. Idempotent in both
 * directions: blocking someone already blocked, or unblocking someone who
 * was not, is a no-op rather than an error - a retried tap must not fail.
 */
function applyBlock(current, targetUid, blocked, {max = MAX_BLOCKED} = {}) {
  const list = Array.isArray(current) ? current.filter(
      (id) => typeof id === "string" && id) : [];
  const has = list.includes(targetUid);

  if (!blocked) {
    return {list: list.filter((id) => id !== targetUid), changed: has};
  }
  if (has) return {list, changed: false};
  if (list.length >= max) {
    return {list, changed: false, reason: "limit-reached"};
  }
  return {list: [...list, targetUid], changed: true};
}

async function setBlocked(auth, data) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const targetUid = data?.userId;
  const blocked = data?.blocked !== false;
  if (typeof targetUid !== "string" || !targetUid) {
    throw new HttpsError("invalid-argument", "userId is required.");
  }
  if (targetUid === auth.uid) {
    throw new HttpsError("invalid-argument", "You can't block yourself.");
  }

  const db = getFirestore();
  const ref = db.collection("users").doc(auth.uid);

  // A transaction so two rapid taps cannot each read the same list and
  // write conflicting versions of it, which with an array would silently
  // drop one of the changes.
  const result = await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const outcome = applyBlock(
        snap.data()?.blockedUserIds, targetUid, blocked);
    if (outcome.changed) {
      tx.update(ref, {blockedUserIds: outcome.list});
    }
    return outcome;
  });

  if (result.reason === "limit-reached") {
    throw new HttpsError("resource-exhausted",
        `You can block up to ${MAX_BLOCKED} people.`,
        {reason: "limit-reached"});
  }
  return {blocked, count: result.list.length};
}

/**
 * The caller's block list, with enough about each person to recognise
 * them - otherwise unblocking means picking from a list of raw ids.
 *
 * Deliberately ignores those people's directory opt-out: this is not
 * discovery, it is showing someone a list they built themselves, and
 * hiding an entry would leave a block they could never undo.
 */
async function getBlockedPlayers(auth) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const db = getFirestore();
  const snap = await db.collection("users").doc(auth.uid).get();
  const ids = (snap.data()?.blockedUserIds ?? []).filter(
      (id) => typeof id === "string" && id);
  if (ids.length === 0) return {players: []};

  const docs = await Promise.all(ids.map((id) =>
    db.collection("users").doc(id).get()));
  return {
    players: docs.map((d, i) => ({
      uid: ids[i],
      // A deleted account still has to be unblockable, so a missing
      // document degrades to a placeholder rather than vanishing.
      username: d.exists ? (d.data().username ?? "Unknown") : "Deleted account",
    })),
  };
}

module.exports = {setBlocked, getBlockedPlayers, applyBlock, MAX_BLOCKED};
