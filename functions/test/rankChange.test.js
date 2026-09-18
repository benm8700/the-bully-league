const assert = require("assert");
const {rankChangeFor, UP, DOWN, ORDER, GOAT_DISPLACED} = require("../rankChange");
const {RANK_TIERS, GOAT_TITLE} = require("../rating");

let passed = 0;
function check(name, fn) {
  fn();
  passed++;
  console.log(`  ok - ${name}`);
}

console.log("rankChange");

check("climbing a tier is announced, in the up voice", () => {
  const c = rankChangeFor("Open Micer", "Class Clown");
  assert.strictEqual(c.direction, "up");
  assert.strictEqual(c.message, UP["Class Clown"]);
});

check("the up headline is the template naming the destination rank", () => {
  const c = rankChangeFor("Open Micer", "Door Guy");
  assert.strictEqual(
      c.title, "Congratulations! You achieved the rank of Door Guy");
});

check("falling a tier is announced, in the down voice", () => {
  const c = rankChangeFor("Class Clown", "Open Micer");
  assert.strictEqual(c.direction, "down");
  assert.strictEqual(c.message, DOWN["Open Micer"]);
});

check("nothing is said when the rank did not change", () => {
  assert.strictEqual(rankChangeFor("Regular", "Regular"), null);
});

check("a brand-new account is not congratulated for existing", () => {
  // No previous title means the account has never been ranked. Greeting
  // someone with "promoted to Average Joe" for merely signing up would
  // devalue every real promotion afterwards.
  assert.strictEqual(rankChangeFor(null, "Average Joe"), null);
  assert.strictEqual(rankChangeFor(undefined, "Average Joe"), null);
  assert.strictEqual(rankChangeFor("", "Average Joe"), null);
});

check("an unrecognised title is ignored rather than mis-announced", () => {
  assert.strictEqual(rankChangeFor("Wizard", "Regular"), null);
  assert.strictEqual(rankChangeFor("Regular", "Wizard"), null);
});

check("SKIPPING tiers still produces the right message for where you LANDED", () => {
  // A big rating swing can jump more than one tier. Keying on the
  // destination means these are covered without a pair table.
  const c = rankChangeFor("Average Joe", "Headliner");
  assert.strictEqual(c.direction, "up");
  assert.strictEqual(c.message, UP["Headliner"]);
  const d = rankChangeFor("Legend", "Class Clown");
  assert.strictEqual(d.direction, "down");
  assert.strictEqual(d.message, DOWN["Class Clown"]);
});

check("THE GOAT CASE: displacement uses the honest displaced line", () => {
  // GOAT is a live top-five position lost when a challenger passes you.
  const c = rankChangeFor(GOAT_TITLE, "Featured Talent", {displacedFromGoat: true});
  assert.strictEqual(c.displaced, true);
  assert.strictEqual(c.message, GOAT_DISPLACED);
});

check("losing GOAT without the displaced flag uses the ordinary down line", () => {
  const c = rankChangeFor(GOAT_TITLE, "Featured Talent", {displacedFromGoat: false});
  assert.strictEqual(c.displaced, false);
  assert.strictEqual(c.message, DOWN["Featured Talent"]);
});

check("EVERY rank has one non-empty line in BOTH directions", () => {
  // A missing entry would surface as a rank change with no message at the
  // exact moment the app is trying to make someone feel something.
  for (const title of ORDER) {
    assert.ok(typeof UP[title] === "string" && UP[title].trim().length > 3,
        `no up copy for ${title}`);
    assert.ok(typeof DOWN[title] === "string" && DOWN[title].trim().length > 3,
        `no down copy for ${title}`);
  }
  assert.strictEqual(ORDER.length, RANK_TIERS.length + 1);
});

check("every possible transition produces a message", () => {
  let checked = 0;
  for (const from of ORDER) {
    for (const to of ORDER) {
      if (from === to) continue;
      const c = rankChangeFor(from, to);
      assert.ok(c && c.message, `no message for ${from} -> ${to}`);
      checked++;
    }
  }
  assert.strictEqual(checked, ORDER.length * (ORDER.length - 1));
});

check("the up and down lines differ per rank", () => {
  for (const title of ORDER) {
    assert.notStrictEqual(UP[title], DOWN[title],
        `${title} reuses the same line both ways`);
  }
});

console.log(`\n${passed} checks passed.`);
