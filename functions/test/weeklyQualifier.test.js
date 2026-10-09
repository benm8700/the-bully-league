const assert = require("assert");
const {
  qualifyingWeek,
  mostRecentlyClosedWeek,
  computeStandings,
  computeJudgeStandings,
  topN,
  weekdayOf,
} = require("../weeklyQualifier");

let passed = 0;
function check(name, fn) {
  fn();
  passed++;
  console.log(`  ok - ${name}`);
}

const HOUR = 60 * 60 * 1000;
const THURSDAY = 4;

console.log("weekly qualifier - qualifyingWeek (Pacific boundary math)");

check("summer Wednesday -> closes this Thursday, 7-day (168h) window", () => {
  // Jul 1 2026 is a Wednesday, PDT (UTC-7). Noon PDT = 19:00 UTC.
  const w = qualifyingWeek(Date.UTC(2026, 6, 1, 19, 0));
  assert.strictEqual(w.cutoffDayKey, "2026-07-02");
  assert.strictEqual(w.startDayKey, "2026-06-25");
  assert.strictEqual(w.cutoffMs - w.startMs, 168 * HOUR, "pure PDT week");
});

check("winter Monday -> closes this Thursday, 168h window", () => {
  // Jan 5 2026 is a Monday, PST (UTC-8). Noon PST = 20:00 UTC.
  const w = qualifyingWeek(Date.UTC(2026, 0, 5, 20, 0));
  assert.strictEqual(w.cutoffDayKey, "2026-01-08");
  assert.strictEqual(w.startDayKey, "2026-01-01");
  assert.strictEqual(w.cutoffMs - w.startMs, 168 * HOUR, "pure PST week");
});

check("ON a Thursday -> rolls to NEXT Thursday (00:00 already passed)", () => {
  // Jan 8 2026 is a Thursday, 2pm PST. The 00:00 cutoff passed this morning,
  // so this week closes NEXT Thursday and Thursday's play feeds it.
  const w = qualifyingWeek(Date.UTC(2026, 0, 8, 22, 0));
  assert.strictEqual(w.cutoffDayKey, "2026-01-15");
  assert.strictEqual(w.startDayKey, "2026-01-08");
});

check("the Wed-11:59pm snapshot instant computes the just-closing week", () => {
  // Wed Jan 7 2026 23:59 PST = Jan 8 07:59 UTC, one minute before the
  // Thu 00:00 (= Jan 8 08:00 UTC PST) cutoff.
  const now = Date.UTC(2026, 0, 8, 7, 59);
  const w = qualifyingWeek(now);
  assert.strictEqual(w.cutoffDayKey, "2026-01-08");
  assert.strictEqual(w.startDayKey, "2026-01-01");
  assert.ok(now < w.cutoffMs, "snapshot runs just before the cutoff");
  assert.ok(now >= w.startMs, "and inside the week");
});

check("DST fall-back week is 169 HOURS, not 168 (the silent bug)", () => {
  // DST ends Sun Nov 1 2026. The week [Thu Oct 29, Thu Nov 5) spans it.
  // Oct 30 2026 noon PDT (UTC-7) = 19:00 UTC.
  const w = qualifyingWeek(Date.UTC(2026, 9, 30, 19, 0));
  assert.strictEqual(w.cutoffDayKey, "2026-11-05");
  assert.strictEqual(w.startDayKey, "2026-10-29");
  assert.strictEqual(w.cutoffMs - w.startMs, 169 * HOUR,
      "the fall-back adds an hour to the week");
});

check("cutoff and start always land on a Thursday, now always inside", () => {
  for (const now of [
    Date.UTC(2026, 6, 1, 19, 0),
    Date.UTC(2026, 0, 5, 20, 0),
    Date.UTC(2026, 9, 30, 19, 0),
    Date.UTC(2026, 2, 10, 12, 0),
    Date.UTC(2026, 11, 25, 6, 0),
  ]) {
    const w = qualifyingWeek(now);
    assert.strictEqual(weekdayOf(w.cutoffDayKey), THURSDAY);
    assert.strictEqual(weekdayOf(w.startDayKey), THURSDAY);
    assert.ok(now >= w.startMs && now < w.cutoffMs,
        `now within week for ${new Date(now).toISOString()}`);
  }
});

console.log("weekly qualifier - mostRecentlyClosedWeek (snapshot target)");

check("just after a Thursday cutoff -> the week that just closed", () => {
  // Thu Jan 8 2026 00:05 PST = Jan 8 08:05 UTC, just past the Thu 00:00 cutoff.
  const now = Date.UTC(2026, 0, 8, 8, 5);
  const w = mostRecentlyClosedWeek(now);
  assert.strictEqual(w.cutoffDayKey, "2026-01-08");
  assert.strictEqual(w.startDayKey, "2026-01-01");
  assert.ok(now >= w.cutoffMs, "the cutoff is at or before now");
  assert.ok(now - w.cutoffMs < 60 * 60 * 1000, "and only just passed");
});

check("mid-week (Wed) -> the PREVIOUS Thursday, not this imminent one", () => {
  // Wed Jan 7 2026 23:00 PST = Jan 8 07:00 UTC, before this week's cutoff.
  const now = Date.UTC(2026, 0, 8, 7, 0);
  const w = mostRecentlyClosedWeek(now);
  assert.strictEqual(w.cutoffDayKey, "2026-01-01");
  // now is ~7 days past that cutoff, so a grace-windowed snapshot won't fire.
  assert.ok(now - w.cutoffMs > 6 * 24 * HOUR);
});

check("mirror invariant: current week starts where the closed week ended", () => {
  for (const now of [
    Date.UTC(2026, 6, 1, 19, 0),
    Date.UTC(2026, 0, 8, 8, 5),
    Date.UTC(2026, 9, 30, 19, 0),
    Date.UTC(2026, 2, 12, 3, 0),
  ]) {
    assert.strictEqual(
        qualifyingWeek(now).startMs, mostRecentlyClosedWeek(now).cutoffMs,
        `mirror at ${new Date(now).toISOString()}`);
  }
});

console.log("weekly qualifier - computeStandings (weekly Elo gain)");

const WIN = {startMs: 1000, cutoffMs: 2000, minGames: 2};
const e = (uid, delta, at = 1500, mode = "ranked") => ({uid, delta, at, mode});

check("sums deltas per player and ranks by gain", () => {
  const s = computeStandings([
    e("a", 10), e("a", 5), e("b", 30), e("b", -1), e("c", 2), e("c", 2),
  ], WIN);
  assert.deepStrictEqual(s.map((p) => p.uid), ["b", "a", "c"]);
  assert.strictEqual(s[0].gain, 29);
  assert.strictEqual(s[1].gain, 15);
});

check("minGames floor excludes a tiny-sample run", () => {
  const s = computeStandings([
    e("lucky", 40), // 1 game, huge gain - must NOT qualify at minGames 2
    e("real", 3), e("real", 3),
  ], WIN);
  assert.deepStrictEqual(s.map((p) => p.uid), ["real"]);
});

check("friend/exhibition/practice are ignored; tournament counts", () => {
  const s = computeStandings([
    e("a", 50, 1500, "friend"), e("a", 50, 1500, "exhibition"),
    e("a", 50, 1500, "practice"),
    e("a", 7, 1500, "ranked"), e("a", 8, 1500, "tournament"),
  ], WIN);
  // Only the ranked + tournament entries count: 2 games, gain 15.
  assert.strictEqual(s.length, 1);
  assert.strictEqual(s[0].gain, 15);
  assert.strictEqual(s[0].games, 2);
});

check("entries outside [start, cutoff) are excluded", () => {
  const s = computeStandings([
    e("a", 100, 999), // before start
    e("a", 100, 2000), // at cutoff (exclusive)
    e("a", 5, 1500), e("a", 5, 1999),
  ], WIN);
  assert.strictEqual(s.length, 1);
  assert.strictEqual(s[0].gain, 10, "only the two in-window entries count");
});

check("tie on gain breaks by more games, then uid", () => {
  const s = computeStandings([
    e("zed", 10), e("zed", 0), // gain 10, 2 games
    e("amy", 5), e("amy", 5), e("amy", 0), // gain 10, 3 games
    e("ben", 5), e("ben", 5), // gain 10, 2 games
  ], WIN);
  // amy (3 games) first; zed vs ben both 2 games, gain 10 -> uid: ben < zed.
  assert.deepStrictEqual(s.map((p) => p.uid), ["amy", "ben", "zed"]);
});

check("malformed entries are skipped, never counted as zero", () => {
  const s = computeStandings([
    e("a", 5), e("a", 5),
    {uid: "a", delta: NaN, at: 1500, mode: "ranked"}, // bad delta
    {uid: "", delta: 5, at: 1500, mode: "ranked"}, // empty uid
    {delta: 5, at: 1500, mode: "ranked"}, // no uid
    {uid: "a", delta: 5, at: "nope", mode: "ranked"}, // bad at
    null,
  ], WIN);
  assert.strictEqual(s.length, 1);
  assert.strictEqual(s[0].uid, "a");
  assert.strictEqual(s[0].gain, 10, "only the two valid entries counted");
  assert.strictEqual(s[0].games, 2);
});

check("a losing week is still eligible and ranked", () => {
  const s = computeStandings([
    e("down", -8), e("down", -4), e("up", 2), e("up", 1),
  ], WIN);
  assert.deepStrictEqual(s.map((p) => p.uid), ["up", "down"]);
  assert.strictEqual(s[1].gain, -12);
});

check("topN selects finalists (and alternates) in order", () => {
  const s = computeStandings([
    e("a", 90), e("a", 0), e("b", 80), e("b", 0), e("c", 70), e("c", 0),
    e("d", 60), e("d", 0), e("x", 50), e("x", 0),
  ], WIN);
  assert.deepStrictEqual(topN(s, 4).map((p) => p.uid), ["a", "b", "c", "d"]);
  assert.strictEqual(topN(s, 0).length, 0);
  assert.strictEqual(topN(s, 99).length, 5);
});

console.log("weekly qualifier - computeJudgeStandings (most-judged pool)");

const jb = (uid, at = 1500) => ({uid, at});

check("ranks judges by ballot count, most first", () => {
  const s = computeJudgeStandings([
    jb("a"), jb("a"), jb("a"), jb("b"), jb("b"), jb("c"),
  ], {startMs: 1000, cutoffMs: 2000});
  assert.deepStrictEqual(s.map((x) => x.uid), ["a", "b", "c"]);
  assert.strictEqual(s[0].judged, 3);
});

check("judge count ignores ballots outside the window", () => {
  const s = computeJudgeStandings([
    jb("a", 999), jb("a", 2000), jb("a", 1500), jb("a", 1800),
  ], {startMs: 1000, cutoffMs: 2000});
  assert.strictEqual(s[0].judged, 2, "only the two in-window ballots count");
});

check("judge ties break by uid; malformed ballots are skipped", () => {
  const s = computeJudgeStandings([
    jb("zed"), jb("amy"), {uid: "", at: 1500}, {at: 1500}, null,
    {uid: "x", at: "bad"},
  ], {startMs: 1000, cutoffMs: 2000});
  assert.deepStrictEqual(s.map((x) => x.uid), ["amy", "zed"]);
});

console.log(`\n${passed} passed`);
