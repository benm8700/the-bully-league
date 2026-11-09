const assert = require("assert");
const {clipReadyRecipients} = require("../autoRender");

let passed = 0;
function check(name, fn) {
  fn();
  passed++;
  console.log(`  ok - ${name}`);
}

check("nobody until the captioned cut exists", () => {
  assert.deepStrictEqual(clipReadyRecipients({
    clipGrants: {a: {}}, highlight: {captionRequested: true},
  }), []);
});
check("every claimer once captioned", () => {
  assert.deepStrictEqual(clipReadyRecipients({
    clipGrants: {a: {}, b: {}}, highlight: {captioned: true},
  }).sort(), ["a", "b"]);
});
check("never twice", () => {
  assert.deepStrictEqual(clipReadyRecipients({
    clipGrants: {a: {}}, highlight: {captioned: true, clipReadyNotified: true},
  }), []);
});
check("a captioned clip nobody claimed tells nobody", () => {
  assert.deepStrictEqual(clipReadyRecipients({highlight: {captioned: true}}), []);
});
check("tolerates a missing match", () => {
  assert.deepStrictEqual(clipReadyRecipients(null), []);
});
console.log(`clipReady: ${passed} passed`);

// A no-speech battle: the caption pass ran (captionedRenderedAt) but found no
// cues, so captioned stays false. It must still count as ready.
const {captionPassDone, clipDeliverable} = require("../clipGrants");
check("a caption pass with no speech still makes the clip ready", () => {
  const m = {highlight: {captioned: false, captionedRenderedAt: {s: 1}},
    clipGrants: {a: {}}};
  assert.strictEqual(captionPassDone(m), true);
  assert.deepStrictEqual(clipReadyRecipients(m), ["a"]);
});
check("not ready before the caption pass has run", () => {
  assert.strictEqual(captionPassDone({highlight: {captioned: false}}), false);
});
check("deliverable once the no-speech caption pass has run", () => {
  const m = {status: "completed", completedAt: {toMillis: () => 0},
    highlight: {captioned: false, captionedRenderedAt: {s: 1}}};
  assert.strictEqual(clipDeliverable(m, Date.now()).reason === "rendering", false);
});
console.log(`clipReady (no-speech): ${passed} passed`);
