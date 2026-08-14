/**
 * Local tests for highlight render timing (functions/highlightRender.js).
 * Runs with plain `node test/highlightRender.test.js` - no ffmpeg needed,
 * because the alignment maths is pure and separated from the invocation.
 *
 * This is the part worth testing hard. A compositing mistake is obvious
 * the moment anyone watches the clip; a timing mistake is not. Each
 * player's mic is muted during their opponent's turn, so their audio has
 * gaps, and if those gaps are collapsed the audio slides progressively out
 * of sync with the picture - which looks like a vague "the video feels
 * off" rather than an error, and gets steadily worse later in the clip
 * where the funniest material usually is.
 */

const assert = require("assert");
const {
  parseSegmentTimeMs,
  classifyFile,
  buildTimeline,
  buildFfmpegArgs,
  RENDITIONS,
} = require("../highlightRender");

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

// Real filenames from a recorded match.
const SID = "88032b23494f35ba2014959c146341dd";
const M = "match_9UYg8wfuQgdIVaVw5hGR";
const seg = (uid, kind, stamp) =>
  `match_recordings/x/${SID}_${M}__uid_s_${uid}__uid_e_${kind}_${stamp}.ts`;
const playlist = (uid, kind) =>
  `match_recordings/x/${SID}_${M}__uid_s_${uid}__uid_e_${kind}.m3u8`;

// --- Timestamp parsing ----------------------------------------------------

test("a segment timestamp is parsed to a real instant", () => {
  const ms = parseSegmentTimeMs(`${SID}_${M}__uid_s_1__uid_e_audio_20260813234113969.ts`);
  const d = new Date(ms);
  assert.strictEqual(d.getUTCFullYear(), 2026);
  assert.strictEqual(d.getUTCMonth() + 1, 8);
  assert.strictEqual(d.getUTCDate(), 13);
  assert.strictEqual(d.getUTCHours(), 23);
  assert.strictEqual(d.getUTCMinutes(), 41);
  assert.strictEqual(d.getUTCSeconds(), 13);
  assert.strictEqual(d.getUTCMilliseconds(), 969);
});

test("timestamps preserve millisecond ordering", () => {
  const a = parseSegmentTimeMs(`x_audio_20260813234113076.ts`);
  const b = parseSegmentTimeMs(`x_audio_20260813234113969.ts`);
  assert.strictEqual(b - a, 893, "sub-second differences must survive parsing");
});

test("playlists and junk parse to null rather than epoch zero", () => {
  // Returning 0 here would silently place a track at the very start.
  assert.strictEqual(parseSegmentTimeMs(`x_audio.m3u8`), null);
  assert.strictEqual(parseSegmentTimeMs(`nonsense.ts`), null);
});

// --- Classification -------------------------------------------------------

test("files are attributed to the right player and track", () => {
  assert.deepStrictEqual(
      {...classifyFile(seg("2", "video", "20260813234112808"))},
      {
        name: `${SID}_${M}__uid_s_2__uid_e_video_20260813234112808.ts`,
        uid: "2", kind: "video", isPlaylist: false,
      },
  );
  assert.strictEqual(classifyFile(playlist("1", "audio")).isPlaylist, true);
});

// --- Timeline -------------------------------------------------------------

test("offsets are measured from the earliest track, not from zero", () => {
  const t = buildTimeline([
    seg("1", "video", "20260813234113076"),
    seg("2", "video", "20260813234112808"), // earliest
    seg("1", "audio", "20260813234113969"),
  ]);
  const byName = (uid, kind) => t.segments.find((s) => s.uid === uid && s.kind === kind);
  assert.strictEqual(byName("2", "video").offsetMs, 0, "earliest track anchors the clip");
  assert.strictEqual(byName("1", "video").offsetMs, 268);
  assert.strictEqual(byName("1", "audio").offsetMs, 1161);
});

test("playlists are excluded from the timeline", () => {
  const t = buildTimeline([playlist("1", "audio"), seg("1", "audio", "20260813234113969")]);
  assert.strictEqual(t.segments.length, 1);
});

test("gaps between a player's audio segments are preserved", () => {
  // The whole point: player 1 speaks, is muted for their opponent's turn,
  // then speaks again. The second stretch must stay at its real offset.
  const t = buildTimeline([
    seg("1", "audio", "20260813234113000"),
    seg("1", "audio", "20260813234153000"), // 40s later, after a muted turn
  ]);
  const offsets = t.segments.map((s) => s.offsetMs);
  assert.deepStrictEqual(offsets, [0, 40000], "a 40s mute must remain a 40s offset");
});

test("player order is stable regardless of who started publishing first", () => {
  const later = buildTimeline([
    seg("2", "video", "20260813234112000"), // player 2 started first
    seg("1", "video", "20260813234113000"),
  ]);
  assert.deepStrictEqual(later.uids, ["1", "2"], "player 1 always renders on top");
});

test("an empty or unusable recording yields an empty timeline, not a crash", () => {
  assert.deepStrictEqual(buildTimeline([]).segments, []);
  assert.deepStrictEqual(buildTimeline([playlist("1", "audio")]).segments, []);
});

// --- ffmpeg arguments -----------------------------------------------------

function argsFor(paths) {
  return buildFfmpegArgs(buildTimeline(paths), "/tmp/work", "/tmp/out.mp4");
}

test("filter input indices count inputs, not argv entries", () => {
  // Regression: the index was taken from the args array's length, which
  // advances by two per input because it holds the "-i" flag as well as
  // the path. Every filter got an index of 0, 2, 4... and ffmpeg rejected
  // the whole graph with "Stream specifier ':v' matches no streams".
  const args = argsFor([
    seg("1", "video", "20260813234113000"),
    seg("2", "video", "20260813234113000"),
    seg("1", "audio", "20260813234113000"),
    seg("2", "audio", "20260813234123000"),
  ]);
  const graph = args[args.indexOf("-filter_complex") + 1];
  const referenced = [...graph.matchAll(/\[(\d+):[av]\]/g)].map((m) => Number(m[1]));
  const inputCount = args.filter((a) => a === "-i").length;

  assert.deepStrictEqual(
      [...referenced].sort((a, b) => a - b),
      [0, 1, 2, 3],
      "indices must be consecutive from zero",
  );
  assert.strictEqual(inputCount, 4, "one -i per referenced stream");
  for (const i of referenced) {
    assert.ok(i < inputCount, `index ${i} exceeds the ${inputCount} declared inputs`);
  }
});

test("truncated segments are dropped when sizes are supplied", () => {
  // A few-millisecond trailing fragment can be undecodable and abort the
  // entire render; one unusable scrap must not cost the whole clip.
  const t = buildTimeline([
    {path: seg("1", "video", "20260813234113000"), sizeBytes: 900000},
    {path: seg("1", "audio", "20260813234113000"), sizeBytes: 140000},
    {path: seg("1", "audio", "20260813234153000"), sizeBytes: 900}, // truncated tail
  ]);
  assert.strictEqual(t.segments.length, 2);
  assert.strictEqual(t.dropped.length, 1);
});

test("each audio segment is delayed to its own offset", () => {
  const args = argsFor([
    seg("1", "video", "20260813234113000"),
    seg("1", "audio", "20260813234113000"),
    seg("1", "audio", "20260813234153000"),
  ]);
  const graph = args[args.indexOf("-filter_complex") + 1];
  assert.ok(graph.includes("adelay=0|0"), "first segment starts at zero");
  assert.ok(graph.includes("adelay=40000|40000"), "second segment keeps its 40s offset");
});

test("a late-starting video is padded rather than pulled forward", () => {
  const args = argsFor([
    seg("2", "video", "20260813234112808"),
    seg("1", "video", "20260813234113808"), // a full second later
  ]);
  const graph = args[args.indexOf("-filter_complex") + 1];
  assert.ok(graph.includes("tpad=start_duration=1.000"), "the later video gets 1s of black");
  assert.ok(graph.includes("tpad=start_duration=0.000"), "the earlier video is not shifted");
});

test("two players are stacked vertically", () => {
  const args = argsFor([
    seg("1", "video", "20260813234113000"),
    seg("2", "video", "20260813234113000"),
  ]);
  const graph = args[args.indexOf("-filter_complex") + 1];
  assert.ok(graph.includes("vstack=inputs=2"), "stacked, not side by side");
});

test("a solo player fills the frame instead of stacking against black", () => {
  const args = argsFor([seg("1", "video", "20260813234113000")]);
  const graph = args[args.indexOf("-filter_complex") + 1];
  assert.ok(!graph.includes("vstack"), "nothing to stack against");
  assert.ok(graph.includes("crop=1080:1920"), "fills the full canvas");
});

test("audio is mixed without normalising", () => {
  // Segments don't overlap, so normalising would duck every player's
  // volume by the number of inputs for no reason.
  const args = argsFor([
    seg("1", "video", "20260813234113000"),
    seg("1", "audio", "20260813234113000"),
    seg("2", "audio", "20260813234123000"),
  ]);
  const graph = args[args.indexOf("-filter_complex") + 1];
  assert.ok(graph.includes("amix=inputs=2:normalize=0"));
});

test("a recording with no video is refused rather than rendering silence", () => {
  assert.throws(
      () => argsFor([seg("1", "audio", "20260813234113000")]),
      /no video track/,
  );
});

test("output is vertical 9:16 with a playable moov position", () => {
  const args = argsFor([
    seg("1", "video", "20260813234113000"),
    seg("2", "video", "20260813234113000"),
  ]);
  const graph = args[args.indexOf("-filter_complex") + 1];
  assert.ok(graph.includes("scale=1080:960"), "each tile is half of 1080x1920");
  assert.ok(args.includes("+faststart"), "index at the front so it streams while downloading");
  assert.ok(args.includes("yuv420p"), "widely-playable pixel format");
});

// --- Renditions -----------------------------------------------------------

test("the landscape rendition puts players side by side, not stacked", () => {
  // Side-by-side is right in 16:9 and wrong in 9:16 - the two renditions
  // must not share a stacking direction.
  const timeline = buildTimeline([
    seg("1", "video", "20260813234113000"),
    seg("2", "video", "20260813234113000"),
  ]);
  const args = buildFfmpegArgs(timeline, "/tmp/work", "/tmp/out.mp4",
      {rendition: RENDITIONS.landscape});
  const graph = args[args.indexOf("-filter_complex") + 1];
  assert.ok(graph.includes("hstack=inputs=2"), "landscape stacks horizontally");
  assert.ok(!graph.includes("vstack"), "and never vertically");
  assert.ok(graph.includes("scale=960:1080"), "each tile is half of 1920x1080");
});

test("the two renditions differ in shape and filename", () => {
  const v = RENDITIONS.vertical;
  const l = RENDITIONS.landscape;
  assert.strictEqual(v.canvas.width / v.canvas.height, 9 / 16, "vertical is 9:16");
  assert.strictEqual(l.canvas.width / l.canvas.height, 16 / 9, "landscape is 16:9");
  assert.notStrictEqual(v.fileName, l.fileName, "they must not overwrite each other");
});

test("tiles tile exactly, leaving no dead space in either rendition", () => {
  for (const [name, r] of Object.entries(RENDITIONS)) {
    const across = r.stackFilter === "hstack";
    const totalW = across ? r.tile.width * 2 : r.tile.width;
    const totalH = across ? r.tile.height : r.tile.height * 2;
    assert.strictEqual(totalW, r.canvas.width, `${name} tiles do not fill the width`);
    assert.strictEqual(totalH, r.canvas.height, `${name} tiles do not fill the height`);
  }
});

console.log(`highlightRender: ${passed} checks passed`);
