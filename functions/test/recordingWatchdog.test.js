/**
 * Local tests for the runaway-recording cap (functions/cloudRecording.js).
 * Runs with plain `node test/recordingWatchdog.test.js`.
 *
 * This is the only guard against the project's one genuinely unbounded
 * cost path: a recording that never stops because a match wedged with
 * clients still connected. It has to satisfy two opposing properties at
 * once —
 *   - never cut off a legitimately long match (which would destroy real
 *     footage of real people), and
 *   - never let a stuck recording bill indefinitely.
 * Match timings are live-configurable, so the cap is derived per match
 * rather than fixed, and these tests pin that derivation across the whole
 * configurable range.
 */

const assert = require("assert");
const {maxRecordingSeconds} = require("../cloudRecording");
const {DEFAULTS, LIMITS} = require("../matchSettings");

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

/** What a match of the given settings actually takes, with no slack. */
function realMatchSeconds(s) {
  return s.bioRevealSeconds + s.roundCount * 2 * (s.roundLengthSeconds + s.countdownSeconds);
}

test("the cap exceeds a default match with real but not excessive slack", () => {
  const cap = maxRecordingSeconds(DEFAULTS);
  const real = realMatchSeconds(DEFAULTS);
  const slack = cap - real;
  assert.ok(cap > real, `cap ${cap}s must exceed a real match's ${real}s`);
  // Enough for the verdict screen, the stop call and network lag...
  assert.ok(slack >= 60, `slack ${slack}s is too tight to be safe`);
  // ...but not so much that a wedged recording outcosts a real match.
  // Recording starts at host election, so joining is already done.
  assert.ok(slack <= 180, `slack ${slack}s is more than the backstop needs`);
});

test("the cap never cuts off a match at ANY legal configuration", () => {
  // Sweep the whole configurable space. A cap that clips a legitimate
  // match destroys footage that can't be recovered.
  for (let rounds = LIMITS.roundCount.min; rounds <= LIMITS.roundCount.max; rounds++) {
    for (const turn of [LIMITS.roundLengthSeconds.min, 15, 60, LIMITS.roundLengthSeconds.max]) {
      for (const countdown of [LIMITS.countdownSeconds.min, 5, LIMITS.countdownSeconds.max]) {
        for (const reveal of [LIMITS.bioRevealSeconds.min, 60, LIMITS.bioRevealSeconds.max]) {
          const s = {
            roundCount: rounds,
            roundLengthSeconds: turn,
            countdownSeconds: countdown,
            bioRevealSeconds: reveal,
          };
          assert.ok(
              maxRecordingSeconds(s) > realMatchSeconds(s),
              `cap too tight for ${JSON.stringify(s)}`,
          );
        }
      }
    }
  }
});

test("a stuck recording is bounded to under a dollar, even worst-case", () => {
  // The property that actually matters isn't a round number of seconds,
  // it's how much a single wedged recording can cost before the watchdog
  // kills it. Asserting on cost keeps this meaningful if the timing
  // limits are ever retuned.
  const worst = {
    roundCount: LIMITS.roundCount.max,
    roundLengthSeconds: LIMITS.roundLengthSeconds.max,
    countdownSeconds: LIMITS.countdownSeconds.max,
    bioRevealSeconds: LIMITS.bioRevealSeconds.max,
  };
  const capMinutes = maxRecordingSeconds(worst) / 60;
  // Full HD is the most expensive band this could plausibly land in
  // ($13.49 per 1,000 recorded minutes - see CLAUDE.md's Cost Planning).
  const worstCaseCost = capMinutes * (13.49 / 1000);
  assert.ok(
      worstCaseCost < 1,
      `a single stuck recording could cost $${worstCaseCost.toFixed(2)} before being stopped`,
  );

  // The everyday case - default settings, HD band. A wedged recording
  // should stay in the same order of magnitude as a normal match
  // (~$0.015), not dwarf it. An earlier version used five minutes of
  // slack, which made a stuck recording cost more than a real match.
  //
  // Sub-cent precision here is meaningless: the watchdog polls on a
  // schedule, so actual stop time is this cap plus up to one poll
  // interval regardless.
  const defaultCost = (maxRecordingSeconds(DEFAULTS) / 60) * (5.99 / 1000);
  assert.ok(defaultCost < 0.05, `default-config stuck recording costs $${defaultCost.toFixed(4)}`);
});

test("the cap is proportionate - a wedged match can't cost wildly more than a real one", () => {
  // A normal default match records for about 3 minutes.
  const realMatchCost = 3 * (5.99 / 1000);
  const wedgedCost = (maxRecordingSeconds(DEFAULTS) / 60) * (5.99 / 1000);
  assert.ok(
      wedgedCost < realMatchCost * 3,
      `wedged ($${wedgedCost.toFixed(4)}) should stay within 3x a real match ($${realMatchCost.toFixed(4)})`,
  );
});

test("missing settings fall back to the documented defaults", () => {
  // An older match document written before settings existed must still
  // get a sane cap rather than NaN or Infinity.
  const cap = maxRecordingSeconds(undefined);
  assert.strictEqual(cap, maxRecordingSeconds(DEFAULTS));
  assert.ok(Number.isFinite(cap) && cap > 0, "cap must be a finite positive number");
});

test("a partial settings object still yields a finite cap", () => {
  const cap = maxRecordingSeconds({roundCount: 5});
  assert.ok(Number.isFinite(cap) && cap > 0);
});

test("a longer configuration produces a longer cap", () => {
  // The whole point of deriving it: the cap has to track configuration.
  const short = maxRecordingSeconds({...DEFAULTS, roundCount: 1});
  const long = maxRecordingSeconds({...DEFAULTS, roundCount: 10});
  assert.ok(long > short, "cap must scale with round count");
});

console.log(`recordingWatchdog: ${passed} checks passed`);
