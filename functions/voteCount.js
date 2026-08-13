const {onDocumentCreated} = require("firebase-functions/v2/firestore");
const {getFirestore, FieldValue} = require("firebase-admin/firestore");

/**
 * Denormalizes a raw voteCount onto the match doc whenever a ballot is
 * cast, so the website's Trending feed (CLAUDE.md's Website homepage /
 * discovery feed decision: "Trending tab... sorted by vote count") can do
 * a cheap `orderBy('voteCount', 'desc')` instead of counting each match's
 * votes/{matchId}/ballots subcollection on every page load. Intentionally
 * a RAW count (each ballot = +1), not the account-age-weighted tally used
 * to actually decide the winner (see castVote/finalizeMatch) - this number
 * is only ever used as an engagement/sort signal, never for judging.
 */
exports.onVoteCast = onDocumentCreated("votes/{matchId}/ballots/{voterId}", async (event) => {
  const {matchId} = event.params;
  await getFirestore()
      .collection("matches")
      .doc(matchId)
      .update({voteCount: FieldValue.increment(1)});
});
