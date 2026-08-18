/**
 * Local tests for the capture-quality summary (functions/captureQuality.js).
 * Runs with `node test/captureQuality.test.js`.
 *
 * The rule this pins hardest is that SILENCE IS NOT FAILURE. Every match
 * played before this existed, and every older client, reports nothing -
 * and reading nothing as "their capture was broken" would quietly demote
 * the entire back catalogue out of the caption ranking, which would look
 * exactly like the ranking working.
 */

const assert = require("assert");
const {
  sanitiseQualityReport,
  qualityFactor,
  isNotablyBad,
  MAX_EPISODES,
  MIN_QUALITY_FACTOR,
} = require("../captureQuality");

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

// --- sanitising a self-reported number ------------------------------------

test("an ordinary report survives intact", () => {
  assert.deepStrictEqual(
      sanitiseQualityReport({darkEpisodes: 2, quietEpisodes: 1}),
      {darkEpisodes: 2, quietEpisodes: 1});
});

test("NO REPORT IS NOT A ZERO REPORT", () => {
  // "We have no information" and "their capture was perfect" are
  // different claims. Conflating them would let a client that sends
  // nothing be indistinguishable from one that measured and found
  // nothing wrong - which matters the moment anything reads these back.
  for (const empty of [null, undefined, {}, "2", 7, []]) {
    assert.strictEqual(sanitiseQualityReport(empty), null,
        `accepted ${JSON.stringify(empty)}`);
  }
});

test("a hostile number is clamped, not rejected", () => {
  // Rejecting the whole report would let one bad field discard the
  // honest half of it.
  const r = sanitiseQualityReport({darkEpisodes: 1e9, quietEpisodes: 3});
  assert.strictEqual(r.darkEpisodes, MAX_EPISODES);
  assert.strictEqual(r.quietEpisodes, 3);
});

test("negatives and junk are dropped, and cannot flatter the reporter", () => {
  // A negative would otherwise subtract from the other player's episodes
  // and buy back caption rank.
  const r = sanitiseQualityReport({darkEpisodes: -5, quietEpisodes: 2});
  assert.strictEqual(r.darkEpisodes, 0);
  assert.strictEqual(sanitiseQualityReport({darkEpisodes: "lots"}), null);
});

// --- the ranking discount -------------------------------------------------

test("THE MIGRATION RULE: a match with no reports ranks normally", () => {
  assert.strictEqual(qualityFactor(undefined), 1);
  assert.strictEqual(qualityFactor(null), 1);
  assert.strictEqual(qualityFactor({}), 1);
});

test("a clean match is not discounted", () => {
  assert.strictEqual(
      qualityFactor({a: {darkEpisodes: 0, quietEpisodes: 0}}), 1);
});

test("problems drag the score down", () => {
  const clean = qualityFactor({a: {darkEpisodes: 0, quietEpisodes: 0}});
  const rough = qualityFactor({a: {darkEpisodes: 2, quietEpisodes: 0}});
  assert.ok(rough < clean, `${rough} was not below ${clean}`);
});

test("THE WORSE PLAYER DECIDES, not the sum", () => {
  // A battle is unwatchable if EITHER end is broken. Summing would make
  // two mildly glitchy players look worse than one player who was
  // invisible for the entire match, which is backwards.
  const oneBad = qualityFactor({
    a: {darkEpisodes: 4, quietEpisodes: 0},
    b: {darkEpisodes: 0, quietEpisodes: 0},
  });
  const bothMild = qualityFactor({
    a: {darkEpisodes: 2, quietEpisodes: 0},
    b: {darkEpisodes: 2, quietEpisodes: 0},
  });
  assert.ok(oneBad < bothMild,
      `one badly broken player (${oneBad}) must rank below two mildly ` +
      `glitchy ones (${bothMild})`);
});

test("A DISCOUNT, NEVER A VETO - the factor has a floor", () => {
  // A dark clip with overwhelming votes may still be the best thing that
  // happened all week. A zero here would let one bad reading silently
  // veto a real highlight.
  const awful = qualityFactor({a: {darkEpisodes: 50, quietEpisodes: 50}});
  assert.strictEqual(awful, MIN_QUALITY_FACTOR);
  assert.ok(awful > 0);
});

test("the factor never exceeds 1 - it discounts, it cannot promote", () => {
  for (const n of [0, 1, 5, 50]) {
    assert.ok(qualityFactor({a: {darkEpisodes: n, quietEpisodes: 0}}) <= 1);
  }
});

test("a malformed report is ignored rather than counted as perfect", () => {
  // It must not reset a genuine problem reported by the other player.
  const f = qualityFactor({
    a: "broken",
    b: {darkEpisodes: 3, quietEpisodes: 0},
  });
  assert.ok(f < 1, "the other player's real report was discarded");
});

// --- the abuse-safeguard signal ------------------------------------------

test("only a thoroughly broken match is flagged for review", () => {
  assert.strictEqual(isNotablyBad({a: {darkEpisodes: 1, quietEpisodes: 0}}),
      false, "one glitch is not evidence of anything");
  assert.strictEqual(isNotablyBad({a: {darkEpisodes: 20, quietEpisodes: 0}}),
      true);
  assert.strictEqual(isNotablyBad(undefined), false,
      "an unreported match must never be flagged");
});

console.log(`captureQuality: ${passed} checks passed`);
