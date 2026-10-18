/**
 * Verifies the FACE-OFF (improv) sequential render against REAL footage.
 *
 * Finds the most recent completed improv match that has a recording, forces a
 * render NOW (renderImprovHighlight, bypassing the 5-min autoRender delay),
 * then downloads the result and probes it: it must be ONE vertical stream of
 * roughly set1 + 0.75s beat + set2, and highlight.layout must be "sequential".
 *
 * Run from functions/:
 *   NODE_PATH=./node_modules node live/verifyImprovRender.js [matchId]
 */
const os = require("os");
const path = require("path");
const fs = require("fs");
const {spawnSync} = require("child_process");
const {initializeApp, cert} = require("firebase-admin/app");
const {getFirestore} = require("firebase-admin/firestore");
const {getStorage} = require("firebase-admin/storage");

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
  storageBucket: "the-bully-league.firebasestorage.app",
});
const db = getFirestore();
const bucket = getStorage().bucket();
const {renderMatchHighlight} = require("../highlightRender");

(async () => {
  let matchId = process.argv[2];
  if (!matchId) {
    const snap = await db.collection("matches")
        .where("mode", "==", "improv")
        .where("status", "==", "completed")
        .orderBy("completedAt", "desc")
        .limit(10)
        .get();
    for (const doc of snap.docs) {
      const files = doc.data().recording?.files;
      if (Array.isArray(files) && files.length > 0) {
        matchId = doc.id;
        console.log(`Latest improv match with a recording: ${matchId}`);
        break;
      }
    }
    if (!matchId) {
      console.error("No completed improv match WITH A RECORDING found. " +
        "Play a Face-Off to the verdict first, and give Agora a minute to " +
        "upload the segments.");
      process.exit(2);
    }
  }

  // Confirm the recording files are actually in Storage.
  const [objs] = await bucket.getFiles({prefix: `match_recordings/${matchId}/`});
  console.log(`${objs.length} recording object(s) in Storage for ${matchId}`);
  if (objs.length === 0) {
    console.error("No recording objects yet - Agora may still be uploading. " +
      "Wait a minute and re-run.");
    process.exit(2);
  }

  console.log("Rendering (this runs the real ffmpeg sequential cut)...");
  const res = await renderMatchHighlight(matchId);
  console.log("render result:", JSON.stringify(res, null, 2));

  const fresh = (await db.collection("matches").doc(matchId).get()).data();
  const h = fresh.highlight || {};
  console.log(`highlight.layout = ${h.layout} (expect "sequential")`);
  const vpath = h.renditions?.vertical?.path;
  console.log(`vertical path = ${vpath}`);

  if (!vpath) {
    console.error("No vertical rendition path written.");
    process.exit(1);
  }

  // Download + probe the real output.
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "improvverify-"));
  const local = path.join(tmp, "out.mp4");
  await bucket.file(vpath).download({destination: local});
  const ffmpeg = require("ffmpeg-static");
  const probe = spawnSync(ffmpeg, ["-i", local], {encoding: "utf8"});
  const dur = (probe.stderr.match(/Duration: (\d+:\d+:\d+\.\d+)/) || [])[1];
  const streams = (probe.stderr.match(/Stream #0:\d+.*/g) || []);
  console.log(`\nRENDERED CLIP: ${(fs.statSync(local).size / 1024).toFixed(0)} KB, ` +
    `duration ${dur}`);
  for (const s of streams) console.log("  " + s.trim());

  // Pull two frames - one from each set - so the red/blue borders can be eyeballed.
  for (const [t, who] of [["25%", "set1-red"], ["75%", "set2-blue"]]) {
    const frame = path.join(tmp, `${who}.png`);
    spawnSync(ffmpeg, ["-y", "-ss", "3", "-i", local, "-frames:v", "1",
      frame.replace("3", "3")]);
  }
  // Extract one frame from each half by absolute time.
  const totalSec = (() => {
    const m = (dur || "0:0:0").split(":").map(Number);
    return m[0] * 3600 + m[1] * 60 + m[2];
  })();
  const shots = [];
  for (const [frac, who] of [[0.25, "red_set1"], [0.75, "blue_set2"]]) {
    const frame = path.join(tmp, `frame_${who}.png`);
    const r = spawnSync(ffmpeg, ["-y", "-ss", String((totalSec * frac).toFixed(1)),
      "-i", local, "-frames:v", "1", frame], {encoding: "utf8"});
    if (r.status === 0 && fs.existsSync(frame)) shots.push(frame);
  }
  console.log("\nframes written for eyeballing:");
  for (const s of shots) console.log("  " + s);
  console.log(`\n(clip kept at ${local})`);
})();
