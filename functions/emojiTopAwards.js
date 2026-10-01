/**
 * Permanent "ever been #1 in an emoji" awards.
 *
 * A scheduled sweep finds the current top holder of each of the four emojis
 * (🔥 fire / 🧠 clever / 🥱 boring / 💩 trash) and stamps a PERMANENT flag on
 * that account - `emojiTopAwards.<key> = true`. Once set it is NEVER cleared,
 * so the award is earned-and-kept: being #1 even briefly earns it forever, and
 * as the lead changes hands over time MANY different players collect it. That
 * is the whole point over a single live crown - a live "#1 right now" title is
 * only ever held by four people at once, which "doesn't go around" in a big
 * userbase; a permanent award accumulates holders.
 *
 * The flag is the source of truth for the matching Awards badge on the client
 * (emoji_top_fire / _clever / _boring / _trash in lib/core/badges/badges.dart).
 * It is server-only in firestore.rules - it is DERIVED from emojiCounts, which
 * is itself server-only, so a client must not be able to crown itself. The
 * client earned-check reads ONLY this flag for these four badges (it filters
 * them out of the client-writable `badges.earned` set).
 *
 * Cost is trivial: four single-field limit-1 queries per run (the same
 * `where('emojiCounts.<key>', '>', 0).orderBy(... 'desc')` the APPLAUSE board
 * uses, so no composite index), and a write only when the leader changes.
 */
const {getFirestore} = require("firebase-admin/firestore");

/** The four emoji keys, in display order. */
const EMOJI_AWARD_KEYS = ["fire", "clever", "boring", "trash"];

/**
 * True when this account should have the award stamped - i.e. it does not
 * already hold it. Pure, for tests and to keep the sweep idempotent (an
 * account that already holds an award is never re-written).
 */
function needsAward(userAwards, key) {
  const awards =
      userAwards && typeof userAwards === "object" ? userAwards : {};
  return awards[key] !== true;
}

/**
 * Finds the current #1 holder of each emoji and permanently stamps the award.
 * Each emoji is handled independently so one failing query never blocks the
 * others. Returns a per-emoji summary for the scheduler log.
 */
async function awardEmojiTopTitles() {
  const db = getFirestore();
  const result = {};
  for (const key of EMOJI_AWARD_KEYS) {
    try {
      const snap = await db
          .collection("users")
          .where(`emojiCounts.${key}`, ">", 0)
          .orderBy(`emojiCounts.${key}`, "desc")
          .limit(1)
          .get();
      if (snap.empty) {
        result[key] = {leader: null};
        continue;
      }
      const doc = snap.docs[0];
      if (needsAward(doc.get("emojiTopAwards"), key)) {
        await doc.ref.set({emojiTopAwards: {[key]: true}}, {merge: true});
        result[key] = {leader: doc.id, awarded: true};
      } else {
        result[key] = {leader: doc.id, awarded: false};
      }
    } catch (e) {
      result[key] = {error: String((e && e.message) || e)};
    }
  }
  return result;
}

module.exports = {awardEmojiTopTitles, needsAward, EMOJI_AWARD_KEYS};
