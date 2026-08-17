const assert = require("assert");
const {referralOutcome} = require("../referral");

let passed = 0;
function check(name, fn) {
  fn();
  passed++;
  console.log(`  ok - ${name}`);
}

const ME = "me";
const REFERRER = "referrer";
const user = (over = {}) => ({
  referredByUserId: REFERRER,
  rankedMatchesPlayed: 1,
  ...over,
});

console.log("referral");

check("a referred player who has played earns their referrer a reward", () => {
  const r = referralOutcome(user(), ME);
  assert.strictEqual(r.owed, true);
  assert.strictEqual(r.referrerId, REFERRER);
});

check("THE WHOLE POINT: signing up alone earns nothing", () => {
  // Paying at signup makes throwaway accounts directly profitable, which
  // is the one thing a referral programme must not do. Requiring a real
  // match means an abuser must play a battle against a real opponent for
  // every fake account.
  const r = referralOutcome(
      user({rankedMatchesPlayed: 0, exhibitionMatchesPlayed: 0}), ME);
  assert.strictEqual(r.owed, false);
  assert.strictEqual(r.reason, "not-activated");
});

check("a practice match counts as activation too", () => {
  const r = referralOutcome(
      user({rankedMatchesPlayed: 0, exhibitionMatchesPlayed: 1}), ME);
  assert.strictEqual(r.owed, true);
});

check("no referrer means nothing to pay", () => {
  const r = referralOutcome(user({referredByUserId: null}), ME);
  assert.strictEqual(r.owed, false);
  assert.strictEqual(r.reason, "no-referrer");
});

check("PAID ONCE - an already-granted referral never pays again", () => {
  const r = referralOutcome(user({referralRewardGranted: true}), ME);
  assert.strictEqual(r.owed, false);
  assert.strictEqual(r.reason, "already-granted");
});

check("only an explicit true counts as granted", () => {
  // A missing flag on an old account must not be read as already paid.
  for (const value of [undefined, null, false, 0]) {
    assert.strictEqual(
        referralOutcome(user({referralRewardGranted: value}), ME).owed, true,
        `granted=${value}`);
  }
});

check("SELF-REFERRAL is refused even if hand-written into the document", () => {
  // setReferrer refuses this too, but a document edited in the console
  // must not be able to pay someone for inviting themselves.
  const r = referralOutcome(user({referredByUserId: ME}), ME);
  assert.strictEqual(r.owed, false);
  assert.strictEqual(r.reason, "self-referral");
});

check("a missing or malformed user degrades to owing nothing", () => {
  for (const u of [null, undefined, {}, "user"]) {
    assert.strictEqual(referralOutcome(u, ME).owed, false);
  }
});

check("non-numeric match counts do not accidentally activate", () => {
  const r = referralOutcome(
      user({rankedMatchesPlayed: "lots", exhibitionMatchesPlayed: null}), ME);
  assert.strictEqual(r.owed, false);
  assert.strictEqual(r.reason, "not-activated");
});

console.log(`\n${passed} checks passed.`);
