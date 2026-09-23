/**
 * Local tests for publish naming (functions/publishHighlight.js).
 *
 * The one subtle correctness point since captioned clips became a SEPARATE
 * file: the captioned cut (`vertical_captioned.mp4`) and the plain cut
 * (`vertical.mp4`) are the SAME rendition and must collapse to one public
 * key, or a published match would expose two `publicUrls` entries and the
 * website/profile would not know which to play.
 */

const assert = require("assert");
const {renditionNameFromPath} = require("../publishHighlight");

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

test("plain cut maps to its rendition name", () => {
  assert.strictEqual(
      renditionNameFromPath("match_highlights/abc/vertical.mp4"), "vertical");
  assert.strictEqual(
      renditionNameFromPath("match_highlights/abc/landscape.mp4"), "landscape");
});

test("captioned cut maps to the SAME rendition name as the plain cut", () => {
  assert.strictEqual(
      renditionNameFromPath("match_highlights/abc/vertical_captioned.mp4"),
      "vertical");
  assert.strictEqual(
      renditionNameFromPath("match_highlights/abc/landscape_captioned.mp4"),
      "landscape");
});

// Mirrors the publish loop's "prefer the captioned cut per rendition" choice,
// so the public clip is the captioned one where both exist.
test("prefer-captioned grouping keeps one object per rendition", () => {
  const names = [
    "match_highlights/abc/vertical.mp4",
    "match_highlights/abc/vertical_captioned.mp4",
    "match_highlights/abc/landscape.mp4",
  ];
  const chosen = {};
  for (const name of names) {
    const base = renditionNameFromPath(name);
    const captioned = /_captioned\.mp4$/.test(name);
    const cur = chosen[base];
    if (!cur || (captioned && !cur.captioned)) chosen[base] = {name, captioned};
  }
  assert.strictEqual(Object.keys(chosen).length, 2, "one key per rendition");
  assert.strictEqual(chosen.vertical.name,
      "match_highlights/abc/vertical_captioned.mp4", "captioned wins");
  assert.strictEqual(chosen.vertical.captioned, true);
  assert.strictEqual(chosen.landscape.name,
      "match_highlights/abc/landscape.mp4", "plain-only stays");
});

// Order-independence: the captioned cut must win even if it is seen first.
test("captioned wins regardless of file order", () => {
  const names = [
    "match_highlights/abc/vertical_captioned.mp4",
    "match_highlights/abc/vertical.mp4",
  ];
  const chosen = {};
  for (const name of names) {
    const base = renditionNameFromPath(name);
    const captioned = /_captioned\.mp4$/.test(name);
    const cur = chosen[base];
    if (!cur || (captioned && !cur.captioned)) chosen[base] = {name, captioned};
  }
  assert.strictEqual(chosen.vertical.name,
      "match_highlights/abc/vertical_captioned.mp4");
});

if (process.exitCode) {
  console.error(`\npublishHighlight: some checks FAILED`);
} else {
  console.log(`publishHighlight: ${passed} checks passed`);
}
