/**
 * Whether a match counts as a prime-time-window match.
 *
 * THE RULE: judged at the START of a match, never at the end. A battle that
 * kicks off at 6:58 and runs past 7:00 qualifies in full.
 *
 * This is tested before any reward is attached to it, precisely so the rule
 * is decided deliberately rather than by whatever the first bonus feature
 * happens to implement. Judging on completion would penalise a long match
 * and, worse, give players a reason to rush or abandon one to beat the
 * clock - the exact opposite of what an hour designed to get people
 * battling should encourage.
 *
 * Run: node test/eventWindowQualify.test.js
 */
const assert = require("assert");
const {
  qualifiesForWindow,
  readEventWindowConfig,
  isWithinWindow,
  PAIRING_GRACE_MS,
} = require("../eventWindow");
const {earliestQueuedAt} = require("../matchmaking");

let checks = 0;
function check(label, fn) {
  fn();
  checks += 1;
  console.log(`  ok  ${label}`);
}

const config = readEventWindowConfig(null); // 6-7pm Pacific
const MINUTE = 60 * 1000;

/** A UTC instant for a given Pacific wall-clock time in high summer (PDT,
 * UTC-7), so 6pm Pacific is 01:00 UTC the next day. */
const pacific = (hour, minute = 0) =>
  Date.parse("2026-07-02T00:00:00Z") + (hour + 7) * 60 * MINUTE + minute * MINUTE;

// --- the case the developer raised ---

check("a match started at 6:58 qualifies, however long it runs", () => {
  // The whole point: completion time is not consulted at all. This match
  // ends well past 7:00 and is fully qualified.
  assert.strictEqual(qualifiesForWindow({
    pairedAtMs: pacific(18, 58),
    queuedAtMs: pacific(18, 57),
    config,
  }), true);
});

check("a match started one minute before close still qualifies", () => {
  assert.strictEqual(qualifiesForWindow({
    pairedAtMs: pacific(18, 59),
    queuedAtMs: pacific(18, 59),
    config,
  }), true);
});

check("nothing about the rule depends on when a match ENDS", () => {
  // Stated as an explicit assertion because it is the property most likely
  // to be quietly broken later by someone adding a completedAt check.
  const args = {pairedAtMs: pacific(18, 58), queuedAtMs: pacific(18, 58), config};
  assert.strictEqual(qualifiesForWindow(args), true);
  assert.strictEqual(qualifiesForWindow({...args, now: pacific(23, 0)}), true);
});

// --- the boundaries ---

check("a match started at the top of the hour qualifies", () => {
  assert.strictEqual(qualifiesForWindow({
    pairedAtMs: pacific(18, 0), queuedAtMs: pacific(18, 0), config,
  }), true);
});

check("a match started after close does NOT qualify", () => {
  assert.strictEqual(qualifiesForWindow({
    pairedAtMs: pacific(19, 0), queuedAtMs: pacific(19, 0), config,
  }), false);
});

check("a match started before the window does NOT qualify", () => {
  assert.strictEqual(qualifiesForWindow({
    pairedAtMs: pacific(17, 59), queuedAtMs: pacific(17, 55), config,
  }), false);
});

// --- pairing latency is not the player's fault ---

check("queueing inside the window survives a slow pairing", () => {
  // Queued at 6:58, the pool was thin, paired at 7:02. Losing the bonus
  // because matchmaking was slow is exactly the kind of arbitrary penalty
  // that makes a reward feel rigged.
  assert.strictEqual(qualifiesForWindow({
    pairedAtMs: pacific(19, 2),
    queuedAtMs: pacific(18, 58),
    config,
  }), true);
});

check("the grace is bounded, so a dormant entry can't farm it", () => {
  // Matters for the planned standing-challenge design, where entries live
  // for hours rather than minutes - without a cap, a challenge left at
  // 6:59pm would still be minting bonuses at midnight.
  assert.strictEqual(qualifiesForWindow({
    pairedAtMs: pacific(18, 59) + PAIRING_GRACE_MS + MINUTE,
    queuedAtMs: pacific(18, 59),
    config,
  }), false);
});

check("a pairing right at the grace limit still counts", () => {
  assert.strictEqual(qualifiesForWindow({
    pairedAtMs: pacific(18, 59) + PAIRING_GRACE_MS,
    queuedAtMs: pacific(18, 59),
    config,
  }), true);
});

check("queueing before the window and pairing inside it qualifies", () => {
  // Judged on the pairing, which is inside - waiting through the run-up
  // should not disqualify anyone.
  assert.strictEqual(qualifiesForWindow({
    pairedAtMs: pacific(18, 1), queuedAtMs: pacific(17, 55), config,
  }), true);
});

// --- both players get one answer ---

check("the earlier of the two queue times is the one used", () => {
  const pairing = {joinedAt: 500, opponentJoinedAt: 100};
  assert.strictEqual(earliestQueuedAt(pairing), 100);
  assert.strictEqual(earliestQueuedAt({joinedAt: 100, opponentJoinedAt: 500}), 100);
});

check("a missing opponent time falls back to our own", () => {
  assert.strictEqual(earliestQueuedAt({joinedAt: 250, opponentJoinedAt: null}), 250);
});

check("no usable times at all yields NaN rather than zero", () => {
  // Zero would be 1970, which sits outside every window - but it would do
  // so by accident. NaN makes the "unknown" case explicit and is refused.
  assert.ok(Number.isNaN(earliestQueuedAt({})));
  assert.ok(Number.isNaN(earliestQueuedAt(null)));
});

check("an unknown queue time never qualifies a late pairing", () => {
  assert.strictEqual(qualifiesForWindow({
    pairedAtMs: pacific(19, 5), queuedAtMs: NaN, config,
  }), false);
});

// --- disabled and misconfigured ---

check("a disabled window qualifies nobody", () => {
  const off = readEventWindowConfig({enabled: false});
  assert.strictEqual(qualifiesForWindow({
    pairedAtMs: pacific(18, 30), queuedAtMs: pacific(18, 30), config: off,
  }), false);
  assert.strictEqual(isWithinWindow(new Date(pacific(18, 30)), off), false);
});

check("a reconfigured window is respected", () => {
  const late = readEventWindowConfig({startHourPacific: 21, endHourPacific: 23});
  assert.strictEqual(qualifiesForWindow({
    pairedAtMs: pacific(18, 30), queuedAtMs: pacific(18, 30), config: late,
  }), false);
  assert.strictEqual(qualifiesForWindow({
    pairedAtMs: pacific(21, 30), queuedAtMs: pacific(21, 30), config: late,
  }), true);
});

check("a missing pairing time never qualifies", () => {
  assert.strictEqual(qualifiesForWindow({
    pairedAtMs: undefined, queuedAtMs: pacific(18, 30), config,
  }), false);
});

check("a queue time AFTER the pairing is rejected as nonsense", () => {
  // Clock skew or a corrupted entry; it must not become a free bonus.
  assert.strictEqual(qualifiesForWindow({
    pairedAtMs: pacific(20, 0), queuedAtMs: pacific(21, 0), config,
  }), false);
});

// --- winter, so the rule doesn't quietly shift by an hour ---

check("the window is 6-7pm Pacific in standard time too", () => {
  const winter6pm = Date.parse("2026-01-16T02:00:00Z"); // 6pm PST Jan 15
  assert.strictEqual(isWithinWindow(new Date(winter6pm), config), true);
  assert.strictEqual(
      isWithinWindow(new Date(winter6pm - MINUTE), config), false);
});

console.log(`\n${checks} checks passed.`);
