/**
 * Local tests for the username filter, shape rules and change cooldown
 * (functions/username.js). Runs with plain `node test/username.test.js`.
 *
 * A filter like this has two failure modes and they pull in opposite
 * directions. Too permissive puts a slur on the public leaderboard and on
 * the website, in front of people who never agreed to this app's content
 * policy. Too strict tells someone their own name or their own country is
 * unacceptable - the Scunthorpe problem, which is not hypothetical here
 * because "Nigeria" contains a substring of a slur once you start
 * collapsing repeated letters to evade padding.
 *
 * So roughly half of these tests assert that ORDINARY NAMES PASS. Those
 * are the ones worth keeping when the word lists are next edited.
 */

const assert = require("assert");
const {
  normalizeForMatch,
  tokensOf,
  shapeProblem,
  contentProblem,
  usernameProblem,
  usernameKey,
  cooldownUntilMs,
  waitPhrase,
  DEFAULT_COOLDOWN_DAYS,
} = require("../username");

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

const ok = (n) => assert.strictEqual(usernameProblem(n), null,
    `expected "${n}" to be allowed, got: ${usernameProblem(n)}`);
const bad = (n) => assert.ok(usernameProblem(n) !== null,
    `expected "${n}" to be refused`);

// --- Shape ----------------------------------------------------------------

test("length bounds are enforced at both ends", () => {
  bad("ab");
  ok("abc");
  ok("a".repeat(20));
  bad("a".repeat(21));
});

test("only letters, numbers and . _ - are accepted", () => {
  ok("Ben_Malslamrod");
  ok("roast.king");
  ok("x-ray-99");
  bad("hey there");
  bad("emoji\u{1F525}fan");
  bad("semi;colon");
});

test("a name must start and end with a letter or number", () => {
  bad("_lurker");
  bad("lurker.");
  ok("lurker1");
});

test("punctuation cannot run together", () => {
  bad("no__way");
  bad("no.-way");
  ok("no_way");
});

test("a name of only digits is refused", () => {
  bad("12345");
  ok("g0at");
});

test("leading or trailing whitespace is a shape error, not silently trimmed", () => {
  // The callables trim before calling in, so this only fires if someone
  // routes around them - but a name stored with a leading space sorts
  // strangely on every leaderboard forever.
  assert.ok(shapeProblem(" ben") !== null);
});

// --- Normalisation --------------------------------------------------------

test("confusable characters are mapped before matching", () => {
  assert.strictEqual(normalizeForMatch("N1GG3R"), normalizeForMatch("nigger"));
  assert.strictEqual(normalizeForMatch("f@ggot"), normalizeForMatch("faggot"));
  assert.strictEqual(normalizeForMatch("a.d.m.i.n"), "admin");
});

test("padded repeats collapse to two, NOT to one", () => {
  // Collapsing to one is the obvious implementation and it is wrong: it
  // turns "Nigeria" into a string containing a slur. Collapsing to two
  // still defeats padding.
  assert.strictEqual(normalizeForMatch("niiiiice"), "niice");
  assert.strictEqual(normalizeForMatch("Nigeria"), "nigeria");
  assert.ok(!normalizeForMatch("Nigeria").includes("niger" + "r"));
});

test("tokens split on separators, digits and capitalisation", () => {
  assert.deepStrictEqual(tokensOf("Ben_Admin"), ["ben", "admin"]);
  assert.deepStrictEqual(tokensOf("BenAdmin"), ["ben", "admin"]);
  assert.deepStrictEqual(tokensOf("ben99"), ["ben", "99"]);
});

// --- Hate terms -----------------------------------------------------------

test("slurs are refused, including obfuscated spellings", () => {
  bad("n1gger");
  bad("BigF4ggot");
  bad("xX_tranny_Xx".replace(/_/g, ""));
  bad("heilhitler");
  bad("KKK88");
  bad("retardking");
});

test("the refusal never names the term that matched", () => {
  // Quoting it back is a free lesson in what to change next.
  const reason = usernameProblem("n1gger");
  assert.ok(!/nig/i.test(reason), `leaked the term: ${reason}`);
});

test("short slurs are refused as whole words", () => {
  bad("Spic");
  bad("big_coon");
  bad("PakiHater");
});

// --- The false positives that matter --------------------------------------

test("ordinary names containing an unlucky substring still pass", () => {
  ok("Nigeria");
  ok("Despicable");
  ok("Raccoon");
  ok("Badminton");
  ok("Cockburn");
  ok("Dickinson");
  ok("Scunthorpe");
  ok("Analysis");
  ok("Assassin");
  ok("Shitake");
});

test("profanity is NOT filtered - only hate is", () => {
  // The app's whole content policy is that offensive comedy is allowed.
  // A filter that rejects "DamnGood" is enforcing a rule this product
  // does not have.
  ok("DamnGood");
  ok("HellRaiser");
  ok("BadassBen");
  ok("crapshoot");
});

// --- Impersonation --------------------------------------------------------

test("platform and staff names are reserved", () => {
  bad("Admin");
  bad("TheBullyLeague");
  bad("Support_Team");
  bad("ben.official");
  bad("a.d.m.i.n");
});

test("but a name that merely contains a reserved word is fine", () => {
  ok("Badminton");
  ok("Modest");
  ok("Systemic");
});

// --- Uniqueness key -------------------------------------------------------

test("the uniqueness key is case-insensitive", () => {
  assert.strictEqual(usernameKey("TheGoat"), usernameKey("thegoat"));
  assert.strictEqual(usernameKey("  TheGoat  "), "thegoat");
});

test("the key does NOT strip punctuation", () => {
  // "ben_ross" and "benross" are different names, and treating them as
  // one would refuse a legitimate signup with a confusing message.
  assert.notStrictEqual(usernameKey("ben_ross"), usernameKey("benross"));
});

// --- Cooldown -------------------------------------------------------------

const DAY = 24 * 60 * 60 * 1000;

test("an account that has never changed its name has no cooldown", () => {
  assert.strictEqual(cooldownUntilMs({}, DEFAULT_COOLDOWN_DAYS), null);
  assert.strictEqual(
      cooldownUntilMs({username: "ben"}, DEFAULT_COOLDOWN_DAYS), null,
      "having a name is not the same as having changed it");
});

test("the cooldown runs from the last change", () => {
  const changedAt = 1_000_000_000_000;
  const until = cooldownUntilMs({usernameChangedAt: changedAt}, 30);
  assert.strictEqual(until, changedAt + 30 * DAY);
});

test("a Firestore Timestamp is read as readily as epoch millis", () => {
  const changedAt = 1_000_000_000_000;
  const ts = {toMillis: () => changedAt};
  assert.strictEqual(
      cooldownUntilMs({usernameChangedAt: ts}, 30),
      cooldownUntilMs({usernameChangedAt: changedAt}, 30));
});

test("a zero-day cooldown never locks anyone out", () => {
  const now = 1_000_000_000_000;
  const until = cooldownUntilMs({usernameChangedAt: now}, 0);
  assert.ok(!(now < until), "a 0-day cooldown must already have elapsed");
});

test("the wait is phrased as a wait, not a date", () => {
  const now = 1_000_000_000_000;
  assert.strictEqual(waitPhrase(now + 12 * DAY, now), "in 12 days");
  assert.strictEqual(waitPhrase(now + 1000, now), "tomorrow");
});

// --- Config-supplied extras ----------------------------------------------

test("extra blocked terms from config are honoured and normalised too", () => {
  assert.strictEqual(contentProblem("SlopKing", []), null);
  assert.ok(contentProblem("SlopKing", ["slop"]) !== null);
  assert.ok(contentProblem("Sl0pKing", ["slop"]) !== null,
      "a config term must be matched through confusables like any other");
});

console.log(`username: ${passed} checks passed`);
