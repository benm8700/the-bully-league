const assert = require("assert");
const {
  createBattle,
  reduce,
  mutedPlayer,
  isOver,
} = require("../mainStageBattle");

let passed = 0;
function check(name, fn) {
  fn();
  passed++;
  console.log(`  ok - ${name}`);
}

const ev = (type, by, atMs) => ({type, by, atMs});
const run = (state, events) => events.reduce(reduce, state);

console.log("main stage battle - chess clock + interrupts");

check("a fresh battle is pending with full clocks and steals", () => {
  const s = createBattle(["a", "b"]);
  assert.strictEqual(s.status, "pending");
  assert.strictEqual(s.remaining.a, 60000);
  assert.strictEqual(s.remaining.b, 60000);
  assert.strictEqual(s.steals.a, 2);
  assert.strictEqual(s.floor, null);
});

check("open gives the floor and goes live; opponent is muted", () => {
  const s = reduce(createBattle(["a", "b"]), ev("open", "a", 0));
  assert.strictEqual(s.status, "live");
  assert.strictEqual(s.floor, "a");
  assert.strictEqual(mutedPlayer(s), "b");
});

check("the clock only deducts from the player holding the floor", () => {
  const s = run(createBattle(["a", "b"]), [
    ev("open", "a", 0), ev("startTalking", "a", 0), ev("tick", null, 10000),
  ]);
  assert.strictEqual(s.remaining.a, 50000);
  assert.strictEqual(s.remaining.b, 60000, "opponent's clock untouched");
});

check("yielding is free and BANKS your remaining time", () => {
  const s = run(createBattle(["a", "b"]), [
    ev("open", "a", 0), ev("startTalking", "a", 0), ev("yield", "a", 5000),
    ev("startTalking", "b", 5000), ev("yield", "b", 8000),
  ]);
  assert.strictEqual(s.floor, "a", "floor back to a");
  assert.strictEqual(s.remaining.a, 55000, "a's banked time survived");
  assert.strictEqual(s.remaining.b, 57000);
  assert.strictEqual(s.steals.a, 2, "yielding costs no steal");
});

check("interrupt steals the floor, spends a token, freezes the opponent", () => {
  const s = run(createBattle(["a", "b"]), [
    ev("open", "a", 0), ev("startTalking", "a", 0), ev("interrupt", "b", 3000),
  ]);
  assert.strictEqual(s.floor, "b");
  assert.strictEqual(s.steals.b, 1, "one steal spent");
  assert.strictEqual(s.remaining.a, 57000, "a's clock frozen at the steal");
  assert.strictEqual(mutedPlayer(s), "a");
});

check("you cannot interrupt while you already hold the floor", () => {
  const s = run(createBattle(["a", "b"]), [
    ev("open", "a", 0), ev("interrupt", "a", 1000),
  ]);
  assert.strictEqual(s.floor, "a");
  assert.strictEqual(s.steals.a, 2, "no token spent on a no-op");
});

check("interrupts are capped - the 3rd steal is refused", () => {
  const s = run(createBattle(["a", "b"]), [
    ev("open", "a", 0), ev("startTalking", "a", 0),
    ev("interrupt", "b", 1000), // b 2->1, floor b
    ev("interrupt", "a", 2000), // a 2->1, floor a
    ev("interrupt", "b", 3000), // b 1->0, floor b
    ev("interrupt", "a", 4000), // a 1->0, floor a
    ev("interrupt", "b", 5000), // b has 0 steals -> no-op
  ]);
  assert.strictEqual(s.steals.b, 0);
  assert.strictEqual(s.floor, "a", "the 3rd interrupt did nothing");
});

check("you cannot interrupt with no time left", () => {
  const s = run(createBattle(["a", "b"], {turnMs: 4000}), [
    ev("open", "b", 0), ev("startTalking", "b", 0),
    ev("tick", null, 5000), // b runs out -> floor passes to a
    ev("interrupt", "b", 6000), // b has 0 time -> no-op
  ]);
  assert.strictEqual(s.remaining.b, 0);
  assert.strictEqual(s.floor, "a", "a keeps the floor; b can't steal it back");
});

check("the shot-clock bounces an idle floor", () => {
  const s = run(createBattle(["a", "b"]), [
    ev("open", "a", 0), ev("tick", null, 7000), // never started talking
  ]);
  assert.strictEqual(s.floor, "b", "floor bounced after the shot-clock");
});

check("starting to talk cancels the shot-clock", () => {
  const s = run(createBattle(["a", "b"]), [
    ev("open", "a", 0), ev("startTalking", "a", 1000), ev("tick", null, 8000),
  ]);
  assert.strictEqual(s.floor, "a", "no bounce once talking");
  assert.strictEqual(s.remaining.a, 52000);
});

check("running out of time passes the floor, then ends when both are spent",
    () => {
      const mid = run(createBattle(["a", "b"], {turnMs: 5000}), [
        ev("open", "a", 0), ev("startTalking", "a", 0), ev("tick", null, 6000),
      ]);
      assert.strictEqual(mid.remaining.a, 0);
      assert.strictEqual(mid.floor, "b", "opponent gets to spend their time");
      assert.strictEqual(mid.status, "live");

      const end = run(mid, [
        ev("startTalking", "b", 6000), ev("tick", null, 12000),
      ]);
      assert.strictEqual(end.status, "ended");
      assert.strictEqual(end.endReason, "time");
      assert.strictEqual(end.floor, null);
      assert.ok(isOver(end));
    });

check("events on an ended battle are ignored", () => {
  const end = run(createBattle(["a", "b"], {turnMs: 3000}), [
    ev("open", "a", 0), ev("startTalking", "a", 0), ev("tick", null, 3000),
    ev("startTalking", "b", 3000), ev("tick", null, 6000), // both spent -> end
  ]);
  assert.ok(isOver(end));
  const after = reduce(end, ev("interrupt", "a", 7000));
  assert.strictEqual(after.status, "ended");
  assert.strictEqual(after.floor, null);
});

check("only the floor-holder can yield", () => {
  const s = run(createBattle(["a", "b"]), [
    ev("open", "a", 0), ev("yield", "b", 1000),
  ]);
  assert.strictEqual(s.floor, "a", "a non-holder yield is a no-op");
});

check("endEarly ends the battle when the opponent is already out of time", () => {
  // a runs b out of time, then a holds the floor with banked time and nothing
  // to say - the dead-air case. endEarly lets a end it rather than draining.
  const mid = run(createBattle(["a", "b"], {turnMs: 5000}), [
    ev("open", "b", 0), ev("startTalking", "b", 0),
    ev("tick", null, 6000), // b spent -> floor passes to a, a still has time
  ]);
  assert.strictEqual(mid.remaining.b, 0);
  assert.strictEqual(mid.floor, "a");
  assert.strictEqual(mid.status, "live", "a could still talk out the clock");

  const end = reduce(mid, ev("endEarly", "a", 7000));
  assert.strictEqual(end.status, "ended");
  assert.strictEqual(end.endReason, "done");
  assert.strictEqual(end.floor, null);
  assert.ok(isOver(end));
  assert.ok(end.remaining.a > 0, "a's banked time was not forfeited to anyone");
});

check("endEarly is refused while the opponent still has time (use yield)", () => {
  // a must not be able to cut b out of a turn b has not had.
  const s = run(createBattle(["a", "b"]), [
    ev("open", "a", 0), ev("startTalking", "a", 0),
    ev("endEarly", "a", 3000),
  ]);
  assert.strictEqual(s.status, "live", "both still had time - no end");
  assert.strictEqual(s.floor, "a");
});

check("only the floor-holder can endEarly", () => {
  const mid = run(createBattle(["a", "b"], {turnMs: 5000}), [
    ev("open", "b", 0), ev("startTalking", "b", 0), ev("tick", null, 6000),
  ]);
  assert.strictEqual(mid.floor, "a");
  const s = reduce(mid, ev("endEarly", "b", 7000)); // b has no floor, no time
  assert.strictEqual(s.status, "live", "a non-holder endEarly is a no-op");
});

check("createBattle refuses two of the same player", () => {
  assert.throws(() => createBattle(["a", "a"]));
});

console.log(`\n${passed} passed`);
