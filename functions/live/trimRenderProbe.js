/**
 * Does ffmpeg actually accept the trimmed filter graph, and does the
 * output really get shorter?
 *
 * Unit tests can only check that the labels wire up. Only running the
 * real binary proves the graph is valid - this project has already had a
 * render fail in production on a filter ffmpeg rejected outright.
 */
const {execFileSync, spawnSync} = require("child_process");
const ffmpeg = require("ffmpeg-static");
const os = require("os");
const path = require("path");
const fs = require("fs");
const {buildTrimFilters} = require("./trimSilence");

const dir = fs.mkdtempSync(path.join(os.tmpdir(), "trimprobe-"));
const full = path.join(dir, "full.mp4");
const cut = path.join(dir, "cut.mp4");

// Keep 0-2s and 6-8s of a ten-second source: four seconds should survive.
const trim = buildTrimFilters([{start: 0, end: 2}, {start: 6, end: 8}], 10);

function render(withTrim, target) {
  const stages = [
    "[0:v]scale=1080:960:force_original_aspect_ratio=increase," +
      "crop=1080:960,setsar=1,fps=30[v1]",
    "[2:v]scale=1080:960:force_original_aspect_ratio=increase," +
      "crop=1080:960,setsar=1,fps=30[v2]",
    "[v1][v2]vstack=inputs=2[vstacked]",
    withTrim ? `[vstacked]${trim.video}[vout]` : "[vstacked]null[vout]",
    "[1:a][3:a]amix=inputs=2:normalize=0:dropout_transition=0[amixed]",
    withTrim ? `[amixed]${trim.audio}[aout]` : "[amixed]anull[aout]",
  ];
  execFileSync(ffmpeg, ["-y",
    "-f", "lavfi", "-i", "testsrc=size=720x1280:rate=30:duration=10",
    "-f", "lavfi", "-i", "sine=frequency=440:duration=10",
    "-f", "lavfi", "-i", "testsrc2=size=720x1280:rate=30:duration=10",
    "-f", "lavfi", "-i", "sine=frequency=660:duration=10",
    "-filter_complex", stages.join(";"), "-map", "[vout]", "-map", "[aout]",
    "-c:v", "libx264", "-preset", "ultrafast", "-crf", "30",
    "-pix_fmt", "yuv420p", "-c:a", "aac", target,
  ], {stdio: ["ignore", "ignore", "pipe"]});
}

/**
 * ffmpeg writes its report to STDERR and exits ZERO, so spawnSync is
 * needed - execFileSync only surfaces stderr when the command fails, and
 * reading it in a catch block returned nothing at all on success.
 */
function durationOf(file) {
  const r = spawnSync(ffmpeg, ["-i", file, "-f", "null", "-"],
      {encoding: "utf8"});
  const m = String(r.stderr).match(/Duration: (\d+):(\d+):([\d.]+)/);
  if (!m) return null;
  return Number(m[1]) * 3600 + Number(m[2]) * 60 + Number(m[3]);
}

try {
  render(false, full);
  console.log("ok   the untrimmed graph renders");
  render(true, cut);
  console.log("ok   FFMPEG ACCEPTED THE TRIMMED GRAPH");

  const a = durationOf(full);
  const b = durationOf(cut);
  console.log(`     ${a}s -> ${b}s`);
  console.log(b !== null && a !== null && b < a - 3 ?
    "ok   the clip is genuinely SHORTER, so the cut really happened" :
    "FAIL the output was not shortened - the filter did nothing");
  console.log(b !== null && Math.abs(b - 4) < 1 ?
    "ok   ...and lands on the four seconds the plan kept" :
    `FAIL expected about 4s of kept video, got ${b}`);
} catch (e) {
  console.log("FFMPEG REJECTED IT:");
  console.log(String(e.stderr).split("\n").slice(-14).join("\n"));
} finally {
  fs.rmSync(dir, {recursive: true, force: true});
}
