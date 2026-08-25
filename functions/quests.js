const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {HttpsError} = require("firebase-functions/v2/https");
const {pacificNow} = require("./eventWindow");

/**
 * Daily quests: three small, concrete things to do today.
 *
 * WHY THEY EARN THEIR PLACE when a career-title ladder did not. Quests
 * feed the points economy that already exists rather than standing beside
 * it as a second scoreboard - there is no new title, no new rank, nothing
 * extra to keep track of. What they add is DIRECTION: the app currently
 * answers "am I any good" but never "what should I do right now", and
 * opening an app with no obvious next action is how a session becomes a
 * thirty-second visit.
 *
 * DELIBERATELY WEIGHTED TOWARD JUDGING. Votes are the scarce resource the
 * ladder runs on and the thing players are least naturally inclined to
 * do, so the quest that always appears is a judging one. Battling needs
 * no encouragement; judging somebody else's battle does.
 *
 * THE SAME SET FOR EVERYONE EACH DAY, chosen deterministically from the
 * Pacific day key. Two reasons: it is something players can talk about
 * ("did you get the win-three one"), and it makes the day's difficulty a
 * single knowable thing rather than a per-user lottery nobody can support.
 */

/**
 * PLACEHOLDER definitions, in the same sense as the rank thresholds and
 * the clip price - the shapes are considered, the numbers want real
 * playtesting. Rewards are modest on purpose: a quest should be a nudge
 * toward what you were going to do anyway, not a second job that
 * out-earns actually playing.
 */
const QUESTS = {
  judge3: {id: "judge3", metric: "votes", target: 3, reward: 20,
    label: "Judge 3 battles"},
  judge5: {id: "judge5", metric: "votes", target: 5, reward: 35,
    label: "Judge 5 battles"},
  judge1: {id: "judge1", metric: "votes", target: 1, reward: 10,
    label: "Judge a battle"},
  play1: {id: "play1", metric: "matches", target: 1, reward: 15,
    label: "Play a battle"},
  play2: {id: "play2", metric: "matches", target: 2, reward: 30,
    label: "Play 2 battles"},
  win1: {id: "win1", metric: "wins", target: 1, reward: 25,
    label: "Win a battle"},
};

/** One judging quest, one playing quest, one stretch. Fixed shape so a
 * day can never be all-judging or all-winning. */
const SLOTS = [
  ["judge1", "judge3", "judge5"],
  ["play1", "play2"],
  ["win1", "judge3", "play2"],
];

/** Stable small hash of a day key, so the rotation is deterministic
 * without a stored seed and without Math.random. */
function daySeed(dayKey) {
  let h = 0;
  for (const ch of String(dayKey)) h = (h * 31 + ch.charCodeAt(0)) % 100000;
  return h;
}

/**
 * The three quests for a given Pacific day.
 *
 * Pure, so a whole week of rotations can be inspected without a clock.
 */
function questsForDay(dayKey) {
  const seed = daySeed(dayKey);
  const picked = [];
  const usedMetrics = new Set();

  for (let slot = 0; slot < SLOTS.length; slot++) {
    const options = SLOTS[slot];
    // THE STRETCH SLOT MUST NOT REPEAT A METRIC ALREADY CHOSEN.
    //
    // Its options deliberately overlap the earlier slots so the day has
    // some variety, but nothing stopped it drawing the same metric
    // twice. Seen live: judge5 + play2 + judge3, so two of the three
    // quests were judging - and judge3 is strictly CONTAINED in judge5,
    // so judging five completed both. Three quests that are really two,
    // which reads as the feature being broken rather than generous.
    const fresh = options.filter((id) => !usedMetrics.has(QUESTS[id].metric));
    // Falling back to the full list rather than to nothing: a repeated
    // metric is a poor day, an empty slot is a bug.
    const pool = fresh.length > 0 ? fresh : options;
    const chosen = QUESTS[pool[(seed + slot * 7) % pool.length]];
    usedMetrics.add(chosen.metric);
    picked.push(chosen);
  }
  return picked;
}

/**
 * Applies one event to a day's progress and reports what just completed.
 *
 * Pure. Returns the new state plus the quests that crossed their target
 * on THIS event, so a completion is announced exactly once rather than
 * re-detected on every subsequent event.
 */
function applyProgress(state, dayKey, metric, quests = questsForDay(dayKey)) {
  const fresh = state?.dayKey === dayKey ? state : {dayKey, counts: {}, done: []};
  const counts = {...(fresh.counts ?? {})};
  const done = [...(fresh.done ?? [])];
  counts[metric] = (Number(counts[metric]) || 0) + 1;

  const completed = [];
  for (const quest of quests) {
    if (done.includes(quest.id)) continue;
    if ((Number(counts[quest.metric]) || 0) >= quest.target) {
      done.push(quest.id);
      completed.push(quest);
    }
  }
  return {state: {dayKey, counts, done}, completed};
}

/** How a day's progress reads to the player. Pure. */
function questView(state, dayKey) {
  const quests = questsForDay(dayKey);
  const counts = state?.dayKey === dayKey ? (state.counts ?? {}) : {};
  const done = state?.dayKey === dayKey ? (state.done ?? []) : [];
  return quests.map((q) => ({
    id: q.id,
    label: q.label,
    target: q.target,
    reward: q.reward,
    // Capped at the target so a finished quest never reads "5 / 3".
    progress: Math.min(Number(counts[q.metric]) || 0, q.target),
    done: done.includes(q.id),
  }));
}

/**
 * Records one event against today's quests and pays anything completed.
 *
 * Best-effort: a quest failure must never fail the vote or match that
 * triggered it. The award goes through the same idempotent ledger as
 * everything else, keyed by day and quest, so a retry cannot double-pay.
 */
async function recordQuestEvent(uid, metric, {nowMs = Date.now()} = {}) {
  try {
    const db = getFirestore();
    const dayKey = pacificNow(new Date(nowMs)).dayKey;
    const ref = db.collection("users").doc(uid)
        .collection("quests").doc(dayKey);

    const {completed} = await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      const result = applyProgress(snap.data(), dayKey, metric);
      tx.set(ref, result.state);
      return result;
    });
    if (completed.length === 0) return {completed: []};

    const {awardPoints} = require("./points");
    let awarded = 0;
    for (const quest of completed) {
      const r = await awardPoints(uid, {
        reason: "quest",
        sourceId: `${dayKey}_${quest.id}`,
        amount: quest.reward,
      });
      awarded += r.awarded;
    }
    return {completed: completed.map((q) => q.label), awarded};
  } catch (e) {
    console.error(`quest ${metric} for ${uid} failed:`, e.message);
    return {completed: []};
  }
}

async function getMyQuests(auth, data) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const dayKey = pacificNow(new Date(Number(data?.nowMs) || Date.now())).dayKey;
  const snap = await getFirestore().collection("users").doc(auth.uid)
      .collection("quests").doc(dayKey).get();
  return {dayKey, quests: questView(snap.data(), dayKey)};
}

module.exports = {
  recordQuestEvent, getMyQuests, questsForDay, applyProgress, questView,
  daySeed, QUESTS, SLOTS,
};
