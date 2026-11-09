const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {getMessaging} = require("firebase-admin/messaging");
const {onDocumentWritten} = require("firebase-functions/v2/firestore");

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
const CATEGORIES = ["match_found", "event_window", "vote_reminder", "tournament", "rank_change", "weekly_recap", "followed_performer", "daily_reward", "prize_won", "main_stage", "clip_reminder"];

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
/**
 * Accepts either user document snapshots or plain uid strings.
 *
 * THREE CALLERS GOT THIS WRONG before it was tolerant, which makes it an
 * API problem rather than three mistakes. Passing a uid threw "doc.data
 * is not a function" inside the caller's try/catch, so the push simply
 * never arrived and nothing surfaced it - the friend-challenge
 * notification, which is how somebody learns they were challenged at all,
 * had never once fired.
 *
 * Fetching here rather than demanding snapshots also puts the read where
 * it is cheapest to reason about: a caller that already holds the
 * document passes it and pays nothing extra.
 */
async function resolveUserDocs(userDocsOrIds) {
  const db = getFirestore();
  const out = [];
  for (const entry of userDocsOrIds) {
    if (typeof entry === "string") {
      const snap = await db.collection("users").doc(entry).get();
      if (snap.exists) out.push(snap);
    } else if (entry && typeof entry.data === "function") {
      out.push(entry);
    }
    // Anything else is silently skipped: a malformed recipient must never
    // stop the rest of a batch being notified.
  }
  return out;
}

/**
 * Flattens recipients into one {token, uid} per DEVICE.
 *
 * A token identifies a phone, not an account. Before this, one iPhone that
 * had been signed into three accounts carried the same token on all three
 * user docs, so every broadcast (the Happy Hour push, vote reminders) hit
 * that phone three times. Found live, 2026-11-08. The first account to
 * claim a token keeps it for dead-token pruning; the duplicates are dropped.
 * claimPushToken (below) stops the duplicates being stored in the first
 * place; this is the backstop for any that already exist.
 *
 * @param {Array<{uid: string, tokens: string[]}>} recipients
 * @return {Array<{token: string, uid: string}>}
 */
function dedupeTargets(recipients) {
  const seen = new Set();
  const out = [];
  for (const {uid, tokens} of recipients) {
    for (const token of tokens ?? []) {
      if (typeof token !== "string" || token.length === 0) continue;
      if (seen.has(token)) continue;
      seen.add(token);
      out.push({token, uid});
    }
  }
  return out;
}

/**
 * Which tokens were newly added to a user doc by this write.
 *
 * @param {string[]|undefined} before
 * @param {string[]|undefined} after
 * @return {string[]}
 */
function addedTokens(before, after) {
  const prev = new Set(before ?? []);
  return [...new Set(after ?? [])].filter(
      (t) => typeof t === "string" && t.length > 0 && !prev.has(t));
}

/**
 * A device's push token belongs to whoever is signed in on it NOW.
 *
 * When a token lands on users/{uid}, remove it from every OTHER account.
 * Signing out already drops the token, but plenty of paths skip sign-out
 * (signing up a second account on the same phone, an uninstall, a crash),
 * and each one left the phone receiving another account's pushes - a
 * challenge to an account you are not even logged into still buzzed the
 * phone, and opening the app showed nothing. Done server-side because a
 * client may not write other people's user docs.
 */
const claimPushToken = onDocumentWritten("users/{uid}", async (event) => {
  const before = event.data?.before?.data()?.fcmTokens;
  const after = event.data?.after?.data()?.fcmTokens;
  const added = addedTokens(before, after);
  if (added.length === 0) return;
  const db = getFirestore();
  const uid = event.params.uid;
  for (const token of added) {
    try {
      const others = await db.collection("users")
          .where("fcmTokens", "array-contains", token).get();
      await Promise.all(others.docs
          .filter((d) => d.id !== uid)
          .map((d) => d.ref.update({
            fcmTokens: FieldValue.arrayRemove(token),
          })));
    } catch (e) {
      console.error("claimPushToken failed:", e.message);
    }
  }
});

async function sendToUsers(userDocsOrIds, {title, body, category, data = {}}) {
  const db = getFirestore();
  const userDocs = await resolveUserDocs(userDocsOrIds);
  const targets = dedupeTargets(userDocs.map((doc) => ({
    uid: doc.id,
    tokens: wantsCategory(doc.data(), category) ?
      (doc.data()?.fcmTokens ?? []) : [],
  })));
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

module.exports = {CATEGORIES, wantsCategory, sendToUsers, resolveUserDocs,
  MULTICAST_LIMIT, dedupeTargets, addedTokens, claimPushToken};
