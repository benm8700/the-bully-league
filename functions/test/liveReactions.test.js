/**
 * Pure tests for who may react to a Main Stage battle and with what
 * (functions/liveReactions.js). Run: node test/liveReactions.test.js
 *
 * These guard a write to a PUBLIC IDENTITY number (emojiCounts drives badges,
 * nicknames, the Applause board, the superlative awards), so the rule is worth
 * pinning exactly rather than inferring from behaviour - the same reason
 * spectateProblem is tested.
 */
const assert = require("assert");
const {reactionProblem, MESSAGES} = require("../liveReactions");

let passed = 0;
function test(name, fn) {
  try {
    fn();
    passed++;
  } catch (e) {
    console.error(`FAIL: ${name}\n  ${e.message}`);
    process.exitCode = 1;
  }
}

const match = {
  status: "in_progress",
  player1Id: "alice",
  player2Id: "bob",
  mainStage: {tournamentId: "ms1", roundIdx: 0, matchIdx: 0},
};
const emoji = {alice: "fire", bob: "clever"};
const ask = (over = {}) => reactionProblem({
  match, uid: "carol", emojiRatings: emoji, favorite: "alice", ...over,
});

// --- the allowed case ---

test("a spectator may react to a live Main Stage battle", () => {
  assert.strictEqual(ask(), null);
});

test("a just-finished battle (not yet finalized) is still reactable", () => {
  assert.strictEqual(ask({match: {...match, status: "completed"}}), null);
});

test("favourite may be either roaster", () => {
  assert.strictEqual(ask({favorite: "bob"}), null);
});

// --- refusals ---

test("a missing match is refused", () => {
  assert.strictEqual(ask({match: null}), "match-not-found");
});

test("a non-Main-Stage match is not reactable (nobody signed up for a crowd)", () => {
  // An ordinary ranked / friend battle carries no mainStage link.
  const {mainStage, ...noMs} = match;
  assert.strictEqual(ask({match: noMs}), "not-a-live-battle");
  assert.strictEqual(
      ask({match: {...match, mainStage: {}}}), "not-a-live-battle");
});

test("the two players can't react to their own battle", () => {
  assert.strictEqual(ask({uid: "alice"}), "you-are-playing");
  assert.strictEqual(ask({uid: "bob"}), "you-are-playing");
});

test("an abandoned battle is not reactable", () => {
  assert.strictEqual(
      ask({match: {...match, status: "abandoned"}}), "not-a-live-battle");
});

test("once the result has landed, reactions are closed", () => {
  assert.strictEqual(
      ask({match: {...match, status: "completed", voteFinalized: true}}),
      "reactions-closed");
});

test("both roasters must be rated with a valid emoji", () => {
  assert.strictEqual(ask({emojiRatings: {alice: "fire"}}), "rate-both");
  assert.strictEqual(
      ask({emojiRatings: {alice: "fire", bob: "nope"}}), "rate-both");
  assert.strictEqual(ask({emojiRatings: null}), "rate-both");
});

test("the crowd favourite must be one of the two roasters", () => {
  assert.strictEqual(ask({favorite: "carol"}), "pick-favorite");
  assert.strictEqual(ask({favorite: null}), "pick-favorite");
});

test("every refusal reason has a human-readable message", () => {
  for (const r of ["match-not-found", "not-a-live-battle", "you-are-playing",
    "reactions-closed", "rate-both", "pick-favorite", "already-reacted"]) {
    assert.ok(MESSAGES[r] && MESSAGES[r].length > 0, `no message for ${r}`);
  }
});

console.log(`liveReactions: ${passed} checks passed`);
