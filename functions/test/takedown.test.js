/**
 * Clip takedown: a participant objecting to their own footage being public.
 *
 * These rules decide whether video of a real person who asked for it to
 * come down stays up, so the publish block is the single most important
 * assertion in this file.
 *
 * Run: node test/takedown.test.js
 */
const assert = require("assert");
const {
  publishBlockedReason,
  preferenceWindowOpen,
  preferenceRemaining,
  monthKey,
  PREFERENCE_CAP_PER_MONTH,
  HARM_REASONS,
} = require("../takedown");

let checks = 0;
function check(label, fn) {
  fn();
  checks += 1;
  console.log(`  ok  ${label}`);
}

const HOUR = 60 * 60 * 1000;
const NOW = Date.parse("2026-08-14T12:00:00Z");
const ts = (ms) => ({toMillis: () => ms});

/** A match completed two hours ago - voting still open. */
const openMatch = {completedAt: ts(NOW - 2 * HOUR)};
/** Completed two days ago - voting long closed. */
const closedMatch = {completedAt: ts(NOW - 48 * HOUR)};

// --- the publish block, which is the part that actually protects someone ---

check("an objection blocks publishing outright", () => {
  assert.strictEqual(
      publishBlockedReason({...closedMatch, objections: {alice: {channel: "preference"}}}, NOW),
      "participant-objected");
});

check("a harm objection blocks publishing just as hard", () => {
  assert.strictEqual(
      publishBlockedReason({...closedMatch, objections: {bob: {channel: "harm"}}}, NOW),
      "participant-objected");
});

check("EITHER player objecting is enough", () => {
  // A battle has two people in it, and one wanting out is sufficient -
  // there is no majority to reach.
  for (const who of ["alice", "bob"]) {
    assert.strictEqual(
        publishBlockedReason({...closedMatch, objections: {[who]: {}}}, NOW),
        "participant-objected");
  }
});

check("nothing publishes while the objection window is still open", () => {
  // Nothing reaches a public audience before both players have had their
  // full chance to opt out. It also means the render is never spent on
  // footage that cannot be used.
  assert.strictEqual(publishBlockedReason(openMatch, NOW), "objection-window-open");
});

check("a settled, unobjected match may be published", () => {
  assert.strictEqual(publishBlockedReason(closedMatch, NOW), null);
  assert.strictEqual(publishBlockedReason({...closedMatch, objections: {}}, NOW), null);
});

check("a missing match is never publishable", () => {
  assert.strictEqual(publishBlockedReason(null, NOW), "not-found");
  assert.strictEqual(publishBlockedReason(undefined, NOW), "not-found");
});

check("an objection outlasts the window closing", () => {
  // The block must not quietly lapse once the deadline passes - that would
  // make every honoured takedown temporary.
  const objected = {...closedMatch, objections: {alice: {channel: "preference"}}};
  assert.strictEqual(publishBlockedReason(objected, NOW + 365 * 24 * HOUR),
      "participant-objected");
});

// --- the preference deadline ---

check("preference requests are open while voting is", () => {
  assert.strictEqual(preferenceWindowOpen(openMatch, NOW), true);
});

check("preference requests close when voting closes", () => {
  // Deciding before the result is known means the choice is made on "am I
  // comfortable with this being public" rather than "I lost, delete it".
  assert.strictEqual(preferenceWindowOpen(closedMatch, NOW), false);
});

check("the deadline is exactly the end of the voting window", () => {
  const endsNow = {completedAt: ts(NOW - 24 * HOUR)};
  assert.strictEqual(preferenceWindowOpen(endsNow, NOW), false);
  assert.strictEqual(preferenceWindowOpen(endsNow, NOW - 1), true);
});

// --- the monthly cap, which must never touch the harm channel ---

check("a new user has the full monthly allowance", () => {
  assert.strictEqual(preferenceRemaining(undefined, NOW), PREFERENCE_CAP_PER_MONTH);
  assert.strictEqual(preferenceRemaining({}, NOW), PREFERENCE_CAP_PER_MONTH);
});

check("the allowance decrements and runs out", () => {
  const key = monthKey(NOW);
  assert.strictEqual(preferenceRemaining({takedowns: {monthKey: key, count: 1}}, NOW), 1);
  assert.strictEqual(preferenceRemaining({takedowns: {monthKey: key, count: 2}}, NOW), 0);
});

check("an overspent allowance never goes negative", () => {
  const key = monthKey(NOW);
  assert.strictEqual(preferenceRemaining({takedowns: {monthKey: key, count: 99}}, NOW), 0);
});

check("last month's usage does not count against this month", () => {
  assert.strictEqual(
      preferenceRemaining({takedowns: {monthKey: "2026-07", count: 2}}, NOW),
      PREFERENCE_CAP_PER_MONTH);
});

check("the month key rolls on calendar months", () => {
  assert.strictEqual(monthKey(Date.parse("2026-08-31T23:59:59Z")), "2026-08");
  assert.strictEqual(monthKey(Date.parse("2026-09-01T00:00:01Z")), "2026-09");
});

// --- the harm channel's shape ---

check("harm reasons cover the cases that motivated this", () => {
  // Routing, not friction - it makes bad-faith use visible without gating
  // anyone at the moment of asking.
  for (const reason of ["harassment", "doxxing", "false_claim", "brigading"]) {
    assert.ok(HARM_REASONS.includes(reason), `missing ${reason}`);
  }
});

check("the cap is small enough to be a courtesy, not a policy", () => {
  // If this ever grew large the deadline would stop doing its job, since
  // someone could simply opt out of every loss.
  assert.ok(PREFERENCE_CAP_PER_MONTH <= 5, `cap too generous: ${PREFERENCE_CAP_PER_MONTH}`);
});

console.log(`\n${checks} checks passed.`);
