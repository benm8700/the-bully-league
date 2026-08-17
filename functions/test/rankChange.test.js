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

check("THE GOAT CASE: displacement is reported honestly, not as decline", () => {
  // GOAT is a live top-five position, so it can be lost without losing a
  // match - somebody else simply passed you. Telling that player they got
  // worse is untrue and makes the ladder feel rigged.
  const c = rankChangeFor(GOAT_TITLE, "Hall of Famer", {displacedFromGoat: true});
  assert.strictEqual(c.displaced, true);
  assert.strictEqual(c.message, GOAT_DISPLACED);
  assert.ok(!/worse/.test(c.message.replace("did not get worse", "")),
      "must not imply they declined");
});

check("losing GOAT by actually dropping rating uses the ordinary line", () => {
  const c = rankChangeFor(GOAT_TITLE, "Hall of Famer", {displacedFromGoat: false});
  assert.strictEqual(c.displaced, false);
  assert.strictEqual(c.message, DOWN["Hall of Famer"]);
});

check("EVERY rank has copy in BOTH directions", () => {
  // A missing entry would surface as a rank change with no message at the
  // exact moment the app is trying to make someone feel something.
  for (const title of ORDER) {
    assert.ok(UP[title], `no up copy for ${title}`);
    assert.ok(DOWN[title], `no down copy for ${title}`);
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

check("the up and down voices are actually different per rank", () => {
  for (const title of ORDER) {
    assert.notStrictEqual(UP[title], DOWN[title],
        `${title} says the same thing whether you rose or fell`);
  }
});

console.log(`\n${passed} checks passed.`);
