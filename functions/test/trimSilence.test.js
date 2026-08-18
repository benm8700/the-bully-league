/**
 * Local tests for dead-air trimming (functions/trimSilence.js).
 * Runs with `node test/trimSilence.test.js`.
 *
 * The tests are weighted toward what it REFUSES to cut, because the two
 * failure directions are not symmetrical. Under-trimming costs a slightly
 * slack clip. Over-trimming deletes footage from the rendered file, takes
 * the timing that made a joke land with it, and cannot be recovered
 * without paying to render again.
 */

const assert = require("assert");
const {
  planKeeps,
  remapTime,
  remapCues,
  removedSeconds,
  trims,
  buildTrimFilters,
  shouldTrim,
  MIN_GAP_SECONDS,
} = require("../trimSilence");

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

/** Words at one-second intervals over [from, to). */
function speech(from, to, uid = "a") {
  const words = [];
  for (let t = from; t < to; t += 0.5) {
    words.push({uid, text: "x", start: t, end: t + 0.4});
  }
  return words;
}

// --- what it refuses to do ----------------------------------------------

test("NO TRANSCRIPT MEANS NO TRIMMING, never a full cut", () => {
  // A clip that transcribed to nothing is one we know nothing about.
  // Treating silence as "cut everything" would delete the whole battle.
  for (const words of [[], null, undefined]) {
    const keeps = planKeeps(words, {duration: 60});
    assert.deepStrictEqual(keeps, [{start: 0, end: 60}]);
  }
});

test("ANY TRANSCRIPTION FAILURE DISABLES TRIMMING ENTIRELY", () => {
  // The specific disaster: transcription runs per player, so one failure
  // leaves that player's whole turn with no words - it reads as dead air
  // and would be cut out, deleting half the battle while the render
  // succeeds and looks perfectly fine.
  const words = [...speech(0, 10, "a"), ...speech(20, 30, "b")];
  const withFailure = planKeeps(words,
      {duration: 30, failures: ["seg2.ts: deadline exceeded"]});
  assert.deepStrictEqual(withFailure, [{start: 0, end: 30}]);
  assert.strictEqual(shouldTrim(words, ["boom"]), false);
  // ...and without the failure it genuinely would have cut, so this
  // test cannot pass merely because there was nothing to cut.
  assert.ok(trims(planKeeps(words, {duration: 30}), 30));
});

test("IT BAILS OUT rather than removing most of a clip", () => {
  // Even with no reported failure, a clip that is mostly silence by this
  // measure is one we do not understand.
  const words = speech(0, 2);
  const keeps = planKeeps(words, {duration: 120});
  assert.deepStrictEqual(keeps, [{start: 0, end: 120}],
      "removing 98% of a clip must never look like success");
});

test("A SHORT PAUSE IS A BEAT and is left alone", () => {
  // In roast content the reaction is frequently funnier than the line,
  // and the moment right after a punch lands is exactly what a naive
  // trimmer deletes.
  const words = [...speech(0, 5), ...speech(5 + MIN_GAP_SECONDS - 0.5, 12)];
  const keeps = planKeeps(words, {duration: 12});
  assert.strictEqual(trims(keeps, 12), false,
      `a gap under ${MIN_GAP_SECONDS}s must survive`);
});

test("even a cut gap keeps some of the pause", () => {
  // Lengths here are realistic on purpose: a real match runs about two
  // minutes, so a ten-second stall is a small share of it. Shorter
  // fixtures trip the bail-out guard and end up testing that instead.
  const words = [...speech(0, 20), ...speech(30, 50)];
  const keeps = planKeeps(words, {duration: 50});
  const removed = removedSeconds(keeps, 50);
  assert.ok(removed > 0, "a ten-second stall should be cut");
  assert.ok(removed < 10,
      `the whole gap was removed (${removed}s) - a cut must still breathe`);
});

// --- what it does do -----------------------------------------------------

test("a long stall in the middle is cut", () => {
  const words = [...speech(0, 40), ...speech(55, 100)];
  const keeps = planKeeps(words, {duration: 100});
  assert.ok(keeps.length > 1, "expected a cut");
  assert.ok(removedSeconds(keeps, 100) > 5);
});

test("LEADING DEAD AIR IS CUT FROM THE FRONT", () => {
  // The opening second is where a viewer decides whether to keep
  // watching, and there is nothing before it to breathe from - so unlike
  // a middle gap this is trimmed from its start rather than split.
  const words = speech(8, 20);
  const keeps = planKeeps(words, {duration: 20});
  assert.ok(keeps[0].start > 4,
      `clip still opens on ${keeps[0].start}s of nothing`);
});

test("trailing dead air is cut too", () => {
  const words = speech(0, 30);
  const keeps = planKeeps(words, {duration: 40});
  const last = keeps[keeps.length - 1];
  assert.ok(last.end < 40, "the clip should not end on silence");
});

test("keeps are ordered, non-overlapping and inside the clip", () => {
  const words = [...speech(0, 4), ...speech(12, 16), ...speech(30, 34)];
  const keeps = planKeeps(words, {duration: 40});
  let prev = -1;
  for (const k of keeps) {
    assert.ok(k.start >= 0 && k.end <= 40, JSON.stringify(k));
    assert.ok(k.end > k.start, JSON.stringify(k));
    assert.ok(k.start >= prev, "keeps out of order");
    prev = k.end;
  }
});

test("speech is padded, so a cut never lands on a syllable", () => {
  const words = [...speech(0, 5), ...speech(20, 25)];
  const keeps = planKeeps(words, {duration: 25});
  // The first keep must extend past the last word's end.
  assert.ok(keeps[0].end > 5, `first keep ended at ${keeps[0].end}`);
});

// --- caption remapping ---------------------------------------------------

test("THE CAPTIONS MOVE WITH THE CUTS", () => {
  // Without this the subtitles drift further out of sync with every cut,
  // and a clip whose captions lag the mouth by three seconds looks
  // broken rather than merely unsubtitled.
  const keeps = [{start: 0, end: 5}, {start: 15, end: 20}];
  assert.strictEqual(remapTime(2, keeps), 2);
  assert.strictEqual(remapTime(16, keeps), 6,
      "a moment after a cut must shift back by the cut length");
});

test("a moment inside a cut has no place on the new timeline", () => {
  const keeps = [{start: 0, end: 5}, {start: 15, end: 20}];
  assert.strictEqual(remapTime(9, keeps), null);
});

test("a cue whose words were cut is dropped, not misplaced", () => {
  const keeps = [{start: 0, end: 5}, {start: 15, end: 20}];
  const cues = remapCues([
    {start: 1, end: 2, text: "kept"},
    {start: 8, end: 9, text: "cut"},
  ], keeps);
  assert.strictEqual(cues.length, 1);
  assert.strictEqual(cues[0].text, "kept");
});

test("a cue spanning a cut is COMPRESSED, not left hanging", () => {
  // The cut is removed from inside the cue, so it must end up SHORTER
  // than it was in the source - otherwise it hangs on screen through a
  // jump, which reads as a stuck subtitle rather than an edit.
  //
  // In practice this cannot arise: cues are split on any pause over
  // 0.6s and only gaps over 2.5s are ever cut, so no cue can span one.
  // Asserted anyway, because that relationship between two separate
  // modules' constants is not enforced anywhere.
  const keeps = [{start: 0, end: 5}, {start: 15, end: 20}];
  const [cue] = remapCues([{start: 4.5, end: 16, text: "straddles"}], keeps);
  assert.ok(cue.end - cue.start < 16 - 4.5,
      `cue ran ${cue.end - cue.start}s, longer than in the source`);
  assert.ok(cue.end > cue.start);
});

test("remapped cues stay ordered and positive", () => {
  const keeps = [{start: 0, end: 5}, {start: 15, end: 20}];
  const cues = remapCues([
    {start: 0.5, end: 1}, {start: 3, end: 4}, {start: 16, end: 17},
  ], keeps);
  let prev = -1;
  for (const c of cues) {
    assert.ok(c.start >= prev, "cues out of order");
    assert.ok(c.end > c.start);
    prev = c.start;
  }
});

// --- the filter ----------------------------------------------------------

test("no filter is produced when nothing is cut", () => {
  // The caller leaves its graph untouched rather than paying for a no-op
  // decode pass on every clip.
  assert.strictEqual(buildTrimFilters([{start: 0, end: 30}], 30), null);
});

test("the filter names every kept interval, for video AND audio", () => {
  const keeps = [{start: 0, end: 5}, {start: 15, end: 20}];
  const f = buildTrimFilters(keeps, 20);
  assert.ok(f.video.includes("between(t,0.000,5.000)"));
  assert.ok(f.video.includes("between(t,15.000,20.000)"));
  // Audio must be cut identically or the clip desynchronises, which is a
  // worse outcome than not trimming at all.
  assert.ok(f.audio.includes("between(t,15.000,20.000)"));
  assert.ok(f.video.includes("setpts") && f.audio.includes("asetpts"),
      "the holes left by select must be closed up");
});

// --- degenerate input ----------------------------------------------------

test("junk words cannot produce a nonsense plan", () => {
  const keeps = planKeeps([
    {start: NaN, end: 5}, {start: 3, end: 1}, {start: "x", end: "y"},
    ...speech(0, 5),
  ], {duration: 20});
  for (const k of keeps) {
    assert.ok(Number.isFinite(k.start) && Number.isFinite(k.end));
    assert.ok(k.end > k.start);
  }
});

test("a zero or unknown duration trims nothing", () => {
  assert.deepStrictEqual(planKeeps(speech(0, 5), {duration: 0}), []);
  assert.deepStrictEqual(planKeeps(speech(0, 5), {duration: undefined}), []);
});

console.log(`trimSilence: ${passed} checks passed`);
