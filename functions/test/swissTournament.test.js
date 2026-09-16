const assert = require("assert");
const S = require("../swissTournament");

let passed = 0;
function check(name, fn) {
  fn();
  passed++;
  console.log(`  ok - ${name}`);
}

const {STATUS} = S;
const entrant = (uid, over = {}) => ({
  uid, wins: 0, losses: 0, opponents: [], status: STATUS.waiting,
  joinedMs: 0, ...over,
});

// A tiny seeded RNG (mulberry32) so failures are reproducible.
function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a |= 0; a = (a + 0x6D2B79F5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

console.log("swiss pairing");

check("pairs waiting players and never with themselves", () => {
  const es = [entrant("a"), entrant("b"), entrant("c"), entrant("d")];
  const pairs = S.planPairings(es);
  assert.strictEqual(pairs.length, 2);
  for (const [x, y] of pairs) assert.notStrictEqual(x, y);
});

check("skips in_match and done players", () => {
  const es = [
    entrant("a"), entrant("b", {status: STATUS.inMatch}),
    entrant("c", {status: STATUS.done}), entrant("d"),
  ];
  const pairs = S.planPairings(es);
  assert.deepStrictEqual(pairs, [["a", "d"]]);
});

check("pairs by closest record (most wins meet)", () => {
  const es = [
    entrant("hi", {wins: 2}), entrant("hi2", {wins: 2}),
    entrant("lo", {wins: 0}), entrant("lo2", {wins: 0}),
  ];
  const pairs = S.planPairings(es);
  // Top two (2-win) pair, bottom two (0-win) pair.
  const set = pairs.map((p) => p.slice().sort().join("|")).sort();
  assert.deepStrictEqual(set, ["hi|hi2", "lo|lo2"]);
});

check("never rematches unless allowRematch", () => {
  // a and b already faced each other; both 0-0, no one else free.
  const es = [
    entrant("a", {opponents: ["b"]}),
    entrant("b", {opponents: ["a"]}),
  ];
  assert.deepStrictEqual(S.planPairings(es), []);
  assert.deepStrictEqual(S.planPairings(es, {allowRematch: true}), [["a", "b"]]);
});

check("respects the round cap", () => {
  const es = [entrant("a", {wins: 3}), entrant("b", {losses: 3}), entrant("c")];
  // a and b have each played 3; with maxRounds 3 they are ineligible, so only
  // c is left and cannot be paired.
  assert.deepStrictEqual(S.planPairings(es, {maxRounds: 3}), []);
});

console.log("results");

check("applyResult moves win/loss, records opponents, back to waiting", () => {
  const es = [entrant("a"), entrant("b")];
  const out = S.applyResult(es, {winnerUid: "a", loserUid: "b"});
  const a = out.find((e) => e.uid === "a");
  const b = out.find((e) => e.uid === "b");
  assert.strictEqual(a.wins, 1);
  assert.strictEqual(b.losses, 1);
  assert.deepStrictEqual(a.opponents, ["b"]);
  assert.deepStrictEqual(b.opponents, ["a"]);
  assert.strictEqual(a.status, STATUS.waiting);
  assert.strictEqual(b.status, STATUS.waiting);
});

check("applyResult sends a capped player to done", () => {
  const es = [entrant("a", {wins: 2}), entrant("b")];
  const out = S.applyResult(es, {winnerUid: "a", loserUid: "b"}, {maxRounds: 3});
  assert.strictEqual(out.find((e) => e.uid === "a").status, STATUS.done);
});

check("applyTie scores nobody but records the meeting", () => {
  const es = [entrant("a"), entrant("b")];
  const out = S.applyTie(es, {player1Id: "a", player2Id: "b"});
  assert.strictEqual(out.find((e) => e.uid === "a").wins, 0);
  assert.strictEqual(out.find((e) => e.uid === "b").wins, 0);
  assert.deepStrictEqual(out.find((e) => e.uid === "a").opponents, ["b"]);
  assert.strictEqual(out.find((e) => e.uid === "a").status, STATUS.waiting);
});

check("applyForfeit gives present the win and drops the absent", () => {
  const es = [entrant("a"), entrant("b")];
  const out = S.applyForfeit(es, {winnerUid: "a", loserUid: "b"});
  assert.strictEqual(out.find((e) => e.uid === "a").wins, 1);
  assert.strictEqual(out.find((e) => e.uid === "a").status, STATUS.waiting);
  assert.strictEqual(out.find((e) => e.uid === "b").status, STATUS.done);
});

check("applyDoubleNoShow drops both", () => {
  const es = [entrant("a"), entrant("b")];
  const out = S.applyDoubleNoShow(es, {player1Id: "a", player2Id: "b"});
  assert.strictEqual(out.find((e) => e.uid === "a").status, STATUS.done);
  assert.strictEqual(out.find((e) => e.uid === "b").status, STATUS.done);
});

console.log("standings + champion");

check("standings order most wins, fewest losses, then SoS", () => {
  const es = [
    entrant("x", {wins: 2, losses: 1}),
    entrant("y", {wins: 2, losses: 0}),
    entrant("z", {wins: 1, losses: 2}),
  ];
  const order = S.standings(es).map((e) => e.uid);
  assert.deepStrictEqual(order, ["y", "x", "z"]); // y fewer losses than x
});

check("no champion while the window is open and people can still play", () => {
  const es = [entrant("a", {wins: 1}), entrant("b")];
  assert.deepStrictEqual(
      S.resolveChampion(es, {windowEnded: false}), {done: false, winnerUid: null});
});

check("champion is top of standings at window end", () => {
  const es = [entrant("a", {wins: 3}), entrant("b", {wins: 1}), entrant("c")];
  assert.deepStrictEqual(
      S.resolveChampion(es, {windowEnded: true}), {done: true, winnerUid: "a"});
});

check("a field where nobody won crowns nobody", () => {
  const es = [entrant("a"), entrant("b")];
  assert.deepStrictEqual(
      S.resolveChampion(es, {windowEnded: true}), {done: true, winnerUid: null});
});

check("empty field is only over once the window ends", () => {
  assert.deepStrictEqual(S.resolveChampion([], {windowEnded: false}),
      {done: false, winnerUid: null});
  assert.deepStrictEqual(S.resolveChampion([], {windowEnded: true}),
      {done: true, winnerUid: null});
});

console.log("randomised full-tournament simulations");

function simulate(seed, n, maxRounds, tieRate) {
  const rand = rng(seed);
  let es = [];
  for (let i = 0; i < n; i++) {
    es.push(entrant(`u${i}`, {joinedMs: Math.floor(rand() * 1000)}));
  }
  let guard = 0;
  for (;;) {
    if (++guard > 100000) throw new Error("simulation did not terminate");
    let allowRematch = false;
    let pairs = S.planPairings(es, {maxRounds});
    if (pairs.length === 0) {
      allowRematch = true;
      pairs = S.planPairings(es, {allowRematch: true, maxRounds});
    }
    if (pairs.length === 0) break; // field exhausted

    // Validate the pass.
    const seen = new Set();
    for (const [a, b] of pairs) {
      assert.notStrictEqual(a, b, "paired with self");
      assert.ok(!seen.has(a) && !seen.has(b), "double-booked a player");
      seen.add(a); seen.add(b);
      const ea = es.find((e) => e.uid === a);
      const eb = es.find((e) => e.uid === b);
      assert.strictEqual(ea.status, STATUS.waiting);
      assert.strictEqual(eb.status, STATUS.waiting);
      assert.ok(S.roundsPlayed(ea) < maxRounds && S.roundsPlayed(eb) < maxRounds,
          "paired a capped player");
      if (!allowRematch) {
        assert.ok(!(ea.opponents || []).includes(b), "rematch without allowRematch");
      }
    }

    es = S.markInMatch(es, pairs.flat());
    for (const [a, b] of pairs) {
      if (rand() < tieRate) {
        es = S.applyTie(es, {player1Id: a, player2Id: b});
      } else {
        const aWins = rand() < 0.5;
        es = S.applyResult(es,
            {winnerUid: aWins ? a : b, loserUid: aWins ? b : a}, {maxRounds});
      }
    }
  }

  // Window ends: every entrant survives (non-elimination) and the champion is
  // the true top of the standings.
  assert.strictEqual(es.length, n, "an entrant vanished");
  const result = S.resolveChampion(es, {windowEnded: true});
  assert.strictEqual(result.done, true);
  const maxWins = Math.max(...es.map((e) => e.wins), 0);
  if (maxWins === 0) {
    assert.strictEqual(result.winnerUid, null, "crowned a winless champion");
  } else {
    const champ = es.find((e) => e.uid === result.winnerUid);
    assert.strictEqual(champ.wins, maxWins, "champion is not the most-wins player");
    assert.strictEqual(S.standings(es)[0].uid, result.winnerUid,
        "champion is not top of standings");
  }
  return es;
}

check("1,200 randomised simulations hold every invariant", () => {
  let sims = 0;
  for (let n = 2; n <= 26; n++) {
    for (let s = 0; s < 48; s++) {
      const maxRounds = 3 + (s % 5); // 3..7 rounds per player
      const tieRate = (s % 7 === 0) ? 0.15 : 0.0;
      simulate(n * 1000 + s, n, maxRounds, tieRate);
      sims++;
    }
  }
  assert.ok(sims >= 1200, `only ran ${sims} sims`);
  console.log(`    (${sims} simulations)`);
});

console.log(`\n${passed} passed`);
