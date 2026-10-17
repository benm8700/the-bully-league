/**
 * IMPROV STATION (planned mode, built 2026-10-15) - a prompt-based comedy
 * SHOWCASE, distinct from the roast battle. Both comedians riff the SAME
 * prompt each round, BLIND to each other while performing (the client blacks
 * out the opponent during their set), then the crowd votes who was funnier.
 *
 * This file holds the PURE/config pieces: the prompt catalog + selection. The
 * mode plumbing (queue, finalize, matchmaking banding) lives where those
 * systems already are; see CLAUDE.md's "Improv Station" planning record and
 * the memory improv-station-planned-mode.
 *
 * RANKING SHAPE (the decided hybrid): Improv feeds the SAME career XP (your
 * title/Roman numeral climb from playing it - one identity ladder, two ways to
 * feed it) but has its OWN hidden Elo (`improvRating`) for its OWN matchmaking,
 * which NEVER touches roast Elo, the roast leaderboard, or Main Stage
 * qualification. That purity is enforced two ways: improv writes improvRating
 * (not rating) and no ratingHistory in finalize, AND "improv" is in the weekly
 * qualifier's NON_LADDER_MODES denylist.
 */

/** Improv players start at the same 1200 as roast, but on a SEPARATE ladder. */
const IMPROV_STARTING_RATING = 1200;

/** How many PROMPTS a match plays (one performance each, back-to-back). This is
 * DELIBERATELY separate from the VOTING round count: the match plays 3 prompts
 * but the crowd casts ONE overall "who was funnier" vote (developer's call
 * 2026-10-15), which is why the match's settings.roundCount is 1. Override via
 * config/improvPrompts.perMatch. */
const IMPROV_PROMPTS_PER_MATCH = 3;

/** The seed prompt catalog. Short, broad, riff-able subjects for a 10-second
 * one-liner. Lives here as a fallback; the live list is config/improvPrompts
 * so it can be retuned/grown from the console without a release. Kept PG-broad
 * on purpose - the comedy can go anywhere, but the PROMPT shouldn't pre-load a
 * target or a slur. */
const DEFAULT_PROMPTS = [
  "Airports",
  "Your ex",
  "Group projects",
  "Gym bros",
  "First dates that went wrong",
  "The DMV",
  "Living with roommates",
  "Family holidays",
  "Dating apps",
  "Cheap weddings",
  "Your worst job",
  "Gas station food",
  "The group chat",
  "Influencers",
  "Monday mornings",
  "Public transportation",
  "Your landlord",
  "Cafeteria food",
  "Online reviews",
  "New Year's resolutions",
  "Awkward small talk",
  "Street preachers",
  "Vegan friends",
  "Horoscopes",
];

/** Max prompts we'll ever hand a match (a cap so a misconfigured roundCount
 * can't ask for a thousand). Rounds are 1..10 per matchSettings LIMITS. */
const MAX_PROMPTS = 10;

/**
 * Clean the config/improvPrompts doc into a usable list. PURE. Falls back to
 * DEFAULT_PROMPTS whenever the config is missing, malformed, or empties out
 * after cleaning - a broken config must never leave a match with no prompts.
 */
function readImprovPrompts(doc) {
  const raw = doc && Array.isArray(doc.prompts) ? doc.prompts : null;
  if (!raw) return [...DEFAULT_PROMPTS];
  const cleaned = [];
  const seen = new Set();
  for (const p of raw) {
    if (typeof p !== "string") continue;
    const t = p.trim();
    if (t.length === 0 || t.length > 80) continue;
    const key = t.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    cleaned.push(t);
  }
  return cleaned.length > 0 ? cleaned : [...DEFAULT_PROMPTS];
}

/**
 * Pick [n] prompts for a match. PURE (takes an rng so it's testable). Distinct
 * when the pool is big enough; if the pool is smaller than n (shouldn't happen
 * with the defaults) it tops up with repeats rather than returning too few, so
 * a match always has exactly the rounds it expects.
 */
function pickPrompts(list, n, rng = Math.random) {
  const count = Math.max(1, Math.min(MAX_PROMPTS, Math.trunc(Number(n) || 1)));
  const pool = Array.isArray(list) && list.length > 0 ? [...list] : [...DEFAULT_PROMPTS];
  const picked = [];
  // Fisher-Yates partial shuffle for distinct picks.
  for (let i = 0; i < pool.length && picked.length < count; i++) {
    const j = i + Math.floor(rng() * (pool.length - i));
    const tmp = pool[i]; pool[i] = pool[j]; pool[j] = tmp;
    picked.push(pool[i]);
  }
  // Top up with repeats only if the pool was too small.
  while (picked.length < count) {
    picked.push(pool[Math.floor(rng() * pool.length)]);
  }
  return picked;
}

/** How many prompts a match plays - config/improvPrompts.perMatch, bounds
 * 1..MAX_PROMPTS, default IMPROV_PROMPTS_PER_MATCH. PURE. */
function improvPromptCount(doc) {
  const n = Math.trunc(Number(doc && doc.perMatch));
  return Number.isFinite(n) && n >= 1 && n <= MAX_PROMPTS ?
    n : IMPROV_PROMPTS_PER_MATCH;
}

/** Read + pick in one go, for the match-creation path. The COUNT comes from
 * config (perMatch), NOT the voting roundCount - the match plays N prompts but
 * the crowd casts a single overall vote. */
async function pickImprovPrompts(db) {
  let doc = null;
  try {
    const snap = await db.collection("config").doc("improvPrompts").get();
    doc = snap.exists ? snap.data() : null;
  } catch (_) {
    // Fall back to defaults on any read failure.
  }
  return pickPrompts(readImprovPrompts(doc), improvPromptCount(doc));
}

module.exports = {
  IMPROV_STARTING_RATING,
  IMPROV_PROMPTS_PER_MATCH,
  DEFAULT_PROMPTS,
  MAX_PROMPTS,
  readImprovPrompts,
  pickPrompts,
  improvPromptCount,
  pickImprovPrompts,
};
