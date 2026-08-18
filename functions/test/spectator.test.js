/**
 * Local tests for who may watch a live tournament match
 * (functions/spectator.js). Runs with `node test/spectator.test.js`.
 *
 * THIS IS A RULE ABOUT WATCHING VIDEO OF REAL PEOPLE, so it is worth
 * pinning exactly rather than inferring from behaviour. generateAgoraToken
 * refuses a token for any match the caller is not playing in - a fix made
 * specifically to stop anyone dropping in on a stranger's live battle.
 * Spectating is a second door, and if it is one condition too wide it
 * quietly reopens that hole.
 */

const assert = require("assert");
const {spectateProblem, spectatorUid, MESSAGES} = require("../spectator");

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

const liveRunning = {format: "live", status: "in_progress"};
const match = {
  mode: "tournament",
  status: "pending",
  player1Id: "alice",
  player2Id: "bob",
  tournament: {tournamentId: "t1"},
  channelName: "match_t1_r1_m0",
};
const ask = (over = {}) => spectateProblem({
  match, tournament: liveRunning, uid: "carol", ...over,
});

// --- the one case that is allowed ----------------------------------------

test("a stranger may watch a live tournament match in progress", () => {
  assert.strictEqual(ask(), null);
});

test("an in_progress match is watchable too, not just a pending one", () => {
  assert.strictEqual(ask({match: {...match, status: "in_progress"}}), null);
});

// --- everything else is refused ------------------------------------------

test("THE RULE THAT MUST NOT WIDEN: an ordinary ranked match is private", () => {
  // This is the whole point. Somebody in a live tournament chose to
  // perform in front of an audience; two strangers paired at random did
  // not, and letting spectators into their channel would undo the fix
  // that closed that hole.
  assert.strictEqual(ask({match: {...match, mode: "ranked"}}),
      "not-a-tournament-match");
});

test("a friend battle is private too", () => {
  assert.strictEqual(ask({match: {...match, mode: "friend"}}),
      "not-a-tournament-match");
});

test("an ASYNC tournament match is not spectatable", () => {
  // Nobody is assembled to watch it, and its players did not sign up for
  // a live audience.
  assert.strictEqual(
      ask({tournament: {format: "async", status: "in_progress"}}),
      "not-a-live-event");
});

test("a live tournament that is not running yet is not watchable", () => {
  assert.strictEqual(ask({tournament: {...liveRunning, status: "open"}}),
      "not-running");
  assert.strictEqual(ask({tournament: {...liveRunning, status: "completed"}}),
      "not-running");
});

test("a finished match is not watchable live", () => {
  // The clip is how you see a finished battle, and that path has its own
  // consent and takedown rules.
  for (const status of ["completed", "abandoned"]) {
    assert.strictEqual(ask({match: {...match, status}}), "already-finished");
  }
});

test("a match with no tournament link is refused", () => {
  assert.strictEqual(ask({match: {...match, tournament: undefined}}),
      "not-a-tournament-match");
});

test("a missing tournament document is refused rather than assumed live", () => {
  assert.strictEqual(ask({tournament: null}), "tournament-not-found");
});

test("a missing match is refused", () => {
  assert.strictEqual(ask({match: null}), "match-not-found");
});

test("the players themselves are sent to the player path", () => {
  // They need a PUBLISHER token, not this one - handing them a subscriber
  // token would put them in their own match unable to speak.
  assert.strictEqual(ask({uid: "alice"}), "you-are-playing");
  assert.strictEqual(ask({uid: "bob"}), "you-are-playing");
});

test("every refusal has a message a human can read", () => {
  const reasons = ["match-not-found", "you-are-playing",
    "not-a-tournament-match", "tournament-not-found", "not-a-live-event",
    "not-running", "already-finished"];
  for (const r of reasons) {
    assert.ok(MESSAGES[r] && MESSAGES[r].length > 0, `no message for ${r}`);
  }
});

// --- the uid a spectator joins with --------------------------------------

test("spectator uids never collide with the players' fixed 1 and 2", () => {
  // Players join as uid 1 and 2 so the recording layout can name their
  // regions. A spectator landing on either would be composited into the
  // recording as if they were a player.
  for (const id of ["a", "alice", "zzzzzzzzzzzz", "1", "2", ""]) {
    assert.ok(spectatorUid(id) > 2, `uid for ${id} was ${spectatorUid(id)}`);
  }
});

test("the same account always gets the same spectator uid", () => {
  // Otherwise one person reopening the screen accumulates as a crowd of
  // ghosts in the channel - and Agora bills per participant-minute.
  assert.strictEqual(spectatorUid("carol"), spectatorUid("carol"));
  assert.notStrictEqual(spectatorUid("carol"), spectatorUid("dave"));
});

console.log(`spectator: ${passed} checks passed`);
