const assert = require("assert");
const {
  initialInvites,
  confirmedFrom,
  buildMainStageDoc,
  lockOutcome,
  inviteResponse,
  calloutResult,
  storeBracket,
  loadBracket,
  MIN_FIELD,
} = require("../mainStageLifecycle");

let passed = 0;
function check(name, fn) {
  fn();
  passed++;
  console.log(`  ok - ${name}`);
}

// A realistic frozen snapshot: 4 finalists, 4 alternates, a judge pool.
const SNAP = {
  tournamentDayKey: "2026-10-15",
  finalists: [{uid: "f1", gain: 90}, {uid: "f2", gain: 70},
    {uid: "f3", gain: 50}, {uid: "f4", gain: 40}],
  alternates: [{uid: "a1", gain: 30}, {uid: "a2", gain: 25},
    {uid: "a3", gain: 20}, {uid: "a4", gain: 15}],
  judgePool: [{uid: "j1", judged: 40}, {uid: "j2", judged: 30},
    {uid: "j3", judged: 20}, {uid: "j4", judged: 10}, {uid: "j5", judged: 5}],
};

console.log("main stage lifecycle - create / respond / lock / callout");

check("initialInvites marks every finalist AND alternate pending", () => {
  const inv = initialInvites(["f1", "f2"], ["a1"]);
  assert.deepStrictEqual(inv, {f1: "pending", f2: "pending", a1: "pending"});
});

check("confirmedFrom returns only accepted uids", () => {
  const got = confirmedFrom({f1: "accepted", f2: "declined", a1: "pending",
    a2: "accepted"}).sort();
  assert.deepStrictEqual(got, ["a2", "f1"]);
});

check("buildMainStageDoc shapes uid arrays + schedule + pending invites", () => {
  const doc = buildMainStageDoc({
    snapshot: SNAP, nowMs: 1000, lockAtMs: 2000, showAtMs: 3000,
  });
  assert.strictEqual(doc.format, "mainstage");
  assert.strictEqual(doc.status, "accepting");
  assert.strictEqual(doc.cutoffDayKey, "2026-10-15");
  assert.deepStrictEqual(doc.finalists, ["f1", "f2", "f3", "f4"]);
  assert.deepStrictEqual(doc.alternates, ["a1", "a2", "a3", "a4"]);
  assert.deepStrictEqual(doc.judgePool, ["j1", "j2", "j3", "j4", "j5"]);
  assert.strictEqual(doc.lockAtMs, 2000);
  assert.strictEqual(doc.showAtMs, 3000);
  assert.strictEqual(doc.bracket, null);
  // every finalist + alternate is pending, nobody else
  assert.strictEqual(Object.keys(doc.invites).length, 8);
  assert.ok(Object.values(doc.invites).every((s) => s === "pending"));
});

check("buildMainStageDoc tolerates a thin snapshot (missing pools)", () => {
  const doc = buildMainStageDoc({
    snapshot: {tournamentDayKey: "d"}, nowMs: 1, lockAtMs: 2, showAtMs: 3,
  });
  assert.deepStrictEqual(doc.finalists, []);
  assert.deepStrictEqual(doc.alternates, []);
  assert.deepStrictEqual(doc.judgePool, []);
  assert.deepStrictEqual(doc.invites, {});
});

check("lock: all four confirm -> field is the four finalists in seed order", () => {
  const invites = {f1: "accepted", f2: "accepted", f3: "accepted",
    f4: "accepted", a1: "pending", a2: "pending", a3: "pending", a4: "pending"};
  const out = lockOutcome({
    finalists: ["f1", "f2", "f3", "f4"],
    alternates: ["a1", "a2", "a3", "a4"],
    invites,
    judgePool: ["j1", "j2", "j3", "j4", "j5"],
  });
  assert.deepStrictEqual(out.field, ["f1", "f2", "f3", "f4"]);
  assert.strictEqual(out.full, true);
  assert.strictEqual(out.cancel, false);
  assert.strictEqual(out.judges.length, 5); // autofilled from the pool
  assert.strictEqual(out.judgeShortfall, 0);
});

check("lock: a declining finalist is replaced by the top CONFIRMED alternate", () => {
  // f2 declines; a1 (top alternate) confirmed, so the field is f1,f3,f4,a1.
  const invites = {f1: "accepted", f2: "declined", f3: "accepted",
    f4: "accepted", a1: "accepted", a2: "pending", a3: "pending",
    a4: "pending"};
  const out = lockOutcome({
    finalists: ["f1", "f2", "f3", "f4"],
    alternates: ["a1", "a2", "a3", "a4"],
    invites,
    judgePool: ["j1", "j2", "j3", "j4", "j5"],
  });
  assert.deepStrictEqual(out.field, ["f1", "f3", "f4", "a1"]);
  assert.strictEqual(out.full, true);
  assert.strictEqual(out.cancel, false);
  assert.strictEqual(out.field[0], "f1"); // #1 who makes the callout
});

check("lock: an unconfirmed alternate never fills a slot", () => {
  // f2 declines, no alternate confirmed -> field short, but still >= MIN_FIELD.
  const invites = {f1: "accepted", f2: "declined", f3: "accepted",
    f4: "accepted", a1: "pending", a2: "declined"};
  const out = lockOutcome({
    finalists: ["f1", "f2", "f3", "f4"],
    alternates: ["a1", "a2", "a3", "a4"],
    invites,
    judgePool: ["j1", "j2", "j3", "j4", "j5"],
  });
  assert.deepStrictEqual(out.field, ["f1", "f3", "f4"]);
  assert.strictEqual(out.full, false);
  assert.strictEqual(out.cancel, false);
});

check(`lock: fewer than MIN_FIELD (${MIN_FIELD}) confirmed -> cancel`, () => {
  const invites = {f1: "accepted", f2: "declined", f3: "declined",
    f4: "declined", a1: "declined", a2: "pending"};
  const out = lockOutcome({
    finalists: ["f1", "f2", "f3", "f4"],
    alternates: ["a1", "a2", "a3", "a4"],
    invites,
    judgePool: ["j1", "j2", "j3", "j4", "j5"],
  });
  assert.strictEqual(out.field.length, 1);
  assert.strictEqual(out.cancel, true);
});

check("lock: a hand-picked judge takes a seat ahead of the pool", () => {
  const out = lockOutcome({
    finalists: ["f1", "f2", "f3", "f4"],
    alternates: [],
    invites: {f1: "accepted", f2: "accepted", f3: "accepted", f4: "accepted"},
    judgePool: ["j1", "j2", "j3", "j4", "j5"],
    handPicked: ["head"],
  });
  assert.strictEqual(out.judges[0], "head");
  assert.strictEqual(out.judges.length, 5);
});

check("lock: a finalist can never be a judge even if in the pool", () => {
  const out = lockOutcome({
    finalists: ["f1", "f2", "f3", "f4"],
    alternates: [],
    invites: {f1: "accepted", f2: "accepted", f3: "accepted", f4: "accepted"},
    judgePool: ["f1", "j1", "j2", "j3", "j4", "j5"], // f1 wrongly in pool
  });
  assert.ok(!out.judges.includes("f1"));
});

check("lock: excluded (banned) judge is kept off the panel", () => {
  const out = lockOutcome({
    finalists: ["f1", "f2", "f3", "f4"],
    alternates: [],
    invites: {f1: "accepted", f2: "accepted", f3: "accepted", f4: "accepted"},
    judgePool: ["j1", "j2", "j3", "j4", "j5"],
    exclude: ["j1"],
  });
  assert.ok(!out.judges.includes("j1"));
});

check("inviteResponse accepts an invited player while accepting", () => {
  const doc = {status: "accepting", invites: {f1: "pending"}};
  assert.deepStrictEqual(inviteResponse(doc, "f1", true), {ok: true, status: "accepted"});
  assert.deepStrictEqual(inviteResponse(doc, "f1", false), {ok: true, status: "declined"});
});

check("inviteResponse refuses a non-invited caller", () => {
  const doc = {status: "accepting", invites: {f1: "pending"}};
  assert.strictEqual(inviteResponse(doc, "stranger", true).ok, false);
});

check("inviteResponse refuses once past the accepting phase", () => {
  const doc = {status: "locked", invites: {f1: "pending"}};
  assert.strictEqual(inviteResponse(doc, "f1", true).ok, false);
});

check("callout: #1 calls out another finalist -> builds bracket, goes live", () => {
  const doc = {status: "locked", field: ["f1", "f2", "f3", "f4"]};
  const r = calloutResult(doc, "f1", "f3");
  assert.strictEqual(r.ok, true);
  assert.deepStrictEqual([r.bracket.rounds[0][0].a, r.bracket.rounds[0][0].b],
      ["f1", "f3"]);
});

check("callout: only the #1 seed may call out", () => {
  const doc = {status: "locked", field: ["f1", "f2", "f3", "f4"]};
  assert.strictEqual(calloutResult(doc, "f2", "f3").ok, false);
});

check("callout: refused unless locked", () => {
  const doc = {status: "live", field: ["f1", "f2", "f3", "f4"]};
  assert.strictEqual(calloutResult(doc, "f1", "f3").ok, false);
});

check("callout: an illegal pick (self / non-finalist) is rejected", () => {
  const doc = {status: "locked", field: ["f1", "f2", "f3", "f4"]};
  assert.strictEqual(calloutResult(doc, "f1", "f1").ok, false);
  assert.strictEqual(calloutResult(doc, "f1", "nobody").ok, false);
});

check("storeBracket makes the array-of-arrays Firestore-safe and roundtrips", () => {
  const doc = {status: "locked", field: ["f1", "f2", "f3", "f4"]};
  const bracket = calloutResult(doc, "f1", "f3").bracket;
  const stored = storeBracket(bracket);
  // No round is a bare array (the thing Firestore rejects); each is {matches}.
  assert.ok(stored.rounds.every((r) => Array.isArray(r.matches)));
  assert.ok(!stored.rounds.some((r) => Array.isArray(r)));
  // Roundtrips back to the exact pure shape the bracket core consumes.
  assert.deepStrictEqual(loadBracket(stored), bracket);
});

check("storeBracket/loadBracket pass null through untouched", () => {
  assert.strictEqual(storeBracket(null), null);
  assert.strictEqual(loadBracket(null), null);
});

console.log(`\n${passed} passed`);
