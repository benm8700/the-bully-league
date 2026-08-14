const {onDocumentWritten} = require("firebase-functions/v2/firestore");
const {getFirestore, FieldValue} = require("firebase-admin/firestore");

/**
 * Emoji reactions on a battle clip.
 *
 * This is what stands in for comments, which are ruled out entirely because
 * the developer does not want them affecting the roasters' mental state.
 * Reactions give a visitor something to do and give the feed a real
 * popularity signal, with no text to moderate, no 24-hour SLA, and nothing
 * anonymous attached to a real person's face.
 *
 * THE SET IS DELIBERATELY ALL-POSITIVE OR INTENSITY-ONLY. A thumbs-down or
 * a pile-of-dung would be a comment section in emoji form - a way for
 * strangers to pile on the person who lost, which is exactly the harm the
 * no-comments decision exists to prevent. Every reaction here says
 * something about how hard a line landed, never that a player is bad.
 *
 * ONE REACTION PER PERSON PER CLIP, changeable. That keeps the count a
 * measure of how many people felt something rather than of who tapped
 * fastest, and it makes the number meaningful as a caption-selection input.
 */

/** Allowed reactions. Also enforced in firestore.rules, so a modified
 * client cannot invent one - the rule is the real gate, this is the list
 * the rest of the backend reasons about. */
const REACTIONS = ["fire", "skull", "cry", "oof"];

/**
 * Keeps a per-emoji tally on the match document.
 *
 * Maintained by a trigger rather than counted on read, because the feed
 * shows these on every card and an aggregation query per clip per scroll
 * would be far more expensive than one increment per reaction.
 *
 * KNOWN SCALING LIMIT: a single document takes roughly one write per
 * second, so a genuinely viral clip would contend on its own counter. That
 * is fine at any volume this app has now, and the fix when it matters is
 * sharded counters - the same trap view counts would hit, noted here so it
 * is a known cost rather than a surprise.
 */
exports.onReactionWritten = onDocumentWritten(
    "matches/{matchId}/reactions/{userId}",
    async (event) => {
      const before = event.data?.before?.data()?.emoji ?? null;
      const after = event.data?.after?.data()?.emoji ?? null;
      if (before === after) return;

      const updates = {};
      // Changing a reaction moves the count rather than adding a second
      // one, which is what keeps one-per-person meaningful.
      if (before && REACTIONS.includes(before)) {
        updates[`reactionCounts.${before}`] = FieldValue.increment(-1);
      }
      if (after && REACTIONS.includes(after)) {
        updates[`reactionCounts.${after}`] = FieldValue.increment(1);
      }
      // Total reactions, kept alongside the breakdown so popularity can be
      // read without summing a map.
      const delta = (after ? 1 : 0) - (before ? 1 : 0);
      if (delta !== 0) updates.reactionTotal = FieldValue.increment(delta);

      if (Object.keys(updates).length === 0) return;
      await getFirestore().collection("matches").doc(event.params.matchId)
          .update(updates)
          .catch((e) => console.error(`reaction tally failed: ${e.message}`));
    });

module.exports.REACTIONS = REACTIONS;
