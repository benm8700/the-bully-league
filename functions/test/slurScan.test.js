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
  for (const w of ["night", "raccoon", "trigger", "scunthorpe", "assassin"]) {
    assert.strictEqual(scanWordsForSlurs([w]).detected, false, w);
  }
});
check("words removed from the built-in list are NOT flagged", () => {
  for (const w of ["retard", "retarded", "wigger", "tranny"]) {
    assert.strictEqual(scanWordsForSlurs([w]).detected, false, w);
  }
});
check("raghead/towelhead are kept in", () => {
  assert.strictEqual(scanWordsForSlurs(["raghead"]).detected, true);
  assert.strictEqual(scanWordsForSlurs(["towelhead"]).detected, true);
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

// --- shows the ACTUAL word said ---
check("reports the actual spoken word, not the stem", () => {
  assert.deepStrictEqual(scanWordsForSlurs(["retarded"]).terms, ["retarded"]);
  assert.deepStrictEqual(scanWordsForSlurs(["Nigga,"]).terms, ["nigga"]);
});

// --- founder's own database of flagged words ---
check("extraWords adds to the flagged list", () => {
  assert.strictEqual(scanWordsForSlurs(["pineapple"]).detected, false);
  const r = scanWordsForSlurs(["pineapple"], {extraWords: ["pineapple"]});
  assert.strictEqual(r.detected, true);
  assert.deepStrictEqual(r.terms, ["pineapple"]);
});
check("extraWords still flags the built-in slurs too", () => {
  const r = scanWordsForSlurs(["nigger", "pineapple"], {extraWords: ["pineapple"]});
  assert.strictEqual(r.terms.length, 2);
});
check("disableBuiltin uses ONLY the founder's list", () => {
  const r = scanWordsForSlurs(["nigger", "pineapple"],
      {extraWords: ["pineapple"], disableBuiltin: true});
  assert.deepStrictEqual(r.terms, ["pineapple"]); // built-in n-word NOT flagged
});

console.log(`\n${passed} checks passed.`);
