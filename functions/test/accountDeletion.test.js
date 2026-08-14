/**
 * Local tests for the account-deletion policy
 * (functions/accountDeletion.js). Runs with plain
 * `node test/accountDeletion.test.js`.
 *
 * Worth testing hard for two reasons. It irreversibly destroys data, so a
 * mistake in one direction is unrecoverable. And it encodes a legal
 * position rather than a technical one - CCPA erasure weighed against a
 * second person's legitimate interest in their own match history and
 * footage - so the rules need to be legible and pinned, not inferred from
 * whatever the implementation happens to do.
 *
 * The sharp edge throughout: a match has TWO people in it, and one asking
 * to be erased must not destroy the other's footage or rating history.
 */

const assert = require("assert");
const {
  planMatchDeletion,
  playerUidInMatch,
  fileBelongsToPlayer,
} = require("../accountDeletion");

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

const ALICE = "alice-uid";
const BOB = "bob-uid";
const match = (overrides = {}) => ({player1Id: ALICE, player2Id: BOB, ...overrides});

// --- Identifying whose footage is whose ------------------------------------

test("a player's Agora uid is recovered from their side of the match", () => {
  assert.strictEqual(playerUidInMatch(match(), ALICE), "1");
  assert.strictEqual(playerUidInMatch(match(), BOB), "2");
});

test("someone who wasn't in the match maps to no uid", () => {
  assert.strictEqual(playerUidInMatch(match(), "stranger"), null);
});

test("recording files are attributed to exactly one player", () => {
  const alicesFile = "match_recordings/m1/sid_match_m1__uid_s_1__uid_e_video_2026.ts";
  const bobsFile = "match_recordings/m1/sid_match_m1__uid_s_2__uid_e_video_2026.ts";
  assert.strictEqual(fileBelongsToPlayer(alicesFile, "1"), true);
  assert.strictEqual(fileBelongsToPlayer(alicesFile, "2"), false,
      "deleting player 2 must not match player 1's file");
  assert.strictEqual(fileBelongsToPlayer(bobsFile, "2"), true);
});

// --- The policy itself -----------------------------------------------------

test("only the deleting player's own footage is removed", () => {
  // The whole reason per-player recording matters here: under a baked
  // composite the only options would have been destroying the opponent's
  // footage too, or keeping video of someone who asked to be erased.
  const plan = planMatchDeletion(match(), ALICE);
  assert.strictEqual(plan.deleteOwnRecordingForUid, "1");

  const bobsPlan = planMatchDeletion(match(), BOB);
  assert.strictEqual(bobsPlan.deleteOwnRecordingForUid, "2");
});

test("the match record itself always survives, for the opponent", () => {
  // Removing one side would corrupt the opponent's rating history.
  for (const who of [ALICE, BOB]) {
    assert.strictEqual(planMatchDeletion(match(), who).keepMatchRecord, true);
  }
});

test("an unpublished highlight is deleted - it is a composite of both", () => {
  const plan = planMatchDeletion(match({highlight: {published: false}}), ALICE);
  assert.strictEqual(plan.deleteRenditions, true);
  assert.strictEqual(plan.keepPublishedHighlight, false);
});

test("a match with no highlight at all still deletes cleanly", () => {
  const plan = planMatchDeletion(match(), ALICE);
  assert.strictEqual(plan.deleteRenditions, true, "nothing to keep means nothing is spared");
});

test("an ALREADY PUBLISHED highlight is kept - the one that must not regress", () => {
  // CLAUDE.md's position: consented under the ToS at the time, already
  // publicly distributed, and deleting an account does not unpublish a
  // live post. Flagged there as wanting a real legal check, but this is
  // the behaviour that was decided.
  const plan = planMatchDeletion(match({highlight: {published: true}}), ALICE);
  assert.strictEqual(plan.deleteRenditions, false);
  assert.strictEqual(plan.keepPublishedHighlight, true);
});

test("only an explicit `true` counts as published", () => {
  // Anything ambiguous must fall to deletion. Erring toward keeping
  // someone's video after they asked to be erased is the worse mistake.
  for (const value of [undefined, null, false, "true", 1]) {
    const plan = planMatchDeletion(match({highlight: {published: value}}), ALICE);
    assert.strictEqual(
        plan.deleteRenditions,
        true,
        `published=${JSON.stringify(value)} must not be treated as published`,
    );
  }
});

test("a deleting player's own footage removal is independent of publication", () => {
  // Even where a published highlight is retained, the deleting user's raw
  // per-player footage still goes - retention covers the published
  // composite only, not the source material.
  const plan = planMatchDeletion(match({highlight: {published: true}}), ALICE);
  assert.strictEqual(plan.deleteOwnRecordingForUid, "1");
});

console.log(`accountDeletion: ${passed} checks passed`);
