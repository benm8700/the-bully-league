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
  utcDayKey,
  TIER_WIDEN_INTERVAL_MS,
  REPEAT_OPPONENT_COOLDOWN_MS,
  STALE_ENTRY_MS,
  MAX_SKIPS_PER_DAY,
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
    canNotify: true,
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

test("an abandoned entry with no device is never paired against", () => {
  // Without a registered device there is nobody to push, so a long wait
  // cannot become a standing challenge - it stays an ordinary wait and is
  // pruned. Pairing against it would cost a live player five minutes
  // waiting on someone who can never be told they were matched.
  const q = queueOf(
      entry("a"),
      entry("b", {joinedAt: NOW - STALE_ENTRY_MS - 1, canNotify: false}),
  );
  assert.strictEqual(selectOpponent(q, "a", NOW), null);
});

test("a long wait becomes a standing challenge instead of being pruned", () => {
  // This used to assert the opposite: an entry older than the stale
  // threshold was dropped and its owner could not pair. That was the whole
  // problem standing challenges exist to fix - queue outside a busy hour,
  // find nobody, and leave with nothing. A wait that long is now a standing
  // challenge, which is exactly what should be pairable.
  const q = queueOf(entry("a", {joinedAt: NOW - STALE_ENTRY_MS - 1}), entry("b"));
  const picked = selectOpponent(q, "a", NOW);
  assert.ok(picked, "a long-waiting player should still be able to pair");
  assert.strictEqual(picked.uid, "b");
  assert.strictEqual(q["a"].status, "standing");
});

test("a standing challenge outlives the app being closed", () => {
  // The entire point: someone queueing hours later matches it instantly.
  const q = queueOf(
      entry("asleep", {joinedAt: NOW - 3 * 60 * 60 * 1000}),
      entry("fresh"),
  );
  const picked = selectOpponent(q, "fresh", NOW);
  assert.ok(picked);
  assert.strictEqual(picked.uid, "asleep");
});

test("a standing challenge is eventually forgotten", () => {
  // A challenge left days ago would pair someone against an opponent who
  // has long since forgotten they queued.
  const q = queueOf(
      entry("ancient", {joinedAt: NOW - 7 * 60 * 60 * 1000}),
      entry("fresh"),
  );
  assert.strictEqual(selectOpponent(q, "fresh", NOW), null);
});

test("a live opponent is always preferred over a standing one", () => {
  // A live player can battle in the next thirty seconds; a standing one
  // has to be woken by a push and may never answer. Pairing against a
  // sleeper while someone live sits in the same queue would make the app
  // feel slowest exactly when it is busiest.
  const q = queueOf(
      entry("me"),
      entry("standing", {joinedAt: NOW - 60 * 60 * 1000, rating: 1200}),
      entry("live", {joinedAt: NOW - 1000, rating: 1400}),
  );
  const picked = selectOpponent(q, "me", NOW);
  // Picked despite being much further away in rating.
  assert.strictEqual(picked.uid, "live");
});

test("an unwakeable player never becomes a standing challenge", () => {
  // However long they wait. Being pushed is the entire mechanism, so an
  // entry that cannot be pushed has nothing to offer the pool.
  const q = queueOf(
      entry("nodevice", {joinedAt: NOW - 5 * 60 * 60 * 1000, canNotify: false}),
      entry("me"),
  );
  assert.strictEqual(selectOpponent(q, "me", NOW), null);
});

test("a standing challenge survives being taken up and released", () => {
  // Releasing an unanswered challenge returns it to the pool rather than
  // deleting it, so a player who was briefly away is not punished for one
  // missed push.
  const q = queueOf(entry("a", {joinedAt: NOW - 2 * 60 * 1000}), entry("b"));
  const first = selectOpponent(q, "b", NOW);
  assert.strictEqual(first.uid, "a");
  // Simulate release: status goes back to standing rather than vanishing.
  q["a"] = {...q["a"], status: "standing"};
  const second = selectOpponent(q, "b", NOW + 1000);
  assert.strictEqual(second.uid, "a");
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

// --- Daily skip allowance -------------------------------------------------

/** Mirrors skipMatch's counter read. The interesting case is the day
 * rollover: a stale skipsResetDate must reset the count rather than
 * carrying yesterday's usage forward. */
function skipsRemaining(user, today) {
  const used = user.skipsResetDate === today ? (user.skipsUsedToday ?? 0) : 0;
  return Math.max(0, MAX_SKIPS_PER_DAY - used);
}

test("the skip allowance stays within CLAUDE.md's stated 2-3 per day", () => {
  assert.ok(
      MAX_SKIPS_PER_DAY >= 2 && MAX_SKIPS_PER_DAY <= 3,
      `MAX_SKIPS_PER_DAY is ${MAX_SKIPS_PER_DAY}, outside the decided 2-3 range`,
  );
});

test("a fresh account has its full skip allowance", () => {
  assert.strictEqual(skipsRemaining({}, "2026-08-13"), MAX_SKIPS_PER_DAY);
});

test("skips used today count against the allowance", () => {
  const user = {skipsUsedToday: 1, skipsResetDate: "2026-08-13"};
  assert.strictEqual(skipsRemaining(user, "2026-08-13"), MAX_SKIPS_PER_DAY - 1);
});

test("yesterday's skips don't carry over", () => {
  const user = {skipsUsedToday: MAX_SKIPS_PER_DAY, skipsResetDate: "2026-08-12"};
  assert.strictEqual(skipsRemaining(user, "2026-08-13"), MAX_SKIPS_PER_DAY);
});

test("an exhausted allowance reports zero, never negative", () => {
  const user = {skipsUsedToday: MAX_SKIPS_PER_DAY + 5, skipsResetDate: "2026-08-13"};
  assert.strictEqual(skipsRemaining(user, "2026-08-13"), 0);
});

test("utcDayKey is a stable YYYY-MM-DD that rolls at UTC midnight", () => {
  assert.strictEqual(utcDayKey(Date.UTC(2026, 7, 13, 23, 59, 59)), "2026-08-13");
  assert.strictEqual(utcDayKey(Date.UTC(2026, 7, 14, 0, 0, 1)), "2026-08-14");
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

// --- Judging priority in the pairing tiebreak ----------------------------

test("an active judge is paired ahead of an equal candidate", () => {
  // Both identical in tier and rating, both waiting the same length of
  // time. The only difference is that one of them judged today.
  const q = queueOf(
      entry("me"),
      entry("idle", {joinedAt: NOW - 1000}),
      entry("judge", {joinedAt: NOW - 1000, judgePriorityMs: 60000}),
  );
  assert.strictEqual(selectOpponent(q, "me", NOW).uid, "judge");
});

test("PRIORITY NEVER BEATS A CLOSER RATING - it is the LAST term", () => {
  // The whole point of the ladder is skill-appropriate pairing. A
  // reward that degraded match quality would be a punishment dressed as
  // a perk, for both players.
  const q = queueOf(
      entry("me", {rating: 1200}),
      entry("close", {rating: 1205, joinedAt: NOW}),
      entry("judge", {rating: 1400, joinedAt: NOW, judgePriorityMs: 120000}),
  );
  assert.strictEqual(selectOpponent(q, "me", NOW).uid, "close");
});

test("priority never beats a LIVE opponent for a standing challenge", () => {
  // A live player can battle in thirty seconds; a standing one has to be
  // woken by a push and may never answer. That ordering must survive.
  const q = queueOf(
      entry("me"),
      entry("live", {joinedAt: NOW}),
      entry("sleeper", {status: "standing", joinedAt: NOW - 9999999,
        judgePriorityMs: 120000}),
  );
  assert.strictEqual(selectOpponent(q, "me", NOW).uid, "live");
});

test("A LONG-WAITING NON-JUDGE STILL WINS - nobody is starved", () => {
  // 70 seconds, chosen deliberately: still a LIVE entry (past 90 it
  // becomes a standing challenge and is sorted behind every live waiter
  // anyway, which would make this test pass for the wrong reason), and
  // longer than the maximum bonus can ever be.
  const q = queueOf(
      entry("me"),
      entry("patient", {joinedAt: NOW - 70 * 1000}),
      entry("judge", {joinedAt: NOW, judgePriorityMs: 45 * 1000}),
  );
  assert.strictEqual(selectOpponent(q, "me", NOW).uid, "patient");
});

test("a forged priority cannot exceed the bound", () => {
  // Queue entries are written only by the server, but the value is
  // stored data and clamping it costs nothing. Without the clamp a
  // single bad number would outrank every real player forever.
  const q = queueOf(
      entry("me"),
      entry("patient", {joinedAt: NOW - 70 * 1000}),
      entry("cheat", {joinedAt: NOW, judgePriorityMs: Number.MAX_SAFE_INTEGER}),
  );
  assert.strictEqual(selectOpponent(q, "me", NOW).uid, "patient");
});

test("an entry with no priority field pairs exactly as before", () => {
  // Every queue entry written before this existed.
  const q = queueOf(entry("me"), entry("old", {joinedAt: NOW - 5000}),
      entry("newer", {joinedAt: NOW}));
  assert.strictEqual(selectOpponent(q, "me", NOW).uid, "old");
});

console.log(`matchmaking: ${passed} checks passed`);
