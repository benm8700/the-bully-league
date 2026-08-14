/**
 * Keeps the reaction allowlist in step across the three places it lives.
 *
 * The developer expects to change this set, and drift between the three
 * copies fails QUIETLY in the worst possible direction: add an emoji to the
 * app and forget firestore.rules, and every tap on it is silently rejected
 * while the UI shows the chip as tappable. Add it to the rules and forget
 * the trigger, and reactions land but are never counted.
 *
 * Run: node test/reactions.test.js
 */
const assert = require("assert");
const fs = require("fs");
const path = require("path");
const {REACTIONS} = require("../reactions");

let checks = 0;
function check(label, fn) {
  fn();
  checks += 1;
  console.log(`  ok  ${label}`);
}

const root = path.join(__dirname, "..", "..");
const rules = fs.readFileSync(path.join(root, "firestore.rules"), "utf8");
const dart = fs.readFileSync(
    path.join(root, "lib", "widgets", "clip_reactions.dart"), "utf8");

/** The allowlist inside the reactions rule, not any other list in the file. */
function rulesAllowlist() {
  const block = rules.slice(rules.indexOf("match /reactions/{userId}"));
  const list = block.slice(block.indexOf("["), block.indexOf("]"));
  return [...list.matchAll(/'([a-z_]+)'/g)].map((m) => m[1]);
}

/** Keys of the options map in the Flutter widget. */
function dartKeys() {
  const block = dart.slice(dart.indexOf("static const options"));
  const map = block.slice(block.indexOf("{"), block.indexOf("};"));
  return [...map.matchAll(/'([a-z_]+)':/g)].map((m) => m[1]);
}

check("the rules allowlist matches the backend list", () => {
  assert.deepStrictEqual(rulesAllowlist().sort(), [...REACTIONS].sort());
});

check("the app's options match the backend list", () => {
  // An emoji in the app but not the allowlist is the nastiest case: the
  // chip looks tappable and every tap is silently refused.
  assert.deepStrictEqual(dartKeys().sort(), [...REACTIONS].sort());
});

check("every reaction has a distinct key", () => {
  assert.strictEqual(new Set(REACTIONS).size, REACTIONS.length);
});

check("the set still spans approval AND rejection", () => {
  // The point of widening it: feedback that can only agree measures how
  // many people watched rather than how good anything was. If a later edit
  // quietly removes every negative option, that signal is gone again.
  const negative = ["ice", "crickets", "yawn", "meh", "thumbsdown"];
  assert.ok(negative.some((r) => REACTIONS.includes(r)),
      "no negative reactions left - the set has been sanitised again");
  const positive = ["fire", "skull", "laugh", "clap"];
  assert.ok(positive.some((r) => REACTIONS.includes(r)));
});

check("keys are storage-safe", () => {
  // They become Firestore map field names in reactionCounts, so a dot or a
  // slash would silently create a nested path instead of a key.
  for (const r of REACTIONS) {
    assert.ok(/^[a-z_]+$/.test(r), `unsafe reaction key: ${r}`);
  }
});

console.log(`\n${checks} checks passed.`);
