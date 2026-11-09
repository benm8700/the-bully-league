const assert = require("assert");
const {dropHallucinatedCues, groupWordsIntoCues} = require("../captions");

let passed = 0;
function check(name, fn) {
  fn();
  passed++;
  console.log(`  ok - ${name}`);
}
const cue = (text, start = 0) => ({uid: "a", start, end: start + 1, text});

check("number-only cues are dropped (the real clip's garbage)", () => {
  const out = dropHallucinatedCues(
      [cue("0 0 0 0"), cue("1"), cue("2 3 0"), cue("so stupid.")]);
  assert.deepStrictEqual(out.map((c) => c.text), ["so stupid."]);
});
check("a number inside a real sentence is kept", () => {
  const out = dropHallucinatedCues([cue("I'm 30 years old")]);
  assert.strictEqual(out.length, 1);
});
check("punctuation-only cues are dropped", () => {
  assert.strictEqual(dropHallucinatedCues([cue("..."), cue("?!")]).length, 0);
});
check("three identical cues in a row are dropped as a run", () => {
  const out = dropHallucinatedCues([cue("thank you"), cue("Thank you"),
    cue("thank you"), cue("real line")]);
  assert.deepStrictEqual(out.map((c) => c.text), ["real line"]);
});
check("a line said twice is kept", () => {
  assert.strictEqual(
      dropHallucinatedCues([cue("no way"), cue("no way")]).length, 2);
});
check("accented / non-Latin letters count as words", () => {
  assert.strictEqual(dropHallucinatedCues([cue("café"), cue("¿qué?")]).length, 2);
});
check("groupWordsIntoCues applies it end to end", () => {
  const words = [0, 1, 2, 3].map((i) =>
    ({uid: "a", start: i * 0.2, end: i * 0.2 + 0.1, text: "0"}));
  words.push({uid: "a", start: 5, end: 5.3, text: "ugly."});
  assert.deepStrictEqual(groupWordsIntoCues(words).map((c) => c.text), ["ugly."]);
});
console.log(`captionHallucination: ${passed} passed`);
