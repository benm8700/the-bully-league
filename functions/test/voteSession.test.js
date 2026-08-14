/**
 * Vote sessions: one CAPTCHA solve buying a bounded run of votes.
 *
 * The rules worth pinning are the two limits, because they are the entire
 * reason this is an acceptable trade against a per-vote challenge. If
 * either can be circumvented, one solve stops buying "a judging run" and
 * starts buying "unlimited votes".
 *
 * Run: node test/voteSession.test.js
 */
const assert = require("assert");
const {
  sessionUsable,
  SESSION_TTL_MS,
  SESSION_VOTE_BUDGET,
} = require("../voteSession");

let checks = 0;
function check(label, fn) {
  fn();
  checks += 1;
  console.log(`  ok  ${label}`);
}

const NOW = 1_800_000_000_000;
/** Firestore Timestamp stand-in - only toMillis() is ever read. */
const at = (ms) => ({toMillis: () => ms});
const session = (votesRemaining, expiresAtMs) => ({
  votesRemaining, expiresAt: at(expiresAtMs),
});

check("a fresh session is usable", () => {
  assert.strictEqual(
      sessionUsable(session(SESSION_VOTE_BUDGET, NOW + SESSION_TTL_MS), NOW), true);
});

check("no session at all is not usable", () => {
  assert.strictEqual(sessionUsable(null, NOW), false);
  assert.strictEqual(sessionUsable(undefined, NOW), false);
});

check("an expired session is refused", () => {
  // Bounds how long a stolen or abandoned session stays worth anything.
  assert.strictEqual(sessionUsable(session(20, NOW - 1), NOW), false);
});

check("expiry is exact at the boundary", () => {
  assert.strictEqual(sessionUsable(session(20, NOW), NOW), false);
  assert.strictEqual(sessionUsable(session(20, NOW + 1), NOW), true);
});

check("a spent session is refused", () => {
  // The vote ceiling: one solve buys a run, never an unlimited supply.
  assert.strictEqual(sessionUsable(session(0, NOW + SESSION_TTL_MS), NOW), false);
});

check("a negative balance can never be spent", () => {
  // Defensive: if a concurrent decrement ever drove this below zero, it
  // must read as spent rather than wrapping into "usable".
  assert.strictEqual(sessionUsable(session(-3, NOW + SESSION_TTL_MS), NOW), false);
});

check("a malformed balance is refused rather than trusted", () => {
  for (const bad of [undefined, null, "lots", NaN, {}]) {
    assert.strictEqual(
        sessionUsable({votesRemaining: bad, expiresAt: at(NOW + SESSION_TTL_MS)}, NOW),
        false, `votesRemaining=${String(bad)}`);
  }
});

check("a missing expiry is refused rather than treated as forever", () => {
  // The failure that matters most: an absent expiry defaulting to 0 must
  // read as long expired, never as unbounded.
  assert.strictEqual(sessionUsable({votesRemaining: 10}, NOW), false);
  assert.strictEqual(sessionUsable({votesRemaining: 10, expiresAt: null}, NOW), false);
});

check("both limits must hold, not just one", () => {
  assert.strictEqual(sessionUsable(session(0, NOW - 1), NOW), false);
  assert.strictEqual(sessionUsable(session(5, NOW - 1), NOW), false);
  assert.strictEqual(sessionUsable(session(0, NOW + SESSION_TTL_MS), NOW), false);
});

check("the budget is a sitting, not a licence", () => {
  // If this ever grew large the trade against per-vote challenges stops
  // being defensible, so the intent is asserted rather than left to drift.
  assert.ok(SESSION_VOTE_BUDGET <= 50, `budget too generous: ${SESSION_VOTE_BUDGET}`);
  assert.ok(SESSION_TTL_MS <= 60 * 60 * 1000, `ttl too long: ${SESSION_TTL_MS}`);
});

console.log(`\n${checks} checks passed.`);
