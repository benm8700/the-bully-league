/**
 * Local simulation of the matchmaking pairing rules (functions/
 * matchmaking.js). Runs with plain `node test/matchmaking.test.js` - no
 * emulator, no network, no Firebase credentials, because selectOpponent /
 * applyPairing are pure and take the queue as a plain object.
 *
 * This exists for the same reason the tournament bracket simulation did:
 * the bye-handling bug CLAUDE.md documents was found by a local trial
 * sweep before it ever reached a device, and pairing has the same shape -
 * a handful of interacting rules (two-way blocking, cooldown-as-
 * preference, time-widening tier bands, stale pruning) where the failure
 * is silent and only shows up for particular queue compositions.
 *
 * The concurrency section models what an RTDB transaction on the queue
 * node actually guarantees: the callback may re-run against updated data,
 * and only one writer commits at a time. The property that matters is
 * that no player is ever paired into two different matches at once.
 */

const assert = require("assert");
const {
  selectOpponent,
  applyPairing,
  isOnCooldown,
  TIER_WIDEN_INTERVAL_MS,
  REPEAT_OPPONENT_COOLDOWN_MS,
  STALE_ENTRY_MS,
} = require("../matchmaking");

const NOW = 1_700_000_000_000;

function entry(uid, overrides = {}) {
  return {
    uid,
    username: uid,
    rating: 1200,
    tierIndex: 4,
    blockedUserIds: [],
    recentOpponentIds: {},
    joinedAt: NOW,
    status: "waiting",
    ...overrides,
  };
}

function queueOf(...entries) {
  return Object.fromEntries(entries.map((e) => [e.uid, e]));
}

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

// --- Tier proximity and time-based widening -------------------------------

test("same tier pairs immediately", () => {
  const q = queueOf(entry("a"), entry("b"));
  assert.strictEqual(selectOpponent(q, "a", NOW).uid, "b");
});

test("a one-tier gap is refused at band 0", () => {
  const q = queueOf(entry("a", {tierIndex: 4}), entry("b", {tierIndex: 5}));
  assert.strictEqual(selectOpponent(q, "a", NOW), null);
});

test("a one-tier gap is accepted after one widen interval", () => {
  const q = queueOf(entry("a", {tierIndex: 4}), entry("b", {tierIndex: 5}));
  const later = NOW + TIER_WIDEN_INTERVAL_MS;
  assert.strictEqual(selectOpponent(q, "a", later).uid, "b");
});

test("widening keeps expanding until even the widest gap matches", () => {
  const q = queueOf(entry("a", {tierIndex: 0}), entry("b", {tierIndex: 9}));
  assert.strictEqual(selectOpponent(q, "a", NOW), null, "should not match at band 0");
  const eventually = NOW + 9 * TIER_WIDEN_INTERVAL_MS;
  assert.strictEqual(
      selectOpponent(q, "a", eventually).uid,
      "b",
      "nobody should be able to wait forever",
  );
});

// --- Blocking -------------------------------------------------------------

test("blocking is honoured in the blocker's direction", () => {
  const q = queueOf(entry("a", {blockedUserIds: ["b"]}), entry("b"));
  assert.strictEqual(selectOpponent(q, "a", NOW), null);
});

test("blocking is honoured in the blocked party's direction too", () => {
  // b blocked a; a must not be served b either, or the block is useless.
  const q = queueOf(entry("a"), entry("b", {blockedUserIds: ["a"]}));
  assert.strictEqual(selectOpponent(q, "a", NOW), null);
});

test("a block never leaks past widening", () => {
  const q = queueOf(entry("a", {blockedUserIds: ["b"]}), entry("b", {tierIndex: 9}));
  const muchLater = NOW + 50 * TIER_WIDEN_INTERVAL_MS;
  assert.strictEqual(selectOpponent(q, "a", muchLater), null);
});

// --- Repeat-opponent cooldown --------------------------------------------

test("a recent opponent is skipped when someone else is available", () => {
  const q = queueOf(
      entry("a", {recentOpponentIds: {b: NOW - 1000}}),
      entry("b"),
      entry("c"),
  );
  assert.strictEqual(selectOpponent(q, "a", NOW).uid, "c");
});

test("a recent opponent IS used when they're the only option", () => {
  // CLAUDE.md: availability takes priority over the cooldown when the
  // pool is small - the cooldown is a preference, not a hard filter.
  const q = queueOf(entry("a", {recentOpponentIds: {b: NOW - 1000}}), entry("b"));
  assert.strictEqual(selectOpponent(q, "a", NOW).uid, "b");
});

test("the cooldown expires after its window", () => {
  const old = NOW - REPEAT_OPPONENT_COOLDOWN_MS - 1;
  assert.strictEqual(isOnCooldown(entry("a", {recentOpponentIds: {b: old}}), entry("b"), NOW), false);
});

test("the cooldown applies from either side's record", () => {
  const a = entry("a");
  const b = entry("b", {recentOpponentIds: {a: NOW - 1000}});
  assert.strictEqual(isOnCooldown(a, b, NOW), true);
});

test("the legacy plain-array recentOpponentIds shape is treated as on cooldown", () => {
  // CLAUDE.md's schema documents this field as "[array with timestamps]";
  // nothing wrote it before completeMatch, so tolerate both shapes rather
  // than throwing on an old document.
  const a = entry("a", {recentOpponentIds: ["b"]});
  assert.strictEqual(isOnCooldown(a, entry("b"), NOW), true);
});

// --- Stale entries --------------------------------------------------------

test("an abandoned entry is never paired against", () => {
  const q = queueOf(entry("a"), entry("b", {joinedAt: NOW - STALE_ENTRY_MS - 1}));
  assert.strictEqual(selectOpponent(q, "a", NOW), null);
});

test("our own stale entry stops us pairing", () => {
  const q = queueOf(entry("a", {joinedAt: NOW - STALE_ENTRY_MS - 1}), entry("b"));
  assert.strictEqual(selectOpponent(q, "a", NOW), null);
});

// --- Selection quality ----------------------------------------------------

test("the closest-rated candidate wins", () => {
  const q = queueOf(
      entry("a", {rating: 1200}),
      entry("far", {rating: 1400}),
      entry("near", {rating: 1210}),
  );
  assert.strictEqual(selectOpponent(q, "a", NOW).uid, "near");
});

test("equal ratings break toward whoever waited longest", () => {
  const q = queueOf(
      entry("a"),
      entry("recent", {joinedAt: NOW - 1000}),
      entry("patient", {joinedAt: NOW - 60_000}),
  );
  assert.strictEqual(selectOpponent(q, "a", NOW).uid, "patient");
});

test("an already-matched player is not re-paired", () => {
  const q = queueOf(entry("a"), entry("b", {status: "matched"}));
  assert.strictEqual(selectOpponent(q, "a", NOW), null);
});

test("a player already matched cannot pair again themselves", () => {
  const q = queueOf(entry("a", {status: "matched"}), entry("b"));
  assert.strictEqual(selectOpponent(q, "a", NOW), null);
});

// --- Account status gating ------------------------------------------------

/**
 * Mirrors enterQueue's gate. Kept as a tiny local helper rather than
 * exporting the whole callable, which needs Firestore.
 *
 * Regression: an ABSENT accountStatus must count as active. Accounts
 * created before Build Order step 9 introduced the field have no value,
 * and an earlier version of this check used `!== "active"`, which locked
 * every legacy account out of matchmaking. Caught live on two real
 * pre-step-9 test accounts.
 */
function isQueueEligible(user) {
  return (user.accountStatus ?? "active") === "active";
}

test("an account with no accountStatus field can still queue", () => {
  assert.strictEqual(isQueueEligible({}), true);
  assert.strictEqual(isQueueEligible({accountStatus: undefined}), true);
});

test("an explicitly banned or flagged account cannot queue", () => {
  assert.strictEqual(isQueueEligible({accountStatus: "banned"}), false);
  assert.strictEqual(isQueueEligible({accountStatus: "flagged"}), false);
});

test("an explicitly active account can queue", () => {
  assert.strictEqual(isQueueEligible({accountStatus: "active"}), true);
});

// --- Concurrency: the property that actually matters ----------------------

/**
 * Models an RTDB transaction on the queue node: attempts are serialised,
 * and each one re-reads current state before deciding. Two clients polling
 * at the same instant must not both claim the same opponent.
 */
function simulateConcurrentPolls(queue, pollOrder) {
  let matchSeq = 0;
  for (const uid of pollOrder) {
    const opponent = selectOpponent(queue, uid, NOW);
    if (!opponent) continue;
    const matchId = `m${matchSeq++}`;
    applyPairing(queue, uid, opponent.uid, matchId, `match_${matchId}`);
  }
  return queue;
}

function assertQueueConsistent(queue, label) {
  const byMatch = new Map();
  for (const e of Object.values(queue)) {
    if (e.status !== "matched") continue;
    assert.ok(e.matchId, `${label}: matched entry ${e.uid} has no matchId`);
    assert.ok(e.opponentId, `${label}: matched entry ${e.uid} has no opponentId`);
    // The opponent must agree that they're paired with us, in the same match.
    const opp = queue[e.opponentId];
    assert.ok(opp, `${label}: ${e.uid} paired with absent player ${e.opponentId}`);
    assert.strictEqual(opp.opponentId, e.uid, `${label}: pairing is not mutual for ${e.uid}`);
    assert.strictEqual(opp.matchId, e.matchId, `${label}: ${e.uid} and ${opp.uid} disagree on matchId`);
    byMatch.set(e.matchId, (byMatch.get(e.matchId) ?? 0) + 1);
  }
  for (const [matchId, count] of byMatch) {
    assert.strictEqual(count, 2, `${label}: match ${matchId} has ${count} players, expected exactly 2`);
  }
}

test("no player is ever double-booked, across randomised queues", () => {
  // Deterministic PRNG so a failure is reproducible from the seed alone.
  let seed = 12345;
  const rand = () => (seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648;

  for (let trial = 0; trial < 2000; trial++) {
    const size = 2 + Math.floor(rand() * 9); // 2..10 players
    const ids = Array.from({length: size}, (_, i) => `p${i}`);
    const entries = ids.map((id) =>
      entry(id, {
        rating: 1000 + Math.floor(rand() * 800),
        tierIndex: Math.floor(rand() * 10),
        joinedAt: NOW - Math.floor(rand() * 5 * TIER_WIDEN_INTERVAL_MS),
        blockedUserIds: rand() < 0.15 ? [ids[Math.floor(rand() * size)]] : [],
        recentOpponentIds: rand() < 0.2 ?
          {[ids[Math.floor(rand() * size)]]: NOW - Math.floor(rand() * 1000)} :
          {},
      }),
    );
    const q = queueOf(...entries);

    // Poll in a shuffled order, several rounds, as real clients would.
    const order = [];
    for (let round = 0; round < 3; round++) {
      const shuffled = [...ids].sort(() => rand() - 0.5);
      order.push(...shuffled);
    }
    simulateConcurrentPolls(q, order);
    assertQueueConsistent(q, `trial ${trial} (size ${size})`);
  }
});

test("two players polling simultaneously produce one match, not two", () => {
  const q = queueOf(entry("a"), entry("b"));
  simulateConcurrentPolls(q, ["a", "b", "a", "b"]);
  assertQueueConsistent(q, "two-player race");
  assert.strictEqual(q.a.matchId, q.b.matchId, "both players must land in the SAME match");
});

test("an odd player out stays queued rather than being dropped", () => {
  const q = queueOf(entry("a"), entry("b"), entry("c"));
  simulateConcurrentPolls(q, ["a", "b", "c"]);
  const waiting = Object.values(q).filter((e) => e.status === "waiting");
  assert.strictEqual(waiting.length, 1, "exactly one player should be left waiting");
  assertQueueConsistent(q, "odd player out");
});

console.log(`matchmaking: ${passed} checks passed`);
