/**
 * Local tests for the FACE-OFF (improv) sequential render
 * (functions/highlightRender.js). Plain `node test/improvRender.test.js` -
 * no ffmpeg: the filter graph is built purely and asserted here.
 *
 * This matters more than the composite tests, because there is no improv
 * footage to eyeball until a real 2-device Face-Off is recorded, so the
 * graph being WELL FORMED (every consumed label produced, the sets
 * concatenated with a gel border each) is the only pre-footage guarantee.
 */
const assert = require("assert");
const {
  buildImprovTimelines,
  buildImprovFfmpegArgs,
  improvSetVideoDurationMs,
  mergeImprovCues,
} = require("../highlightRender");

let passed = 0;
function test(name, fn) {
  try {
    fn();
    passed++;
    console.log(`  ok  ${name}`);
  } catch (e) {
    console.error(`FAIL: ${name}\n  ${e.message}`);
    process.exitCode = 1;
  }
}

const SID = "88032b23494f35ba2014959c146341dd";
const M = "match_improv123";
const seg = (uid, kind, stamp) =>
  `match_recordings/x/${SID}_${M}__uid_s_${uid}__uid_e_${kind}_${stamp}.ts`;

/** Every label a chain CONSUMES must be PRODUCED somewhere (or be an input
 * stream ref). The single cheapest guard against a graph ffmpeg would reject
 * outright - "Stream specifier matches no streams" and friends. */
function assertGraphConnected(args) {
  const graph = args[args.indexOf("-filter_complex") + 1];
  const inputCount = args.filter((a) => a === "-i").length;
  const produced = new Set();
  const consumed = [];
  for (const ch of graph.split(";")) {
    const lead = ch.match(/^(\[[^\]]+\])+/);
    const trail = ch.match(/(\[[^\]]+\])+$/);
    if (lead) for (const m of lead[0].matchAll(/\[([^\]]+)\]/g)) consumed.push(m[1]);
    if (trail) for (const m of trail[0].matchAll(/\[([^\]]+)\]/g)) produced.add(m[1]);
  }
  for (let i = 0; i < inputCount; i++) {
    produced.add(`${i}:v`);
    produced.add(`${i}:a`);
  }
  for (const c of consumed) {
    assert.ok(produced.has(c), `label [${c}] is consumed but never produced`);
  }
  // Must end mapping both streams.
  assert.ok(args.includes("[vout]") && args.includes("[aout]"),
      "the render must map a video and an audio stream");
}

// --- timeline -------------------------------------------------------------

test("timelines are split per performer and each rebased to its own start", () => {
  const {performers} = buildImprovTimelines([
    seg("1", "video", "20260813234113000"),
    seg("1", "audio", "20260813234113000"),
    seg("2", "video", "20260813234120000"), // player 2 started 7s later
    seg("2", "audio", "20260813234120000"),
  ]);
  assert.strictEqual(performers.length, 2);
  assert.strictEqual(performers[0].uid, "1");
  assert.strictEqual(performers[1].uid, "2");
  // Each performer's earliest segment is offset 0 - rebased to THEIR own t0,
  // not the global one. If player 2 kept the global offset their whole set
  // would start 7s late with a black lead-in.
  for (const p of performers) {
    assert.strictEqual(Math.min(...p.segments.map((s) => s.offsetMs)), 0);
  }
});

test("uids sort stably so player 1 is always the red set", () => {
  const {performers} = buildImprovTimelines([
    seg("2", "video", "20260813234113000"),
    seg("1", "video", "20260813234113000"),
  ]);
  assert.deepStrictEqual(performers.map((p) => p.uid), ["1", "2"]);
});

// --- set duration ---------------------------------------------------------

test("a set's video duration sums offset + segments + holes", () => {
  const perf = {segments: [
    {kind: "video", offsetMs: 0, durationMs: 10000},
    {kind: "video", offsetMs: 25000, durationMs: 10000}, // 15s hole before it
  ]};
  // 0 + 10000 + 15000 hole + 10000 = 35000
  assert.strictEqual(improvSetVideoDurationMs(perf), 35000);
});

test("set duration is null without per-segment durations", () => {
  const perf = {segments: [{kind: "video", offsetMs: 0}]};
  assert.strictEqual(improvSetVideoDurationMs(perf), null);
});

// --- ffmpeg graph ---------------------------------------------------------

function graphFor(paths) {
  const {performers} = buildImprovTimelines(paths);
  const args = buildImprovFfmpegArgs(performers, "/tmp/work", "/tmp/out.mp4",
      {logoPath: "/tmp/wm.png"});
  return {args, graph: args[args.indexOf("-filter_complex") + 1]};
}

test("two sets are concatenated with a black beat between them", () => {
  const {args, graph} = graphFor([
    seg("1", "video", "20260813234113000"),
    seg("1", "audio", "20260813234113000"),
    seg("2", "video", "20260813234113000"),
    seg("2", "audio", "20260813234113000"),
  ]);
  assertGraphConnected(args);
  // 2 performer sets + 1 gap = 3 concat segments.
  assert.ok(/concat=n=3:v=1:a=1/.test(graph),
      "two sets plus a gap make three concat segments");
  // The gap is a black source with its own silent audio.
  assert.ok(/color=c=black:[^;]*d=0\.75/.test(graph), "a 0.75s black beat");
});

test("player 1's set is red and player 2's is blue", () => {
  const {graph} = graphFor([
    seg("1", "video", "20260813234113000"),
    seg("1", "audio", "20260813234113000"),
    seg("2", "video", "20260813234113000"),
    seg("2", "audio", "20260813234113000"),
  ]);
  // Borders use the exact in-app gel colours so the clip matches the vote UI.
  assert.ok(/drawbox=[^;]*color=0xC4485E@1/.test(graph), "player 1 red border");
  assert.ok(/drawbox=[^;]*color=0x5E93A8@1/.test(graph), "player 2 blue border");
});

test("each performer's set fills the full canvas, not a tile", () => {
  const {graph} = graphFor([
    seg("1", "video", "20260813234113000"),
    seg("1", "audio", "20260813234113000"),
    seg("2", "video", "20260813234113000"),
    seg("2", "audio", "20260813234113000"),
  ]);
  // Full 1080x1920, not the 1080x960 composite tile.
  assert.ok(/scale=1080:1920/.test(graph), "scaled to the full vertical canvas");
  assert.ok(!/1080:960/.test(graph), "never the stacked tile size");
});

test("the watermark is overlaid last", () => {
  const {graph} = graphFor([
    seg("1", "video", "20260813234113000"),
    seg("1", "audio", "20260813234113000"),
    seg("2", "video", "20260813234113000"),
    seg("2", "audio", "20260813234113000"),
  ]);
  assert.ok(/\[ivcat\]\[iwm\]overlay=.*\[vout\]/.test(graph),
      "the concatenated video gets the logo overlay into [vout]");
});

test("a silent set still carries an audio stream so concat lines up", () => {
  const {args, graph} = graphFor([
    seg("1", "video", "20260813234113000"),
    // player 1 has NO audio segment
    seg("2", "video", "20260813234113000"),
    seg("2", "audio", "20260813234113000"),
  ]);
  assertGraphConnected(args);
  assert.ok(/anullsrc/.test(graph), "the silent set gets a null audio source");
});

test("a lone performer renders without concat=n=1", () => {
  // If the opponent never published, one set still renders - some ffmpeg
  // builds reject concat=n=1, so it must be a plain pass-through.
  const {args, graph} = graphFor([
    seg("1", "video", "20260813234113000"),
    seg("1", "audio", "20260813234113000"),
  ]);
  assertGraphConnected(args);
  assert.ok(!/concat=n=1/.test(graph), "no concat for a single set");
});

test("multiple video segments in one set are concatenated in order", () => {
  const {performers} = buildImprovTimelines([
    seg("1", "video", "20260813234113000"),
    seg("1", "video", "20260813234143000"),
    seg("1", "audio", "20260813234113000"),
    seg("2", "video", "20260813234113000"),
    seg("2", "audio", "20260813234113000"),
  ]);
  const args = buildImprovFfmpegArgs(performers, "/tmp/work", "/tmp/out.mp4", {});
  assertGraphConnected(args);
  const graph = args[args.indexOf("-filter_complex") + 1];
  assert.ok(/concat=n=2:v=1:a=0/.test(graph),
      "player 1's two video segments concatenate");
});

// --- captions: cue merge + subtitle threading ----------------------------

test("mergeImprovCues offsets P2's set past P1's set plus the beat", () => {
  const merged = mergeImprovCues([
    {durationSec: 40, cues: [{uid: "1", start: 2, end: 4, text: "a"}]},
    {durationSec: 42, cues: [{uid: "2", start: 1, end: 3, text: "b"}]},
  ], 0.75);
  assert.strictEqual(merged.length, 2);
  // P1's cue is unchanged (set 0, offset 0).
  assert.strictEqual(merged[0].uid, "1");
  assert.strictEqual(merged[0].start, 2);
  assert.strictEqual(merged[0].end, 4);
  // P2's cue is shifted by 40 + 0.75 = 40.75, so it lands over P2's set.
  assert.strictEqual(merged[1].uid, "2");
  assert.ok(Math.abs(merged[1].start - 41.75) < 1e-9, `${merged[1].start}`);
  assert.ok(Math.abs(merged[1].end - 43.75) < 1e-9, `${merged[1].end}`);
});

test("mergeImprovCues tolerates a null duration / empty set", () => {
  const merged = mergeImprovCues([
    {durationSec: null, cues: null},
    {durationSec: 30, cues: [{uid: "2", start: 0, end: 1, text: "x"}]},
  ], 0.75);
  // A null first-set duration counts as 0, so set 1 offsets by just the beat.
  assert.strictEqual(merged.length, 1);
  assert.ok(Math.abs(merged[0].start - 0.75) < 1e-9, `${merged[0].start}`);
});

test("a subtitlePath threads a subtitles filter UNDER the watermark", () => {
  const {performers} = buildImprovTimelines([
    seg("1", "video", "20260813234113000"),
    seg("1", "audio", "20260813234113000"),
    seg("2", "video", "20260813234113000"),
    seg("2", "audio", "20260813234113000"),
  ]);
  const args = buildImprovFfmpegArgs(performers, "/tmp/work", "/tmp/out.mp4",
      {logoPath: "/tmp/wm.png", subtitlePath: "/tmp/cap.ass"});
  assertGraphConnected(args);
  const graph = args[args.indexOf("-filter_complex") + 1];
  assert.ok(/\[ivcat\]subtitles=.*\[ivsub\]/.test(graph),
      "subtitles are burned after the concat");
  assert.ok(/\[ivsub\]\[iwm\]overlay=.*\[vout\]/.test(graph),
      "the watermark overlays the subtitled video, so the logo sits above captions");
});

console.log(`\n${passed} passed`);
