const {getFirestore} = require("firebase-admin/firestore");
const {tournamentMatchId} = require("./tournamentPlay");
const {isSettled} = require("./tournament");

/**
 * Telling people their tournament round has opened, and warning them
 * before it closes.
 *
 * WHY THIS MATTERS MORE HERE THAN ANYWHERE ELSE IN THE APP. Every other
 * notification is an invitation - miss it and you have simply missed a
 * battle. In an async bracket the penalty for missing a window is a
 * FORFEIT: you are out of the tournament, having paid to enter, without
 * ever playing. A round that opens silently is a trap.
 *
 * That justifies a second notification per round where vote reminders get
 * one a day, but it does NOT justify spamming: the closing warning goes
 * only to people who have not checked in, because someone who already
 * turned up is in no danger and chasing them is pure noise.
 */

/** How long before the window closes to send the warning. Long enough to
 * actually do something about it, short enough to feel urgent. */
const CLOSING_LEAD_MS = 2 * 60 * 60 * 1000;

/**
 * What this round needs sent right now, and to whom.
 *
 * Pure, so the whole schedule is testable without Firestore or a clock.
 *
 * `arrivedByMatchup[i]` is the set of uids who have started matchup i.
 */
function roundNotification({round, nowMs, arrivedByMatchup = {}, sent = {}}) {
  if (!round || !Array.isArray(round.matchups)) return null;
  const endMs = Number(round.windowEndMs);
  const startMs = Number(round.windowStartMs);

  // Everyone still due to play: settled matchups and byes are nobody's
  // problem, and a bye needs no warning about a match they will not play.
  const pending = [];
  round.matchups.forEach((m, i) => {
    if (isSettled(m) || m.isBye) return;
    for (const uid of [m.player1Id, m.player2Id]) {
      if (uid) pending.push({uid, matchupIndex: i});
    }
  });
  if (pending.length === 0) return null;

  if (Number.isFinite(endMs) && nowMs > endMs) return null;

  // The warning takes priority over the opening announcement. If a job
  // was down through the start of a round and recovers inside the last
  // two hours, "your round is open" is technically true and practically
  // useless - what they need is "play now or forfeit".
  if (Number.isFinite(endMs) && nowMs >= endMs - CLOSING_LEAD_MS) {
    if (sent.closing) return null;
    const recipients = pending
        .filter(({uid, matchupIndex}) =>
          !(arrivedByMatchup[matchupIndex] ?? new Set()).has(uid))
        .map(({uid}) => uid);
    // Everyone who could forfeit has already checked in, so there is
    // nobody left to warn.
    if (recipients.length === 0) return null;
    return {kind: "closing", recipients, endMs};
  }

  if (sent.opened) return null;
  if (Number.isFinite(startMs) && nowMs < startMs) return null;
  return {kind: "opened", recipients: pending.map(({uid}) => uid), endMs};
}

/** Copy for each kind. Says the consequence out loud, because a forfeit
 * is what is actually at stake and softening that would be a disservice. */
function notificationCopy(kind, {roundNumber, endMs, nowMs}) {
  const hours = Number.isFinite(endMs) ?
    Math.max(1, Math.round((endMs - nowMs) / 3600000)) : null;
  if (kind === "opened") {
    return {
      title: `Round ${roundNumber} is open`,
      body: hours ?
        `Your match is ready. You have about ${hours}h to play it.` :
        "Your match is ready to play.",
    };
  }
  return {
    title: "Your match closes soon",
    body: hours && hours > 1 ?
      `About ${hours}h left. Play it or you forfeit the round.` :
      "Less than an hour left. Play it or you forfeit the round.",
  };
}

/**
 * The scheduled sweep.
 *
 * Marks a kind as sent BEFORE sending, matching the event-window push:
 * missing one announcement costs a round, whereas repeating it is how an
 * app earns an OS-level mute, which silences every other category too.
 */
async function sweepTournamentNotifications(nowMs = Date.now()) {
  const db = getFirestore();
  const {sendToUsers} = require("./notifications");

  const snap = await db.collection("tournaments")
      .where("status", "==", "in_progress").get();

  const results = [];
  for (const doc of snap.docs) {
    try {
      const rounds = doc.data().bracket?.rounds;
      if (!Array.isArray(rounds) || rounds.length === 0) continue;
      const roundPos = rounds.length - 1;
      const round = rounds[roundPos];
      if (!round || !Array.isArray(round.matchups)) continue;

      // Who has already checked in, read from the real match documents -
      // the same signal the forfeit sweep judges on, so the warning goes
      // to exactly the people who are actually at risk.
      const arrivedByMatchup = {};
      await Promise.all(round.matchups.map(async (m, i) => {
        if (isSettled(m) || m.isBye) return;
        const matchSnap = await db.collection("matches")
            .doc(tournamentMatchId(doc.id, round.roundNumber, i)).get();
        arrivedByMatchup[i] = new Set(
            Object.keys(matchSnap.exists ?
              (matchSnap.data().arrivedAt ?? {}) : {}));
      }));

      const plan = roundNotification({
        round, nowMs, arrivedByMatchup, sent: round.notified ?? {},
      });
      if (!plan) continue;

      // Claimed first, by rewriting the whole rounds array - Firestore
      // cannot address an array element by dotted field path, and trying
      // corrupts the array rather than failing.
      const nextRounds = rounds.map((r, i) => i === roundPos ?
        {...r, notified: {...(r.notified ?? {}), [plan.kind]: true}} : r);
      await doc.ref.update({bracket: {rounds: nextRounds}});

      const userDocs = await Promise.all(plan.recipients.map((uid) =>
        db.collection("users").doc(uid).get()));
      const copy = notificationCopy(plan.kind, {
        roundNumber: round.roundNumber, endMs: plan.endMs, nowMs,
      });
      const result = await sendToUsers(userDocs.filter((d) => d.exists), {
        title: copy.title,
        body: copy.body,
        category: "tournament",
        data: {kind: "tournament_round", tournamentId: doc.id},
      });
      results.push({tournamentId: doc.id, kind: plan.kind,
        recipients: plan.recipients.length, sent: result?.sent ?? 0});
    } catch (e) {
      console.error(`tournament notify for ${doc.id} failed:`, e.message);
    }
  }
  return {notified: results.length, results};
}

module.exports = {
  sweepTournamentNotifications,
  roundNotification,
  notificationCopy,
  CLOSING_LEAD_MS,
};
