const {getFirestore} = require("firebase-admin/firestore");

/**
 * Nudges people to judge battles that are still open.
 *
 * WHY THIS IS WORTH A NOTIFICATION AT ALL: votes are the scarce resource
 * the whole ladder runs on. Rating only moves as far as a match is
 * actually judged, and vote confidence discounts a thinly-judged result -
 * so an unjudged battle is not merely unwatched, it is a match that
 * barely counted for the two people who played it.
 *
 * THE REAL RISK HERE IS FATIGUE, not under-sending. CLAUDE.md is explicit
 * that repeated notifications are how an app earns an OS-level block,
 * which silences EVERY category and cannot be undone or even detected
 * from inside the app. So the design is deliberately conservative:
 *
 *   - at most ONE vote reminder per person per day, whatever is happening
 *   - nothing at all when there is nothing genuinely worth judging
 *   - never during Sixes and Sevens, where the event push already fired
 *     and people are battling rather than scrolling
 *   - a cap per run, so one busy evening cannot mail the whole userbase
 *
 * CLAUDE.md's decision asks for "periodic nudges throughout the 24-hour
 * voting window (not just a single reminder)". That is satisfied by the
 * SWEEP being periodic - it catches matches whenever they become urgent -
 * rather than by any one person being pushed repeatedly.
 */

/** How often the sweep runs. Matches close on a rolling basis, so this
 * only needs to be fine enough to catch a match before its window shuts. */
const SWEEP_MINUTES = 120;

/** Nobody gets more than this many vote reminders in a day. One. */
const MAX_PER_USER_PER_DAY = 1;

/** Recipients per run. Bounds both the reads and the blast radius of a
 * mistake - a bug that sent to everyone would be discovered at this size
 * rather than at userbase size. */
const RECIPIENTS_PER_RUN = 200;

/** A match with at least this many votes is already being judged, so it
 * is not a reason to interrupt anyone. */
const WELL_JUDGED_VOTES = 8;

/** Inside this much of closing, a match is genuinely urgent - after this
 * point nobody can rescue it. */
const CLOSING_SOON_MS = 6 * 60 * 60 * 1000;

/**
 * Which open matches actually justify a notification.
 *
 * A battle that already has plenty of votes does not need rescuing, and a
 * battle with a full day left can be rescued later - so neither is worth
 * spending someone's attention on. What is worth it is a battle that is
 * both under-judged AND running out of time.
 *
 * Pure, so the whole judgement is testable without Firestore or a clock.
 */
function matchesWorthNudging(matches, nowMs) {
  return matches.filter((m) => {
    if (m.voteFinalized === true) return false;
    if (m.status !== "completed") return false;
    const remaining = m.windowEndMs - nowMs;
    if (remaining <= 0) return false;
    const votes = Number(m.voteCount) || 0;
    if (votes >= WELL_JUDGED_VOTES) return false;
    return remaining <= CLOSING_SOON_MS;
  });
}

/**
 * What to say, given what is actually waiting.
 *
 * Leads with the number, because "5 battles need a verdict" is a concrete
 * claim someone can act on, where "come and vote" is a request. Names the
 * cost too - judging is genuinely quick, and saying so is the difference
 * between a nudge and a chore.
 *
 * Returns null when there is nothing honest to say. A reminder sent on an
 * empty night teaches people the notification is noise.
 */
function reminderCopy(matchCount, {reciprocal = false} = {}) {
  if (matchCount <= 0) return null;
  if (reciprocal) {
    // NO COUNT in this variant, deliberately. One multicast carries one
    // body, but each participant's honest number differs - they cannot
    // judge their own battle, so a shared figure would overstate it for
    // whoever has two open. Better to say something true without a number
    // than something specific and slightly wrong.
    return {
      title: "Your battle is being judged",
      body: "Return the favour - other battles are close to a verdict. " +
        "Takes about a minute.",
    };
  }
  const battles = matchCount === 1 ? "1 battle" : `${matchCount} battles`;
  return {
    title: matchCount === 1 ? "A battle needs a verdict" : `${battles} need a verdict`,
    body: "Closing soon and barely judged. Pick a winner in about a minute.",
  };
}

/**
 * The reminder record to write for a user, given what they already have.
 *
 * Written absolutely rather than with an increment, because an increment
 * carries yesterday's count into today: a user who was reminded once
 * yesterday would land on 2 today and be blocked for the rest of it. The
 * same class of bug as reading a missing field as zero.
 *
 * Pure.
 */
function nextReminderRecord(user, dayKey) {
  const record = user?.voteReminder;
  const sameDay = record?.dayKey === dayKey;
  return {dayKey, count: (sameDay ? Number(record.count) || 0 : 0) + 1};
}

/**
 * Whether this user may be sent a vote reminder right now.
 *
 * Pure. The day key is passed in rather than computed so the caller can
 * use one consistent Pacific day across the whole sweep.
 */
function canRemind(user, dayKey) {
  if (!user) return false;
  // An explicitly non-active account is not someone to chase.
  if ((user.accountStatus ?? "active") !== "active") return false;
  if (!Array.isArray(user.fcmTokens) || user.fcmTokens.length === 0) return false;
  const record = user.voteReminder;
  if (!record || record.dayKey !== dayKey) return true;
  return (Number(record.count) || 0) < MAX_PER_USER_PER_DAY;
}

/**
 * The scheduled sweep.
 *
 * Skips entirely during the prime-time window: the event push has already
 * fired that hour, people are there to battle, and stacking a second
 * notification on top is exactly the pattern that gets an app muted.
 */
async function sweepVoteReminders(nowMs = Date.now()) {
  const db = getFirestore();
  const {readEventWindowConfig, isWithinWindow} = require("./eventWindow");
  const {pacificNow} = require("./eventWindow");
  const {sendToUsers} = require("./notifications");
  const {voteWindowEndMs} = require("./matchFinalization");

  const windowConfig = await db.collection("config").doc("eventWindow").get()
      .then((s) => readEventWindowConfig(s.data()))
      .catch(() => ({enabled: false}));
  if (isWithinWindow(new Date(nowMs), windowConfig)) {
    return {skipped: "event-window"};
  }

  // Only matches that finished recently can still be open, so the scan is
  // bounded by time rather than by collection size.
  // Ordered explicitly so this reuses the existing status+completedAt
  // index rather than needing a new one. Without the orderBy, Firestore
  // wants an ascending variant it does not have - and the failure would
  // have been swallowed by the scheduler's own catch and shown up as a
  // job that silently did nothing every run.
  const since = new Date(nowMs - 25 * 60 * 60 * 1000);
  const snap = await db.collection("matches")
      .where("status", "==", "completed")
      .where("completedAt", ">=", since)
      .orderBy("completedAt", "desc")
      .get();

  const open = snap.docs.map((d) => ({
    id: d.id,
    ...d.data(),
    windowEndMs: voteWindowEndMs(d.data()),
  }));
  const worth = matchesWorthNudging(open, nowMs);
  if (worth.length === 0) return {skipped: "nothing-urgent", scanned: open.length};

  const dayKey = pacificNow(new Date(nowMs)).dayKey;

  // Participants in the urgent matches get the reciprocal framing, which
  // is both more persuasive and more honest - they have something being
  // judged right now, and they cannot judge their own.
  const participants = new Set();
  for (const m of worth) {
    if (m.player1Id) participants.add(m.player1Id);
    if (m.player2Id) participants.add(m.player2Id);
  }

  // NOT filtered by notification preference in the query. A Firestore
  // `!= false` matches only documents where the field EXISTS, so it would
  // silently exclude every account with no preferences map - which is the
  // majority, and which the notification layer documents as opted IN.
  // Exactly the missing-field trap this project has now hit four times.
  // sendToUsers honours the preference itself, so the filtering happens
  // where it is correct.
  const users = await db.collection("users")
      .limit(RECIPIENTS_PER_RUN * 3)
      .get();

  const eligible = users.docs.filter((d) => canRemind(d.data(), dayKey));
  if (eligible.length === 0) return {skipped: "nobody-eligible", urgent: worth.length};

  let sent = 0;
  let failed = 0;
  for (const group of [true, false]) {
    const batch = eligible
        .filter((d) => participants.has(d.id) === group)
        .slice(0, RECIPIENTS_PER_RUN);
    if (batch.length === 0) continue;

    const copy = reminderCopy(worth.length, {reciprocal: group});
    if (!copy) continue;

    const result = await sendToUsers(batch, {
      title: copy.title,
      body: copy.body,
      category: "vote_reminder",
      data: {kind: "vote_reminder"},
    });
    sent += result?.sent ?? 0;
    failed += result?.failed ?? 0;

    // Recorded AFTER sending, unlike the event-window push. There the
    // risk was duplication from a repeating timer; here a failed send
    // should be retryable on the next sweep rather than silently burning
    // someone's one reminder for the day.
    await Promise.all(batch.map((d) => d.ref.set({
      voteReminder: nextReminderRecord(d.data(), dayKey),
    }, {merge: true}).catch(() => {})));
  }

  return {urgent: worth.length, recipients: eligible.length, sent, failed};
}

module.exports = {
  sweepVoteReminders,
  nextReminderRecord,
  matchesWorthNudging,
  reminderCopy,
  canRemind,
  SWEEP_MINUTES,
  MAX_PER_USER_PER_DAY,
  RECIPIENTS_PER_RUN,
  WELL_JUDGED_VOTES,
  CLOSING_SOON_MS,
};
