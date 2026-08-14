/**
 * Local tests for the retention decision (functions/
 * recordingRetention.js). Runs with plain `node
 * test/recordingRetention.test.js`.
 *
 * This is the highest-consequence logic in the recording pipeline: it
 * irreversibly deletes video of real people, and the line between "purge"
 * and "keep" is a promise made in the published Privacy Policy. A bug in
 * the keep direction leaks footage past its retention window; a bug in the
 * purge direction destroys a published highlight that can't be recovered.
 */

const assert = require("assert");
const {purgeDecision, RETENTION_DAYS, RETENTION_MS} = require("../recordingRetention");

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

test("the retention window is the 7 days CLAUDE.md decided on", () => {
  assert.strictEqual(RETENTION_DAYS, 7);
  assert.strictEqual(RETENTION_MS, 7 * 24 * 60 * 60 * 1000);
});

test("the window comfortably outlasts the 24h vote window", () => {
  // Deliberate: a report has to be reviewable against the footage after
  // voting closes, so retention must exceed the vote window by a margin.
  const voteWindowMs = 24 * 60 * 60 * 1000;
  assert.ok(RETENTION_MS > voteWindowMs * 2, "retention should leave real review headroom");
});

test("a match with no recording is skipped, not purged", () => {
  assert.strictEqual(purgeDecision({}), "skip");
  assert.strictEqual(purgeDecision({recording: null}), "skip");
});

test("an already-purged recording is skipped, so the sweep is idempotent", () => {
  assert.strictEqual(purgeDecision({recording: {purged: true}}), "skip");
});

test("unpublished raw footage is purged", () => {
  assert.strictEqual(purgeDecision({recording: {status: "recorded", published: false}}), "purge");
});

test("a published highlight is KEPT - this is the one that must never regress", () => {
  // CLAUDE.md's CCPA position: an already-public clip is not
  // retroactively unpublished, so the sweep must not delete it.
  assert.strictEqual(purgeDecision({recording: {status: "recorded", published: true}}), "keep");
});

test("only an explicit `true` counts as published", () => {
  // Anything ambiguous must fall to purge rather than accidentally
  // retaining footage forever past the window we promised.
  for (const value of [undefined, null, false, "true", 1]) {
    assert.strictEqual(
        purgeDecision({recording: {published: value}}),
        "purge",
        `published=${JSON.stringify(value)} should not count as published`,
    );
  }
});

test("a failed recording is still purged rather than left behind", () => {
  // start_failed/stop_failed matches can still have stray files in
  // storage; they must not become permanent residue.
  assert.strictEqual(purgeDecision({recording: {status: "start_failed"}}), "purge");
  assert.strictEqual(purgeDecision({recording: {status: "stop_failed"}}), "purge");
});

// --- Rendered highlights, swept by the same rule -------------------------

test("an unpublished RENDER is purged, not just the raw footage", () => {
  // A render is as much a copy of two people's faces as its source, so
  // leaving it would quietly outlive the retention window regardless of
  // what happened to the raw files.
  assert.strictEqual(
      purgeDecision({recording: {purged: true}, highlight: {published: false}}),
      "purge",
      "an already-swept recording must not stop a leftover render being swept",
  );
});

test("a published render is KEPT even if the raw recording says otherwise", () => {
  // Publication is recorded on the highlight once one exists; that is the
  // authoritative flag at that point.
  assert.strictEqual(
      purgeDecision({recording: {published: false}, highlight: {published: true}}),
      "keep",
  );
});

test("a match with a render but no recording record is still handled", () => {
  assert.strictEqual(purgeDecision({highlight: {published: false}}), "purge");
  assert.strictEqual(purgeDecision({highlight: {published: true}}), "keep");
});

test("a still-recording match is purged if it somehow survives the window", () => {
  // A match stuck "recording" for over 7 days is broken, not live - the
  // hourly finalization sweep would have abandoned it long before.
  assert.strictEqual(purgeDecision({recording: {status: "recording"}}), "purge");
});

console.log(`recordingRetention: ${passed} checks passed`);
