const assert = require("assert");
const {scanWordsForSlurs, wordIsSlur} = require("../slurScan");

let passed = 0;
function check(name, fn) {
  try {
    fn(); passed++; console.log("  ok -", name);
  } catch (e) {
    console.error("  FAIL -", name, "\n   ", e.message); process.exitCode = 1;
  }
}

// --- the slurs it MUST catch ---
check("catches the n-word (-er and -a)", () => {
  assert.strictEqual(scanWordsForSlurs(["nigger"]).detected, true);
  assert.strictEqual(scanWordsForSlurs(["nigga"]).detected, true);
});
check("catches the n-word across casing/punctuation (STT-clean words)", () => {
  assert.strictEqual(scanWordsForSlurs(["Nigger"]).detected, true);
  assert.strictEqual(scanWordsForSlurs(["nigga,"]).detected, true);
});
check("catches other racial/anti-gay slurs", () => {
  for (const w of ["faggot", "kike", "chink", "spic", "wetback", "gook"]) {
    assert.strictEqual(scanWordsForSlurs([w]).detected, true, w);
  }
});
check("returns the distinct terms found", () => {
  const r = scanWordsForSlurs(["you", "nigger", "nigger", "kike"]);
  assert.strictEqual(r.detected, true);
  assert.deepStrictEqual([...r.terms].sort(), ["kike", "nigger"]);
});
check("accepts {text} word objects (the transcript shape)", () => {
  const r = scanWordsForSlurs([{text: "spic"}, {text: "hello"}]);
  assert.strictEqual(r.detected, true);
});

// --- what it must NOT catch: ordinary words + allowed profanity ---
check("does NOT catch ordinary words", () => {
  for (const w of ["night", "raccoon", "trigger", "scunthorpe", "assassin",
    "retarded"]) {
    // "retarded" DOES hit the ableist stem by design (retard*). Exclude it.
    if (w === "retarded") continue;
    assert.strictEqual(scanWordsForSlurs([w]).detected, false, w);
  }
});
check("short stems need the whole word (coon, not raccoon)", () => {
  assert.strictEqual(wordIsSlur("coon"), true);
  assert.strictEqual(wordIsSlur("raccoon"), false);
  assert.strictEqual(wordIsSlur("spic"), true);
});
check("does NOT flag allowed profanity", () => {
  for (const w of ["fuck", "shit", "bitch", "asshole", "damn", "cunt"]) {
    assert.strictEqual(scanWordsForSlurs([w]).detected, false, w);
  }
});
check("a clean transcript is clean", () => {
  assert.strictEqual(
      scanWordsForSlurs("you absolute clown i will end you".split(" ")).detected,
      false);
});

console.log(`\n${passed} checks passed.`);
