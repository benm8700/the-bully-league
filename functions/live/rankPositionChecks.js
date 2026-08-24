/**
 * LIVE check: can a CLIENT count how many players out-rate it?
 *
 * The Ranks board shows the top 100 and, when the viewer is not on it,
 * appends their own position. That position comes from an aggregation
 * query run on the device - "how many users have a higher rating" - and
 * aggregation queries are subject to firestore.rules exactly like reads.
 * If the rules refused it the board would still look fine and the self
 * row would simply never appear, which is the silent-failure shape this
 * project keeps meeting.
 *
 * Run from functions/:  node live/rankPositionChecks.js
 */
const fs = require("fs");
const {initializeApp, cert} = require("firebase-admin/app");
const {getFirestore} = require("firebase-admin/firestore");
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

initializeApp({credential: cert({
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

const BASE = `https://firestore.googleapis.com/v1/projects/${PROJECT}` +
  "/databases/(default)/documents";

/** The same aggregation the client runs, as the CLIENT. */
async function countAhead(token, rating) {
  const r = await fetch(`${BASE}:runAggregationQuery`, {
    method: "POST",
    headers: {"Content-Type": "application/json",
      Authorization: "Bearer " + token},
    body: JSON.stringify({structuredAggregationQuery: {
      structuredQuery: {
        from: [{collectionId: "users"}],
        where: {fieldFilter: {
          field: {fieldPath: "rating"},
          op: "GREATER_THAN",
          value: {integerValue: String(rating)},
        }},
      },
      aggregations: [{alias: "n", count: {}}],
    }}),
  });
  const text = await r.text();
  if (r.status !== 200) return {status: r.status, body: text.slice(0, 200)};
  const j = JSON.parse(text);
  const n = j?.[0]?.result?.aggregateFields?.n?.integerValue;
  return {status: 200, count: Number(n)};
}

const stamp = Date.now().toString(36);
const LOW = `rp-low-${stamp}`;
const made = [LOW];

(async () => {
  try {
    await auth.createUser({uid: LOW, email: `${LOW}@example.com`,
      password: "Test12345!"});
    // Deliberately at the very bottom, so every real account out-rates it.
    await db.collection("users").doc(LOW).set({
      username: `Rp${stamp}`, usernameLower: `rp${stamp}`,
      rating: 1, rankTitle: "Average Joe", rankedMatchesPlayed: 0,
      wins: 0, losses: 0, accountStatus: "active", isAdmin: false,
    });

    const custom = await auth.createCustomToken(LOW);
    const sr = await fetch("https://identitytoolkit.googleapis.com/v1/" +
      "accounts:signInWithCustomToken?key=" + API_KEY,
    {method: "POST", headers: {"Content-Type": "application/json"},
      body: JSON.stringify({token: custom, returnSecureToken: true})});
    const token = (await sr.json()).idToken;

    console.log("\nthe aggregation the board depends on");
    const mine = await countAhead(token, 1);
    check("A CLIENT MAY RUN THE COUNT - the rules allow it",
        mine.status === 200,
        `status ${mine.status} ${mine.body ?? ""} - if refused, the self ` +
        "row silently never appears and the board still looks fine");
    check("...and it returns a real number", Number.isFinite(mine.count),
        String(mine.count));

    // Cross-check against the truth, computed with the Admin SDK.
    const all = await db.collection("users").get();
    const truth = all.docs.filter((d) => (d.data().rating ?? -1) > 1).length;
    check("the count matches the actual number of higher-rated players",
        mine.count === truth, `client ${mine.count} vs real ${truth}`);
    check("so the bottom player's position is last",
        mine.count + 1 === truth + 1, `position ${mine.count + 1}`);

    console.log("\nan unauthenticated caller");
    const anon = await fetch(`${BASE}:runAggregationQuery`, {
      method: "POST", headers: {"Content-Type": "application/json"},
      body: JSON.stringify({structuredAggregationQuery: {
        structuredQuery: {from: [{collectionId: "users"}]},
        aggregations: [{alias: "n", count: {}}],
      }}),
    });
    check("cannot count the userbase", anon.status !== 200,
        `status ${anon.status}`);
  } catch (err) {
    console.error("THREW:", err.message);
    failed++;
  } finally {
    for (const uid of made) {
      await db.recursiveDelete(db.collection("users").doc(uid)).catch(() => {});
      await auth.deleteUser(uid).catch(() => {});
    }
    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed ? 1 : 0);
  }
})();
