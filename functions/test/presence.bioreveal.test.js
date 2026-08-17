const assert = require("assert");
const {opponentUnresponsive, PRESENCE_STALE_MS} = require("../matchmaking");
const {LIMITS} = require("../matchSettings");

let passed = 0;
function check(name, fn) {
  fn();
  passed++;
  console.log(`  ok - ${name}`);
}

const NOW = 1_700_000_000_000;
const ME = "me";
const THEM = "them";

const matchOf = (extra = {}) => ({
  player1Id: ME,
  player2Id: THEM,
  status: "pending",
  readyPlayerIds: [ME],
  createdAt: {toMillis: () => NOW - 10 * 1000},
  lastSeenAt: {[ME]: NOW, [THEM]: NOW},
  ...extra,
});

const gone = (match, uid = ME) =>
  opponentUnresponsive({match, uid, nowMs: NOW});

console.log("bio reveal - unresponsive opponent");

check("an opponent heartbeating right now is present", () => {
  assert.strictEqual(gone(matchOf()), false);
});

check("an opponent silent past the threshold is gone", () => {
  const stale = matchOf({
    lastSeenAt: {[ME]: NOW, [THEM]: NOW - PRESENCE_STALE_MS - 1},
  });
  assert.strictEqual(gone(stale), true);
});

check("one missed heartbeat is not enough to eject someone", () => {
  // The threshold must comfortably exceed the client's interval, or a
  // single dropped call on a bad connection throws out a real player.
  const blip = matchOf({
    lastSeenAt: {[ME]: NOW, [THEM]: NOW - 30 * 1000},
  });
  assert.strictEqual(gone(blip), false);
});

check("THE POINT: someone still reading is NOT unresponsive", () => {
  // This is why the rule is presence-based rather than readiness-based.
  // With a 10-minute reveal a player may legitimately sit thinking about
  // their material for minutes without tapping Ready - ejecting them
  // would silently collapse the window back to seconds for anyone whose
  // opponent taps Ready quickly.
  const thinking = matchOf({
    readyPlayerIds: [ME],
    lastSeenAt: {[ME]: NOW, [THEM]: NOW - 5 * 1000},
  });
  assert.strictEqual(gone(thinking), false);
});

check("an opponent who is already READY is never released on", () => {
  // Past that point the match is starting regardless, so bailing would
  // just be a free skip.
  const ready = matchOf({
    readyPlayerIds: [ME, THEM],
    lastSeenAt: {[ME]: NOW, [THEM]: NOW - 10 * PRESENCE_STALE_MS},
  });
  assert.strictEqual(gone(ready), false);
});

check("FALLBACK: no heartbeat at all falls back to the pairing time", () => {
  // Someone who never opened the screen sends nothing, so there is no
  // lastSeenAt to age. Without this the one case the feature exists for
  // would be the one it could not handle.
  const never = matchOf({
    lastSeenAt: {[ME]: NOW},
    createdAt: {toMillis: () => NOW - PRESENCE_STALE_MS - 1},
  });
  assert.strictEqual(gone(never), true);
});

check("REGRESSION: createdAt is a Timestamp, and must be converted", () => {
  // Read as a plain number this is NaN, which falls through to 0 and
  // silently disables the fallback entirely - so a player who never sent
  // a heartbeat could never be released.
  const never = matchOf({
    lastSeenAt: {},
    createdAt: {toMillis: () => NOW - PRESENCE_STALE_MS - 1},
  });
  assert.strictEqual(gone(never), true, "Timestamp fallback must work");
});

check("a freshly paired match with no heartbeats yet is not abandoned", () => {
  const fresh = matchOf({lastSeenAt: {}, createdAt: {toMillis: () => NOW - 2000}});
  assert.strictEqual(gone(fresh), false);
});

check("a match that is no longer pending can't be released", () => {
  const done = matchOf({
    status: "completed",
    lastSeenAt: {[ME]: NOW, [THEM]: NOW - 10 * PRESENCE_STALE_MS},
  });
  assert.strictEqual(gone(done), false);
});

check("a non-participant never sees an unresponsive opponent", () => {
  const stale = matchOf({
    lastSeenAt: {[ME]: NOW, [THEM]: NOW - 10 * PRESENCE_STALE_MS},
  });
  assert.strictEqual(gone(stale, "stranger"), false);
});

check("the rule is symmetric - either player can be the one left waiting", () => {
  const stale = matchOf({
    readyPlayerIds: [THEM],
    lastSeenAt: {[THEM]: NOW, [ME]: NOW - PRESENCE_STALE_MS - 1},
  });
  assert.strictEqual(gone(stale, THEM), true);
});

check("the bio reveal ceiling now allows the chosen 10 minutes", () => {
  assert.ok(LIMITS.bioRevealSeconds.max >= 600,
      `ceiling is ${LIMITS.bioRevealSeconds.max}s - 600 would fall back to the default`);
});

console.log(`\n${passed} checks passed.`);
