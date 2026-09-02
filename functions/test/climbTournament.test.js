/**
 * Pure tests for the nightly "climb" tournament (functions/climbTournament.js).
 * No emulator, no credentials:  node test/climbTournament.test.js
 *
 * The simulation is the point - the same approach that caught the bracket bye
 * collision before a device saw it. It plays whole climb tournaments with
 * players joining at staggered times and random outcomes, and asserts the
 * invariants that make the format correct: single elimination always resolves
 * to exactly ONE champion in exactly N-1 matches, nobody skips a tier, an
 * eliminated player is never paired again, and a latecomer can never leapfrog.
 */
const assert = require("assert");
const {
  planPairings,
  applyResult,
  applyTie,
  markInMatch,
  resolveChampion,
  standingFor,
  climbForfeitDecision,
  STATUS,
} = require("../climbTournament");

let passed = 0;
function check(name, cond, detail) {
  if (!cond) {
    console.error("FAIL:", name, detail !== undefined ? `(${detail})` : "");
    process.exitCode = 1;
    throw new assert.AssertionError({message: name});
  }
  passed++;
}

function climber(uid, wins, status, joinedMs) {
  return {uid, wins, status: status || STATUS.waiting, joinedMs: joinedMs || 0};
}

// --- Unit tests -----------------------------------------------------------

// Same-win-count pairing only, no cross-tier without forceResolve.
{
  const cs = [
    climber("a", 0, STATUS.waiting, 1),
    climber("b", 0, STATUS.waiting, 2),
    climber("c", 1, STATUS.waiting, 3),
  ];
  const pairs = planPairings(cs, {forceResolve: false});
  check("pairs the two 0-win climbers together", pairs.length === 1);
  check("a and b are paired", pairs[0].includes("a") && pairs[0].includes("b"));
  check("the lone 1-win climber is NOT cross-paired",
      !pairs.flat().includes("c"));
}

// Longest-waiting is paired first within a bucket.
{
  const cs = [
    climber("late", 0, STATUS.waiting, 100),
    climber("early", 0, STATUS.waiting, 1),
    climber("mid", 0, STATUS.waiting, 50),
  ];
  const pairs = planPairings(cs, {forceResolve: false});
  check("earliest two are paired, latest waits",
      pairs.length === 1 &&
      pairs[0].includes("early") && pairs[0].includes("mid") &&
      !pairs[0].includes("late"));
}

// forceResolve funnels leftover waiters top-down (the "last two fight" rule).
{
  const cs = [
    climber("hi", 2, STATUS.waiting, 1),
    climber("lo", 0, STATUS.waiting, 2),
  ];
  const none = planPairings(cs, {forceResolve: false});
  check("no same-count pair when tiers differ", none.length === 0);
  const forced = planPairings(cs, {forceResolve: true});
  check("forceResolve pairs the last two across tiers",
      forced.length === 1 &&
      forced[0].includes("hi") && forced[0].includes("lo"));
}

// applyResult: winner climbs and waits, loser is out; array is not mutated.
{
  const before = [
    climber("w", 1, STATUS.inMatch, 1),
    climber("l", 1, STATUS.inMatch, 2),
  ];
  const after = applyResult(before, {winnerUid: "w", loserUid: "l"});
  check("winner climbs a tier", after.find((c) => c.uid === "w").wins === 2);
  check("winner is waiting again",
      after.find((c) => c.uid === "w").status === STATUS.waiting);
  check("loser is eliminated",
      after.find((c) => c.uid === "l").status === STATUS.eliminated);
  check("original array is not mutated",
      before.find((c) => c.uid === "w").wins === 1);
}

// applyTie: BOTH climbers advance, nobody eliminated; array not mutated.
{
  const before = [
    climber("a", 1, STATUS.inMatch, 1),
    climber("b", 1, STATUS.inMatch, 2),
    climber("c", 0, STATUS.waiting, 3),
  ];
  const after = applyTie(before, {player1Id: "a", player2Id: "b"});
  check("tie: both climb a tier",
      after.find((c) => c.uid === "a").wins === 2 &&
      after.find((c) => c.uid === "b").wins === 2);
  check("tie: both return to waiting, neither eliminated",
      after.find((c) => c.uid === "a").status === STATUS.waiting &&
      after.find((c) => c.uid === "b").status === STATUS.waiting);
  check("tie: an uninvolved climber is untouched",
      after.find((c) => c.uid === "c").wins === 0 &&
      after.find((c) => c.uid === "c").status === STATUS.waiting);
  check("tie: original array not mutated",
      before.find((c) => c.uid === "a").wins === 1);
}

// resolveChampion in its three states.
{
  const one = [
    climber("x", 3, STATUS.waiting, 1),
    climber("y", 2, STATUS.eliminated, 2),
  ];
  check("one survivor + joins closed = champion",
      resolveChampion(one, {joinsClosed: true, windowEnded: false})
          .winnerUid === "x");
  check("one survivor but joins still open = not done yet",
      resolveChampion(one, {joinsClosed: false, windowEnded: false})
          .done === false);
  const many = [
    climber("a", 1, STATUS.waiting, 1),
    climber("b", 3, STATUS.waiting, 2),
    climber("c", 2, STATUS.waiting, 3),
  ];
  check("window end crowns the highest-win active climber",
      resolveChampion(many, {joinsClosed: true, windowEnded: true})
          .winnerUid === "b");
  check("mid-event with many active = not done",
      resolveChampion(many, {joinsClosed: true, windowEnded: false})
          .done === false);
  // A freshly-created climb has NO climbers yet - it must not complete itself
  // before anyone joins (the bug the device check caught).
  check("empty field while the window is open = not done",
      resolveChampion([], {joinsClosed: false, windowEnded: false})
          .done === false);
  check("empty field at window end = done with no winner (caller cancels)",
      resolveChampion([], {joinsClosed: true, windowEnded: true}).done === true &&
      resolveChampion([], {joinsClosed: true, windowEnded: true})
          .winnerUid === null);
}

// Anti-cheese: a latecomer entering at 0 wins cannot be paired with a
// climber who has already won rounds (they must climb from the bottom).
{
  const cs = [
    climber("veteran", 3, STATUS.waiting, 1),
    climber("latecomer", 0, STATUS.waiting, 9999),
  ];
  const pairs = planPairings(cs, {forceResolve: false});
  check("a fresh latecomer is never handed a match against a 3-win climber",
      pairs.length === 0);
}

// standingFor: a live read of your own position.
{
  const cs = [
    climber("me", 1, STATUS.waiting, 1),
    climber("ahead", 2, STATUS.waiting, 2),
    climber("out", 0, STATUS.eliminated, 3),
  ];
  const s = standingFor(cs, "me");
  check("standing reports wins", s.wins === 1);
  check("standing ranks behind the higher-win climber", s.rank === 2);
  check("standing counts only active climbers", s.activeCount === 2);
}

// --- climbForfeitDecision (the sweep's forfeit rule) ----------------------
{
  const OPTS = {
    matchTimeoutMs: 8 * 60 * 1000,
    battleAbandonMs: 25 * 60 * 1000,
    presenceStaleMs: 75 * 1000,
  };
  const MIN = 60 * 1000;
  const NOW = 100 * MIN; // an arbitrary positive "now"; timestamps are NOW - x
  const ago = (mins) => NOW - mins * MIN;
  const agoS = (secs) => NOW - secs * 1000;
  // Default: created 9 minutes ago (past the 8-min no-show timeout).
  const match = (over) => Object.assign({
    player1Id: "a", player2Id: "b",
    readyPlayerIds: [], lastSeenAt: {}, arrivedAt: {},
    createdMs: ago(9),
  }, over);
  const decide = (over) => climbForfeitDecision(match(over), NOW, OPTS);

  // THE REGRESSION: both readied = battle in progress. Past the 8-min no-show
  // timeout but well inside a battle - must NOT be forfeited (the observed bug
  // force-abandoned exactly this, killing a live 2-device battle mid-fight).
  check("both readied, 9 min in -> wait (battle in progress)",
      decide({readyPlayerIds: ["a", "b"]}).action === "wait");

  // Both readied but past the long crash-safety window -> no-contest.
  {
    const d = climbForfeitDecision(
        match({readyPlayerIds: ["a", "b"], createdMs: ago(26)}), NOW, OPTS);
    check("both readied, 26 min in -> forfeit no-contest",
        d.action === "forfeit" && d.winnerUid === null);
  }

  // Two present players still in the bio reveal (fresh heartbeats, neither
  // readied) - never forfeit two present players, even past the timeout.
  check("both present (fresh heartbeats), 9 min -> wait",
      decide({lastSeenAt: {a: agoS(10), b: agoS(20)}}).action === "wait");

  // One readied, opponent never showed, past the timeout -> present one wins.
  {
    const d = decide({readyPlayerIds: ["a"]});
    check("one readied, opponent no-show -> forfeit, present wins",
        d.action === "forfeit" && d.winnerUid === "a");
  }

  // One present via heartbeat only (not readied), opponent absent -> the
  // present one advances.
  {
    const d = decide({lastSeenAt: {a: agoS(30)}});
    check("one present via heartbeat, opponent absent -> present wins",
        d.action === "forfeit" && d.winnerUid === "a");
  }

  // Genuine double no-show past the timeout -> nobody advances.
  check("neither showed up, past timeout -> forfeit no-contest",
      decide({}).action === "forfeit" && decide({}).winnerUid === null);

  // Before the no-show timeout, a one-sided absence still waits (a brief blip
  // or slow arrival must not be punished).
  check("one-sided absence but only 5 min in -> wait",
      climbForfeitDecision(
          match({readyPlayerIds: ["a"], createdMs: ago(5)}), NOW, OPTS)
          .action === "wait");

  // A stale heartbeat (older than presenceStaleMs) is NOT present, so a
  // present player beats a walked-away opponent rather than a no-contest.
  {
    const d = decide({lastSeenAt: {a: agoS(5), b: ago(5)}});
    check("fresh vs walked-away (stale) opponent -> present wins",
        d.action === "forfeit" && d.winnerUid === "a");
  }

  // No createdMs (unknowable age) -> never act.
  check("missing createdMs -> wait",
      climbForfeitDecision(match({createdMs: undefined}), NOW, OPTS)
          .action === "wait");
}

// --- Simulation -----------------------------------------------------------

// Deterministic PRNG so any failure reproduces.
function makeRng(seed) {
  let s = seed >>> 0;
  return () => {
    s = (s * 1664525 + 1013904223) >>> 0;
    return s / 4294967296;
  };
}

/**
 * Play a whole climb tournament. `joinTimes` is one joinedMs per player
 * (staggered joins). Returns the final state + match count.
 */
function simulate(seed, joinTimes) {
  const rand = makeRng(seed);
  const n = joinTimes.length;
  let climbers = [];
  let nextJoin = 0;
  let clock = 0;
  let matches = 0;
  const guard = n * 6 + 50;

  const admit = () => {
    while (nextJoin < n && joinTimes[nextJoin] <= clock) {
      climbers.push(climber("p" + nextJoin, 0, STATUS.waiting,
          joinTimes[nextJoin]));
      nextJoin++;
    }
  };

  for (;;) {
    admit();
    const joinsClosed = nextJoin >= n;

    let pairs = planPairings(climbers, {forceResolve: false});
    if (pairs.length === 0) {
      const waiting = climbers.filter((c) => c.status === STATUS.waiting);
      // Stalled (no same-count pair) and no more joins coming -> force it.
      if (joinsClosed && waiting.length >= 2) {
        pairs = planPairings(climbers, {forceResolve: true});
      }
    }

    if (pairs.length === 0) {
      const champ = resolveChampion(climbers, {joinsClosed, windowEnded: false});
      if (champ.done) return {climbers, matches, winnerUid: champ.winnerUid};
      // Not done and nothing to pair: fast-forward the clock to the next
      // joiner (rolling joins are what unblocks a thin early pool).
      if (!joinsClosed) {
        clock = joinTimes[nextJoin];
        continue;
      }
      throw new Error("stall: no pairs, not done, joins closed");
    }

    const uids = pairs.flat();
    climbers = markInMatch(climbers, uids);
    for (const [a, b] of pairs) {
      const winnerUid = rand() < 0.5 ? a : b;
      const loserUid = winnerUid === a ? b : a;
      // A winner never jumps more than one tier per match.
      const before = climbers.find((c) => c.uid === winnerUid).wins;
      climbers = applyResult(climbers, {winnerUid, loserUid});
      const after = climbers.find((c) => c.uid === winnerUid).wins;
      if (after !== before + 1) throw new Error("tier skip");
      matches++;
      if (matches > guard) throw new Error("runaway");
    }
    clock += 1;
  }
}

// Run many trials across sizes and join patterns.
let trials = 0;
for (const n of [2, 3, 4, 5, 7, 8, 12, 16, 21]) {
  for (let seed = 1; seed <= 120; seed++) {
    // A mix: some all-at-once, some heavily staggered (rolling/late joins).
    const joinTimes = [];
    for (let i = 0; i < n; i++) {
      joinTimes.push(seed % 3 === 0 ? 0 : (i * (seed % 5)) % 40);
    }
    const {climbers, matches, winnerUid} = simulate(seed, joinTimes);
    const active = climbers.filter((c) => c.status !== STATUS.eliminated);
    if (active.length !== 1) throw new Error(`n=${n} seed=${seed} survivors ${active.length}`);
    if (winnerUid !== active[0].uid) throw new Error(`n=${n} seed=${seed} champ mismatch`);
    // Single elimination: exactly N-1 matches to knock out N-1 players.
    if (matches !== n - 1) throw new Error(`n=${n} seed=${seed} matches ${matches}`);
    trials++;
  }
}
check(`${trials} climb simulations each resolve to one champion in N-1 matches`,
    trials === 9 * 120);

console.log(`climbTournament: ${passed} checks passed (${trials} simulations)`);
