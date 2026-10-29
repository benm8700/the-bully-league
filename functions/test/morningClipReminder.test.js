const assert = require("assert");
const {
  reminderDue,
  isPostable,
  TARGET_HOUR_PACIFIC,
} = require("../morningClipReminder");

let passed = 0;
function check(name, fn) {
  fn();
  passed++;
  console.log(`  ok - ${name}`);
}

console.log("morning clip reminder");

const H = TARGET_HOUR_PACIFIC * 60;

check("not due before the target hour", () => {
  assert.strictEqual(
      reminderDue({minutes: H - 1, dayKey: "2026-10-29", sentDayKey: undefined}),
      false);
});

check("due at/after the target hour when not sent today", () => {
  assert.strictEqual(
      reminderDue({minutes: H, dayKey: "2026-10-29", sentDayKey: undefined}),
      true);
  assert.strictEqual(
      reminderDue({minutes: H + 120, dayKey: "2026-10-29", sentDayKey: "2026-10-28"}),
      true);
});

check("not due a second time the same day", () => {
  assert.strictEqual(
      reminderDue({minutes: H + 60, dayKey: "2026-10-29", sentDayKey: "2026-10-29"}),
      false);
});

// ---- isPostable ----
const base = () => ({
  status: "completed",
  mode: "ranked",
  voteFinalized: true,
  highlight: {renditions: {vertical: "x"}},
  postStudio: {},
  player1Id: "a",
  player2Id: "b",
  marketingConsent: {},
});

check("a finished, judged, rendered recorded clip is postable", () => {
  assert.strictEqual(isPostable(base()), true);
});

check("not postable: not completed / not judged / no reel", () => {
  assert.strictEqual(isPostable({...base(), status: "pending"}), false);
  assert.strictEqual(isPostable({...base(), voteFinalized: false}), false);
  assert.strictEqual(isPostable({...base(), highlight: {renditions: {}}}), false);
});

check("not postable: unrecorded mode (practice/exhibition)", () => {
  assert.strictEqual(isPostable({...base(), mode: "exhibition"}), false);
});

check("not postable: already posted or set aside", () => {
  assert.strictEqual(isPostable({...base(), postStudio: {status: "posted"}}), false);
  assert.strictEqual(isPostable({...base(), postStudio: {status: "dismissed"}}), false);
});

check("not postable: a battler pulled it (consent out)", () => {
  assert.strictEqual(
      isPostable({...base(), marketingConsent: {a: {mode: "out"}}}), false);
  assert.strictEqual(
      isPostable({...base(), marketingConsent: {b: {mode: "out"}}}), false);
});

check("still postable with a blur opt-out (post the blurred cut)", () => {
  assert.strictEqual(
      isPostable({...base(), marketingConsent: {a: {mode: "blur"}}}), true);
});

console.log(`\n${passed} passed`);
