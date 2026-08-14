const {getFirestore, FieldValue} = require("firebase-admin/firestore");

/**
 * The all-time greatest battles.
 *
 * BUILT FROM PUBLISHED CLIPS ONLY, and that is a constraint rather than a
 * preference: unpublished renders are purged after seven days, so any
 * other source would leave a permanent list pointing at deleted videos.
 * Published clips are retained indefinitely and already human-reviewed,
 * which also gives the review gate a positive purpose - approving a clip
 * is how a battle becomes eligible for this - rather than a purely
 * defensive one.
 *
 * SCORED RELATIVE TO ITS ERA, not in absolute counts. The developer
 * spotted this problem for caption selection and it bites harder here:
 * every match gets more votes as the userbase grows, so an all-time list
 * ranked by raw totals slowly becomes a list of RECENT matches, and a
 * genuinely great battle from the first month is pushed out by a mediocre
 * one that simply had more people around to watch it. Scoring against what
 * was normal at the time means a clip that was ten times its era's median
 * stays impressive forever.
 */

/** How many battles the hall holds. */
const HALL_SIZE = 10;

/** Reactions that mean "this was good". Ice, crickets, yawn, meh and
 * thumbs-down are honest feedback and count toward how WATCHED something
 * was, but a hall of fame ranked partly on them would enshrine the worst
 * sets alongside the best. */
const ACCLAIM = ["fire", "skull", "coffin", "cold_blooded", "bullseye",
  "mindblown", "cry", "laugh", "clap", "salute"];

/** How much acclaim counts next to judging volume. Votes measure how many
 * people showed up; reactions measure what they thought, so reactions are
 * weighted at least as heavily despite being the newer signal. */
const ACCLAIM_WEIGHT = 1.5;

function median(values) {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 0 ?
    (sorted[mid - 1] + sorted[mid]) / 2 :
    sorted[mid];
}

/** Positive reactions only - see ACCLAIM. */
function acclaimCount(match) {
  const counts = match?.reactionCounts ?? {};
  return ACCLAIM.reduce((sum, key) => sum + (Number(counts[key]) || 0), 0);
}

/**
 * How great a battle was, relative to what was normal when it happened.
 *
 * Pure and isolated so it can be swapped: watch-through rate is the better
 * signal once the feed has been live long enough to measure it, and that
 * should be a one-function change rather than a redesign.
 */
function legendScore(match, era) {
  const votes = Number(match?.voteCount) || 0;
  const acclaim = acclaimCount(match);
  const voteMedian = era?.voteMedian > 0 ? era.voteMedian : 1;
  const acclaimMedian = era?.acclaimMedian > 0 ? era.acclaimMedian : 1;
  return (votes / voteMedian) + ACCLAIM_WEIGHT * (acclaim / acclaimMedian);
}

/** Calendar month a match belongs to, which is the era it competes in. A
 * month is long enough to have a stable median at small volume and short
 * enough that growth inside one is negligible. */
function eraKeyOf(ms) {
  return new Date(ms).toISOString().slice(0, 7);
}

/**
 * Ranks candidates into the hall.
 *
 * Pure, so the whole selection can be exercised without Firestore.
 */
function selectHall(candidates, {size = HALL_SIZE} = {}) {
  const byEra = new Map();
  for (const c of candidates) {
    const key = eraKeyOf(c.completedAtMs);
    if (!byEra.has(key)) byEra.set(key, []);
    byEra.get(key).push(c);
  }

  const eras = new Map();
  for (const [key, group] of byEra) {
    eras.set(key, {
      voteMedian: median(group.map((c) => Number(c.voteCount) || 0)),
      acclaimMedian: median(group.map((c) => acclaimCount(c))),
    });
  }

  return candidates
      .map((c) => ({...c, score: legendScore(c, eras.get(eraKeyOf(c.completedAtMs)))}))
      // A battle nobody judged or reacted to is not a legend, however
      // quiet its month was.
      .filter((c) => (Number(c.voteCount) || 0) > 0 || acclaimCount(c) > 0)
      .sort((a, b) => b.score - a.score || b.completedAtMs - a.completedAtMs)
      .slice(0, size);
}

/**
 * Recomputes the hall and publishes it to a single document.
 *
 * Published to one doc rather than queried per client for the same reason
 * the online count is: every reader would otherwise run a scan plus a
 * username lookup per entry, and this changes at most once a day.
 */
async function rebuildHallOfFame() {
  const db = getFirestore();

  const snap = await db.collection("matches")
      .where("status", "==", "completed")
      .orderBy("completedAt", "desc")
      .limit(500)
      .get();

  const candidates = [];
  for (const doc of snap.docs) {
    const match = doc.data();
    // The constraint that shapes this whole feature.
    if (match.highlight?.published !== true) continue;
    const completedAtMs = match.completedAt?.toMillis?.() ?? 0;
    if (completedAtMs === 0) continue;
    candidates.push({
      matchId: doc.id,
      player1Id: match.player1Id,
      player2Id: match.player2Id,
      winnerId: match.winnerId ?? null,
      voteCount: match.voteCount ?? 0,
      reactionCounts: match.reactionCounts ?? {},
      publicUrls: match.highlight?.publicUrls ?? {},
      completedAtMs,
    });
  }

  const hall = selectHall(candidates);

  // Names resolved here rather than by every client on every read.
  const ids = [...new Set(hall.flatMap((h) => [h.player1Id, h.player2Id]))];
  const names = new Map();
  if (ids.length > 0) {
    const users = await db.getAll(...ids.map((id) => db.collection("users").doc(id)));
    for (const u of users) names.set(u.id, u.data()?.username ?? "Unknown");
  }

  await db.collection("stats").doc("hallOfFame").set({
    entries: hall.map((h, i) => ({
      rank: i + 1,
      matchId: h.matchId,
      player1Username: names.get(h.player1Id) ?? "Unknown",
      player2Username: names.get(h.player2Id) ?? "Unknown",
      winnerUsername: h.winnerId ? names.get(h.winnerId) ?? "Unknown" : null,
      voteCount: h.voteCount,
      acclaim: acclaimCount(h),
      videoUrl: h.publicUrls.vertical ?? h.publicUrls.landscape ?? null,
      completedAtMs: h.completedAtMs,
    })),
    candidateCount: candidates.length,
    updatedAt: FieldValue.serverTimestamp(),
  });

  return {size: hall.length, candidates: candidates.length};
}

module.exports = {
  rebuildHallOfFame,
  selectHall,
  legendScore,
  acclaimCount,
  eraKeyOf,
  HALL_SIZE,
  ACCLAIM,
  ACCLAIM_WEIGHT,
};
