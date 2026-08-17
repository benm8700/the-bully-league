const assert = require("assert");
const {
  roundNotification, notificationCopy, CLOSING_LEAD_MS,
} = require("../tournamentNotify");

let passed = 0;
function check(name, fn) {
  fn();
  passed++;
  console.log(`  ok - ${name}`);
}

const NOW = 1_700_000_000_000;
const HOUR = 3600 * 1000;

const roundOf = (matchups, over = {}) => ({
  roundNumber: 1,
  windowStartMs: NOW - HOUR,
  windowEndMs: NOW + 10 * HOUR,
  matchups,
  ...over,
});
const m = (p1, p2, extra = {}) =>
  ({player1Id: p1, player2Id: p2, winnerId: null, isBye: false, ...extra});

console.log("tournamentNotify");

// ------------------------------------------------------- round opened
check("an open round is announced to both players", () => {
  const plan = roundNotification({round: roundOf([m("a", "b")]), nowMs: NOW});
  assert.strictEqual(plan.kind, "opened");
  assert.deepStrictEqual(plan.recipients.sort(), ["a", "b"]);
});

check("IT FIRES ONCE - a round already announced says nothing", () => {
  const plan = roundNotification({
    round: roundOf([m("a", "b")]), nowMs: NOW, sent: {opened: true},
  });
  assert.strictEqual(plan, null);
});

check("a round that has not opened yet is not announced", () => {
  const plan = roundNotification({
    round: roundOf([m("a", "b")], {windowStartMs: NOW + HOUR}), nowMs: NOW,
  });
  assert.strictEqual(plan, null);
});

check("byes and decided matchups are nobody's problem", () => {
  const plan = roundNotification({
    round: roundOf([
      {player1Id: "a", player2Id: null, winnerId: "a", isBye: true},
      m("c", "d", {winnerId: "c"}),
      m("e", "f"),
    ]),
    nowMs: NOW,
  });
  assert.deepStrictEqual(plan.recipients.sort(), ["e", "f"]);
});

check("a fully settled round is not announced at all", () => {
  const plan = roundNotification({
    round: roundOf([m("a", "b", {winnerId: "a"})]), nowMs: NOW,
  });
  assert.strictEqual(plan, null);
});

// ------------------------------------------------------ closing warning
check("THE WARNING GOES ONLY TO PEOPLE WHO HAVE NOT CHECKED IN", () => {
  // Someone who already turned up is in no danger of forfeiting, so
  // chasing them is pure noise.
  const plan = roundNotification({
    round: roundOf([m("a", "b")], {windowEndMs: NOW + HOUR}),
    nowMs: NOW,
    arrivedByMatchup: {0: new Set(["a"])},
  });
  assert.strictEqual(plan.kind, "closing");
  assert.deepStrictEqual(plan.recipients, ["b"]);
});

check("nobody is warned when everyone has already checked in", () => {
  const plan = roundNotification({
    round: roundOf([m("a", "b")], {windowEndMs: NOW + HOUR}),
    nowMs: NOW,
    arrivedByMatchup: {0: new Set(["a", "b"])},
  });
  assert.strictEqual(plan, null);
});

check("the warning fires once", () => {
  const plan = roundNotification({
    round: roundOf([m("a", "b")], {windowEndMs: NOW + HOUR}),
    nowMs: NOW,
    sent: {closing: true},
  });
  assert.strictEqual(plan, null);
});

check("the warning starts exactly at the lead time, not before", () => {
  const justOutside = roundNotification({
    round: roundOf([m("a", "b")], {windowEndMs: NOW + CLOSING_LEAD_MS + 1}),
    nowMs: NOW,
  });
  assert.strictEqual(justOutside.kind, "opened");
  const justInside = roundNotification({
    round: roundOf([m("a", "b")], {windowEndMs: NOW + CLOSING_LEAD_MS - 1}),
    nowMs: NOW,
  });
  assert.strictEqual(justInside.kind, "closing");
});

check("A LATE RECOVERY WARNS rather than announcing an opening", () => {
  // If the job was down through the start of a round and recovers inside
  // the last two hours, "your round is open" is technically true and
  // practically useless - what they need is "play now or forfeit".
  const plan = roundNotification({
    round: roundOf([m("a", "b")], {windowEndMs: NOW + HOUR}),
    nowMs: NOW,
    sent: {},
  });
  assert.strictEqual(plan.kind, "closing");
});

check("nothing is sent once the window has already closed", () => {
  const plan = roundNotification({
    round: roundOf([m("a", "b")], {windowEndMs: NOW - 1}), nowMs: NOW,
  });
  assert.strictEqual(plan, null);
});

check("a round with no window still announces its opening", () => {
  // Brackets created before windows existed must not go silent.
  const plan = roundNotification({
    round: roundOf([m("a", "b")],
        {windowStartMs: undefined, windowEndMs: undefined}),
    nowMs: NOW,
  });
  assert.strictEqual(plan.kind, "opened");
});

// ------------------------------------------------------------ the copy
check("the closing copy says the consequence out loud", () => {
  const c = notificationCopy("closing", {roundNumber: 2,
    endMs: NOW + 2 * HOUR, nowMs: NOW});
  assert.ok(/forfeit/.test(c.body), c.body);
});

check("the opening copy names the round and the time left", () => {
  const c = notificationCopy("opened", {roundNumber: 3,
    endMs: NOW + 10 * HOUR, nowMs: NOW});
  assert.ok(c.title.includes("3"), c.title);
  assert.ok(/10h/.test(c.body), c.body);
});

check("under an hour reads sensibly rather than saying 0h", () => {
  const c = notificationCopy("closing", {roundNumber: 1,
    endMs: NOW + 10 * 60 * 1000, nowMs: NOW});
  assert.ok(!/\b0h\b/.test(c.body), c.body);
});

console.log(`\n${passed} checks passed.`);
