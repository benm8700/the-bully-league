/**
 * The single watch/judge feed's ordering and verdict rules.
 *
 * Run: node test/watchFeed.test.js
 */
const assert = require("assert");
const {orderFeed, openSortKey, verdictFor, URGENCY_BAND_MS} =
  require("../watchFeed");

let checks = 0;
function check(label, fn) {
  fn();
  checks += 1;
  console.log(`  ok  ${label}`);
}

const NOW = 1_800_000_000_000;
const HOUR = 60 * 60 * 1000;

const open = (id, hoursLeft, votes) => ({
  matchId: id, canVote: true,
  windowEndMs: NOW + hoursLeft * HOUR, voteCount: votes,
});
const archived = (id, votes) => ({
  matchId: id, canVote: false, windowEndMs: NOW - HOUR, voteCount: votes,
});

// --- phase 1: what still needs judgement comes first ---

check("everything votable sorts ahead of the archive", () => {
  const feed = orderFeed(
      [archived("old", 500), open("live", 5, 0)], NOW);
  assert.deepStrictEqual(feed.map((m) => m.matchId), ["live", "old"]);
});

check("a hugely popular finished battle still sorts below an open one", () => {
  // Popularity is the ordering for the archive, never a reason to jump the
  // queue ahead of a match that can still be influenced.
  const feed = orderFeed([archived("viral", 10_000), open("quiet", 20, 0)], NOW);
  assert.strictEqual(feed[0].matchId, "quiet");
});

check("the soonest deadline comes first", () => {
  const feed = orderFeed(
      [open("later", 20, 0), open("soon", 1, 0), open("mid", 9, 0)], NOW);
  assert.deepStrictEqual(feed.map((m) => m.matchId), ["soon", "mid", "later"]);
});

check("within one urgency band the least-judged comes first", () => {
  // Both close within the same band, so the tiebreak is need - which is
  // how "closing soon" and "nobody has judged it" both count without
  // either drowning the other.
  const feed = orderFeed([open("judged", 1, 9), open("ignored", 1.5, 0)], NOW);
  assert.deepStrictEqual(feed.map((m) => m.matchId), ["ignored", "judged"]);
});

check("urgency still beats need across bands", () => {
  // A zero-vote match with a day left can still be rescued; one closing in
  // minutes cannot, so time wins when the gap is real.
  const feed = orderFeed([open("plenty", 20, 0), open("closing", 0.2, 6)], NOW);
  assert.strictEqual(feed[0].matchId, "closing");
});

check("an expired window sorts into the most urgent band", () => {
  const [band] = openSortKey(open("x", -5, 0), NOW);
  assert.strictEqual(band, 0);
});

check("the band width is what groups peers", () => {
  const [inBand] = openSortKey(open("a", (URGENCY_BAND_MS / HOUR) - 0.1, 0), NOW);
  const [nextBand] = openSortKey(open("b", (URGENCY_BAND_MS / HOUR) + 0.1, 0), NOW);
  assert.strictEqual(inBand, 0);
  assert.strictEqual(nextBand, 1);
});

// --- phase 2: the archive, by popularity ---

check("the archive is ordered most-watched first", () => {
  const feed = orderFeed(
      [archived("c", 3), archived("a", 90), archived("b", 40)], NOW);
  assert.deepStrictEqual(feed.map((m) => m.matchId), ["a", "b", "c"]);
});

check("an empty feed does not throw", () => {
  assert.deepStrictEqual(orderFeed([], NOW), []);
});

// --- verdicts, revealed only once voting has closed ---

check("no verdict is exposed while voting is open", () => {
  // The running score stays hidden until the viewer has judged - seeing
  // who is ahead beforehand biases the judgement.
  assert.strictEqual(verdictFor({voteFinalized: false, winnerId: "a"}), null);
  assert.strictEqual(verdictFor({}), null);
});

check("a settled match reports its winner and the split", () => {
  const v = verdictFor({
    voteFinalized: true, winnerId: "a",
    player1FinalWeight: 6, player2FinalWeight: 4,
  });
  assert.strictEqual(v.outcome, "decided");
  assert.strictEqual(v.winnerId, "a");
  assert.strictEqual(v.player1Share, 0.6);
  assert.strictEqual(v.totalVotes, 10);
});

check("a tie is reported as a tie, not as a narrow win", () => {
  // CLAUDE.md's tie rule: neither a win nor a loss, and no rating change.
  const v = verdictFor({
    voteFinalized: true, winnerId: null,
    player1FinalWeight: 5, player2FinalWeight: 5,
  });
  assert.strictEqual(v.outcome, "tie");
});

check("a match nobody judged reads as undecided", () => {
  const v = verdictFor({
    voteFinalized: true, winnerId: null,
    player1FinalWeight: 0, player2FinalWeight: 0,
  });
  assert.strictEqual(v.outcome, "undecided");
});

check("verdicts never leak a rating change", () => {
  // How the crowd voted is public; how far someone's rating moved is not.
  const v = verdictFor({
    voteFinalized: true, winnerId: "a",
    player1FinalWeight: 9, player2FinalWeight: 1,
  });
  assert.ok(!("ratingChange" in v) && !("rating" in v), JSON.stringify(v));
});

console.log(`\n${checks} checks passed.`);
