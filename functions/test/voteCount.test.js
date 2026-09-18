/**
 * Tests the pure half of the live-scoreboard trigger.
 *
 * No emulator, no credentials - same approach as the matchmaking and
 * rating suites, which is what let the tournament bye bug be caught before
 * it ever reached a device.
 *
 * Run: node test/voteCount.test.js
 */
const assert = require("assert");
const {tallyFieldFor, ballotLean} = require("../voteCount");

let checks = 0;
function check(label, fn) {
  fn();
  checks += 1;
  console.log(`  ok  ${label}`);
}

const match = {player1Id: "alice", player2Id: "bob"};

check("a ballot for player 1 lands on player1Votes", () => {
  assert.strictEqual(tallyFieldFor("alice", match), "player1Votes");
});

check("a ballot for player 2 lands on player2Votes", () => {
  assert.strictEqual(tallyFieldFor("bob", match), "player2Votes");
});

check("a ballot naming neither player counts for nobody", () => {
  // castVote refuses to write one of these, but the trigger fires on
  // whatever is in the document. Crediting a guess would be worse than
  // dropping it.
  assert.strictEqual(tallyFieldFor("carol", match), null);
});

check("a missing vote target counts for nobody", () => {
  assert.strictEqual(tallyFieldFor(undefined, match), null);
  assert.strictEqual(tallyFieldFor(null, match), null);
  assert.strictEqual(tallyFieldFor("", match), null);
});

check("a missing match counts for nobody rather than throwing", () => {
  // The trigger reads the match after incrementing voteCount; a match
  // deleted in between would otherwise crash the function.
  assert.strictEqual(tallyFieldFor("alice", undefined), null);
  assert.strictEqual(tallyFieldFor("alice", null), null);
});

check("an empty player id on the match never swallows a ballot", () => {
  // Defends the shape rather than the value: if a malformed match doc had
  // an absent player1Id, `undefined === undefined` would quietly credit
  // player 1 for a ballot that named nobody.
  assert.strictEqual(tallyFieldFor(undefined, {player2Id: "bob"}), null);
});

// ---- ballotLean (per-round -> which side of the scoreboard) --------------
check("a per-round ballot leans to whoever won more rounds", () => {
  assert.strictEqual(
      ballotLean({picks: {0: "alice", 1: "alice", 2: "bob"}}, match), "alice");
  assert.strictEqual(
      ballotLean({picks: {0: "bob", 1: "bob", 2: "alice"}}, match), "bob");
});

check("a per-round ballot split evenly leans to neither", () => {
  assert.strictEqual(
      ballotLean({picks: {0: "alice", 1: "bob"}}, match), null);
});

check("a legacy single-vote ballot still leans to that player", () => {
  assert.strictEqual(ballotLean({votedForPlayerId: "bob"}, match), "bob");
});

check("a junk or empty ballot leans to nobody", () => {
  assert.strictEqual(ballotLean({}, match), null);
  assert.strictEqual(ballotLean(null, match), null);
  assert.strictEqual(ballotLean({picks: {0: "carol"}}, match), null);
});

console.log(`\n${checks} checks passed.`);
