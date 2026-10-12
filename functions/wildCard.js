/**
 * THE WILD CARD - seat 4 on the Main Stage.
 *
 * The finals field is the top 3 by skill (weekly Elo gain) PLUS one WILD CARD,
 * drawn by weighted lottery from everyone else who qualified (the
 * 5-distinct-opponent floor still applies, so the wild card is always a real
 * competitor - just not a top-3 one). This separates the two concerns cleanly:
 * skill owns 3 seats so the show stays good and un-grindable, while the wild
 * card is a pure ENGAGEMENT carrot that gives the whole field a real shot and a
 * reason to show up and - crucially - to JUDGE.
 *
 * Your lottery odds scale with engagement, tilted 60/40 toward judging:
 *   tickets = PLAY_WEIGHT * min(battles, PLAY_CAP)
 *           + JUDGE_WEIGHT * min(judged, JUDGE_CAP)
 * Judging is weighted higher because it's the scarce resource the ladder runs
 * on AND the wild card is the ONLY place it buys a shot at the stage (battling
 * already buys the top-3 path). The caps are anti-farm ceilings so neither
 * metric can be ground to infinity for odds.
 *
 * The draw is DETERMINISTIC given the pool and a seed (the week key), so the
 * snapshot is reproducible/idempotent and the whole thing is pure-testable -
 * the discipline that keeps catching silent bugs here before they ship.
 */

// How many seats go to pure skill; the rest of the field (FINALISTS-SKILL_SEATS)
// is wild cards. Must match _weeklyCutoff in weekly_standings_board.dart.
const SKILL_SEATS = 3;

// Defaults (placeholders, like the rest of the economy numbers - tunable via
// config/tournament). Weights give judging a 60/40 edge PER ACTION (3:2).
const DEFAULTS = {
  playWeight: 2,
  judgeWeight: 3,
  playCap: 15,
  judgeCap: 30,
};

/** Bounds-checked wild-card weights/caps from config/tournament. */
function resolveWildCardConfig(cfg) {
  const num = (v, def, lo, hi) => {
    const n = Number(v);
    return Number.isFinite(n) && n >= lo && n <= hi ? n : def;
  };
  return {
    playWeight: num(cfg && cfg.wildCardPlayWeight, DEFAULTS.playWeight, 0, 100),
    judgeWeight:
      num(cfg && cfg.wildCardJudgeWeight, DEFAULTS.judgeWeight, 0, 100),
    playCap: Math.floor(num(cfg && cfg.wildCardPlayCap, DEFAULTS.playCap, 1, 1e4)),
    judgeCap:
      Math.floor(num(cfg && cfg.wildCardJudgeCap, DEFAULTS.judgeCap, 1, 1e4)),
  };
}

/** Lottery tickets for one player from their week's engagement. Pure. */
function engagementTickets(stat, cfg) {
  const games = Math.max(0, Number(stat && stat.games) || 0);
  const judged = Math.max(0, Number(stat && stat.judged) || 0);
  return Math.min(games, cfg.playCap) * cfg.playWeight +
    Math.min(judged, cfg.judgeCap) * cfg.judgeWeight;
}

/** A deterministic [0,1) from a string (FNV-1a). Same seed -> same value. */
function hashUnit(str) {
  let h = 2166136261 >>> 0;
  const s = String(str || "");
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 16777619) >>> 0;
  }
  return (h >>> 0) / 4294967296;
}

/**
 * Draw one wild card from the pool, weighted by tickets, deterministic for a
 * given seed. Pure.
 *   pool: [{uid, tickets}]
 *   seed: a stable string (the week key)
 * Returns a uid, or null if the pool is empty. When every entry has 0 tickets
 * (nobody engaged beyond qualifying), it falls back to a uniform draw so the
 * seat is still filled rather than left empty.
 */
function drawWildCard(pool, seed) {
  const entries = (pool || [])
      .filter((p) => p && typeof p.uid === "string" && p.uid);
  if (entries.length === 0) return null;
  const weight = (p) => Math.max(0, Number(p.tickets) || 0);
  const total = entries.reduce((s, p) => s + weight(p), 0);
  const r = hashUnit(seed);
  if (total <= 0) {
    return entries[Math.min(entries.length - 1, Math.floor(r * entries.length))]
        .uid;
  }
  let acc = r * total;
  for (const p of entries) {
    acc -= weight(p);
    if (acc < 0) return p.uid;
  }
  return entries[entries.length - 1].uid; // float-rounding safety
}

/**
 * Build the finals field: top SKILL_SEATS by skill + one wild card drawn from
 * the rest, plus the alternates (next best skill players, not already seated).
 * Pure - hand it the sorted standings, the per-uid judged counts, the config
 * and the seed.
 *   standings: [{uid, gain, games, ...}] already sorted best-first
 *   judgedByUid: Map/obj of uid -> ballots judged this week
 * Returns {finalists, wildCardUid, alternates}. The wild-card finalist row
 * carries wildCard:true. Fewer than SKILL_SEATS+1 if the field is small.
 */
function buildField(standings, judgedByUid, cfg, seed, alternatesCount) {
  const rows = Array.isArray(standings) ? standings : [];
  const judgedOf = (uid) => {
    if (judgedByUid instanceof Map) return judgedByUid.get(uid) || 0;
    return (judgedByUid && judgedByUid[uid]) || 0;
  };
  const skillSeats = rows.slice(0, SKILL_SEATS);
  const skillUids = new Set(skillSeats.map((s) => s.uid));
  const pool = rows
      .filter((s) => s && !skillUids.has(s.uid))
      .map((s) => ({
        uid: s.uid,
        tickets: engagementTickets(
            {games: s.games, judged: judgedOf(s.uid)}, cfg),
      }));
  const wildCardUid = drawWildCard(pool, seed);
  const wildRow = wildCardUid ?
    rows.find((s) => s.uid === wildCardUid) : null;
  const finalists = wildRow ?
    [...skillSeats, {...wildRow, wildCard: true}] : skillSeats.slice();
  const finalistUids = new Set(finalists.map((f) => f.uid));
  const alternates = rows
      .filter((s) => !finalistUids.has(s.uid))
      .slice(0, alternatesCount);
  return {finalists, wildCardUid: wildCardUid || null, alternates};
}

module.exports = {
  SKILL_SEATS,
  resolveWildCardConfig,
  engagementTickets,
  drawWildCard,
  buildField,
};
