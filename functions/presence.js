const {getDatabase} = require("firebase-admin/database");
const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {MODES, STALE_ENTRY_MS} = require("./matchmaking");
const {readEventWindowConfig, upcomingWindowDayKey} = require("./eventWindow");

/**
 * How many people are actually here right now.
 *
 * This is the highest-leverage piece of the Sixes and Sevens window, and
 * the reason is worth stating plainly: the objection to showing up is
 * almost never "I don't want to roast someone." It is "there won't be
 * anyone there." A real number answers that objection directly, and during
 * the window it answers it in the affirmative, which is the entire point of
 * concentrating everyone into one hour.
 *
 * It counts people WAITING TO BATTLE (in a matchmaking queue) and people
 * ALREADY IN ONE (paired, match not yet settled). Both are "here to
 * battle"; someone idly browsing the leaderboard is not, and counting them
 * would inflate the number into a lie. The number has to stay honest or it
 * stops doing its job the first time someone queues against it and finds
 * nobody.
 */

/** Entries this old were abandoned by a crashed or closed client and must
 * not be counted - a ghost entry inflating the number is exactly the kind
 * of dishonesty this feature cannot afford. Same threshold the pairing
 * logic uses to refuse to pair against them. */
const PRESENCE_STALE_MS = STALE_ENTRY_MS;

/**
 * Counts live queue entries out of a raw per-mode queue snapshot.
 *
 * Pure, so the counting rules can be tested without a database.
 */
function countQueue(queuesByMode, nowMs, staleMs = PRESENCE_STALE_MS) {
  let waiting = 0;
  let matched = 0;
  for (const queue of Object.values(queuesByMode || {})) {
    for (const entry of Object.values(queue || {})) {
      if (!entry || typeof entry !== "object") continue;
      const joinedAt = Number(entry.joinedAt) || 0;
      if (nowMs - joinedAt > staleMs) continue;
      if (entry.status === "matched") matched += 1;
      else if (entry.status === "waiting") waiting += 1;
    }
  }
  return {waiting, matched, total: waiting + matched};
}

/**
 * Reads the queues and publishes the count to `stats/presence`.
 *
 * WHY A SCHEDULED JOB rather than a callable clients poll, or a write on
 * every pairing poll:
 * - A callable costs one invocation per client per poll, so cost scales
 *   with users watching the number - the opposite of what's wanted during
 *   the traffic spike this feature exists to create.
 * - Writing from pollMatchmaking would fire every 3 seconds per waiting
 *   client. Twenty people queueing would be roughly 576k Firestore writes a
 *   day against a 20k/day free tier.
 * - A fixed once-a-minute job costs 1,440 writes a day whatever the user
 *   count, and every client reads it through one cheap snapshot listener.
 *
 * It also has no staleness hole: if everyone closes the app, the next tick
 * still publishes zero, whereas an activity-driven write would leave the
 * last non-zero number frozen on screen with nobody around.
 */
async function publishOnlineCount() {
  const db = getDatabase();
  const queuesByMode = {};
  for (const mode of MODES) {
    const snap = await db.ref(`matchmakingQueue/${mode}`).get();
    queuesByMode[mode] = snap.val() || {};
  }

  const counts = countQueue(queuesByMode, Date.now());
  const committed = await countCommitments();
  await getFirestore().collection("stats").doc("presence").set({
    ...counts,
    ...committed,
    updatedAt: FieldValue.serverTimestamp(),
  });
  return {...counts, ...committed};
}

/**
 * How many people have said they're in for tonight's window.
 *
 * Piggybacks on this once-a-minute job rather than getting its own,
 * because it publishes to the same document clients already listen to -
 * so a second number costs no extra write, no extra listener, and no extra
 * scheduled job. It also inherits the same honesty rule as the live count:
 * the figure is only worth showing while it's true.
 *
 * Uses an aggregation count() rather than reading the matching documents,
 * which stays cheap as the userbase grows - the whole point is that this
 * number gets larger.
 *
 * Best-effort: a failure here returns nothing rather than throwing, so a
 * broken commitment count never takes the live online count down with it.
 */
async function countCommitments(now = new Date()) {
  try {
    const db = getFirestore();
    const configSnap = await db.collection("config").doc("eventWindow").get();
    const config = readEventWindowConfig(configSnap.data());
    if (!config.enabled) return {};
    const dayKey = upcomingWindowDayKey(now, config);
    const agg = await db.collection("users")
        .where("eventCommitmentDayKey", "==", dayKey)
        .count().get();
    return {committedTonight: agg.data().count, commitmentDayKey: dayKey};
  } catch (e) {
    console.error("countCommitments failed:", e.message);
    return {};
  }
}

module.exports = {publishOnlineCount, countQueue, countCommitments, PRESENCE_STALE_MS};
