/**
 * Local tests for the clip lip-sync correction (functions/clipSync.js) and its
 * use in the renderer's timeline. Runs with `node test/clipSync.test.js`.
 *
 * Pinned: an iPhone player's AUDIO is placed earlier by the configured lead,
 * video never moves, Android/unknown players are untouched, and a bad console
 * value can never produce a wild shift.
 */

const assert = require("assert");
const {
  DEFAULTS, resolveClipSync, sanitisePlatform, audioLeadByUid,
} = require("../clipSync");
const {buildTimeline, buildImprovTimelines} = require("../highlightRender");

let passed = 0;
function check(name, fn) {
  fn();
  passed++;
  console.log("ok -", name);
}

check("defaults: iOS 200ms, Android 0", () => {
  assert.deepStrictEqual(resolveClipSync(null), {iosAudioLeadMs: 200, androidAudioLeadMs: 0});
  assert.deepStrictEqual(DEFAULTS, {iosAudioLeadMs: 200, androidAudioLeadMs: 0});
});

check("config: valid override applies, bad values fall back per field", () => {
  assert.deepStrictEqual(resolveClipSync({iosAudioLeadMs: 150, androidAudioLeadMs: 40}),
      {iosAudioLeadMs: 150, androidAudioLeadMs: 40});
  assert.deepStrictEqual(resolveClipSync({iosAudioLeadMs: 99999, androidAudioLeadMs: -5}),
      {iosAudioLeadMs: 200, androidAudioLeadMs: 0});
  assert.deepStrictEqual(resolveClipSync({iosAudioLeadMs: "abc"}), DEFAULTS);
  assert.strictEqual(resolveClipSync({iosAudioLeadMs: 0}).iosAudioLeadMs, 0);
});

check("platform: only ios/android are kept", () => {
  assert.strictEqual(sanitisePlatform("ios"), "ios");
  assert.strictEqual(sanitisePlatform("android"), "android");
  assert.strictEqual(sanitisePlatform("windows"), null);
  assert.strictEqual(sanitisePlatform(undefined), null);
});

const match = {
  player1Id: "A", player2Id: "B",
  devicePlatform: {A: "ios", B: "android"},
};

check("lead by uid: iPhone player shifted, Android not", () => {
  assert.deepStrictEqual(audioLeadByUid(match, null), {"1": 200});
  const swapped = {...match, devicePlatform: {A: "android", B: "ios"}};
  assert.deepStrictEqual(audioLeadByUid(swapped, null), {"2": 200});
});

check("lead by uid: no platform reported = no shift (old matches)", () => {
  assert.deepStrictEqual(audioLeadByUid({player1Id: "A", player2Id: "B"}, null), {});
  assert.deepStrictEqual(audioLeadByUid(null, null), {});
});

const files = [
  "match_recordings/m/sid_match_m__uid_s_1__uid_e_video_20261111060607629.ts",
  "match_recordings/m/sid_match_m__uid_s_1__uid_e_audio_20261111060610000.ts",
  "match_recordings/m/sid_match_m__uid_s_2__uid_e_video_20261111060607687.ts",
  "match_recordings/m/sid_match_m__uid_s_2__uid_e_audio_20261111060610000.ts",
];

check("timeline: iPhone audio moves 200ms earlier, its video does not", () => {
  const plain = buildTimeline(files);
  const synced = buildTimeline(files, {audioLeadMsByUid: {"1": 200}});
  const off = (tl, uid, kind) =>
    tl.segments.find((s) => s.uid === uid && s.kind === kind).offsetMs;
  assert.strictEqual(off(synced, "1", "audio"), off(plain, "1", "audio") - 200);
  assert.strictEqual(off(synced, "1", "video"), off(plain, "1", "video"));
  assert.strictEqual(off(synced, "2", "audio"), off(plain, "2", "audio"));
  assert.strictEqual(off(synced, "2", "video"), off(plain, "2", "video"));
});

check("timeline: no lead map behaves exactly as before", () => {
  assert.deepStrictEqual(buildTimeline(files, {}), buildTimeline(files));
});

check("face-off timeline: same shift applied per performer", () => {
  const plain = buildImprovTimelines(files);
  const synced = buildImprovTimelines(files, {audioLeadMsByUid: {"1": 200}});
  const p1 = (r) => r.performers.find((p) => p.uid === "1").segments;
  const gap = (segs) => segs.find((s) => s.kind === "audio").offsetMs -
    segs.find((s) => s.kind === "video").offsetMs;
  assert.strictEqual(gap(p1(synced)), gap(p1(plain)) - 200);
});

console.log(`\n${passed} clipSync checks passed`);
