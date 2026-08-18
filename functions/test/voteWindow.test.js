/**
 * The 24-hour voting window.
 *
 * Worth pinning because the window is enforced in three places that must
 * agree - castVote refuses late ballots, finalizeMatch decides when to
 * tally, and the client draws a countdown from it. If they drift apart the
 * symptom is not an error, it's a match that closes while the app still
 * says there's time left.
 *
 * Run: node test/voteWindow.test.js
 */
const assert = require("assert");
const {
  VOTE_WINDOW_MS,
  voteWindowStartMs,
  voteWindowEndMs,
} = require("../matchFinalization");
const {isVotableBy, msRemaining} = require("../voteQueue");

let checks = 0;
function check(label, fn) {
  fn();
  checks += 1;
  console.log(`  ok  ${label}`);
}

/** Firestore Timestamp stand-in - only toMillis() is ever used. */
const ts = (ms) => ({toMillis: () => ms});

const PAIRED = 1_000_000;
const COMPLETED = PAIRED + 5 * 60 * 1000; // five minutes of actual match

check("the window starts at completion, not pairing", () => {
  const match = {createdAt: ts(PAIRED), completedAt: ts(COMPLETED)};
  assert.strictEqual(voteWindowStartMs(match), COMPLETED);
});

check("a played match gets its full 24 hours after the verdict", () => {
  // The bug this replaces: measuring from pairing silently shortened every
  // match's window by however long the match itself took.
  const match = {createdAt: ts(PAIRED), completedAt: ts(COMPLETED)};
  assert.strictEqual(voteWindowEndMs(match) - COMPLETED, VOTE_WINDOW_MS);
});

check("an unfinished match falls back to pairing time", () => {
  // Abandoned matches never get a completedAt. Falling back to createdAt is
  // what lets the hourly sweep still settle them rather than leaving them
  // open forever.
  const match = {createdAt: ts(PAIRED)};
  assert.strictEqual(voteWindowStartMs(match), PAIRED);
  assert.strictEqual(voteWindowEndMs(match), PAIRED + VOTE_WINDOW_MS);
});

check("a match with no timestamps at all is treated as long expired", () => {
  assert.strictEqual(voteWindowStartMs({}), 0);
  assert.strictEqual(voteWindowStartMs(null), 0);
  assert.strictEqual(voteWindowStartMs(undefined), 0);
});

check("the sweep query on createdAt is a superset of closed windows", () => {
  // finalizeExpiredMatches queries createdAt <= cutoff while the real
  // window runs from completedAt. That's only safe because completedAt is
  // always >= createdAt, so anything actually expired is always caught.
  const match = {createdAt: ts(PAIRED), completedAt: ts(COMPLETED)};
  assert.ok(voteWindowStartMs(match) >= match.createdAt.toMillis());
});

// --- the queue's own copy of the rule, which must not drift ---

const votable = {
  status: "completed",
  voteFinalized: false,
  player1Id: "alice",
  player2Id: "bob",
  createdAtMs: PAIRED,
  completedAtMs: COMPLETED,
};

check("a match inside its window is offered to an outsider", () => {
  assert.strictEqual(isVotableBy(votable, "carol", COMPLETED + 1000), true);
});

check("a match is still votable in the hours pairing-time would have cut", () => {
  // Just past createdAt + 24h, but comfortably inside completedAt + 24h.
  // Under the old arithmetic this ballot would have been refused.
  const justPastOldWindow = PAIRED + VOTE_WINDOW_MS + 1000;
  assert.ok(justPastOldWindow < voteWindowEndMs({
    createdAt: ts(PAIRED), completedAt: ts(COMPLETED),
  }));
  assert.strictEqual(isVotableBy(votable, "carol", justPastOldWindow), true);
});

check("a match past its real window is not offered", () => {
  assert.strictEqual(
      isVotableBy(votable, "carol", COMPLETED + VOTE_WINDOW_MS + 1), false);
});

check("participants are never offered their own match", () => {
  assert.strictEqual(isVotableBy(votable, "alice", COMPLETED + 1000), false);
  assert.strictEqual(isVotableBy(votable, "bob", COMPLETED + 1000), false);
});

check("time remaining counts down from completion", () => {
  assert.strictEqual(msRemaining(votable, COMPLETED), VOTE_WINDOW_MS);
  assert.strictEqual(
      msRemaining(votable, COMPLETED + VOTE_WINDOW_MS / 2), VOTE_WINDOW_MS / 2);
});

check("time remaining never goes negative", () => {
  assert.strictEqual(
      msRemaining(votable, COMPLETED + VOTE_WINDOW_MS * 10), 0);
});

check("the queue falls back to pairing time exactly as the server does", () => {
  const noCompletion = {...votable, completedAtMs: null};
  assert.strictEqual(msRemaining(noCompletion, PAIRED), VOTE_WINDOW_MS);
});


// ------------------- voting and objecting are separate clocks now --------
//
// They were the same thing until live tournaments needed voting to close
// in about a minute. Tying them together would have given a player SIXTY
// SECONDS to decide whether video of themselves may be published - and
// that is worse now that withdrawing by preference only works before a
// clip is public, because missing the minute leaves claiming harm as the
// only route.
const {voteWindowMs, objectionWindowEndMs} = require("../matchFinalization");
const NOW = COMPLETED;

check("a match with no stamp votes for the standard day", () => {
  assert.strictEqual(voteWindowMs({}), VOTE_WINDOW_MS);
});

check("a live match can close voting in a minute", () => {
  assert.strictEqual(voteWindowMs({voteWindowMs: 60_000}), 60_000);
});

check("THE SPLIT: a one-minute vote window still gets a full day to object", () => {
  const live = {completedAt: ts(NOW), voteWindowMs: 60_000};
  assert.strictEqual(voteWindowEndMs(live) - NOW, 60_000);
  assert.strictEqual(objectionWindowEndMs(live) - NOW, VOTE_WINDOW_MS,
      "the chance to stop a clip must never shrink with the vote window");
});

check("the objection window ignores the stamp entirely", () => {
  // Whatever a tournament sets, nobody gets less than a day to object.
  for (const ms of [30_000, 60_000, 5 * 60_000, VOTE_WINDOW_MS]) {
    assert.strictEqual(
        objectionWindowEndMs({completedAt: ts(NOW), voteWindowMs: ms}) - NOW,
        VOTE_WINDOW_MS, `stamp of ${ms} changed the objection window`);
  }
});

check("a nonsense vote window falls back rather than breaking a bracket", () => {
  // Arrives from a document. Zero would close voting before anyone could
  // vote; a huge value would hold a live round open forever.
  for (const bad of [0, -1, 1000, "soon", null, undefined, NaN,
    VOTE_WINDOW_MS * 10]) {
    assert.strictEqual(voteWindowMs({voteWindowMs: bad}), VOTE_WINDOW_MS,
        `bad value ${String(bad)} was accepted`);
  }
});

console.log(`
${checks} checks passed.`);
