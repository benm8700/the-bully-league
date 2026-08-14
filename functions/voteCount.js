const {onDocumentCreated} = require("firebase-functions/v2/firestore");
const {getFirestore, FieldValue} = require("firebase-admin/firestore");

/**
 * Maintains two denormalized things whenever a ballot is cast.
 *
 * 1. `voteCount` on the match doc - a RAW count (each ballot = +1), used
 *    only as an engagement/sort signal for the website's Trending feed and
 *    for the needs-votes queue's fewest-first ordering. Never used to
 *    judge a winner.
 *
 * 2. `matches/{matchId}/tally/live` - the running head-to-head split that
 *    powers the live scoreboard.
 *
 * WHY THE TALLY LIVES IN ITS OWN DOCUMENT rather than on the match:
 * visibility differs. The match document has to be readable by everyone
 * for the feed, but the running score must NOT be - seeing who's ahead
 * before you vote biases the vote, and it would tell someone rallying
 * support exactly how many more ballots they need. Splitting it out lets
 * firestore.rules gate the score on its own terms while the match itself
 * stays public.
 *
 * It also can't simply be derived client-side, because clients are
 * deliberately blocked from reading the ballots subcollection - exposing
 * who voted for whom would make brigading trivial to coordinate.
 */
/**
 * Which side of the scoreboard a ballot belongs on, or null if it names
 * neither player.
 *
 * A ballot naming a non-participant should be impossible - castVote
 * rejects one before it is ever written - but the trigger fires on
 * whatever is in the document, so it checks rather than assumes. Guessing
 * would silently credit the wrong player, which is worse than not counting
 * it at all.
 *
 * Pure, so it can be tested without an emulator.
 */
function tallyFieldFor(votedForPlayerId, match) {
  if (!match || !votedForPlayerId) return null;
  if (votedForPlayerId === match.player1Id) return "player1Votes";
  if (votedForPlayerId === match.player2Id) return "player2Votes";
  return null;
}

exports.onVoteCast = onDocumentCreated("votes/{matchId}/ballots/{voterId}", async (event) => {
  const {matchId} = event.params;
  const db = getFirestore();
  const ballot = event.data?.data() ?? {};

  const matchRef = db.collection("matches").doc(matchId);
  await matchRef.update({voteCount: FieldValue.increment(1)});

  const match = (await matchRef.get()).data();
  if (!match) return;

  // Raw per-player counts, not the account-age-weighted tally that
  // actually decides the winner. Raw is what a viewer expects a
  // scoreboard to mean; the weighting exists to blunt burner accounts and
  // only rarely changes the outcome relative to the raw count.
  const field = tallyFieldFor(ballot.votedForPlayerId, match);
  if (!field) return;

  await matchRef.collection("tally").doc("live").set({
    [field]: FieldValue.increment(1),
    total: FieldValue.increment(1),
    updatedAt: FieldValue.serverTimestamp(),
  }, {merge: true});
});

module.exports.tallyFieldFor = tallyFieldFor;
