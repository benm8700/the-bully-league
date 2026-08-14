/**
 * Local tests for caption grouping and subtitle generation
 * (functions/captions.js). Runs with plain `node test/captions.test.js` -
 * no Speech-to-Text call needed, because the grouping and formatting are
 * pure and separated from transcription.
 *
 * The grouping rules are judgement encoded as numbers rather than anything
 * the recogniser hands back, and they decide whether captions feel snappy
 * or laggy. The ASS formatting is worth pinning too: a malformed timestamp
 * or an unescaped brace doesn't error, it silently produces a subtitle
 * track that renders wrong or not at all.
 */

const assert = require("assert");
const {
  groupWordsIntoCues,
  buildAssFile,
  formatAssTime,
  escapeAssText,
  durationToSeconds,
} = require("../captions");

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

const w = (uid, text, start, end) => ({uid, text, start, end});

// --- Speech-to-Text duration handling -------------------------------------

test("durations combine seconds and nanos", () => {
  assert.strictEqual(durationToSeconds({seconds: "2", nanos: 500000000}), 2.5);
  assert.strictEqual(durationToSeconds({seconds: 3}), 3);
  assert.strictEqual(durationToSeconds({nanos: 250000000}), 0.25);
  assert.strictEqual(durationToSeconds(null), 0);
});

// --- Cue grouping ---------------------------------------------------------

test("consecutive words from one speaker group into a cue", () => {
  const cues = groupWordsIntoCues([
    w("1", "your", 0.0, 0.2),
    w("1", "haircut", 0.2, 0.6),
    w("1", "is", 0.6, 0.8),
  ]);
  assert.strictEqual(cues.length, 1);
  assert.strictEqual(cues[0].text, "your haircut is");
});

test("cues never mix speakers", () => {
  // The whole benefit of per-player audio: attribution is certain, and
  // must survive grouping.
  const cues = groupWordsIntoCues([
    w("1", "you", 0.0, 0.2),
    w("2", "me?", 0.25, 0.5),
  ]);
  assert.strictEqual(cues.length, 2);
  assert.deepStrictEqual(cues.map((c) => c.uid), ["1", "2"]);
});

test("cues stay short rather than becoming full sentences", () => {
  const words = Array.from({length: 12}, (_, i) => w("1", `word${i}`, i * 0.2, i * 0.2 + 0.2));
  const cues = groupWordsIntoCues(words);
  assert.ok(cues.length >= 3, "a dozen words must not become one long caption");
  for (const c of cues) {
    assert.ok(c.text.split(" ").length <= 4, `cue too long: "${c.text}"`);
  }
});

test("a pause starts a new cue", () => {
  const cues = groupWordsIntoCues([
    w("1", "wait", 0.0, 0.3),
    w("1", "for", 5.0, 5.2), // long beat
    w("1", "it", 5.2, 5.4),
  ]);
  assert.strictEqual(cues.length, 2, "text must not hang across a pause");
  assert.strictEqual(cues[0].text, "wait");
});

test("a long run is split by duration even without pauses", () => {
  const words = Array.from({length: 8}, (_, i) => w("1", `w${i}`, i * 1.0, i * 1.0 + 0.9));
  const cues = groupWordsIntoCues(words);
  for (const c of cues) {
    assert.ok(c.end - c.start <= 3.5, `cue held too long: ${(c.end - c.start).toFixed(2)}s`);
  }
});

test("every cue is held long enough to be readable", () => {
  const cues = groupWordsIntoCues([w("1", "oof", 1.0, 1.05)]);
  const dwell = cues[0].end - cues[0].start;
  // Compared with a tolerance rather than exactly: the minimum is applied
  // as start + 0.4, and 0.4 has no exact binary representation, so an
  // exact >= 0.4 fails by an epsilon on a perfectly correct result.
  assert.ok(dwell > 0.39, `a single short word still needs dwell time, got ${dwell}`);
});

test("out-of-order words are sorted before grouping", () => {
  // Segments are transcribed independently, so words can arrive
  // interleaved across players.
  const cues = groupWordsIntoCues([
    w("1", "second", 2.0, 2.2),
    w("1", "first", 0.0, 0.2),
  ]);
  assert.strictEqual(cues[0].text, "first");
});

test("no words yields no cues rather than an empty caption", () => {
  assert.deepStrictEqual(groupWordsIntoCues([]), []);
});

// --- ASS timestamp formatting ---------------------------------------------

test("timestamps use ASS H:MM:SS.cc form", () => {
  assert.strictEqual(formatAssTime(0), "0:00:00.00");
  assert.strictEqual(formatAssTime(65.42), "0:01:05.42");
  assert.strictEqual(formatAssTime(3661.5), "1:01:01.50");
});

test("centisecond rounding never emits an invalid .100", () => {
  // 1.999 rounds to 100 centiseconds; that has to carry into the second.
  const formatted = formatAssTime(1.999);
  assert.ok(!formatted.includes(".100"), `invalid timestamp: ${formatted}`);
  assert.strictEqual(formatted, "0:00:02.00");
});

test("negative time clamps to zero", () => {
  assert.strictEqual(formatAssTime(-5), "0:00:00.00");
});

// --- Text escaping --------------------------------------------------------

test("braces are neutralised so they aren't read as override tags", () => {
  assert.strictEqual(escapeAssText("what {is} this"), "what (is) this");
});

test("newlines are flattened so a cue stays one dialogue line", () => {
  assert.strictEqual(escapeAssText("line one\nline two"), "line one line two");
});

// --- ASS file assembly ----------------------------------------------------

test("the subtitle file declares the video's own resolution", () => {
  // Font sizes are in script coordinates; a mismatched PlayRes renders
  // captions at the wrong scale.
  const ass = buildAssFile([], {width: 1080, height: 1920});
  assert.ok(ass.includes("PlayResX: 1080"));
  assert.ok(ass.includes("PlayResY: 1920"));
});

test("each speaker gets their own style", () => {
  const ass = buildAssFile([
    {uid: "1", start: 0, end: 1, text: "mine"},
    {uid: "2", start: 1, end: 2, text: "yours"},
  ], {width: 1080, height: 1920});
  assert.ok(/Dialogue: 0,[^,]+,[^,]+,P1,/.test(ass), "player 1 uses the P1 style");
  assert.ok(/Dialogue: 0,[^,]+,[^,]+,P2,/.test(ass), "player 2 uses the P2 style");
  assert.ok(ass.includes("Style: P1,"), "P1 style is defined");
  assert.ok(ass.includes("Style: P2,"), "P2 style is defined");
});

test("dialogue lines carry the caption text last, after nine commas", () => {
  // ASS splits a Dialogue line on the first nine commas and treats the
  // rest as text - getting the field count wrong silently drops captions.
  const ass = buildAssFile([{uid: "1", start: 0, end: 1, text: "hello there"}],
      {width: 1080, height: 1920});
  const line = ass.split("\n").find((l) => l.startsWith("Dialogue:"));
  const fields = line.slice("Dialogue: ".length).split(",");
  assert.ok(fields.length >= 10, "a dialogue line needs its full field set");
  assert.strictEqual(fields.slice(9).join(","), "hello there");
});

console.log(`captions: ${passed} checks passed`);
