const assert = require("assert");
const {
  messageProblem, rateProblem, nextRate, RATE_MAX, RATE_WINDOW_MS, MAX_LEN,
} = require("../lobby");

let passed = 0;
function ok(cond, msg) {
  assert.ok(cond, msg);
  passed++;
}

// --- messageProblem ---
ok(messageProblem("") !== null, "empty message blocked");
ok(messageProblem("   ") !== null, "whitespace-only blocked");
ok(messageProblem("a".repeat(MAX_LEN + 1)) !== null, "over-length blocked");
ok(messageProblem("a".repeat(MAX_LEN)) === null, "at the length cap is fine");

// Edgy comedy is allowed - the whole point of this app.
ok(messageProblem("you absolute clown, that was dreadful") === null,
    "ordinary brutal insult passes");
ok(messageProblem("damn that was a savage roast") === null,
    "profanity passes (not hate)");
ok(messageProblem("let's gooo 🔥🔥") === null, "hype passes");

// Reuses the username hate/slur filter - a reserved staff/platform token is
// blocked (stands in for the moderation path being wired, without writing
// slurs into the test file; the username suite covers the slur detection).
ok(messageProblem("admin") !== null, "reserved token blocked (moderation wired)");

// --- rateProblem / nextRate ---
const now = 1_000_000;
ok(rateProblem(undefined, now) === null, "no record -> not rate-limited");
ok(rateProblem({windowStartMs: now, count: RATE_MAX - 1}, now) === null,
    "under the limit in-window is fine");
ok(rateProblem({windowStartMs: now, count: RATE_MAX}, now) !== null,
    "at the limit in-window is blocked");
ok(rateProblem({windowStartMs: now - RATE_WINDOW_MS - 1, count: RATE_MAX}, now)
    === null, "a full window later, the count no longer blocks");

const first = nextRate(undefined, now);
ok(first.count === 1 && first.windowStartMs === now, "first post starts a window");
const second = nextRate(first, now + 1000);
ok(second.count === 2 && second.windowStartMs === now,
    "a post inside the window increments and keeps the window start");
const rolled = nextRate({windowStartMs: now, count: RATE_MAX},
    now + RATE_WINDOW_MS + 1);
ok(rolled.count === 1 && rolled.windowStartMs === now + RATE_WINDOW_MS + 1,
    "a post after the window resets the window");

console.log(`lobby: ${passed} checks passed`);
