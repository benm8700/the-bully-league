const {getFirestore, FieldValue, Timestamp} = require("firebase-admin/firestore");
const {pacificNow} = require("./eventWindow");

/**
 * The weekly recap: one push a week telling a player what they actually
 * did (CLAUDE.md's Weekly recap notification decision, whose content was
 * left "not yet detailed").
 *
 * THE RULE THAT SHAPES EVERYTHING ELSE: NEVER SEND AN EMPTY ONE. A recap
 * reading "0 battles, 0 wins" is not a summary, it is a notification
 * telling somebody they were absent - which is a reason to mute the app,
 * not to open it. So this only goes to people who did something. That
 * costs reach and buys the only thing that matters here, which is that
 * every recap anyone receives is worth receiving.
 *
 * JUDGING COUNTS AS DOING SOMETHING. Someone who cast twenty votes and
 * played nothing had a real week in this app - votes are the scarce
 * resource the whole ladder runs on, and a recap that only recognised
 * battling would tell the most useful people in the app that they did
 * nothing.
 *
 * Built on the POINTS LEDGER rather than on match documents, which is
 * what makes it one query per person instead of several: the ledger
 * already records every battle played, every win, every vote and every
 * award, each with a timestamp, because it exists to make awards
 * idempotent. A recap is just that ledger read back.
 */

/** How many people one run will message. A bug is far better discovered
 * at this size than at userbase size - the same reason the vote reminder
 * sweep is capped. */
const MAX_RECIPIENTS = 200;

/** Sent Sunday evening Pacific, shortly before the daily window opens.
 * A recap is a nudge back into the app, so it should land when there is
 * somewhere to go: Sixes and Sevens starts at 18:00, and this arrives
 * while the week is ending and the evening has not. */
const SEND_DAY = 0; // Sunday
const SEND_HOUR_MIN = 17 * 60;
const SEND_HOUR_MAX = 19 * 60;

/**
 * The Pacific week a moment belongs to, identified by the date of its
 * Sunday.
 *
 * Keyed by week rather than by date so the idempotency marker survives
 * the job running more than once in the sending window - which it will,
 * because the schedule is a poll rather than an exact cron.
 */
function pacificWeekKey(date) {
  const {dayKey} = pacificNow(date);
  const [y, m, d] = dayKey.split("-").map(Number);
  // Constructed in UTC purely as calendar arithmetic on the Pacific date;
  // no timezone conversion is happening here, so this cannot drift.
  const asUtc = new Date(Date.UTC(y, m - 1, d));
  const sunday = new Date(asUtc);
  sunday.setUTCDate(asUtc.getUTCDate() - asUtc.getUTCDay());
  return sunday.toISOString().slice(0, 10);
}

/** Whether now is inside the Sunday-evening sending window. */
function inSendWindow(date) {
  const {dayKey, minutes} = pacificNow(date);
  const [y, m, d] = dayKey.split("-").map(Number);
  const weekday = new Date(Date.UTC(y, m - 1, d)).getUTCDay();
  return weekday === SEND_DAY &&
    minutes >= SEND_HOUR_MIN && minutes < SEND_HOUR_MAX;
}

/**
 * Turns a week of ledger entries into the numbers a recap talks about.
 *
 * PURE, so the copy rules can be tested without Firestore or a clock.
 */
function summarise(entries) {
  const out = {matchesPlayed: 0, wins: 0, votesCast: 0, pointsEarned: 0};
  for (const e of entries) {
    const amount = Number(e?.amount) || 0;
    // Spends are negative and are not "earned" - counting them would
    // report a week of buying things as a week of achievement.
    if (amount > 0) out.pointsEarned += amount;
    switch (e?.reason) {
      case "match_played": out.matchesPlayed += 1; break;
      case "match_won": out.wins += 1; break;
      case "vote_cast": out.votesCast += 1; break;
      default: break;
    }
  }
  return out;
}

/** Did this person actually do anything worth telling them about? */
function worthSending(summary) {
  return (summary?.matchesPlayed ?? 0) > 0 || (summary?.votesCast ?? 0) > 0;
}

/**
 * The recap copy.
 *
 * LEADS WITH WHATEVER THEY ACTUALLY DID, rather than a fixed template
 * with zeroes in it. Someone who only judged hears about judging; someone
 * who only battled hears about battling. A single template would tell
 * half its readers what they did not do.
 *
 * Pure.
 */
function recapCopy(summary, {windowName = "Sixes and Sevens"} = {}) {
  const {matchesPlayed, wins, votesCast, pointsEarned} = summary;
  const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`;

  let body;
  if (matchesPlayed > 0 && votesCast > 0) {
    body = `${plural(matchesPlayed, "battle", "battles")}, ` +
      `${plural(wins, "win", "wins")}, and you judged ` +
      `${plural(votesCast, "other", "others")}.`;
  } else if (matchesPlayed > 0) {
    body = wins === matchesPlayed && wins > 0 ?
      `${plural(matchesPlayed, "battle", "battles")}, and you won every one.` :
      `${plural(matchesPlayed, "battle", "battles")}, ` +
        `${plural(wins, "win", "wins")}.`;
  } else {
    // Judging-only, and said as a contribution rather than a consolation.
    body = `You judged ${plural(votesCast, "battle", "battles")}. ` +
      "Those results only count because somebody watched them.";
  }

  if (pointsEarned > 0) body += ` ${pointsEarned} points earned.`;
  return {
    title: "Your week in The Bully League",
    body: `${body} ${windowName} is on tonight at 6.`,
  };
}

/**
 * Sends the week's recaps.
 *
 * Idempotent on a marker keyed by Pacific week, CLAIMED BEFORE SENDING -
 * missing one week costs a nudge, sending twice is how an app earns an
 * OS-level mute that silences every other category too.
 */
async function sweepWeeklyRecap({force = false, now = new Date()} = {}) {
  const db = getFirestore();
  if (!force && !inSendWindow(now)) {
    return {skipped: "outside-send-window"};
  }

  const weekKey = pacificWeekKey(now);
  const markerRef = db.collection("stats").doc("weeklyRecap");
  const marker = await markerRef.get();
  if (!force && marker.data()?.weekKey === weekKey) {
    return {skipped: "already-sent", weekKey};
  }

  // Claimed first, deliberately.
  await markerRef.set({weekKey, startedAt: FieldValue.serverTimestamp()},
      {merge: true});

  const weekStart = Timestamp.fromMillis(
      now.getTime() - 7 * 24 * 60 * 60 * 1000);

  const users = await db.collection("users").limit(MAX_RECIPIENTS).get();
  const recipients = [];
  const summaries = new Map();

  for (const doc of users.docs) {
    const ledger = await doc.ref.collection("pointsLedger")
        .where("createdAt", ">=", weekStart).get();
    const summary = summarise(ledger.docs.map((d) => d.data()));
    if (!worthSending(summary)) continue;
    recipients.push(doc.id);
    summaries.set(doc.id, summary);
  }

  if (recipients.length === 0) {
    await markerRef.set({lastResult: {sent: 0, reason: "nobody-qualified"}},
        {merge: true});
    return {weekKey, sent: 0, reason: "nobody-qualified"};
  }

  // One message per person, because the whole point is that it describes
  // THEIR week - a multicast would have to say something generic, which is
  // the empty recap this design exists to avoid.
  const {sendToUsers} = require("./notifications");
  let sent = 0;
  let failed = 0;
  for (const uid of recipients) {
    try {
      const copy = recapCopy(summaries.get(uid));
      const result = await sendToUsers([uid], {
        category: "weekly_recap",
        title: copy.title,
        body: copy.body,
        data: {kind: "weekly_recap", weekKey},
      });
      sent += result?.sent ?? 0;
    } catch (e) {
      failed += 1;
      console.error(`weekly recap for ${uid} failed:`, e.message);
    }
  }

  // Recorded so a scheduled send's outcome is inspectable without log
  // access - "silently sent to nobody" is otherwise indistinguishable
  // from "worked".
  await markerRef.set({
    lastResult: {sent, failed, candidates: recipients.length},
    finishedAt: FieldValue.serverTimestamp(),
  }, {merge: true});

  return {weekKey, sent, failed, candidates: recipients.length};
}

module.exports = {
  sweepWeeklyRecap,
  // Pure, exported for tests.
  pacificWeekKey,
  inSendWindow,
  summarise,
  worthSending,
  recapCopy,
  MAX_RECIPIENTS,
};
