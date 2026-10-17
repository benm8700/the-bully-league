/**
 * Local tests for the phone-number normalizer (functions/phoneSignup.js).
 * Runs with plain `node test/phoneSignup.test.js`.
 *
 * The one property that actually matters here: the server normalizer MUST
 * produce the same E.164 string as the client normalizer in
 * lib/screens/auth/signup_screen.dart (`_normalizePhone`). The invite loop
 * pins a pending challenge to a number on one side and matches it on the
 * other - if the two disagree on, say, how a bare 10-digit US number becomes
 * +1..., the challenge is written under one key and looked up under another
 * and silently never attaches. These cases mirror the client's rules exactly,
 * so a future edit to one that isn't mirrored in the other fails here.
 */

const assert = require("assert");
const {normalizeE164} = require("../phoneSignup");

let passed = 0;
function check(label, got, want) {
  assert.strictEqual(got, want, `${label}: got ${got}, want ${want}`);
  passed++;
}

// Bare 10-digit US number -> +1 prepended (the common case).
check("10-digit US", normalizeE164("5551234567"), "+15551234567");
check("10-digit with punctuation", normalizeE164("(555) 123-4567"), "+15551234567");

// 11 digits starting with 1 -> treated as US with country code.
check("11-digit leading 1", normalizeE164("15551234567"), "+15551234567");
check("1-prefixed punctuation", normalizeE164("1 (555) 123-4567"), "+15551234567");

// Explicit + is trusted as typed (international).
check("explicit +1", normalizeE164("+15551234567"), "+15551234567");
check("explicit +44 UK", normalizeE164("+447911123456"), "+447911123456");
check("explicit + with spaces", normalizeE164("+44 7911 123456"), "+447911123456");

// Garbage / too short / too long -> null so the validator rejects it.
check("empty", normalizeE164(""), null);
check("too short", normalizeE164("12345"), null);
check("non-string", normalizeE164(null), null);
check("letters only", normalizeE164("nope"), null);
check("way too long", normalizeE164("+1234567890123456789"), null);
// Bare number that is neither 10 nor 1+10 digits: rejected, matching the
// client (which returns null here too) so the two never drift apart.
check("bare 9-digit no plus", normalizeE164("123456789"), null);

console.log(`\nphoneSignup normalizer: ${passed} checks passed.`);
