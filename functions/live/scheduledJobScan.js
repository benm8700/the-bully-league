/**
 * Runs EVERY scheduled job against real Firestore and reports which ones
 * actually work.
 *
 * WHY THIS EXISTS. Three times now a scheduled function in this project
 * has been silently dead in production - the MODES export that was never
 * exported, the voteReminders query that needed an index, and
 * finalizeExpiredMatches which needed one too and had therefore NEVER
 * settled a single ranked match. Every one of them had a green deploy, a
 * firing schedule, and a try/catch that swallowed the error. Unit tests
 * cannot see any of it, because the break is in the seam between the
 * function and the database.
 *
 * So this calls each job's real entry point and reports the throw. It is
 * deliberately READ-HEAVY BUT WRITE-CAPABLE: these are the production
 * sweeps, so running them does real work (settling matches, sending
 * pushes, purging recordings). That is the point - a job that cannot be
 * safely run is a job nobody can verify - but it means this should be run
 * deliberately rather than casually.
 *
 * Run from functions/:  node live/scheduledJobScan.js
 */
const fs = require("fs");
const {initializeApp, cert} = require("firebase-admin/app");

const E = fs.readFileSync("../website/.env.local", "utf8");
function val(k) {
  const line = E.split(/\r?\n/).find((l) => l.startsWith(k + "="));
  let v = line.slice(k.length + 1).trim();
  if (v.startsWith("\"") && v.endsWith("\"")) v = v.slice(1, -1);
  return v.replace(/\\n/g, "\n");
}
initializeApp({
  credential: cert({
    projectId: val("FIREBASE_PROJECT_ID"),
    clientEmail: val("FIREBASE_CLIENT_EMAIL"),
    privateKey: val("FIREBASE_PRIVATE_KEY"),
  }),
  databaseURL: "https://the-bully-league-default-rtdb.firebaseio.com",
  // Cloud Functions supplies this automatically from FIREBASE_CONFIG;
  // a standalone script must state it or Storage-touching jobs fail for
  // a reason that has nothing to do with the job.
  storageBucket: "the-bully-league.firebasestorage.app",
});

/**
 * Each scheduled job, and how to invoke exactly what the schedule
 * invokes. Anything that needs a secret this environment does not hold is
 * listed with `needsSecret` so a credential failure is not reported as a
 * broken query.
 */
const JOBS = [
  {name: "publishOnlineCount", mod: "../presence", fn: "publishOnlineCount"},
  {name: "sendEventWindowPush", mod: "../eventWindowPush",
    fn: "sendEventWindowPush"},
  {name: "tournamentNotifications", mod: "../tournamentNotify",
    fn: "sweepTournamentNotifications"},
  {name: "tournamentForfeits", mod: "../tournamentPlay",
    fn: "sweepTournamentForfeits"},
  {name: "voteReminders", mod: "../voteReminder", fn: "sweepVoteReminders"},
  {name: "autoRenderHighlights", mod: "../autoRender", fn: "sweepRenders",
    note: "renders cost money and time; limited below"},
  {name: "releaseUnansweredChallenges", mod: "../releaseChallenges",
    fn: "releaseUnansweredChallenges"},
  {name: "rebuildHallOfFame", mod: "../hallOfFame", fn: "rebuildHallOfFame"},
  {name: "purgeExpiredRecordings", mod: "../recordingRetention",
    fn: "purgeExpiredRecordings"},
  {name: "advanceLiveTournaments", mod: "../liveTournament",
    fn: "sweepLiveTournaments"},
  {name: "stopRunawayRecordings", mod: "../cloudRecording",
    fn: "stopRunawayRecordings", needsSecret: true},
];

(async () => {
  let ok = 0; let broken = 0; let skipped = 0;
  console.log("Running every scheduled job against real Firestore.\n");

  for (const job of JOBS) {
    let mod;
    try {
      mod = require(job.mod);
    } catch (e) {
      console.log(`  BROKEN  ${job.name}  (module will not load: ${e.message})`);
      broken++;
      continue;
    }
    const fn = mod[job.fn];
    if (typeof fn !== "function") {
      // Exactly the MODES-export class of bug: the schedule destructures a
      // name the module does not export, and throws on every run.
      console.log(`  BROKEN  ${job.name}  (${job.mod} does not export ` +
        `${job.fn} - the schedule would throw on every run)`);
      broken++;
      continue;
    }
    try {
      const started = Date.now();
      // autoRender is the one job that costs real money per item, so it is
      // called with the smallest possible batch.
      const result = job.name === "autoRenderHighlights" ?
        await fn({limit: 0}) : await fn();
      const ms = Date.now() - started;
      const summary = JSON.stringify(result ?? {}).slice(0, 90);
      console.log(`  ok      ${job.name}  (${ms}ms) ${summary}`);
      ok++;
    } catch (e) {
      const msg = String(e.message || e);
      if (job.needsSecret && /credential|secret|unset|customer/i.test(msg)) {
        console.log(`  skip    ${job.name}  (needs a secret this ` +
          "environment does not hold)");
        skipped++;
        continue;
      }
      const isIndex = /requires an index|FAILED_PRECONDITION/i.test(msg);
      console.log(`  BROKEN  ${job.name}  ${isIndex ? "[MISSING INDEX] " : ""}` +
        msg.slice(0, 150));
      broken++;
    }
  }

  console.log(`\n${ok} working, ${broken} broken, ${skipped} skipped`);
  if (broken > 0) {
    console.log("\nA broken scheduled job is invisible in production: the " +
      "deploy is green, the schedule fires, and its own try/catch eats " +
      "the error.");
  }
  process.exit(broken > 0 ? 1 : 0);
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
