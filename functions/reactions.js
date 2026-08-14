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
 * THE SET IS WIDE AND INCLUDES NEGATIVE REACTIONS, deliberately. An earlier
 * version allowed only approving ones and that was wrong twice over: it is
 * tonally absurd for an app whose premise is harsh unfiltered comedy, and
 * feedback that can only agree measures how many people watched rather than
 * how good anything was. The crowd already votes that someone LOST a
 * battle, which is a far heavier judgement than any emoji.
 *
 * THE LINE THAT DOES MATTER is performance versus person. "That didn't
 * land", "ice cold", crickets - all judgements of the material, all things
 * comedians actually use. What stays out is contempt aimed at the human
 * rather than the set. Stand-up audiences boo the bit, not the person's
 * worth.
 *
 * AN ALLOWLIST RATHER THAN FREE EMOJI INPUT, and that is a real constraint
 * rather than caution: a field accepting arbitrary characters is a comment
 * box. Someone would type a slur into it within a week, and the entire
 * reason comments are ruled out is to avoid exactly that. A large curated
 * set gets the expressiveness without reopening a text-moderation problem,
 * and it keeps the per-emoji tally bounded instead of growing a new key for
 * every character anyone invents.
 *
 * ONE REACTION PER PERSON PER CLIP, changeable. That keeps the count a
 * measure of how many people felt something rather than of who tapped
 * fastest, and it makes the number meaningful as a caption-selection input.
 */

/** Allowed reactions. Also enforced in firestore.rules, which is the real
 * gate - this is the list the rest of the backend reasons about. Ordered
 * roughly from "that killed" through to "that died". */
const REACTIONS = [
  // It landed.
  "fire", "skull", "coffin", "cold_blooded", "bullseye", "mindblown",
  "cry", "laugh", "clap", "salute",
  // Reactions to the hit itself.
  "shocked", "hide", "oof",
  // It didn't land.
  "ice", "crickets", "yawn", "meh", "thumbsdown",
];

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
