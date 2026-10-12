const assert = require("assert");
const {
  SKILL_SEATS,
  resolveWildCardConfig,
  engagementTickets,
  drawWildCard,
  buildField,
} = require("../wildCard");

let n = 0;
const check = (label, fn) => {
  fn();
  n += 1;
  void label;
};

const CFG = resolveWildCardConfig(undefined); // defaults: play 2/cap15, judge 3/cap30

check("config defaults + bounds", () => {
  assert.deepStrictEqual(CFG, {
    playWeight: 2, judgeWeight: 3, playCap: 15, judgeCap: 30,
  });
  assert.strictEqual(resolveWildCardConfig({wildCardJudgeWeight: 5}).judgeWeight, 5);
  assert.strictEqual(resolveWildCardConfig({wildCardPlayCap: 0}).playCap, 15,
      "0 is below the min -> default");
  assert.strictEqual(resolveWildCardConfig({wildCardJudgeWeight: -1}).judgeWeight, 3);
});

check("tickets: judging weighted 3, playing 2 (the 60/40 tilt)", () => {
  assert.strictEqual(engagementTickets({games: 10, judged: 0}, CFG), 20);
  assert.strictEqual(engagementTickets({games: 0, judged: 10}, CFG), 30);
  // equal effort -> judging contributes 60%, playing 40%
  const t = engagementTickets({games: 10, judged: 10}, CFG);
  assert.strictEqual(t, 50);
});

check("tickets are capped (anti-farm ceiling)", () => {
  // 1000 battles + 1000 judged -> capped at 15*2 + 30*3 = 30 + 90 = 120
  assert.strictEqual(engagementTickets({games: 1000, judged: 1000}, CFG), 120);
});

check("drawWildCard is deterministic for a seed", () => {
  const pool = [
    {uid: "a", tickets: 10}, {uid: "b", tickets: 10}, {uid: "c", tickets: 10},
  ];
  const first = drawWildCard(pool, "2026-10-15");
  assert.strictEqual(drawWildCard(pool, "2026-10-15"), first, "same seed");
  assert.ok(["a", "b", "c"].includes(first));
});

check("drawWildCard empty pool -> null", () => {
  assert.strictEqual(drawWildCard([], "x"), null);
  assert.strictEqual(drawWildCard(null, "x"), null);
});

check("drawWildCard respects weight over many seeds", () => {
  // d has 90% of the tickets -> should win the big majority of random seeds.
  const pool = [{uid: "d", tickets: 90}, {uid: "e", tickets: 10}];
  let dWins = 0;
  for (let i = 0; i < 2000; i++) {
    if (drawWildCard(pool, `seed-${i}`) === "d") dWins++;
  }
  assert.ok(dWins > 1600 && dWins < 1960,
      `heavy favourite should win ~90%, got ${dWins}/2000`);
});

check("all-zero tickets -> still fills the seat (uniform)", () => {
  const pool = [{uid: "a", tickets: 0}, {uid: "b", tickets: 0}];
  const got = drawWildCard(pool, "z");
  assert.ok(["a", "b"].includes(got), "a zero-engagement pool still fills");
});

// --- buildField ---
const rows = [
  {uid: "s1", gain: 100, games: 10},
  {uid: "s2", gain: 80, games: 10},
  {uid: "s3", gain: 60, games: 10},
  {uid: "p4", gain: 40, games: 10}, // pool
  {uid: "p5", gain: 20, games: 10}, // pool
  {uid: "p6", gain: 10, games: 10}, // pool
];

check("buildField seats top 3 by skill + a wild card from the rest", () => {
  const judged = {p4: 50, p5: 0, p6: 0}; // p4 judged a lot -> best odds
  const {finalists, wildCardUid, alternates} =
    buildField(rows, judged, CFG, "wk", 4);
  // first 3 are the skill seats, in order
  assert.deepStrictEqual(finalists.slice(0, 3).map((f) => f.uid),
      ["s1", "s2", "s3"]);
  // 4th is the wild card, flagged, drawn from the pool (not a skill seat)
  assert.strictEqual(finalists.length, 4);
  assert.strictEqual(finalists[3].wildCard, true);
  assert.ok(["p4", "p5", "p6"].includes(finalists[3].uid));
  assert.strictEqual(finalists[3].uid, wildCardUid);
  // alternates are the remaining skill-ranked players, wild card excluded
  assert.ok(!alternates.some((a) => a.uid === wildCardUid));
  assert.ok(!alternates.some((a) => ["s1", "s2", "s3"].includes(a.uid)));
});

check("the skill seats are NEVER the wild card", () => {
  for (let i = 0; i < 50; i++) {
    const {finalists, wildCardUid} = buildField(rows, {}, CFG, `s${i}`, 4);
    assert.ok(["p4", "p5", "p6"].includes(wildCardUid));
    assert.deepStrictEqual(finalists.slice(0, 3).map((f) => f.uid),
        ["s1", "s2", "s3"]);
  }
});

check("small field: only skill seats, no wild card, when <= SKILL_SEATS", () => {
  const small = rows.slice(0, 2); // 2 players
  const {finalists, wildCardUid} = buildField(small, {}, CFG, "wk", 4);
  assert.strictEqual(finalists.length, 2);
  assert.strictEqual(wildCardUid, null);
  assert.strictEqual(SKILL_SEATS, 3);
});

check("exactly SKILL_SEATS+1 -> the one extra is the wild card", () => {
  const four = rows.slice(0, 4);
  const {finalists, wildCardUid} = buildField(four, {}, CFG, "wk", 4);
  assert.strictEqual(finalists.length, 4);
  assert.strictEqual(wildCardUid, "p4");
  assert.strictEqual(finalists[3].wildCard, true);
});

console.log(`wildCard: ${n} checks passed`);
