/**
 * The "N roasters online now" count.
 *
 * Tested because this number's only value is being TRUE. It exists to
 * answer "will anyone be there?", so an inflated count doesn't just look
 * wrong - it sends someone into an empty queue and teaches them the app is
 * dead, which is worse than showing no number at all.
 *
 * Run: node test/presence.test.js
 */
const assert = require("assert");
const {countQueue, PRESENCE_STALE_MS} = require("../presence");
const {MODES, STALE_ENTRY_MS} = require("../matchmaking");

let checks = 0;
function check(label, fn) {
  fn();
  checks += 1;
  console.log(`  ok  ${label}`);
}

const NOW = 1_700_000_000_000;
const fresh = (status) => ({status, joinedAt: NOW - 5_000});
const stale = (status) => ({status, joinedAt: NOW - PRESENCE_STALE_MS - 1});

check("the modes this sweeps are actually importable and non-empty", () => {
  // This exact assertion would have caught a real bug: MODES was not in
  // matchmaking.js's exports, so publishOnlineCount threw "MODES is not
  // iterable" on every run. The deploy succeeded, the error was swallowed
  // by the function's own catch, and the only visible symptom was a
  // stats/presence document that never appeared. Testing the pure counting
  // helper alone could never have found it - the break was in the seam
  // between two modules.
  assert.ok(Array.isArray(MODES), "MODES must be exported as an array");
  assert.ok(MODES.length > 0, "sweeping zero modes would always report nobody");
  assert.ok(MODES.includes("ranked") && MODES.includes("exhibition"));
});

check("staleness matches the threshold pairing itself uses", () => {
  // If these drift apart, the count can advertise people the matchmaker has
  // already decided are gone.
  assert.strictEqual(PRESENCE_STALE_MS, STALE_ENTRY_MS);
});

check("an empty set of queues counts zero", () => {
  assert.deepStrictEqual(countQueue({}, NOW), {waiting: 0, matched: 0, total: 0});
});

check("a missing queue node does not throw", () => {
  // The RTDB returns null for a node that has never had an entry, which is
  // the normal state of a mode nobody has queued for yet.
  assert.deepStrictEqual(
      countQueue({exhibition: null, ranked: undefined}, NOW),
      {waiting: 0, matched: 0, total: 0});
  assert.deepStrictEqual(countQueue(null, NOW), {waiting: 0, matched: 0, total: 0});
});

check("people waiting are counted", () => {
  const counts = countQueue({ranked: {a: fresh("waiting"), b: fresh("waiting")}}, NOW);
  assert.strictEqual(counts.waiting, 2);
  assert.strictEqual(counts.total, 2);
});

check("people already in a match are counted too", () => {
  // Someone mid-battle is emphatically "here" - excluding them would make
  // the app look emptiest at exactly the moment it is busiest.
  const counts = countQueue({ranked: {a: fresh("matched"), b: fresh("matched")}}, NOW);
  assert.strictEqual(counts.matched, 2);
  assert.strictEqual(counts.total, 2);
});

check("counts are summed across every mode", () => {
  const counts = countQueue({
    exhibition: {a: fresh("waiting")},
    ranked: {b: fresh("waiting"), c: fresh("matched")},
  }, NOW);
  assert.deepStrictEqual(counts, {waiting: 2, matched: 1, total: 3});
});

check("ghost entries from a crashed client are NOT counted", () => {
  // The single most important case. A client that closes without leaving
  // the queue strands its entry; counting it would report people who are
  // not there, which is the exact dishonesty this number cannot survive.
  const counts = countQueue({ranked: {ghost: stale("waiting")}}, NOW);
  assert.strictEqual(counts.total, 0);
});

check("a stale matched entry is also excluded", () => {
  assert.strictEqual(countQueue({ranked: {g: stale("matched")}}, NOW).total, 0);
});

check("an entry right on the staleness boundary still counts", () => {
  const boundary = {status: "waiting", joinedAt: NOW - PRESENCE_STALE_MS};
  assert.strictEqual(countQueue({ranked: {a: boundary}}, NOW).total, 1);
});

check("an entry with no joinedAt is treated as stale, not as brand new", () => {
  // A malformed entry defaults joinedAt to 0, which is decades ago. That
  // must read as "don't count it" rather than "count it forever".
  assert.strictEqual(countQueue({ranked: {a: {status: "waiting"}}}, NOW).total, 0);
});

check("unknown statuses are ignored rather than guessed at", () => {
  const counts = countQueue({ranked: {a: fresh("cancelled"), b: fresh("waiting")}}, NOW);
  assert.strictEqual(counts.total, 1);
});

check("non-object junk in the queue is skipped", () => {
  const counts = countQueue({ranked: {a: "corrupt", b: null, c: fresh("waiting")}}, NOW);
  assert.strictEqual(counts.total, 1);
});

check("waiting and matched never double-count the same person", () => {
  const counts = countQueue({ranked: {a: fresh("waiting"), b: fresh("matched")}}, NOW);
  assert.strictEqual(counts.waiting + counts.matched, counts.total);
});

console.log(`\n${checks} checks passed.`);
