/**
 * The clip strip (2026-11-15): the watcher strip burned into highlight clips.
 * Plain `node test/clipStrip.test.js`.
 */
const assert = require("node:assert/strict");
const {
  sanitiseTurnLog, buildStripAss, remapSpans, statesFromLog, tickSpans, fmtClock,
  avatarSpots,
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

check("the strip draws clock, round and the bar - no names (pictures instead)", () => {
  const s = strip();
  const all = s.lines.join("\n");
  assert.ok(all.includes("0:15") && all.includes("0:09"), "clock");
  assert.ok(all.includes("ROUND"), "round");
  assert.ok(!all.includes("TheRealRoastMasterSupreme"), "names are no longer burned in");
  assert.ok(all.includes("GET READY") && all.includes("TIME!"));
  assert.ok(/\\t\(0,\d+,\\clip/.test(all), "draining bar");
  assert.ok(!all.includes("LIVE"), "no LIVE in clips");
  assert.ok(!all.includes("MAIN STAGE"), "no tag outside the Main Stage");
});
// The visible clip ends before the logged end (a silent final turn cut, or
// audio outlasting video): the last moments must still read TIME!.
function timeLines(st) {
  return st.lines.filter((l) => l.includes("TIME!")).map((l) => {
    const [, a, b] = l.match(/Dialogue: \d+,([^,]+),([^,]+),/);
    const sec = (t) => {
      const [h, m, x] = t.split(":");
      return Number(h) * 3600 + Number(m) * 60 + Number(x);
    };
    return [sec(a), sec(b)];
  });
}
check("TIME! shows at the end even when the video stops before the battle ends", () => {
  // Video only 20s long; the battle's end is logged at 27s.
  const st = strip({durationSec: 20});
  const t = timeLines(st);
  assert.equal(t.length, 1);
  assert.ok(Math.abs(t[0][0] - 18.5) < 0.02, `starts 1.5s before the end, got ${t[0][0]}`);
  // Nothing else (no clock) is drawn over it.
  const clockAfter = st.lines.some((l) => {
    const m = l.match(/Dialogue: \d+,([^,]+),/);
    return /\\fs50\}0:\d\d/.test(l) && m && m[1] >= "0:00:18.50";
  });
  assert.ok(!clockAfter, "no clock under TIME!");
});
check("a cut (trimmed) clip also ends on TIME!", () => {
  // Keep 0-14s only: the final turn and the end are cut as dead air.
  const st = strip({keeps: [{start: 0, end: 14}]});
  const t = timeLines(st);
  assert.equal(t.length, 1);
  assert.ok(Math.abs(t[0][0] - 12.5) < 0.02 && Math.abs(t[0][1] - 14) < 0.02);
});
check("when the real end is visible, TIME! starts at the real end", () => {
  const t = timeLines(strip());
  assert.equal(t.length, 1);
  assert.ok(Math.abs(t[0][0] - 27) < 0.02, `got ${t[0][0]}`);
});
check("no finish when the log never reached the end", () => {
  const st = buildStripAss({canvas: CANVAS, durationSec: 20, t0Ms: T0,
    log: log(BATTLE.slice(0, 2)), p1Id: A, p2Id: B, names: {}, hidden: {},
    mainStage: null, keeps: null});
  assert.equal(timeLines(st).length, 0);
});
check("no photo: an initials disc; with a photo: an overlay spot instead", () => {
  const none = strip();
  const all = none.lines.join("\n");
  assert.ok(all.includes("}T") && all.includes("}J"), "initials");
  assert.equal(none.avatars[1], null);
  const withPhotos = strip({photos: {1: true, 2: true}});
  const sp = avatarSpots(960)[1];
  const initialAt = `\\an5\\pos(${sp.x + sp.d / 2},${sp.y + sp.d / 2})`;
  assert.ok(all.includes(initialAt), "initial drawn when there is no photo");
  assert.ok(!withPhotos.lines.join("\n").includes(initialAt), "no initials under a photo");
  assert.deepEqual(withPhotos.avatars[1], avatarSpots(960)[1]);
  // Player 1 above the strip, player 2 below, both at the far left.
  assert.ok(withPhotos.avatars[1].y + 100 <= 905);
  assert.ok(withPhotos.avatars[2].y >= 1015);
});
check("the speaker's ring is lit, the other dim", () => {
  const {x, y} = avatarSpots(960)[1];
  const ring = `\\pos(${x - 8},${y - 8})`;
  const lines = strip().lines.filter((l) => l.includes(ring));
  // A holds the mic 5-12s: A's ring is pink; afterwards dim white.
  const lit = lines.find((l) => l.startsWith("Dialogue: 5,0:00:05.00"));
  assert.ok(lit.includes("\\1c&H7E2EFF&"));
  const dim = lines.find((l) => l.startsWith("Dialogue: 5,0:00:12.00"));
  assert.ok(dim.includes("\\1c&HFFFFFF&") && dim.includes("\\1a&H80&"));
});
check("a blurred player gets no picture, ring or initial", () => {
  const s = strip({hidden: {1: true}, photos: {1: true, 2: true}});
  const {x, y} = avatarSpots(960)[1];
  assert.equal(s.avatars[1], null);
  assert.ok(s.avatars[2]);
  assert.ok(!s.lines.some((l) => l.includes(`\\pos(${x - 8},${y - 8})`)));
});
check("Main Stage: gold tag, seeds, both clocks", () => {
  const chess = sanitiseTurnLog({v: 1, sentAt: 1, kind: "chess", players: [A, B],
    e: [{t: T0, f: B, n: 0, r: {[A]: 41000, [B]: 28000}}]}, 1, [A, B]);
  const all = buildStripAss({canvas: CANVAS, durationSec: 5, t0Ms: T0, log: chess,
    p1Id: A, p2Id: B, names: {1: "Carl", 2: "Maxine"}, hidden: {},
    mainStage: {label: "FINAL", seeds: {1: 1, 2: 3}}, keeps: null}).lines.join("\n");
  assert.ok(all.includes("MAIN STAGE · FINAL"));
  assert.ok(all.includes("}#1") && all.includes("}#3"));
  assert.ok(all.includes("0:41") && all.includes("0:28"));
  assert.ok(!all.includes("ROUND"), "no rounds on a chess clock");
});
check("everything stays inside the centre column", () => {
  const all = strip().lines.join("\n");
  for (const m of all.matchAll(/\\pos\((\d+),/g)) {
    const x = Number(m[1]);
    // Full-width bars start at 0; the pictures (and their glow) sit in the
    // left corners just inside the in-app crop; everything else in 150..812.
    assert.ok(x === 0 || (x >= 100 && x <= 812), `x=${x} outside the safe area`);
  }
});
check("captions move under the bottom picture when the strip is on", () => {
  const s = strip();
  const ass = buildAssFile([{start: 1, end: 2, text: "hi", uid: "1"}], CANVAS, undefined, s);
  assert.ok(ass.includes("Style: Strip,"));
  const p1 = ass.split("\n").find((l) => l.startsWith("Style: P1"));
  assert.ok(p1.includes(`,8,`) && p1.endsWith(`,${s.captionTop},1`));
  assert.ok(s.captionTop > avatarSpots(960)[2].y + 100);
  // Without a strip the captions keep their centred spot.
  const plain = buildAssFile([], CANVAS);
  assert.ok(!plain.includes("Strip"));
});

check("the strip outlasts the measured length (audio runs longer than video)", () => {
  const s = strip();
  const ends = s.lines.map((l) => l.split(",")[2]);
  // durationSec 30 -> held to 1:00, so a longer audio tail never shows a bare seam.
  assert.ok(ends.includes("0:01:00.00"), "background held past the end");
  const trimmed = strip({keeps: [{start: 0, end: 30}]});
  assert.ok(!trimmed.lines.some((l) => l.split(",")[2] === "0:01:00.00"), "trimmed clip not padded");
});

check("a 14999ms turn still ticks every second (float freeze, 2026-11-19)", () => {
  for (const base of [15000, 14999, 14001, 9871]) {
    const out = tickSpans([{start: 10.2, end: 25.2,
      state: {phase: "live", kind: "rounds", holderMs: base, clocks: {}}}]);
    for (let i = 0; i < out.length - 1; i++) {
      assert.ok(out[i].end - out[i].start <= 1.001, `frozen at ${base}`);
    }
    assert.ok(out.length >= Math.ceil(base / 1000));
  }
});

console.log(`clipStrip: ${n} checks passed`);
