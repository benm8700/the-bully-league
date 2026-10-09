/**
 * Pure tests for The Belt + tournament-champion logic (functions/belt.js).
 * Run: node test/belt.test.js
 */
const assert = require("assert");
const {beltTransition, isGauntlet, championOf} = require("../belt");

let passed = 0;
function test(name, fn) {
  try {
    fn();
    passed++;
  } catch (e) {
    console.error(`FAIL: ${name}\n  ${e.message}`);
    process.exitCode = 1;
  }
}

test("a vacant belt goes to the new champion, defense count 0", () => {
  const next = beltTransition(null,
      {championUid: "A", championName: "Ava", tournamentId: "t1", nowMs: 100});
  assert.strictEqual(next.holderUid, "A");
  assert.strictEqual(next.holderName, "Ava");
  assert.strictEqual(next.defenseCount, 0);
  assert.strictEqual(next.previousHolderUid, null);
  assert.strictEqual(next.sourceTournamentId, "t1");
  assert.strictEqual(next.wonAtMs, 100);
});

test("a new champion TAKES the belt from a different holder", () => {
  const cur = {holderUid: "A", holderName: "Ava", defenseCount: 3,
    sourceTournamentId: "t1", previousHolderUid: "Z"};
  const next = beltTransition(cur,
      {championUid: "B", championName: "Ben", tournamentId: "t2", nowMs: 200});
  assert.strictEqual(next.holderUid, "B");
  assert.strictEqual(next.defenseCount, 0, "a fresh holder starts at 0");
  assert.strictEqual(next.previousHolderUid, "A", "records who it was taken from");
});

test("the SAME holder winning again DEFENDS (count increments)", () => {
  const cur = {holderUid: "A", holderName: "Ava", defenseCount: 1,
    sourceTournamentId: "t1", previousHolderUid: null};
  const next = beltTransition(cur,
      {championUid: "A", championName: "Ava", tournamentId: "t2", nowMs: 300});
  assert.strictEqual(next.holderUid, "A");
  assert.strictEqual(next.defenseCount, 2);
  assert.strictEqual(next.previousHolderUid, null, "defense keeps prior lineage");
});

test("no champion (cancelled gauntlet) leaves the belt unchanged", () => {
  assert.strictEqual(beltTransition({holderUid: "A"},
      {championUid: null, tournamentId: "t9", nowMs: 1}), null);
});

test("the SAME tournament can never award the belt twice (idempotent)", () => {
  const cur = {holderUid: "A", defenseCount: 0, sourceTournamentId: "t5"};
  assert.strictEqual(beltTransition(cur,
      {championUid: "B", championName: "Ben", tournamentId: "t5", nowMs: 1}),
  null);
});

test("a defense with no fresh name keeps the stored name", () => {
  const cur = {holderUid: "A", holderName: "Ava", defenseCount: 0,
    sourceTournamentId: "t1"};
  const next = beltTransition(cur,
      {championUid: "A", championName: null, tournamentId: "t2", nowMs: 1});
  assert.strictEqual(next.holderName, "Ava");
});

test("only the Daily Gauntlet (createdBy auto) contests the belt", () => {
  assert.strictEqual(isGauntlet({createdBy: "auto"}), true);
  assert.strictEqual(isGauntlet({createdBy: "auto", format: "climb"}), true);
  assert.strictEqual(isGauntlet({createdBy: "auto", format: "swiss"}), true);
  assert.strictEqual(isGauntlet({createdBy: "admin"}), false);
  assert.strictEqual(isGauntlet({}), false);
  assert.strictEqual(isGauntlet(null), false);
});

test("the weekly Main Stage (also auto) never moves the daily belt", () => {
  // buildMainStageDoc writes createdBy "auto" too, so without the format carve-
  // out a weekly finals win would wrongly take the nightly belt.
  assert.strictEqual(
      isGauntlet({createdBy: "auto", format: "mainstage"}), false);
});

test("championOf reads the winner whatever the format wrote", () => {
  assert.strictEqual(championOf({winnerId: "W"}), "W");
  assert.strictEqual(championOf({swiss: {championUid: "S"}}), "S");
  assert.strictEqual(championOf({climb: {championUid: "C"}}), "C");
  assert.strictEqual(championOf({status: "cancelled"}), null);
  assert.strictEqual(championOf(null), null);
});

if (process.exitCode) {
  console.error("\nbelt: some checks FAILED");
} else {
  console.log(`belt: ${passed} checks passed`);
}
