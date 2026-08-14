/**
 * Standing challenges: a queue entry that outlives the app being closed.
 *
 * The rules worth pinning are the ones that decide whether a player can be
 * left stranded - a challenge that never expires, or one released against
 * the wrong person, both remove a willing player from the pool silently.
 *
 * Run: node test/standingChallenge.test.js
 */
const assert = require("assert");
const {
  shouldBecomeStanding,
  isLive,
  acceptanceExpired,
  releaseOutcome,
  STANDING_AFTER_MS,
  STANDING_TTL_MS,
  ACCEPT_WINDOW_MS,
} = require("../standingChallenge");

let checks = 0;
function check(label, fn) {
  fn();
  checks += 1;
  console.log(`  ok  ${label}`);
}

const NOW = 1_800_000_000_000;
const STALE = 10 * 60 * 1000;
const waiting = (ageMs, canNotify = true) => ({
  status: "waiting", joinedAt: NOW - ageMs, canNotify,
});
const ts = (ms) => ({toMillis: () => ms});

// --- becoming standing ---

check("a short wait stays an ordinary wait", () => {
  assert.strictEqual(shouldBecomeStanding(waiting(1000), NOW), false);
});

check("a long enough wait becomes a standing challenge", () => {
  assert.strictEqual(shouldBecomeStanding(waiting(STANDING_AFTER_MS), NOW), true);
});

check("a player with no device NEVER becomes standing", () => {
  // Being pushed is the entire mechanism. Without a device the entry would
  // sit in the pool being paired against and never answered, costing every
  // player who matched it a five-minute wait for nothing - which is worse
  // than an empty pool, because the app feels broken rather than quiet.
  assert.strictEqual(
      shouldBecomeStanding(waiting(5 * 60 * 60 * 1000, false), NOW), false);
});

check("an already-standing entry is not re-transitioned", () => {
  assert.strictEqual(
      shouldBecomeStanding({status: "standing", joinedAt: 0, canNotify: true}, NOW),
      false);
});

check("a matched entry is never transitioned", () => {
  assert.strictEqual(
      shouldBecomeStanding({status: "matched", joinedAt: 0, canNotify: true}, NOW),
      false);
});

// --- staying in the pool ---

check("a fresh wait is live", () => {
  assert.strictEqual(isLive(waiting(1000), NOW, {staleMs: STALE}), true);
});

check("an abandoned wait is not live", () => {
  assert.strictEqual(isLive(waiting(STALE + 1), NOW, {staleMs: STALE}), false);
});

check("a standing challenge survives far past the stale threshold", () => {
  // The entire point: it has to outlive the app being closed.
  const standing = {status: "standing", joinedAt: NOW - 3 * 60 * 60 * 1000};
  assert.strictEqual(isLive(standing, NOW, {staleMs: STALE}), true);
});

check("a standing challenge does eventually expire", () => {
  // One left from days ago would pair someone against an opponent who has
  // long forgotten they queued.
  const ancient = {status: "standing", joinedAt: NOW - STANDING_TTL_MS - 1};
  assert.strictEqual(isLive(ancient, NOW, {staleMs: STALE}), false);
});

check("a matched entry is never pruned, however old", () => {
  // It is how a player who closed the app still finds their match.
  const matched = {status: "matched", joinedAt: NOW - 10 * STANDING_TTL_MS};
  assert.strictEqual(isLive(matched, NOW, {staleMs: STALE}), true);
});

check("an unknown status is not live", () => {
  assert.strictEqual(isLive({status: "weird", joinedAt: NOW}, NOW, {staleMs: STALE}), false);
  assert.strictEqual(isLive(null, NOW, {staleMs: STALE}), false);
});

// --- the acceptance window ---

const challenge = (createdAtMs, ready = []) => ({
  status: "pending", origin: "standing",
  createdAt: ts(createdAtMs), readyPlayerIds: ready,
  player1Id: "sleeper", player2Id: "shower", challengerId: "sleeper",
});

check("a fresh challenge has not expired", () => {
  assert.strictEqual(acceptanceExpired(challenge(NOW - 1000), NOW), false);
});

check("an unanswered challenge expires", () => {
  assert.strictEqual(
      acceptanceExpired(challenge(NOW - ACCEPT_WINDOW_MS - 1), NOW), true);
});

check("a challenge both players accepted never expires", () => {
  // They are in the match; expiring it would tear down a battle in progress.
  assert.strictEqual(
      acceptanceExpired(challenge(NOW - ACCEPT_WINDOW_MS - 1, ["a", "b"]), NOW),
      false);
});

check("a LIVE pairing is never subject to this window", () => {
  // Both players are already present and the bio reveal has its own much
  // shorter timer. Applying a five-minute release to a live match would
  // abandon battles that were about to start.
  const live = {...challenge(NOW - ACCEPT_WINDOW_MS - 1), origin: "live"};
  assert.strictEqual(acceptanceExpired(live, NOW), false);
});

check("a match that already started is never released", () => {
  const started = {...challenge(NOW - ACCEPT_WINDOW_MS - 1), status: "completed"};
  assert.strictEqual(acceptanceExpired(started, NOW), false);
});

check("a match with no creation time is left alone", () => {
  // Better to leave one odd document pending than to abandon matches on
  // the strength of a missing field.
  const undated = {...challenge(0), createdAt: null};
  assert.strictEqual(acceptanceExpired(undated, NOW), false);
});

// --- who gets what on release ---

check("the player who showed up is requeued, the absentee is not blamed", () => {
  // No forfeit: a forfeit is for accepting and then not turning up, which
  // is a promise broken rather than one never made.
  const r = releaseOutcome({
    player1Id: "sleeper", player2Id: "shower", challengerId: "sleeper",
  });
  assert.strictEqual(r.requeue, "shower");
  assert.strictEqual(r.noShow, "sleeper");
});

check("it works whichever side issued the challenge", () => {
  const r = releaseOutcome({
    player1Id: "shower", player2Id: "sleeper", challengerId: "sleeper",
  });
  assert.strictEqual(r.requeue, "shower");
  assert.strictEqual(r.noShow, "sleeper");
});

console.log(`\n${checks} checks passed.`);
