/**
 * Local tests for live tournament scheduling (functions/liveTournament.js).
 * Runs with plain `node test/liveTournament.test.js`.
 *
 * The rules here are all about TIME, which is exactly the kind of thing
 * that looks right and is off by one boundary. A check-in window that
 * opens a minute late costs a player their entry in a bracket built from
 * whoever showed up, and nobody would see an error - the bracket would
 * simply be built without them.
 */

const assert = require("assert");
const {
  checkInState,
  startDecision,
  liveRoundWindow,
  liveRoundMs,
  liveVoteMs,
  startsAtMs,
  isLive,
  DEFAULT_CHECKIN_LEAD_MS,
  DEFAULT_LIVE_ROUND_MS,
  DEFAULT_LIVE_VOTE_MS,
} = require("../liveTournament");

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

const START = 1_700_000_000_000;
const live = (extra = {}) => ({
  format: "live", status: "open", startsAtMs: START, minEntrants: 4, ...extra,
});

// --- check-in window ------------------------------------------------------

test("check-in opens exactly one lead-time before the start", () => {
  const t = live();
  assert.strictEqual(checkInState(t, START - DEFAULT_CHECKIN_LEAD_MS - 1),
      "too-early");
  assert.strictEqual(checkInState(t, START - DEFAULT_CHECKIN_LEAD_MS), "open");
});

test("check-in closes exactly at the start, not a moment after", () => {
  const t = live();
  assert.strictEqual(checkInState(t, START - 1), "open");
  assert.strictEqual(checkInState(t, START), "closed",
      "the bracket is built at the start, so a late check-in is worthless");
});

test("an async tournament has no check-in at all", () => {
  assert.strictEqual(checkInState(live({format: "async"}), START - 1000),
      "not-live");
  assert.strictEqual(checkInState(live({format: undefined}), START - 1000),
      "not-live");
});

test("a tournament already running cannot be checked into", () => {
  assert.strictEqual(
      checkInState(live({status: "in_progress"}), START - 1000), "not-open");
});

test("a live tournament with no start time is inert, not guessed at", () => {
  // Starting a scheduled event at an unscheduled moment is worse than not
  // starting it.
  assert.strictEqual(checkInState(live({startsAtMs: null}), START),
      "no-start-time");
  assert.strictEqual(startsAtMs({startsAtMs: 0}), null);
  assert.strictEqual(startsAtMs({}), null);
});

test("a Firestore Timestamp start time reads the same as millis", () => {
  assert.strictEqual(startsAtMs({startsAtMs: {toMillis: () => START}}), START);
});

// --- what happens at the start -------------------------------------------

test("before the start, the sweep waits", () => {
  const d = startDecision({tournament: live(), checkedInCount: 99,
    nowMs: START - 1});
  assert.strictEqual(d.action, "wait");
});

test("THE BRACKET IS BUILT FROM WHO SHOWED UP", () => {
  // Not from everyone who entered. Building from all entrants and
  // forfeiting the absentees would make a first round mostly of byes,
  // which is not a show.
  const d = startDecision({tournament: live(), checkedInCount: 4,
    nowMs: START});
  assert.strictEqual(d.action, "start");
  assert.strictEqual(d.checkedInCount, 4);
});

test("GOLDEN PARACHUTE: too few present cancels rather than running", () => {
  const d = startDecision({tournament: live(), checkedInCount: 3,
    nowMs: START});
  assert.strictEqual(d.action, "cancel");
  assert.strictEqual(d.reason, "too-few-checked-in");
});

test("two is the floor whatever the configured minimum says", () => {
  // buildFirstRound has no meaningful matchup below two, so a minimum of
  // 1 or 0 must not be honoured into an unbuildable bracket.
  const t = live({minEntrants: 1});
  assert.strictEqual(startDecision({tournament: t, checkedInCount: 1,
    nowMs: START}).action, "cancel");
  assert.strictEqual(startDecision({tournament: t, checkedInCount: 2,
    nowMs: START}).action, "start");
});

test("a missing minEntrants falls back rather than running on one player", () => {
  const t = live({minEntrants: undefined});
  assert.strictEqual(startDecision({tournament: t, checkedInCount: 2,
    nowMs: START}).action, "cancel");
});

test("the sweep never touches an async tournament", () => {
  const d = startDecision({tournament: live({format: "async"}),
    checkedInCount: 99, nowMs: START + 1});
  assert.strictEqual(d.action, "skip");
  assert.strictEqual(d.reason, "not-live");
});

test("a tournament already started is not started again", () => {
  const d = startDecision({tournament: live({status: "in_progress"}),
    checkedInCount: 8, nowMs: START + 1});
  assert.strictEqual(d.action, "skip");
});

// --- timings, which arrive from a hand-edited document -------------------

test("live rounds are measured in minutes, not the async format's hours", () => {
  assert.strictEqual(liveRoundMs({}), DEFAULT_LIVE_ROUND_MS);
  assert.ok(DEFAULT_LIVE_ROUND_MS <= 15 * 60 * 1000,
      "a live bracket that waits longer than this has stopped being live");
});

test("a sane round override applies", () => {
  assert.strictEqual(liveRoundMs({liveRoundMs: 5 * 60 * 1000}), 5 * 60 * 1000);
});

test("a nonsense round length falls back rather than breaking the bracket", () => {
  // A zero would forfeit every matchup the instant the round opened.
  for (const bad of [0, -1, 1000, "soon", null, NaN, 99 * 60 * 60 * 1000]) {
    assert.strictEqual(liveRoundMs({liveRoundMs: bad}), DEFAULT_LIVE_ROUND_MS,
        `accepted ${String(bad)}`);
  }
});

test("the vote window is short but never instant", () => {
  assert.strictEqual(liveVoteMs({}), DEFAULT_LIVE_VOTE_MS);
  assert.ok(DEFAULT_LIVE_VOTE_MS >= 30 * 1000,
      "a crowd needs long enough to actually press something");
  for (const bad of [0, 1, -5, "fast", null]) {
    assert.strictEqual(liveVoteMs({liveVoteMs: bad}), DEFAULT_LIVE_VOTE_MS);
  }
});

test("the round window has the same shape as the async one", () => {
  // The bracket structure must stay identical, so everything already
  // built on it - forfeits, advancement - keeps working unchanged.
  const w = liveRoundWindow(live(), START);
  assert.strictEqual(w.windowStartMs, START);
  assert.strictEqual(w.windowEndMs, START + DEFAULT_LIVE_ROUND_MS);
});

test("a round is much shorter than the chance to object to the clip", () => {
  // The whole point of splitting the two clocks. If a round could outlast
  // the objection window, the format would be rushing the one decision
  // that must not be rushed.
  const {VOTE_WINDOW_MS} = require("../matchFinalization");
  assert.ok(DEFAULT_LIVE_ROUND_MS < VOTE_WINDOW_MS / 10);
  assert.ok(DEFAULT_LIVE_VOTE_MS < VOTE_WINDOW_MS / 100);
});

test("isLive is explicit rather than truthy", () => {
  assert.strictEqual(isLive({format: "live"}), true);
  assert.strictEqual(isLive({format: "LIVE"}), false);
  assert.strictEqual(isLive({}), false);
  assert.strictEqual(isLive(null), false);
});

console.log(`liveTournament: ${passed} checks passed`);
