/* Pure tests for the match-stats aggregation - no emulator, no credentials.
 * Run: node test/matchStats.test.js */
const assert = require("assert");
const {computeMatchStats} = require("../matchStats");

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

function m(status, extra = {}) {
  return {status, mode: "ranked", ...extra};
}
// A round window is two turns; startMs/endMs are ms offsets into the clip.
function rb(...durationsSec) {
  let t = 0;
  return durationsSec.map((d, i) => {
    const startMs = t;
    t += d * 1000;
    const endMs = t;
    t += 500; // small gap between rounds
    return {round: i, startMs, endMs};
  });
}

test("empty input yields zeroed counts and null averages", () => {
  const s = computeMatchStats([]);
  assert.strictEqual(s.sampleSize, 0);
  assert.strictEqual(s.completed, 0);
  assert.strictEqual(s.abandoned, 0);
  assert.strictEqual(s.completionRate, null);
  assert.strictEqual(s.avgRoundSeconds, null);
  assert.strictEqual(s.avgRoundsPerMatch, null);
  assert.strictEqual(s.avgVotesPerCompleted, null);
  assert.deepStrictEqual(s.byMode, {});
});

test("non-array input is treated as empty", () => {
  assert.strictEqual(computeMatchStats(null).sampleSize, 0);
  assert.strictEqual(computeMatchStats(undefined).sampleSize, 0);
});

test("completion rate is completed / (completed + abandoned)", () => {
  const s = computeMatchStats([
    m("completed"), m("completed"), m("completed"), m("abandoned"),
  ]);
  assert.strictEqual(s.completed, 3);
  assert.strictEqual(s.abandoned, 1);
  assert.strictEqual(s.completionRate, 0.75);
});

test("disqualified counts as abandoned for the rate", () => {
  const s = computeMatchStats([m("completed"), m("disqualified")]);
  assert.strictEqual(s.abandoned, 1);
  assert.strictEqual(s.completionRate, 0.5);
});

test("pending (in-progress) matches are ignored for the rate", () => {
  // Two completed, one still pending -> rate is 2/2, not 2/3.
  const s = computeMatchStats([m("completed"), m("completed"), m("pending")]);
  assert.strictEqual(s.completionRate, 1);
  assert.strictEqual(s.sampleSize, 3);
});

test("average round seconds is computed from roundBoundaries", () => {
  // Two completed matches, 3 rounds each of 30/30/20 and 40/20/... -> average
  // over all 6 rounds.
  const s = computeMatchStats([
    m("completed", {roundBoundaries: rb(30, 30, 20)}), // 80 over 3
    m("completed", {roundBoundaries: rb(40, 20, 30)}), // 90 over 3
  ]);
  assert.strictEqual(s.matchesWithRoundData, 2);
  assert.strictEqual(s.avgRoundSeconds, 28.3); // (80+90)/6 = 28.33
  assert.strictEqual(s.avgRoundsPerMatch, 3);
});

test("round data on non-completed matches is not counted", () => {
  const s = computeMatchStats([m("abandoned", {roundBoundaries: rb(30, 30)})]);
  assert.strictEqual(s.matchesWithRoundData, 0);
  assert.strictEqual(s.avgRoundSeconds, null);
});

test("malformed and absurd round boundaries are skipped", () => {
  const s = computeMatchStats([
    m("completed", {roundBoundaries: [
      {round: 0, startMs: 0, endMs: 20000}, // 20s - valid
      {round: 1, startMs: 0}, // missing endMs - skip
      {round: 2, startMs: 100, endMs: 50}, // negative - skip
      {round: 3, startMs: 0, endMs: 99_000_000}, // absurd (>1h) - skip
    ]}),
  ]);
  assert.strictEqual(s.avgRoundSeconds, 20);
  assert.strictEqual(s.matchesWithRoundData, 1);
  assert.strictEqual(s.avgRoundsPerMatch, 1);
});

test("a completed match with no round data still counts, just not for rounds", () => {
  const s = computeMatchStats([m("completed"), m("completed", {roundBoundaries: rb(30)})]);
  assert.strictEqual(s.completed, 2);
  assert.strictEqual(s.matchesWithRoundData, 1);
  assert.strictEqual(s.avgRoundSeconds, 30);
});

test("average votes per completed ignores matches without a vote count", () => {
  const s = computeMatchStats([
    m("completed", {voteCount: 4}),
    m("completed", {voteCount: 8}),
    m("completed"), // no voteCount - not counted
    m("abandoned", {voteCount: 100}), // not completed - not counted
  ]);
  assert.strictEqual(s.avgVotesPerCompleted, 6); // (4+8)/2
});

test("byMode tallies every match regardless of status", () => {
  const s = computeMatchStats([
    m("completed", {mode: "ranked"}),
    m("abandoned", {mode: "ranked"}),
    m("completed", {mode: "tournament"}),
    m("pending", {mode: "friend"}),
    m("completed", {}), // mode present via helper default (ranked)
  ]);
  assert.strictEqual(s.byMode.ranked, 3);
  assert.strictEqual(s.byMode.tournament, 1);
  assert.strictEqual(s.byMode.friend, 1);
});

test("a match with a non-string mode is bucketed as unknown", () => {
  const s = computeMatchStats([{status: "completed", mode: undefined}]);
  assert.strictEqual(s.byMode.unknown, 1);
});

console.log(`matchStats: ${passed} checks passed`);
