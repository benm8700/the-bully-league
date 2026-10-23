const assert = require("assert");
const {runnerUpOf, placementsOf} = require("../mainStageFinale");

let passed = 0;
function check(name, fn) {
  fn();
  passed++;
  console.log(`  ok - ${name}`);
}

console.log("main stage finale - runner-up resolution");

// The stored shape: each round is {matches:[...]} (Firestore can't nest arrays).
const stored = (finalA, finalB, winner, championId) => ({
  winnerId: championId,
  bracket: {
    rounds: [
      {matches: [
        {a: "s1a", b: "s1b", winner: finalA},
        {a: "s2a", b: "s2b", winner: finalB},
      ]},
      {matches: [{a: finalA, b: finalB, winner}]},
    ],
  },
});

check("runner-up is the loser of the final (stored {matches} shape)", () => {
  assert.strictEqual(runnerUpOf(stored("alice", "bob", "alice", "alice")), "bob");
  assert.strictEqual(runnerUpOf(stored("alice", "bob", "bob", "bob")), "alice");
});

check("runner-up resolves against the RAW array shape too", () => {
  const raw = {
    winnerId: "x",
    bracket: {rounds: [[{a: "p", b: "q", winner: "p"}], [{a: "x", b: "y", winner: "x"}]]},
  };
  assert.strictEqual(runnerUpOf(raw), "y");
});

check("null when there is no winner", () => {
  assert.strictEqual(runnerUpOf(stored("a", "b", null, null)), null);
});

check("null when the champion is not in the final match", () => {
  // A malformed doc whose winnerId is not one of the two finalists.
  assert.strictEqual(runnerUpOf(stored("a", "b", "a", "stranger")), null);
});

check("null when the final is not yet filled in", () => {
  const half = {
    winnerId: "a",
    bracket: {rounds: [{matches: [{a: "a", b: "b", winner: "a"}]}, {matches: [{a: null, b: null, winner: null}]}]},
  };
  assert.strictEqual(runnerUpOf(half), null);
});

check("null on a missing/empty bracket", () => {
  assert.strictEqual(runnerUpOf({winnerId: "a"}), null);
  assert.strictEqual(runnerUpOf({winnerId: "a", bracket: {rounds: []}}), null);
  assert.strictEqual(runnerUpOf(null), null);
});

check("a single-round bracket (final only) still resolves", () => {
  const oneRound = {
    winnerId: "w",
    bracket: {rounds: [{matches: [{a: "w", b: "l", winner: "w"}]}]},
  };
  assert.strictEqual(runnerUpOf(oneRound), "l");
});

console.log("\nmain stage finale - placements (every participant)");

// A consistent 4-player bracket: alice beats dave, bob beats carol, alice beats
// bob in the final.
const fourPlayer = {
  winnerId: "alice",
  field: ["alice", "dave", "bob", "carol"],
  bracket: {
    rounds: [
      {matches: [
        {a: "alice", b: "dave", winner: "alice"},
        {a: "bob", b: "carol", winner: "bob"},
      ]},
      {matches: [{a: "alice", b: "bob", winner: "alice"}]},
    ],
  },
};

check("champion / finalist / tied semifinalists all placed", () => {
  const p = placementsOf(fourPlayer);
  assert.strictEqual(p["alice"].place, 1);
  assert.strictEqual(p["alice"].label, "Champion");
  assert.strictEqual(p["bob"].place, 2);
  assert.strictEqual(p["bob"].label, "Finalist");
  assert.strictEqual(p["dave"].place, 3);
  assert.strictEqual(p["dave"].label, "Semifinalist");
  assert.strictEqual(p["carol"].place, 3);
  assert.strictEqual(p["carol"].label, "Semifinalist");
  // every participant carries the field size
  for (const u of ["alice", "bob", "dave", "carol"]) {
    assert.strictEqual(p[u].totalPlayers, 4);
  }
});

check("placements resolve against the RAW array shape too", () => {
  const raw = {
    winnerId: "x",
    field: ["x", "y", "p", "q"],
    bracket: {rounds: [
      [{a: "p", b: "q", winner: "p"}, {a: "x", b: "y", winner: "x"}],
      [{a: "x", b: "p", winner: "x"}],
    ]},
  };
  const p = placementsOf(raw);
  assert.strictEqual(p["x"].place, 1);
  assert.strictEqual(p["p"].place, 2); // p reached the final and lost it
  assert.strictEqual(p["y"].place, 3); // y lost a semi
  assert.strictEqual(p["q"].place, 3);
});

check("empty when there is no field, bracket, or winner", () => {
  assert.deepStrictEqual(placementsOf({winnerId: "a", bracket: {rounds: []}}), {});
  assert.deepStrictEqual(placementsOf({field: ["a"], bracket: {rounds: [[{a: "a", b: "b", winner: "a"}]]}}), {});
  assert.deepStrictEqual(placementsOf(null), {});
});

console.log(`\n${passed} passed`);
