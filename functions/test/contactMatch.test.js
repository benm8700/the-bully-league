/**
 * Private phone numbers + contact matching (2026-11-19).
 * Plain `node test/contactMatch.test.js`.
 */
const assert = require("node:assert/strict");
const {phoneHash, cleanHashes, rateCheck, visibleMatch,
  MAX_HASHES_PER_CALL, MAX_CALLS_PER_DAY, MAX_HASHES_PER_DAY} =
  require("../contactMatch");

let n = 0;
function check(name, fn) {
  fn();
  n++;
  console.log(`ok - ${name}`);
}

check("hash = sha256 hex of the E.164 string (same value the app computes)", () => {
  assert.equal(phoneHash("+16505551235"),
      "9c416fef0b6f2137a2c8cd341f839e36ee4e3fa2bca0b553c68fbe56e0b8f69c");
});

check("junk, dupes and over-cap hashes are dropped", () => {
  const h = phoneHash("+15555550100");
  assert.deepEqual(cleanHashes([h, h, "nope", 5, null, h.toUpperCase()]), [h]);
  assert.deepEqual(cleanHashes("x"), []);
  const many = Array.from({length: 600}, (_, i) => phoneHash(`+1555${i}`));
  assert.equal(cleanHashes(many).length, MAX_HASHES_PER_CALL);
});

check("daily rate limit on calls and on hashes, resets next day", () => {
  let st = null;
  for (let i = 0; i < MAX_CALLS_PER_DAY; i++) {
    const r = rateCheck(st, 1, "2026-11-19");
    assert.ok(r.ok);
    st = r.next;
  }
  assert.equal(rateCheck(st, 1, "2026-11-19").ok, false);
  assert.ok(rateCheck(st, 1, "2026-11-20").ok);
  assert.equal(rateCheck(null, MAX_HASHES_PER_DAY + 1, "d").ok, false);
});

check("who can be found", () => {
  const me = "me";
  assert.equal(visibleMatch(me, {}, me, {}), false, "never yourself");
  assert.ok(visibleMatch(me, {}, "a", {accountStatus: "active"}));
  assert.ok(visibleMatch(me, {}, "a", {}), "missing status = active");
  assert.equal(visibleMatch(me, {}, "a", {contactDiscoverable: false}), false);
  assert.equal(visibleMatch(me, {}, "a", {accountStatus: "banned"}), false);
  assert.equal(visibleMatch(me, {}, "a", {blockedUserIds: [me]}), false);
  assert.equal(visibleMatch(me, {blockedUserIds: ["a"]}, "a", {}), false);
  assert.equal(visibleMatch(me, {}, "a", null), false);
});

console.log(`contactMatch: ${n} checks passed`);
