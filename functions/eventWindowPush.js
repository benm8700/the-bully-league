const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {sendToUsers} = require("./notifications");
const {readEventWindowConfig, pacificNow, upcomingWindowDayKey} = require("./eventWindow");

/**
 * The daily "it's starting" push for the prime-time window, plus a last
 * call before it closes.
 *
 * The window only works if people know it's happening, and the countdown on
 * Home only reaches people who already opened the app - which is precisely
 * the group that needs the least persuading. This is the part that reaches
 * everyone else.
 */

/** How long before the window closes the last-call nudge goes out. Long
 * enough to still play a match, short enough to feel urgent. */
const LAST_CALL_LEAD_MINUTES = 15;

// Config parsing and the Pacific clock live in eventWindow.js so the push
// and match qualification share one definition of the window rather than
// two that can drift apart.
const readConfig = readEventWindowConfig;

/**
 * Which notification, if any, is due right now.
 *
 * Pure so the schedule can be tested across a whole day without waiting for
 * one, and without any risk of a test actually pushing to real phones.
 *
 * Idempotency is the property that matters most here: this runs on a timer,
 * so without a record of what has already gone out it would re-send on
 * every tick. Nothing gets an app muted faster than the same notification
 * twice, and a muted user is lost for every future category too.
 */
function pushDecision({nowMinutes, startMinutes, endMinutes, sentKinds = [], leadMinutes = LAST_CALL_LEAD_MINUTES}) {
  if (nowMinutes < startMinutes || nowMinutes >= endMinutes) return null;

  // Past the lead point, "starting now" would be actively misleading for a
  // window that is nearly over - so the last call supersedes it rather than
  // both firing in quick succession if the job was late or recovering.
  if (nowMinutes >= endMinutes - leadMinutes) {
    return sentKinds.includes("last_call") ? null : "last_call";
  }
  return sentKinds.includes("start") ? null : "start";
}

/**
 * Notification copy.
 *
 * `committed` gives people who tapped "I'm in tonight" a different line
 * that references their own promise. That is the entire mechanism
 * pre-commitment relies on - an intention only raises follow-through if
 * something reminds you that you made it - and it costs one extra send.
 * Without it, someone who deliberately opted in gets the same generic
 * broadcast as someone who never engaged, which wastes the strongest
 * signal the app has about who actually intends to show up.
 */
function copyFor(kind, config, onlineCount, {committed = false} = {}) {
  const people = (n) => `${n} ${n === 1 ? "roaster is" : "roasters are"}`;

  if (kind === "last_call") {
    if (committed) {
      return {
        title: `${config.name} closes soon`,
        body: onlineCount > 0 ?
          `You said you were in. ${people(onlineCount)} still on - one more battle?` :
          "You said you were in. Still time for one battle.",
      };
    }
    return {
      title: `Last call for ${config.name}`,
      body: onlineCount > 0 ?
        `${people(onlineCount)} still on. Time for one more battle.` :
        "It closes soon - time for one more battle.",
    };
  }

  if (committed) {
    return {
      title: `${config.name} starts now`,
      body: onlineCount > 0 ?
        `You said you'd be here. So ${onlineCount === 1 ? "is" : "are"} ${onlineCount} other${onlineCount === 1 ? "" : "s"}.` :
        "You said you'd be here. Go get someone.",
    };
  }
  return {
    title: `${config.name} starts now`,
    body: onlineCount > 0 ?
      `${people(onlineCount)} already on. Come get someone.` :
      "The busiest hour of the day. Come get someone.",
  };
}

/**
 * Runs on a timer, sends at most one notification per kind per Pacific day.
 *
 * POLLED rather than pinned to a 6pm cron because the window's hours live
 * in Firestore and are explicitly provisional - a cron would be fixed at
 * deploy time, so retuning the hours from the console would silently leave
 * the push firing at the old one. Polling costs a few hundred no-op
 * invocations a day, which is nothing, and keeps one source of truth.
 */
async function sendEventWindowPush(now = new Date()) {
  const db = getFirestore();
  const configSnap = await db.collection("config").doc("eventWindow").get();
  const config = readConfig(configSnap.data());
  if (!config.enabled) return {skipped: "disabled"};

  const {dayKey, minutes} = pacificNow(now);
  const stateRef = db.collection("stats").doc("eventWindowPush");
  const state = (await stateRef.get()).data() ?? {};
  // A record from a previous day says nothing about today.
  const sentKinds = state.dayKey === dayKey ? (state.sentKinds ?? []) : [];

  const kind = pushDecision({
    nowMinutes: minutes,
    startMinutes: config.startHourPacific * 60,
    endMinutes: config.endHourPacific * 60,
    sentKinds,
  });
  if (!kind) return {skipped: "nothing-due", dayKey, minutes};

  // Claim BEFORE sending. A duplicate push is worse than a missed one: the
  // cost of missing is one quiet evening, the cost of duplicating is
  // someone muting the app permanently.
  await stateRef.set({
    dayKey,
    sentKinds: FieldValue.arrayUnion(kind),
    lastAttemptAt: FieldValue.serverTimestamp(),
  }, {merge: true});

  const presence = (await db.collection("stats").doc("presence").get()).data();
  const onlineCount = Number(presence?.total) || 0;

  // Everyone with at least one registered device. Preference filtering
  // happens in sendToUsers, which also prunes dead tokens.
  const users = await db.collection("users").where("fcmTokens", "!=", null).get();

  // Split so people who tapped "I'm in tonight" get copy that references
  // their own promise. Two sends rather than one; the extra call is
  // trivial next to the point of pre-commitment existing at all.
  const commitmentKey = upcomingWindowDayKey(now, config);
  const committed = [];
  const everyoneElse = [];
  for (const doc of users.docs) {
    (doc.data()?.eventCommitmentDayKey === commitmentKey ? committed : everyoneElse)
        .push(doc);
  }

  const [committedResult, generalResult] = await Promise.all([
    committed.length === 0 ? {sent: 0, failed: 0, recipients: 0} :
      sendToUsers(committed, {
        ...copyFor(kind, config, onlineCount, {committed: true}),
        category: "event_window",
        data: {kind, committed: "true"},
      }),
    everyoneElse.length === 0 ? {sent: 0, failed: 0, recipients: 0} :
      sendToUsers(everyoneElse, {
        ...copyFor(kind, config, onlineCount),
        category: "event_window",
        data: {kind},
      }),
  ]);

  const result = {
    sent: committedResult.sent + generalResult.sent,
    failed: committedResult.failed + generalResult.failed,
    recipients: committedResult.recipients + generalResult.recipients,
    committedRecipients: committedResult.recipients,
  };

  // Recorded on the marker so the outcome of a send is inspectable without
  // Cloud Logging access. A scheduled push has no user watching it fail,
  // so "it silently sent to nobody" is otherwise indistinguishable from
  // "it worked" - which is exactly how the MODES export bug hid.
  await stateRef.set({lastResult: {kind, ...result}}, {merge: true});

  return {kind, dayKey, onlineCount, ...result};
}

module.exports = {
  sendEventWindowPush,
  pushDecision,
  pacificNow,
  readConfig,
  copyFor,
  LAST_CALL_LEAD_MINUTES,
};
