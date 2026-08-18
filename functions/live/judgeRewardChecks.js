/**
 * LIVE checks for what judging earns beyond points.
 *
 * The check that matters most is the CEILING. Skips are worth more to a
 * rating-manipulator than to an honest player - someone farming rating
 * specifically wants to dodge strong opponents - so an uncapped mint here
 * would quietly reintroduce the opponent cherry-picking the daily cap
 * exists to prevent, while looking like a generous reward.
 *
 * Votes are written directly rather than through castVote, because
 * castVote requires a Turnstile solve and Turnstile deliberately refuses
 * automated browsers. The judge counter is therefore driven the same way
 * the function drives it, and the counter-to-reward rules are what is
 * being asserted.
 *
 * Run from functions/:  node live/judgeRewardChecks.js
 */
const fs = require("fs");
const {initializeApp, cert} = require("firebase-admin/app");
const {getFirestore, Timestamp} = require("firebase-admin/firestore");
const {getAuth} = require("firebase-admin/auth");

const E = fs.readFileSync("../website/.env.local", "utf8");
function val(k) {
  const line = E.split(/\r?\n/).find((l) => l.startsWith(k + "="));
  let v = line.slice(k.length + 1).trim();
  if (v.startsWith("\"") && v.endsWith("\"")) v = v.slice(1, -1);
  return v.replace(/\\n/g, "\n");
}
const PROJECT = "the-bully-league";
const API_KEY = "AIzaSyD-yeC1osuXpfwXWNZPnLEOq7yLviM7J0c";

initializeApp({
  // The queue lives in the Realtime Database, which needs an explicit
  // URL when the Admin SDK is initialised outside Cloud Functions.
  databaseURL: "https://the-bully-league-default-rtdb.firebaseio.com",
  credential: cert({
  projectId: val("FIREBASE_PROJECT_ID"),
  clientEmail: val("FIREBASE_CLIENT_EMAIL"),
  privateKey: val("FIREBASE_PRIVATE_KEY"),
})});
const db = getFirestore();
const auth = getAuth();

let passed = 0; let failed = 0;
function check(name, cond, detail = "") {
  if (cond) {
    passed++; console.log(`  ok   ${name}`);
  } else {
    failed++; console.log(`  FAIL ${name} ${detail}`);
  }
}

const tokens = {};
async function call(uid, fn, data) {
  if (!tokens[uid]) {
    const custom = await auth.createCustomToken(uid);
    const r = await fetch("https://identitytoolkit.googleapis.com/v1/accounts:" +
        "signInWithCustomToken?key=" + API_KEY,
    {method: "POST", headers: {"Content-Type": "application/json"},
      body: JSON.stringify({token: custom, returnSecureToken: true})});
    tokens[uid] = (await r.json()).idToken;
  }
  const r = await fetch(`https://us-central1-${PROJECT}.cloudfunctions.net/${fn}`, {
    method: "POST",
    headers: {"Content-Type": "application/json",
      Authorization: "Bearer " + tokens[uid]},
    body: JSON.stringify({data: data ?? {}}),
  });
  const j = await r.json().catch(() => ({}));
  return {status: r.status, body: j.result, raw: j};
}

const {utcDayKey} = require("../matchmaking");
const {HARD_TOTAL_SKIP_CAP, MAX_EARNED_SKIPS, VOTES_PER_EARNED_SKIP} =
  require("../judgeRewards");

const stamp = Date.now().toString(36);
const JUDGE = `jr-judge-${stamp}`;
const IDLE = `jr-idle-${stamp}`;
const users = [JUDGE, IDLE];

async function makeUser(uid) {
  await auth.createUser({uid, email: `${uid}@example.com`,
    password: "Test12345!"});
  await db.collection("users").doc(uid).set({
    username: `Jr${uid.slice(-6)}`, usernameLower: `jr${uid.slice(-6)}`,
    rating: 1200, rankTitle: "Average Joe", rankedMatchesPlayed: 0,
    wins: 0, losses: 0, accountStatus: "active", isAdmin: false,
    createdAt: Timestamp.now(),
  });
}

/** Sets today's judge count the way castVote does. */
async function setVotes(uid, n) {
  await db.collection("users").doc(uid).update({
    judgeDayKey: utcDayKey(Date.now()), judgeVotesToday: n,
  });
}

(async () => {
  try {
    await Promise.all([makeUser(JUDGE), makeUser(IDLE)]);

    console.log("\nthe baseline");
    let r = await call(IDLE, "getSkipAllowance", {});
    const base = r.body?.max;
    check("a non-judge gets the plain daily allowance",
        r.status === 200 && base > 0 && r.body?.earned === 0,
        JSON.stringify(r.body));

    console.log("\njudging earns skips, gradually");
    await setVotes(JUDGE, VOTES_PER_EARNED_SKIP - 1);
    r = await call(JUDGE, "getSkipAllowance", {});
    check("...but not before the threshold", r.body?.earned === 0,
        JSON.stringify(r.body));

    await setVotes(JUDGE, VOTES_PER_EARNED_SKIP);
    r = await call(JUDGE, "getSkipAllowance", {});
    check("one earned skip at the threshold", r.body?.earned === 1,
        JSON.stringify(r.body));
    check("...and the allowance actually grew", r.body?.max === base + 1,
        JSON.stringify(r.body));

    console.log("\nthe ceiling");
    await setVotes(JUDGE, 10000);
    r = await call(JUDGE, "getSkipAllowance", {});
    check("TEN THOUSAND VOTES MINT NO MORE THAN THE CAP",
        r.body?.earned === MAX_EARNED_SKIPS, JSON.stringify(r.body));
    check("...and the total never exceeds the hard ceiling",
        r.body?.max <= HARD_TOTAL_SKIP_CAP, JSON.stringify(r.body));

    console.log("\nthey expire, they never bank up");
    await db.collection("users").doc(JUDGE).update({
      judgeDayKey: "2020-01-01", judgeVotesToday: 10000,
    });
    r = await call(JUDGE, "getSkipAllowance", {});
    check("YESTERDAY'S JUDGING BUYS NOTHING TODAY",
        r.body?.earned === 0 && r.body?.max === base,
        JSON.stringify(r.body));

    console.log("\nthe earned skips are really spendable");
    await setVotes(JUDGE, 10000);
    // Spend the whole base allowance, then check the earned ones remain.
    await db.collection("users").doc(JUDGE).update({
      skipsUsedToday: base, skipsResetDate: utcDayKey(Date.now()),
    });
    r = await call(JUDGE, "getSkipAllowance", {});
    check("a judge who spent the base allowance still has the earned ones",
        r.body?.remaining === MAX_EARNED_SKIPS, JSON.stringify(r.body));

    await db.collection("users").doc(IDLE).update({
      skipsUsedToday: base, skipsResetDate: utcDayKey(Date.now()),
    });
    r = await call(IDLE, "getSkipAllowance", {});
    check("...while a non-judge in the same position has none",
        r.body?.remaining === 0, JSON.stringify(r.body));

    console.log("\npriority reaches the queue");
    await setVotes(JUDGE, 10000);
    r = await call(JUDGE, "enterMatchmakingQueue", {mode: "ranked"});
    check("a judge can queue", r.status === 200,
        JSON.stringify(r.raw).slice(0, 160));
    const {getDatabase} = require("firebase-admin/database");
    const snap = await getDatabase()
        .ref(`matchmakingQueue/ranked/${JUDGE}`).get();
    const bonus = snap.val()?.judgePriorityMs;
    check("THE HEAD START IS STAMPED ON THE QUEUE ENTRY", bonus > 0,
        `judgePriorityMs is ${bonus}`);
    const {MAX_PRIORITY_MS} = require("../judgeRewards");
    check("...and is bounded", bonus <= MAX_PRIORITY_MS, String(bonus));

    const {STANDING_AFTER_MS} = require("../standingChallenge");
    check("...and stays under the standing threshold, so it is a tiebreak " +
        "rather than a separate queue", bonus < STANDING_AFTER_MS,
    `${bonus} vs ${STANDING_AFTER_MS}`);

    // The client reads this straight off the enterQueue response to
    // decide whether to confirm the reward on the waiting screen.
    check("THE CLIENT IS TOLD about its head start on the way in",
        r.body?.judgePriorityMs > 0, JSON.stringify(r.body));

    const idleEnter = await call(IDLE, "enterMatchmakingQueue", {mode: "ranked"});
    check("...and a non-judge is told zero, not left guessing",
        idleEnter.body?.judgePriorityMs === 0,
        JSON.stringify(idleEnter.body));
    const idleSnap = await getDatabase()
        .ref(`matchmakingQueue/ranked/${IDLE}`).get();
    check("a non-judge's entry carries no head start",
        !idleSnap.val()?.judgePriorityMs, String(idleSnap.val()?.judgePriorityMs));
  } catch (err) {
    console.error("THREW:", err.message);
    failed++;
  } finally {
    for (const uid of users) {
      await call(uid, "leaveMatchmakingQueue", {mode: "ranked"}).catch(() => {});
      await db.recursiveDelete(db.collection("users").doc(uid)).catch(() => {});
      await auth.deleteUser(uid).catch(() => {});
    }
    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed ? 1 : 0);
  }
})();
