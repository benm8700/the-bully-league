const {getFirestore, FieldValue} = require("firebase-admin/firestore");

/**
 * Automatic match/round-time stats (answering "can you get stats for round
 * times, and are you doing it automatically?").
 *
 * The data is already collected on every completed match - the host records
 * each round's [startMs, endMs] window in `roundBoundaries` (offsets into the
 * clip, needed for Best-Rounds playback) - it was just never aggregated. This
 * scheduled job rolls a recent sample of matches into `stats/matchStats`,
 * following the exact pattern used for `stats/presence`: a pure aggregation
 * helper (unit-testable), a scheduled wrapper that reads Firestore and writes
 * one doc, and read-by-signed-in / write-by-nobody rules on `stats/**`.
 *
 * It is a rolling SAMPLE, not lifetime totals: recent behaviour (typical
 * round length, completion rate) is what's worth watching while tuning round
 * length and format, and a bounded sample keeps the job cheap as volume grows.
 */

/** How many recent matches to sample per run. Bounded so the read cost stays
 * flat regardless of how big the match collection gets. */
const SAMPLE_SIZE = 500;

/** Guards against a corrupt boundary producing an absurd average: a real
 * round is seconds to a couple of minutes, never an hour. */
const MAX_PLAUSIBLE_ROUND_SECONDS = 3600;

function round(x, digits = 1) {
  return Number.isFinite(x) ? Number(x.toFixed(digits)) : null;
}

/**
 * Aggregates round-time and completion stats from a set of match documents.
 * PURE - takes plain match objects and returns the stats object, so the
 * arithmetic is testable without Firestore.
 *
 * Round duration comes from roundBoundaries (host-recorded per-round windows);
 * only completed matches contribute round/vote figures, while completion rate
 * is over finished matches (completed + abandoned/disqualified). In-progress
 * ("pending") matches in the sample are ignored for the rate - they haven't
 * finished, so counting them as "not completed" would understate it.
 */
function computeMatchStats(matches) {
  const list = Array.isArray(matches) ? matches : [];
  let completed = 0;
  let abandoned = 0;
  const byMode = {};
  let roundDurationSum = 0; // seconds
  let roundCount = 0;
  let matchesWithRounds = 0;
  let voteSum = 0;
  let voteCounted = 0;

  for (const m of list) {
    if (!m || typeof m !== "object") continue;
    const status = m.status;
    if (status === "completed") completed++;
    else if (status === "abandoned" || status === "disqualified") abandoned++;

    const mode = typeof m.mode === "string" ? m.mode : "unknown";
    byMode[mode] = (byMode[mode] || 0) + 1;

    if (status !== "completed") continue;

    if (typeof m.voteCount === "number" && Number.isFinite(m.voteCount)) {
      voteSum += m.voteCount;
      voteCounted++;
    }
    const rb = Array.isArray(m.roundBoundaries) ? m.roundBoundaries : null;
    if (!rb || rb.length === 0) continue;
    let anyRound = false;
    for (const b of rb) {
      if (!b || typeof b.startMs !== "number" || typeof b.endMs !== "number") continue;
      const dur = (b.endMs - b.startMs) / 1000;
      if (dur > 0 && dur < MAX_PLAUSIBLE_ROUND_SECONDS) {
        roundDurationSum += dur;
        roundCount++;
        anyRound = true;
      }
    }
    if (anyRound) matchesWithRounds++;
  }

  const finished = completed + abandoned;
  return {
    sampleSize: list.length,
    completed,
    abandoned,
    completionRate: finished > 0 ? round(completed / finished, 3) : null,
    matchesWithRoundData: matchesWithRounds,
    avgRoundSeconds: roundCount > 0 ? round(roundDurationSum / roundCount, 1) : null,
    avgRoundsPerMatch: matchesWithRounds > 0 ? round(roundCount / matchesWithRounds, 2) : null,
    avgVotesPerCompleted: voteCounted > 0 ? round(voteSum / voteCounted, 2) : null,
    byMode,
  };
}

/**
 * Reads a rolling sample of the most recent matches and publishes the
 * aggregate to `stats/matchStats`. Orders by createdAt (a single-field index,
 * always available - no composite needed) so the sample spans all statuses
 * and the completion rate can be computed directly. Never throws on an empty
 * collection; returns the stats it wrote.
 */
async function aggregateMatchStats() {
  const db = getFirestore();
  const snap = await db.collection("matches")
      .orderBy("createdAt", "desc")
      .limit(SAMPLE_SIZE)
      .get();
  const matches = snap.docs.map((d) => d.data());
  const stats = computeMatchStats(matches);
  await db.collection("stats").doc("matchStats").set({
    ...stats,
    updatedAt: FieldValue.serverTimestamp(),
    updatedAtMs: Date.now(),
    _note: "Rolling sample of the most recent matches (up to " + SAMPLE_SIZE +
      "). avgRoundSeconds is per round window (both turns) from host-recorded " +
      "roundBoundaries. Auto-updated by the aggregateMatchStats scheduled job.",
  });
  return stats;
}

module.exports = {computeMatchStats, aggregateMatchStats, SAMPLE_SIZE};
