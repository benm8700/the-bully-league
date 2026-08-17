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
  assert.ok(UP["Class Clown"].includes(c.message), c.message);
});

check("falling a tier is announced, in the down voice", () => {
  const c = rankChangeFor("Class Clown", "Open Micer");
  assert.strictEqual(c.direction, "down");
  assert.ok(DOWN["Open Micer"].includes(c.message), c.message);
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
  assert.ok(UP["Headliner"].includes(c.message), c.message);
  const d = rankChangeFor("Legend", "Class Clown");
  assert.strictEqual(d.direction, "down");
  assert.ok(DOWN["Class Clown"].includes(d.message), d.message);
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
  assert.ok(DOWN["Hall of Famer"].includes(c.message), c.message);
});

check("EVERY rank has copy in BOTH directions", () => {
  // A missing entry would surface as a rank change with no message at the
  // exact moment the app is trying to make someone feel something.
  for (const title of ORDER) {
    assert.ok(UP[title]?.length > 0, `no up copy for ${title}`);
    assert.ok(DOWN[title]?.length > 0, `no down copy for ${title}`);
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
    for (const line of UP[title]) {
      assert.ok(!DOWN[title].includes(line),
          `${title} reuses a line in both directions: ${line}`);
    }
  }
});

// ------------------------------------------------------------ variants
check("every rank has MULTIPLE variants in both directions", () => {
  // One line each means a player bouncing around a threshold reads the
  // same joke every time, and a joke stops being one on the third read.
  for (const title of ORDER) {
    assert.ok(UP[title].length >= 2, `${title} has only one up line`);
    assert.ok(DOWN[title].length >= 2, `${title} has only one down line`);
  }
});

check("DETERMINISTIC: the same seed always gives the same line", () => {
  // The push and the in-app popup call this separately, at different
  // moments. A random pick would have the notification say one thing and
  // the app say another about the same event.
  const a = rankChangeFor("Regular", "Headliner", {seed: 7});
  const b = rankChangeFor("Regular", "Headliner", {seed: 7});
  assert.strictEqual(a.message, b.message);
});

check("...but different seeds reach different lines", () => {
  const seen = new Set();
  for (let seed = 0; seed < 12; seed++) {
    seen.add(rankChangeFor("Regular", "Headliner", {seed}).message);
  }
  assert.ok(seen.size > 1, "the seed is not varying the line at all");
  assert.ok(seen.size <= UP["Headliner"].length);
});

check("a missing or junk seed still produces a real line", () => {
  for (const seed of [undefined, null, NaN, -3, "seven", 1e9]) {
    const c = rankChangeFor("Regular", "Headliner", {seed});
    assert.ok(UP["Headliner"].includes(c.message),
        `seed=${seed} produced ${c.message}`);
  }
});

check("no line is empty or accidentally duplicated within a rank", () => {
  for (const table of [UP, DOWN]) {
    for (const title of ORDER) {
      const lines = table[title];
      assert.strictEqual(new Set(lines).size, lines.length,
          `${title} repeats a line`);
      for (const line of lines) {
        assert.ok(line.trim().length > 10, `${title} has a stub: "${line}"`);
      }
    }
  }
});

console.log(`\n${passed} checks passed.`);
