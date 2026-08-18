const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {RECORDED_MODES} = require("./matchmaking");
const {qualityFactor} = require("./captureQuality");

/**
 * Turns finished matches into watchable clips automatically, in two
 * stages, so nobody has to click render on every match forever.
 *
 * WHY TWO STAGES. Transcription is essentially the entire cost of a
 * render - roughly $0.066 of a $0.07 clip, against about $0.003 for the
 * compositing itself. Captioning every match would mean paying the
 * expensive part for the large majority of clips nobody ever watches
 * twice.
 *
 *   Stage 1, every recorded match: composite the players together, no
 *   captions. This is what the in-app judging queue needs, and someone
 *   actively judging a battle has the sound on - captions add little.
 *
 *   Stage 2, only clips that earn it: re-render with burned-in captions.
 *   That is where captions genuinely matter - the Watch feed and social,
 *   where people scroll muted.
 *
 * Roughly a 95% cost reduction with no loss to judging, and still nothing
 * for an admin to click.
 *
 * WHY A SCHEDULED SWEEP rather than a Firestore trigger on completion:
 *  - completeMatch writes `status: completed` BEFORE stopping the
 *    recording and listing its files, so a trigger on status would
 *    routinely fire while there is still nothing to render. Sweeping for
 *    matches that already have files sidesteps the ordering entirely.
 *  - Renders run at 4GiB/2vCPU. During a busy Sixes and Sevens a trigger
 *    would start one per finishing match simultaneously; a sweep with a
 *    per-run cap bounds both cost and quota.
 *  - Retries come free. A transient failure is simply picked up next run.
 * The cost is a few minutes of latency, which is irrelevant against a
 * 24-hour voting window.
 */

/** Renders started per sweep. Deliberately small: each one is a 4GiB job,
 * and a backlog draining slowly is much better than a thundering herd. */
const RENDERS_PER_RUN = 3;

/** After this many failed attempts a match is left alone. Something about
 * it is broken - a truncated recording, a missing track - and retrying
 * forever would burn compute on it indefinitely. */
const MAX_ATTEMPTS = 3;

/**
 * How many clips earn captions, as a rolling top-N over the trailing week
 * rather than a fixed vote threshold.
 *
 * A FIXED THRESHOLD WOULD BREAK AS THE APP GROWS - the developer spotted
 * this. Double the userbase and every match gets roughly double the votes,
 * so "caption at 3 votes" would go from selective to captioning
 * everything. A RANKING against peers from the same week is immune: the
 * bar rises on its own and the selection stays proportionate.
 *
 * PROVISIONAL - the developer has explicitly flagged this whole strategy
 * for revisiting. Which is why the scorer below is a single isolated pure
 * function: swapping in a better signal later should be a one-function
 * change, not a redesign.
 */
const CAPTION_TOP_N = 10;

/** Backstop. Ranking churn means a clip can be captioned and later
 * displaced by a better one - harmless in itself, but without a ceiling a
 * chaotic week could caption far more than intended. */
const CAPTION_WEEKLY_CAP = 15;

/** How much a decisive result counts for. Vote COUNT says how many people
 * watched; vote MARGIN says what they thought, and margin is completely
 * immune to exposure bias. A blowout is usually a better highlight than a
 * coin-flip, so it earns up to this much of a boost. */
const MARGIN_BOOST = 0.5;

const WEEK_MS = 7 * 24 * 60 * 60 * 1000;

/**
 * How lopsided the result was, from 0 (dead heat) to 1 (shut out).
 *
 * Uses the final weights finalizeMatch records, so it reflects what
 * actually decided the match.
 */
function voteMargin(match) {
  const a = Number(match?.player1FinalWeight) || 0;
  const b = Number(match?.player2FinalWeight) || 0;
  const total = a + b;
  if (total <= 0) return 0;
  return Math.abs(a - b) / total;
}

/**
 * How deserving of captions a finished match is.
 *
 * Volume is measured RELATIVE to the median of matches that finished the
 * same day, not in absolute votes. That normalises three things at once:
 * userbase growth, weekday-versus-weekend activity, and any day where
 * turnout happened to be unusual. Then a decisive result gets a boost.
 *
 * CAPTURE QUALITY DISCOUNTS THE WHOLE THING, because captions are the
 * expensive stage and a clip nobody can see or hear is the worst
 * possible thing to spend them on. It is a discount rather than a veto:
 * a dark clip with overwhelming votes may still be the best thing that
 * happened all week.
 *
 * THE HONEST LIMITATION: this measures how many people judged a clip,
 * which is a proxy for quality, not quality itself. The real signal is
 * watch-through - did people watch to the end, did they replay it - and
 * nothing can measure that until the Watch feed has been live long enough
 * to gather it. Deliberately isolated so that swap is easy.
 */
function captionScore(match, dayMedianVotes) {
  const votes = Number(match?.voteCount) || 0;
  const median = dayMedianVotes > 0 ? dayMedianVotes : 1;
  return (votes / median) *
    (1 + MARGIN_BOOST * voteMargin(match)) *
    qualityFactor(match?.captureQuality);
}

/** UTC calendar day of a timestamp in millis, for grouping peers. */
function dayKeyOf(ms) {
  return new Date(ms).toISOString().slice(0, 10);
}

function median(values) {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 0 ?
    (sorted[mid - 1] + sorted[mid]) / 2 :
    sorted[mid];
}

/**
 * Picks which finished matches earn captions.
 *
 * Only matches whose voting has CLOSED are ranked. While a window is open
 * the count is still moving, so a match from two hours ago would be
 * compared against one that finished yesterday and had a full day to
 * gather ballots - which measures age, not merit.
 *
 * Pure and exported, so the whole selection can be exercised without
 * Firestore, ffmpeg, or spending a penny on transcription.
 */
function selectForCaptioning(candidates, {
  now,
  topN = CAPTION_TOP_N,
  weeklyCap = CAPTION_WEEKLY_CAP,
  captionedThisWeek = 0,
} = {}) {
  const budget = Math.max(0, weeklyCap - captionedThisWeek);
  if (budget === 0) return [];

  const recent = candidates.filter((c) =>
    c.voteFinalized === true &&
    Number.isFinite(c.finalizedAtMs) &&
    now - c.finalizedAtMs <= WEEK_MS);
  if (recent.length === 0) return [];

  // Peers are matches that finished the same day.
  const byDay = new Map();
  for (const c of recent) {
    const key = dayKeyOf(c.finalizedAtMs);
    if (!byDay.has(key)) byDay.set(key, []);
    byDay.get(key).push(Number(c.voteCount) || 0);
  }
  const medians = new Map();
  for (const [key, votes] of byDay) medians.set(key, median(votes));

  return recent
      .map((c) => ({...c, score: captionScore(c, medians.get(dayKeyOf(c.finalizedAtMs)))}))
      // A match nobody judged at all is never worth captioning, however it
      // ranks in a quiet week.
      .filter((c) => (Number(c.voteCount) || 0) > 0)
      .sort((a, b) => b.score - a.score)
      .slice(0, Math.min(topN, budget));
}

/**
 * Whether a match is ready for its first, uncaptioned render.
 *
 * Pure so the rules can be tested without Firestore or ffmpeg - the same
 * approach that caught the tournament bye bug before it reached a device.
 */
function needsFirstRender(match) {
  if (!match) return false;
  if (match.status !== "completed") return false;
  if (!RECORDED_MODES.includes(match.mode)) return false;
  // Nothing to render until the recorder has actually produced files.
  if (!Array.isArray(match.recording?.files) || match.recording.files.length === 0) {
    return false;
  }
  if (match.highlight?.renditions) return false;
  if ((match.autoRender?.attempts ?? 0) >= MAX_ATTEMPTS) return false;
  return true;
}

/**
 * Whether an already-rendered clip has earned captions.
 *
 * Deliberately does NOT re-caption something already captioned, and does
 * not caption a match still waiting on its first render.
 */
/**
 * Whether a match is even a candidate for captions - the cheap checks,
 * before any ranking. Ranking decides which candidates actually win.
 */
function canBeCaptioned(match) {
  if (!match) return false;
  if (!match.highlight?.renditions) return false;
  // Paying for transcription twice on the same audio is pure waste.
  if (match.highlight.captioned === true) return false;
  if ((match.autoRender?.captionAttempts ?? 0) >= MAX_ATTEMPTS) return false;
  return true;
}

/**
 * An admin preparing a clip for external posting gets captions
 * immediately, without waiting to place in a ranking. That path is where
 * captions matter most - muted autoplay on social - and it is already
 * individually approved, so there is nothing to protect against.
 */
function captionsForced(match) {
  return canBeCaptioned(match) && match.highlight.captionRequested === true;
}

/**
 * One sweep: render what needs rendering, caption what has earned it.
 *
 * Failures are recorded on the match and swallowed, never thrown - one
 * unrenderable match must not stop every other match in the batch.
 */
async function sweepRenders({limit = RENDERS_PER_RUN} = {}) {
  const db = getFirestore();
  const {renderMatchHighlight} = require("./highlightRender");

  // Only completed matches can qualify, and there are far fewer of those
  // than of all matches. Filtering the rest in memory keeps this to one
  // index that already exists.
  const snap = await db.collection("matches")
      .where("status", "==", "completed")
      .orderBy("completedAt", "desc")
      .limit(60)
      .get();

  const now = Date.now();
  const first = [];
  const forced = [];
  const rankable = [];
  let captionedThisWeek = 0;

  for (const doc of snap.docs) {
    const match = doc.data();
    const finalizedAtMs = match.completedAt?.toMillis?.() ?? 0;
    if (match.highlight?.captioned === true && now - finalizedAtMs <= WEEK_MS) {
      captionedThisWeek += 1;
    }
    if (needsFirstRender(match)) {
      first.push(doc.id);
    } else if (captionsForced(match)) {
      forced.push(doc.id);
    } else if (canBeCaptioned(match)) {
      rankable.push({
        id: doc.id,
        voteCount: match.voteCount,
        voteFinalized: match.voteFinalized,
        player1FinalWeight: match.player1FinalWeight,
        player2FinalWeight: match.player2FinalWeight,
        finalizedAtMs,
      });
    }
  }

  const caption = [
    ...forced,
    ...selectForCaptioning(rankable, {now, captionedThisWeek}).map((c) => c.id),
  ];

  const results = {rendered: [], captioned: [], failed: []};

  for (const matchId of first.slice(0, limit)) {
    try {
      await db.collection("matches").doc(matchId).set({
        autoRender: {attempts: FieldValue.increment(1),
          lastAttemptAt: FieldValue.serverTimestamp()},
      }, {merge: true});
      await renderMatchHighlight(matchId, {captions: false});
      results.rendered.push(matchId);
    } catch (e) {
      results.failed.push({matchId, stage: "render", error: e.message});
      console.error(`auto-render failed for ${matchId}:`, e.message);
    }
  }

  // Captioning only gets whatever budget the first stage didn't use, so a
  // backlog of unwatchable matches always takes priority over polishing
  // ones that are already watchable.
  const captionBudget = Math.max(0, limit - results.rendered.length);
  for (const matchId of caption.slice(0, captionBudget)) {
    try {
      await db.collection("matches").doc(matchId).set({
        autoRender: {captionAttempts: FieldValue.increment(1),
          lastCaptionAttemptAt: FieldValue.serverTimestamp()},
      }, {merge: true});
      await renderMatchHighlight(matchId, {captions: true});
      results.captioned.push(matchId);
    } catch (e) {
      results.failed.push({matchId, stage: "caption", error: e.message});
      console.error(`auto-caption failed for ${matchId}:`, e.message);
    }
  }

  return {
    ...results,
    pendingRender: first.length,
    pendingCaption: caption.length,
  };
}

module.exports = {
  sweepRenders,
  needsFirstRender,
  canBeCaptioned,
  captionsForced,
  // Exported so the whole caption selection can be exercised without
  // Firestore, ffmpeg, or spending a penny on transcription.
  selectForCaptioning,
  captionScore,
  voteMargin,
  RENDERS_PER_RUN,
  MAX_ATTEMPTS,
  CAPTION_TOP_N,
  CAPTION_WEEKLY_CAP,
};
