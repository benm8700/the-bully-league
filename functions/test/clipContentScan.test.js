const assert = require("assert");
const {scanRecordingForContent, pickSpread} =
  require("../clipContentScan");

let passed = 0;
function check(name, fn) {
  try {
    fn();
    passed++;
    console.log("  ok -", name);
  } catch (e) {
    console.error("  FAIL -", name, "\n   ", e.message);
    process.exitCode = 1;
  }
}

// ---- pickSpread ----
check("pickSpread returns all when n >= length", () => {
  assert.deepStrictEqual(pickSpread([1, 2, 3], 6), [1, 2, 3]);
});
check("pickSpread spreads evenly across a long array", () => {
  const got = pickSpread([0, 1, 2, 3, 4, 5, 6, 7, 8, 9], 5);
  assert.strictEqual(got.length, 5);
  // Evenly spaced indices 0,2,4,6,8.
  assert.deepStrictEqual(got, [0, 2, 4, 6, 8]);
});

// ---- scanRecordingForContent (injected extract + moderate) ----
function timelineOf() {
  return {
    uids: ["1", "2"],
    segments: [
      {uid: "1", kind: "video", path: "r/1a.ts"},
      {uid: "1", kind: "video", path: "r/1b.ts"},
      {uid: "1", kind: "audio", path: "r/1a_audio.ts"},
      {uid: "2", kind: "video", path: "r/2a.ts"},
      {uid: "2", kind: "video", path: "r/2b.ts"},
    ],
  };
}
// extract returns the segment basename as its "frame", so moderate can decide
// per frame deterministically without ffmpeg.
const extract = async (_ff, local) => local.split(/[\\/]/).pop();

(async () => {
  await (async () => {
    check("a clean recording is not blocked", async () => {
      const r = await scanRecordingForContent(
          timelineOf(), "/tmp", "ffmpeg",
          async () => ({approved: true}), extract);
      assert.strictEqual(r.blocked, false);
    });

    // player 2's second frame trips -> attributed to uid "2".
    check("a trip attributes to the player whose own stream tripped", async () => {
      const r = await scanRecordingForContent(
          timelineOf(), "/tmp", "ffmpeg",
          async (frame) => frame === "2b.ts" ?
            {approved: false, reason: "nudity"} : {approved: true},
          extract);
      assert.strictEqual(r.blocked, true);
      assert.strictEqual(r.reportedUid, "2");
    });

    check("player 1 tripping attributes to uid 1", async () => {
      const r = await scanRecordingForContent(
          timelineOf(), "/tmp", "ffmpeg",
          async (frame) => frame === "1a.ts" ?
            {approved: false} : {approved: true},
          extract);
      assert.strictEqual(r.blocked, true);
      assert.strictEqual(r.reportedUid, "1");
    });

    check("a frame that can't be extracted is skipped, not a block", async () => {
      const r = await scanRecordingForContent(
          timelineOf(), "/tmp", "ffmpeg",
          async () => { throw new Error("vision down"); },
          async () => null); // extraction always fails
      assert.strictEqual(r.blocked, false);
    });

    check("a moderate() error on one frame is skipped, not a block", async () => {
      const r = await scanRecordingForContent(
          timelineOf(), "/tmp", "ffmpeg",
          async () => { throw new Error("transient"); },
          extract);
      assert.strictEqual(r.blocked, false);
    });

    console.log(`\n${passed} checks passed.`);
  })();
})();
