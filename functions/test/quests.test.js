const assert = require("assert");
const {
  questsForDay, applyProgress, questView, QUESTS, SLOTS,
} = require("../quests");

let passed = 0;
function check(name, fn) {
  fn();
  passed++;
  console.log(`  ok - ${name}`);
}

const DAY = "2026-08-17";

console.log("quests");

// -------------------------------------------------------- the rotation
check("a day always has exactly three quests", () => {
  assert.strictEqual(questsForDay(DAY).length, 3);
});

check("DETERMINISTIC - the same day always gives the same set", () => {
  // Everyone should see the same quests, so the day's difficulty is one
  // knowable thing rather than a per-user lottery nobody can support.
  assert.deepStrictEqual(
      questsForDay(DAY).map((q) => q.id),
      questsForDay(DAY).map((q) => q.id));
});

check("...but the set actually changes across days", () => {
  const seen = new Set();
  for (let d = 1; d <= 28; d++) {
    const key = `2026-08-${String(d).padStart(2, "0")}`;
    seen.add(questsForDay(key).map((q) => q.id).join(","));
  }
  assert.ok(seen.size > 1, "the rotation never varies");
});

check("EVERY DAY HAS A JUDGING QUEST", () => {
  // Votes are the scarce resource and the thing players are least
  // naturally inclined to do. Battling needs no encouragement.
  for (let d = 1; d <= 28; d++) {
    const key = `2026-08-${String(d).padStart(2, "0")}`;
    const quests = questsForDay(key);
    assert.ok(quests.some((q) => q.metric === "votes"),
        `${key} has no judging quest: ${quests.map((q) => q.id).join(",")}`);
  }
});

check("a day is never all one metric", () => {
  for (let d = 1; d <= 28; d++) {
    const key = `2026-08-${String(d).padStart(2, "0")}`;
    const metrics = new Set(questsForDay(key).map((q) => q.metric));
    assert.ok(metrics.size >= 2, `${key} is all ${[...metrics][0]}`);
  }
});

check("every quest referenced by a slot actually exists", () => {
  for (const options of SLOTS) {
    for (const id of options) {
      assert.ok(QUESTS[id], `slot references missing quest ${id}`);
    }
  }
});

// --------------------------------------------------------- progression
check("an event advances the right counter", () => {
  const r = applyProgress(undefined, DAY, "votes",
      [QUESTS.judge3, QUESTS.play1]);
  assert.strictEqual(r.state.counts.votes, 1);
  assert.strictEqual(r.completed.length, 0);
});

check("a quest completes exactly when its target is reached", () => {
  let state;
  const quests = [QUESTS.judge3];
  for (let i = 0; i < 2; i++) {
    state = applyProgress(state, DAY, "votes", quests).state;
  }
  const third = applyProgress(state, DAY, "votes", quests);
  assert.deepStrictEqual(third.completed.map((q) => q.id), ["judge3"]);
});

check("COMPLETION IS ANNOUNCED ONCE, not on every later event", () => {
  // Otherwise a fourth vote would re-pay a three-vote quest.
  let state;
  const quests = [QUESTS.judge1];
  state = applyProgress(state, DAY, "votes", quests).state;
  for (let i = 0; i < 5; i++) {
    const r = applyProgress(state, DAY, "votes", quests);
    state = r.state;
    assert.strictEqual(r.completed.length, 0, `re-completed at ${i}`);
  }
});

check("two quests on the same metric can complete on one event", () => {
  let state;
  const quests = [QUESTS.judge1, QUESTS.judge3];
  state = applyProgress(state, DAY, "votes", quests).state; // judge1 done
  state = applyProgress(state, DAY, "votes", quests).state;
  const third = applyProgress(state, DAY, "votes", quests);
  assert.deepStrictEqual(third.completed.map((q) => q.id), ["judge3"]);
});

check("A NEW DAY RESETS progress rather than carrying it", () => {
  const quests = [QUESTS.judge3];
  let state = applyProgress(undefined, DAY, "votes", quests).state;
  state = applyProgress(state, DAY, "votes", quests).state;
  const nextDay = applyProgress(state, "2026-08-18", "votes", quests);
  assert.strictEqual(nextDay.state.counts.votes, 1);
  assert.deepStrictEqual(nextDay.state.done, []);
});

check("an unrelated metric does not advance a quest", () => {
  const r = applyProgress(undefined, DAY, "wins", [QUESTS.judge3]);
  assert.strictEqual(r.completed.length, 0);
  assert.strictEqual(r.state.counts.votes, undefined);
});

check("malformed state degrades to a fresh day", () => {
  for (const state of [null, "state", {dayKey: DAY, counts: null}]) {
    const r = applyProgress(state, DAY, "votes", [QUESTS.judge1]);
    assert.strictEqual(r.state.counts.votes, 1);
  }
});

// -------------------------------------------------------------- view
check("the view shows progress against each target", () => {
  let state = applyProgress(undefined, DAY, "votes",
      questsForDay(DAY)).state;
  state = applyProgress(state, DAY, "votes", questsForDay(DAY)).state;
  const view = questView(state, DAY);
  const judging = view.find((q) => q.id.startsWith("judge"));
  assert.strictEqual(judging.progress, 2);
});

check("progress never exceeds the target, so nothing reads '5 / 3'", () => {
  let state;
  const quests = questsForDay(DAY);
  for (let i = 0; i < 20; i++) {
    state = applyProgress(state, DAY, "votes", quests).state;
  }
  for (const q of questView(state, DAY)) {
    assert.ok(q.progress <= q.target, `${q.id}: ${q.progress}/${q.target}`);
  }
});

check("yesterday's progress does not show against today's quests", () => {
  const stale = {dayKey: "2026-08-16", counts: {votes: 9}, done: ["judge3"]};
  for (const q of questView(stale, DAY)) {
    assert.strictEqual(q.progress, 0);
    assert.strictEqual(q.done, false);
  }
});

check("rewards are modest - a quest must not out-earn playing", () => {
  const {DEFAULTS} = require("../points");
  for (const q of Object.values(QUESTS)) {
    assert.ok(q.reward > 0, `${q.id} pays nothing`);
    assert.ok(q.reward <= DEFAULTS.matchWon + DEFAULTS.matchPlayed,
        `${q.id} pays ${q.reward}, more than winning a battle`);
  }
});

check("NO DAY EVER REPEATS A METRIC, so three quests are really three", () => {
  // The stretch slot overlaps the earlier slots on purpose, but nothing
  // stopped it drawing the same metric twice. Seen live: judge5 + play2
  // + judge3 - two judging quests, and judge3 is strictly CONTAINED in
  // judge5, so judging five completed both.
  for (let d = 1; d <= 400; d++) {
    const key = `2026-${String(1 + (d % 12)).padStart(2, "0")}` +
      `-${String(1 + (d % 28)).padStart(2, "0")}`;
    const q = questsForDay(key);
    const metrics = q.map((x) => x.metric);
    assert.strictEqual(new Set(metrics).size, metrics.length,
        `${key} repeated a metric: ${q.map((x) => x.label).join(", ")}`);
  }
});

check("every day still has a judging quest", () => {
  // Votes are the scarce resource; this is the one slot that must never
  // be optimised away by the de-duplication above.
  for (let d = 1; d <= 400; d++) {
    const key = `2026-${String(1 + (d % 12)).padStart(2, "0")}` +
      `-${String(1 + (d % 28)).padStart(2, "0")}`;
    assert.ok(questsForDay(key).some((q) => q.metric === "votes"),
        `${key} had no judging quest`);
  }
});

console.log(`\n${passed} checks passed.`);
