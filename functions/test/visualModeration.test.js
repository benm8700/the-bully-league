/**
 * Pure tests for the two SafeSearch strictness policies
 * (functions/visualModeration.js). Run: node test/visualModeration.test.js
 *
 * These EXIST because of a real bug: on 2026-09-14 the LIVE in-match detector
 * false-fired on an ordinary lit face / dark room and auto-ended a real
 * battle, and the developer loosened the live rule to blatant nudity only.
 * A future re-tightening would reintroduce that exact bug silently, so the
 * loosened live policy is pinned here - alongside the strict pre-publication
 * gate, so the two can never be confused for each other.
 */
const assert = require("assert");
const {liveFrameVerdict, prepublishVerdict} =
    require("../visualModeration");

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

// A SafeSearch annotation with everything benign, overlaid with the given
// per-category bands.
function ss(overrides) {
  return Object.assign(
      {adult: "UNLIKELY", racy: "UNLIKELY", violence: "UNLIKELY", medical: "UNLIKELY", spoof: "UNLIKELY"},
      overrides);
}

// ---- LIVE in-match frames: reject ONLY adult == VERY_LIKELY, fail OPEN ----

test("LIVE: blatant nudity (adult VERY_LIKELY) is rejected", () => {
  const v = liveFrameVerdict(ss({adult: "VERY_LIKELY"}));
  assert.strictEqual(v.approved, false);
  assert.match(v.reason, /adult/i);
});

test("LIVE: adult LIKELY is APPROVED - the false-fire class (a lit face)", () => {
  // This is the exact case that ended a real battle. LIKELY must NOT reject
  // live, or the false-positive comes straight back.
  assert.strictEqual(liveFrameVerdict(ss({adult: "LIKELY"})).approved, true);
});

test("LIVE: racy VERY_LIKELY is APPROVED (racy dropped live)", () => {
  assert.strictEqual(liveFrameVerdict(ss({racy: "VERY_LIKELY"})).approved, true);
});

test("LIVE: violence VERY_LIKELY is APPROVED (violence dropped live)", () => {
  // A lunge at the camera trips violence - it must never end a battle.
  assert.strictEqual(liveFrameVerdict(ss({violence: "VERY_LIKELY"})).approved, true);
});

test("LIVE: an ordinary frame is approved", () => {
  assert.strictEqual(liveFrameVerdict(ss({})).approved, true);
});

test("LIVE: a missing/unreadable frame FAILS OPEN (approved)", () => {
  // A transient empty SafeSearch result must never auto-end a real battle.
  assert.strictEqual(liveFrameVerdict(null).approved, true);
  assert.strictEqual(liveFrameVerdict(undefined).approved, true);
});

// ---- PRE-PUBLICATION (photos/intro): strict, reject at LIKELY, fail CLOSED ----

test("PRE-PUBLISH: adult LIKELY is rejected", () => {
  assert.strictEqual(prepublishVerdict(ss({adult: "LIKELY"}), "x").approved, false);
});

test("PRE-PUBLISH: racy LIKELY is rejected", () => {
  assert.strictEqual(prepublishVerdict(ss({racy: "LIKELY"}), "x").approved, false);
});

test("PRE-PUBLISH: violence LIKELY is rejected", () => {
  assert.strictEqual(prepublishVerdict(ss({violence: "LIKELY"}), "x").approved, false);
});

test("PRE-PUBLISH: adult POSSIBLE is approved (below the LIKELY bar)", () => {
  assert.strictEqual(prepublishVerdict(ss({adult: "POSSIBLE"}), "x").approved, true);
});

test("PRE-PUBLISH: a missing/unreadable image FAILS CLOSED (rejected)", () => {
  const v = prepublishVerdict(null, "could not analyze");
  assert.strictEqual(v.approved, false);
  assert.strictEqual(v.reason, "could not analyze");
});

// ---- The two policies must DIFFER, which is the whole point ----

test("the live and pre-publish policies genuinely differ", () => {
  // racy VERY_LIKELY: fine live, blocked pre-publish.
  assert.strictEqual(liveFrameVerdict(ss({racy: "VERY_LIKELY"})).approved, true);
  assert.strictEqual(prepublishVerdict(ss({racy: "VERY_LIKELY"}), "x").approved, false);
  // adult LIKELY: fine live, blocked pre-publish.
  assert.strictEqual(liveFrameVerdict(ss({adult: "LIKELY"})).approved, true);
  assert.strictEqual(prepublishVerdict(ss({adult: "LIKELY"}), "x").approved, false);
  // missing: fails open live, fails closed pre-publish.
  assert.strictEqual(liveFrameVerdict(null).approved, true);
  assert.strictEqual(prepublishVerdict(null, "x").approved, false);
});

if (process.exitCode) {
  console.error("\nvisualModeration: some checks FAILED");
} else {
  console.log(`visualModeration: ${passed} checks passed`);
}
