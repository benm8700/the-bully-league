const assert = require("assert");
const {buildFirstRound} = require("../tournament");

let passed = 0;
function check(name, fn) {
  fn();
  passed++;
  console.log(`  ok - ${name}`);
}

// entrants as {id, rating}
const e = (id, rating) => ({id, rating});

// Collects every player id referenced by a first round, plus which ones got
// a bye (auto-advancing matchup with no player2).
function inspect(matchups) {
  const players = new Set();
  const byePlayers = new Set();
  let doubleByes = 0;
  for (const mm of matchups) {
    if (mm.player1Id != null) players.add(mm.player1Id);
    if (mm.player2Id != null) players.add(mm.player2Id);
    if (mm.player1Id == null && mm.player2Id == null) doubleByes++;
    if (mm.isBye) {
      assert.strictEqual(mm.player2Id, null, "a bye has no opponent");
      assert.strictEqual(mm.winnerId, mm.player1Id, "bye auto-advances");
      byePlayers.add(mm.player1Id);
    }
  }
  return {players, byePlayers, doubleByes};
}

console.log("bracket byes (highest Elo)");

const nextPow2 = (n) => {
  let p = 1;
  while (p < n) p *= 2;
  return p;
};

check("bye goes to the single highest-rated player (odd count)", () => {
  // 5 entrants -> bracket 8 -> 3 byes. The 3 highest ratings get them.
  const entrants = [
    e("low", 1000), e("mid", 1200), e("hi", 1600),
    e("hi2", 1500), e("hi3", 1400),
  ];
  const {byePlayers, players, doubleByes} = inspect(buildFirstRound(entrants));
  assert.strictEqual(doubleByes, 0, "no matchup is two byes");
  assert.strictEqual(players.size, 5, "every entrant is in the bracket");
  // 8 - 5 = 3 byes, to the top 3 ratings.
  assert.deepStrictEqual(
      [...byePlayers].sort(), ["hi", "hi2", "hi3"].sort());
  assert.ok(!byePlayers.has("low"), "the weakest never gets a bye");
  assert.ok(!byePlayers.has("mid"));
});

check("exactly one bye for an odd count one over a power of two", () => {
  // 3 entrants -> bracket 4 -> 1 bye, to the top rating.
  const entrants = [e("a", 1100), e("b", 1900), e("c", 1300)];
  const {byePlayers, players} = inspect(buildFirstRound(entrants));
  assert.strictEqual(byePlayers.size, 1);
  assert.ok(byePlayers.has("b"), "the top-rated player gets the only bye");
  assert.strictEqual(players.size, 3);
});

check("no byes when the count is already a power of two", () => {
  const entrants = [e("a", 1), e("b", 2), e("c", 3), e("d", 4)];
  const {byePlayers, players} = inspect(buildFirstRound(entrants));
  assert.strictEqual(byePlayers.size, 0, "a full bracket has no byes");
  assert.strictEqual(players.size, 4);
});

check("a tie for the bye is resolved deterministically (just pick one)", () => {
  // Two players tie at the top; bracket 4 -> 1 bye. Which one is picked must
  // be stable across runs (the developer's 'just pick one' - not a crash,
  // not random flip-flop).
  const entrants = [e("x", 1500), e("y", 1500), e("z", 1200)];
  const first = [...inspect(buildFirstRound(entrants)).byePlayers][0];
  for (let i = 0; i < 20; i++) {
    const again = [...inspect(buildFirstRound(entrants)).byePlayers][0];
    assert.strictEqual(again, first, "tie pick is stable");
  }
  assert.ok(first === "x" || first === "y", "one of the tied top players");
});

check("valid bracket across many counts, byes always the top seeds", () => {
  for (let n = 2; n <= 40; n++) {
    // Give each entrant a distinct rating equal to its index, so the top
    // `byeCount` ids are known exactly.
    const entrants = [];
    for (let i = 0; i < n; i++) entrants.push(e(`p${i}`, i));
    const byeCount = nextPow2(n) - n;
    const {byePlayers, players, doubleByes} =
        inspect(buildFirstRound(entrants));
    assert.strictEqual(doubleByes, 0, `n=${n}: no double-bye matchup`);
    assert.strictEqual(players.size, n, `n=${n}: all entrants present`);
    assert.strictEqual(byePlayers.size, byeCount, `n=${n}: right bye count`);
    // The byes must be exactly the highest `byeCount` ratings: p{n-1} down.
    for (let k = 0; k < byeCount; k++) {
      assert.ok(byePlayers.has(`p${n - 1 - k}`),
          `n=${n}: top seed p${n - 1 - k} should have a bye`);
    }
  }
});

check("legacy bare-string entrants still build a valid bracket", () => {
  // Back-compat: bare ids are treated as rating 0, so the bracket is still
  // structurally valid even without ratings.
  const {players, doubleByes} = inspect(buildFirstRound(["a", "b", "c"]));
  assert.strictEqual(doubleByes, 0);
  assert.strictEqual(players.size, 3);
});

console.log(`\n${passed} passed`);
