/**
 * The clip strip (2026-11-15): the watcher strip burned into highlight clips.
 * Plain `node test/clipStrip.test.js`.
 */
const assert = require("node:assert/strict");
const {
  sanitiseTurnLog, buildStripAss, remapSpans, statesFromLog, tickSpans, fmtClock,
} = require("../clipStrip");
const {buildAssFile} = require("../captions");

let n = 0;
function check(name, fn) {
  fn();
  n++;
  console.log(`ok - ${name}`);
}

const A = "uidA";
const B = "uidB";
const CANVAS = {width: 1080, height: 1920};
const T0 = 1_000_000;

function rawLog(events, sentAt = 5_000_000) {
  return {v: 1, sentAt, kind: "rounds", turnMs: 15000, turnCount: 6,
    players: [A, B], e: events};
}

// A clean log already on the server clock (skew 0).
function log(events) {
  return sanitiseTurnLog(rawLog(events, 5_000_000), 5_000_000, [A, B]);
}

check("the phone's clock is moved onto the server's", () => {
  const l = sanitiseTurnLog(rawLog([{t: 100, f: A, n: 1, r: {[A]: 15000, [B]: 0}}],
      1000), 4000, [A, B]);
  assert.equal(l.events[0].t, 3100); // phone 3s behind
});
check("a wildly wrong clock, bad kind or no events is refused", () => {
  assert.equal(sanitiseTurnLog(rawLog([{t: 1, f: A, n: 1, r: {}}], 0), 3_600_000, [A, B]), null);
  assert.equal(sanitiseTurnLog({...rawLog([{t: 1}]), kind: "x"}, 5_000_000, [A, B]), null);
  assert.equal(sanitiseTurnLog(rawLog([]), 5_000_000, [A, B]), null);
  assert.equal(sanitiseTurnLog(null, 1, [A, B]), null);
});
check("times going backwards are refused", () => {
  assert.equal(log([{t: 200, f: A, n: 1, r: {}}, {t: 100, f: B, n: 2, r: {}}]), null);
});
check("a stranger's uid as the mic holder is dropped, clocks clamped", () => {
  const l = log([{t: 1, f: "evil", n: 1, r: {[A]: -5, [B]: 99999999}}]);
  assert.equal(l.events[0].f, null);
  assert.equal(l.events[0].r[A], 0);
  assert.equal(l.events[0].r[B], 600000);
});

check("clock shows whole seconds rounded up", () => {
  assert.equal(fmtClock(15000), "0:15");
  assert.equal(fmtClock(14001), "0:15");
  assert.equal(fmtClock(14000), "0:14");
  assert.equal(fmtClock(0), "0:00");
  assert.equal(fmtClock(61000), "1:01");
});

const BATTLE = [
  {t: T0 + 5000, f: A, n: 1, r: {[A]: 15000, [B]: 0}},
  {t: T0 + 12000, f: B, n: 2, r: {[A]: 8000, [B]: 15000}},
  {t: T0 + 27000, f: null, n: 6, r: {[A]: 0, [B]: 0}, o: 1},
];

check("states: get ready, then each turn, then TIME!", () => {
  const s = statesFromLog(log(BATTLE), T0, 30, A, B);
  assert.deepEqual(s.map((x) => x.state.phase), ["pre", "live", "live", "over"]);
  assert.equal(s[0].end, 5);
  assert.equal(s[1].state.floor, 1);
  assert.equal(s[2].state.floor, 2);
  assert.equal(s[3].end, 30);
});
check("the last turn is the gold last word", () => {
  const s = statesFromLog(log([{t: T0, f: B, n: 6, r: {[A]: 0, [B]: 15000}}]), T0, 10, A, B);
  assert.equal(s[0].state.last, true);
  assert.equal(s[0].state.round, 3);
});
check("the clock ticks once per second inside a turn", () => {
  const s = statesFromLog(log(BATTLE), T0, 30, A, B);
  const ticks = tickSpans([s[1]]); // 7s of A's turn, from 15s
  assert.equal(ticks.length, 7);
  assert.equal(fmtClock(ticks[0].state.holderMs), "0:15");
  assert.equal(fmtClock(ticks[6].state.holderMs), "0:09");
  assert.ok(Math.abs(ticks[1].start - 6) < 1e-9);
});
check("no log: just the strip, logo and names, no clock", () => {
  const s = statesFromLog(null, T0, 30, A, B);
  assert.equal(s.length, 1);
  assert.equal(s[0].state.phase, "none");
});

check("a dead-air cut splits a span and keeps where it came from", () => {
  const keeps = [{start: 0, end: 4}, {start: 6, end: 10}];
  const out = remapSpans([{start: 3, end: 8}], keeps);
  assert.equal(out.length, 2);
  assert.deepEqual([out[0].start, out[0].end], [3, 4]);
  assert.deepEqual([out[1].start, out[1].end], [4, 6]);
  assert.equal(out[1].oStart, 6);
  assert.equal(out[1].spanStart, 3);
});

function strip(extra = {}) {
  return buildStripAss({canvas: CANVAS, durationSec: 30, t0Ms: T0, log: log(BATTLE),
    p1Id: A, p2Id: B, names: {1: "TheRealRoastMasterSupreme", 2: "JudgeTestB"},
    hidden: {}, mainStage: null, keeps: null, ...extra});
}

check("the strip draws clock, round, names and the bar", () => {
  const s = strip();
  const all = s.lines.join("\n");
  assert.ok(all.includes("0:15") && all.includes("0:09"), "clock");
  assert.ok(all.includes("ROUND"), "round");
  assert.ok(all.includes("TheRealRoastMasterSupreme"), "name 1");
  assert.ok(all.includes("JudgeTestB"), "name 2");
  assert.ok(all.includes("GET READY") && all.includes("TIME!"));
  assert.ok(/\\t\(0,\d+,\\clip/.test(all), "draining bar");
  assert.ok(!all.includes("LIVE"), "no LIVE in clips");
  assert.ok(!all.includes("MAIN STAGE"), "no tag outside the Main Stage");
});
check("the speaker's name is lit, the other isn't", () => {
  const lines = strip().lines.filter((l) => l.includes("TheRealRoast"));
  // While A holds the mic (5-12s) A's name box is pink; otherwise dark.
  const lit = lines.find((l) => l.startsWith("Dialogue: 5,0:00:05.00"));
  assert.ok(lit.includes("\\3c&H7E2EFF&"));
  const dark = lines.find((l) => l.startsWith("Dialogue: 5,0:00:12.00"));
  assert.ok(dark.includes("\\3c&H000000&"));
});
check("a blurred player is not named", () => {
  const all = strip({hidden: {1: true}}).lines.join("\n");
  assert.ok(!all.includes("TheRealRoastMasterSupreme"));
  assert.ok(all.includes("JudgeTestB"));
});
check("Main Stage: gold tag, seeds, both clocks", () => {
  const chess = sanitiseTurnLog({v: 1, sentAt: 1, kind: "chess", players: [A, B],
    e: [{t: T0, f: B, n: 0, r: {[A]: 41000, [B]: 28000}}]}, 1, [A, B]);
  const all = buildStripAss({canvas: CANVAS, durationSec: 5, t0Ms: T0, log: chess,
    p1Id: A, p2Id: B, names: {1: "Carl", 2: "Maxine"}, hidden: {},
    mainStage: {label: "FINAL", seeds: {1: 1, 2: 3}}, keeps: null}).lines.join("\n");
  assert.ok(all.includes("MAIN STAGE · FINAL"));
  assert.ok(all.includes("#1 ") && all.includes("#3 "));
  assert.ok(all.includes("0:41") && all.includes("0:28"));
  assert.ok(!all.includes("ROUND"), "no rounds on a chess clock");
});
check("everything stays inside the centre column", () => {
  const all = strip().lines.join("\n");
  for (const m of all.matchAll(/\\pos\((\d+),/g)) {
    const x = Number(m[1]);
    // Full-width bars start at 0; everything else sits in 268..812.
    assert.ok(x === 0 || (x >= 150 && x <= 812), `x=${x} outside the safe area`);
  }
});
check("captions move under the bottom name when the strip is on", () => {
  const s = strip();
  const ass = buildAssFile([{start: 1, end: 2, text: "hi", uid: "1"}], CANVAS, undefined, s);
  assert.ok(ass.includes("Style: Strip,"));
  const p1 = ass.split("\n").find((l) => l.startsWith("Style: P1"));
  assert.ok(p1.includes(`,8,`) && p1.endsWith(`,${s.captionTop},1`));
  assert.ok(s.captionTop > 1015 + 40);
  // Without a strip the captions keep their centred spot.
  const plain = buildAssFile([], CANVAS);
  assert.ok(!plain.includes("Strip"));
});

console.log(`clipStrip: ${n} checks passed`);
