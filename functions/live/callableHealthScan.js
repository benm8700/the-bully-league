/**
 * Probes every deployed callable and reports which ones are reachable.
 *
 * WHY. A newly created 2nd-gen function repeatedly fails to get its
 * "allow public invocation" IAM binding in this project - it happened to
 * four separate functions today alone. The symptom is a Cloud Run level
 * 401 with Google's generic HTML page, returned BEFORE the function runs,
 * so every real signed-in user is rejected and the function's own auth
 * check never executes. A redeploy fixes it.
 *
 * The distinguishing signal is the BODY, not the status code. A healthy
 * callable answers an unauthenticated request with its own JSON
 * ("UNAUTHENTICATED / Must be signed in"), which is a 401 too. A broken
 * binding answers with HTML. So this checks the shape of the response
 * rather than the code.
 *
 * Run from functions/:  node live/callableHealthScan.js
 */
const fs = require("fs");
const path = require("path");

const PROJECT = "the-bully-league";
const REGION = "us-central1";

const src = fs.readFileSync(path.join(__dirname, "..", "index.js"), "utf8");

// Callables only. Scheduled jobs and Firestore triggers have no HTTP
// endpoint and would always look "missing".
const callables = [];
for (const m of src.matchAll(/exports\.([a-zA-Z0-9_]+)\s*=\s*onCall/g)) {
  callables.push(m[1]);
}

(async () => {
  console.log(`Probing ${callables.length} callables.\n`);
  let healthy = 0; let broken = 0; let missing = 0;

  for (const name of callables.sort()) {
    let res;
    try {
      res = await fetch(
          `https://${REGION}-${PROJECT}.cloudfunctions.net/${name}`,
          {method: "POST", headers: {"Content-Type": "application/json"},
            body: JSON.stringify({data: {}})});
    } catch (e) {
      console.log(`  UNREACHABLE  ${name}  ${e.message}`);
      broken++;
      continue;
    }
    const body = await res.text();
    const isJson = body.trimStart().startsWith("{");

    if (res.status === 404) {
      console.log(`  NOT DEPLOYED ${name}`);
      missing++;
    } else if (isJson) {
      // The function ran and answered for itself, whatever it said.
      healthy++;
    } else {
      // HTML from Cloud Run: the request never reached the function.
      console.log(`  BROKEN       ${name}  (${res.status}, HTML - the IAM ` +
        "binding is missing; redeploy this function)");
      broken++;
    }
  }

  console.log(`\n${healthy} reachable, ${broken} broken, ${missing} not deployed`);
  if (broken || missing) {
    console.log("\nA broken binding rejects every real user before the " +
      "function's own auth check ever runs.");
  }
  process.exit(broken || missing ? 1 : 0);
})();
