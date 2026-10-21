const {getFirestore} = require("firebase-admin/firestore");

/**
 * The FOUNDER (house) account - single source of truth.
 *
 * One designated account (config/founder.uid) is the developer's own house
 * account. It drives three behaviours so they can never point at different
 * accounts:
 *   1. every new signup auto-follows it (see follows.js onUserCreated), so the
 *      fame feed is never empty and the community sees the founder is present;
 *   2. it is exempt from Main Stage QUALIFYING and the judge LOTTERY (built
 *      after the 2026-10-22 capture - the house account should not qualify into
 *      the finals it runs, nor be a random autofill judge); and
 *   3. it is the default permanent HEAD JUDGE.
 * It is deliberately NOT exempt from GOAT - that is earned by real rated play +
 * community vote, so the founder holding it is honest and a good "watch me
 * grow" story (developer's call).
 *
 * Stored in config (client-read, server-write) so it can be re-pointed without
 * a deploy, and read fresh rather than hardcoded in each consumer.
 */
async function getFounderUid(db = getFirestore()) {
  const snap = await db.collection("config").doc("founder").get();
  const uid = snap.exists ? snap.data().uid : null;
  return (typeof uid === "string" && uid) ? uid : null;
}

/** PURE guard: a new account should auto-follow the founder unless there is no
 * configured founder, or the new account IS the founder. */
function shouldAutoFollow(founderUid, newUid) {
  return !!founderUid && !!newUid && founderUid !== newUid;
}

module.exports = {getFounderUid, shouldAutoFollow};
