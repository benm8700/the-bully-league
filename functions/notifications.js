const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {getMessaging} = require("firebase-admin/messaging");

/**
 * Shared push plumbing: per-category mute preferences and fan-out with
 * dead-token pruning.
 *
 * Categories are the unit users can mute (CLAUDE.md's per-category toggle
 * decision - "users can mute vote reminders while keeping match-found
 * alerts on"). A single global on/off is the thing that gets switched off
 * permanently after one annoying notification, taking the useful ones with
 * it, so the granularity is the point.
 */

/** Every category a user can mute. Match-found is deliberately included:
 * it is the most useful notification in the app, but forcing it on anyone
 * is how an app earns a system-level block, which silences everything. */
const CATEGORIES = ["match_found", "event_window", "vote_reminder", "tournament", "rank_change"];

/** FCM's documented per-request ceiling for multicast sends. */
const MULTICAST_LIMIT = 500;

/**
 * Whether this user still wants this category.
 *
 * Absent preferences mean opted IN, so existing accounts - which have no
 * preferences map at all - keep receiving notifications rather than going
 * silent the moment this ships. That's the same trap as the missing
 * `accountStatus` bug that locked pre-existing accounts out of
 * matchmaking, and it's avoided the same way: treat absent as the
 * permissive default, and only an explicit `false` as opting out.
 */
function wantsCategory(user, category) {
  const prefs = user?.notificationPrefs;
  if (!prefs || typeof prefs !== "object") return true;
  return prefs[category] !== false;
}

/**
 * Sends one notification to many users, honouring their preferences and
 * pruning tokens FCM reports as permanently dead.
 *
 * Returns counts rather than throwing: every caller here is best-effort,
 * and a push failing must never fail the thing that triggered it.
 */
async function sendToUsers(userDocs, {title, body, category, data = {}}) {
  const db = getFirestore();
  const targets = [];
  for (const doc of userDocs) {
    const user = doc.data();
    if (!wantsCategory(user, category)) continue;
    const tokens = user?.fcmTokens ?? [];
    for (const token of tokens) targets.push({token, uid: doc.id});
  }
  if (targets.length === 0) return {sent: 0, failed: 0, recipients: 0};

  let sent = 0;
  let failed = 0;
  const deadByUid = new Map();

  for (let i = 0; i < targets.length; i += MULTICAST_LIMIT) {
    const batch = targets.slice(i, i + MULTICAST_LIMIT);
    const response = await getMessaging().sendEachForMulticast({
      tokens: batch.map((t) => t.token),
      notification: {title, body},
      data: {category, ...data},
      android: {priority: "high"},
    });
    sent += response.successCount;
    failed += response.failureCount;

    response.responses.forEach((r, idx) => {
      const code = r.error?.code;
      if (code === "messaging/registration-token-not-registered" ||
          code === "messaging/invalid-registration-token") {
        const {uid, token} = batch[idx];
        if (!deadByUid.has(uid)) deadByUid.set(uid, []);
        deadByUid.get(uid).push(token);
      }
    });
  }

  // Left in place, dead tokens accumulate forever and every future send
  // wastes work on them.
  for (const [uid, tokens] of deadByUid) {
    await db.collection("users").doc(uid)
        .update({fcmTokens: FieldValue.arrayRemove(...tokens)})
        .catch(() => {});
  }

  return {sent, failed, recipients: targets.length};
}

module.exports = {CATEGORIES, wantsCategory, sendToUsers, MULTICAST_LIMIT};
