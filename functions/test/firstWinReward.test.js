const assert = require("assert");
const {eligibility, parseConfig, deadlineMs, phoneKey, sharesDevice} =
  require("../firstWinReward");
let passed = 0;
function test(name, fn) { fn(); passed++; }

const DAY = 24 * 60 * 60 * 1000;
const signup = Date.UTC(2026, 10, 1, 12, 0, 0);
const on = parseConfig({enabled: true});
const base = () => ({
  config: on,
  match: {mode: "ranked", player1Id: "a", player2Id: "b"},
  winnerId: "a",
  winner: {phoneNumber: "+16195550100", fcmTokens: ["t1"]},
  opponent: {fcmTokens: ["t2"]},
  signupMs: signup,
  completedAtMs: signup + 3 * DAY,
  alreadyRewarded: false,
  pairHasHistory: false,
});
const why = (over) => eligibility({...base(), ...over}).reason;

test("ships off", () => {
  assert.strictEqual(parseConfig(null).enabled, false);
  assert.strictEqual(why({config: parseConfig({})}), "disabled");
});
test("a clean first ranked win inside 7 days pays", () => {
  assert.deepStrictEqual(eligibility(base()), {ok: true});
});
test("the deadline is exact: at 7 days counts, 1 minute after does not", () => {
  assert.strictEqual(deadlineMs(signup, 7), signup + 7 * DAY);
  assert.deepStrictEqual(eligibility({...base(), completedAtMs: signup + 7 * DAY}), {ok: true});
  assert.strictEqual(why({completedAtMs: signup + 7 * DAY + 60000}), "past-deadline");
});
test("only ranked, never friend/improv/tournament", () => {
  for (const mode of ["friend", "improv", "tournament", "exhibition"]) {
    assert.strictEqual(why({match: {...base().match, mode}}), "not-ranked");
  }
});
test("a forfeit win never pays (easiest thing to stage)", () => {
  assert.strictEqual(why({match: {...base().match, forfeitWinnerId: "a"}}), "forfeit");
});
test("one per person / phone", () => {
  assert.strictEqual(why({alreadyRewarded: true}), "already-rewarded");
  assert.strictEqual(why({winner: {fcmTokens: []}}), "no-phone");
  assert.strictEqual(phoneKey("+1 (619) 555-0100"), "p16195550100");
  assert.strictEqual(phoneKey(""), null);
});
test("anti-staging: friend history or a shared device blocks it", () => {
  assert.strictEqual(why({pairHasHistory: true}), "friend-history");
  assert.strictEqual(why({opponent: {fcmTokens: ["x", "t1"]}}), "shared-device");
  assert.strictEqual(sharesDevice({}, {fcmTokens: ["t1"]}), false);
});
test("missing times fail closed", () => {
  assert.strictEqual(why({signupMs: NaN}), "no-signup-time");
  assert.strictEqual(why({completedAtMs: NaN}), "no-completion-time");
});
test("config is bounds-checked per field", () => {
  const c = parseConfig({enabled: true, amountUsd: 9999, budgetUsd: -5, windowDays: "x"});
  assert.deepStrictEqual(c, {enabled: true, amountUsd: 5, budgetUsd: 500, windowDays: 7});
});
console.log(`firstWinReward: ${passed} checks passed`);
