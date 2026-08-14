const os = require("os");
const path = require("path");
const fs = require("fs/promises");
const {spawn} = require("child_process");
const {getStorage} = require("firebase-admin/storage");
const {getFirestore, FieldValue} = require("firebase-admin/firestore");

/**
 * Renders a watchable clip from a match's raw per-player recordings
 * (CLAUDE.md's Auto-Editing for Highlights, first pass).
 *
 * Recording captures each player's stream separately and in HLS only (see
 * functions/cloudRecording.js), which means nothing coming out of the
 * recorder is directly watchable or postable. This module is what turns
 * those raw tracks into a single vertical video - which is also what the
 * human review gate needs, since a reviewer can't sensibly approve two
 * unsynchronised HLS playlists.
 *
 * SCOPE OF THIS PASS: composite, align, and mux. Silence trimming,
 * burned-in captions, branded intro/outro and music are all still to come
 * - they are separate passes over the same source and are deliberately not
 * bundled in here.
 *
 * THE HARD PART IS TIME ALIGNMENT, not compositing. Each player's mic is
 * muted during their opponent's turn, so their audio track only covers the
 * stretches where they were unmuted - measured on a real match, 119s of
 * video against 89s and 75s of audio. The two players' tracks also start
 * at slightly different moments. Feeding the audio playlists straight to
 * ffmpeg would concatenate the segments end to end, silently collapsing
 * those gaps and sliding every later line out of sync with the picture.
 *
 * So every segment is placed at its own absolute position instead. Agora
 * embeds a millisecond timestamp in each segment's filename, which is the
 * authoritative source for that - more reliable than playlist arithmetic,
 * which accumulates rounding error across segments.
 */

const CANVAS = {width: 1080, height: 1920};
const TILE = {width: 1080, height: 960};
const OUTPUT_FPS = 30;

/** Where rendered clips live. Deliberately a different prefix from the raw
 * `match_recordings/` footage, because the two have different lifetimes:
 * raw footage is purged after 7 days, a published highlight is kept. */
const HIGHLIGHT_PREFIX = "match_highlights";

/**
 * Recovers the absolute start time Agora embedded in a segment filename.
 *
 * Segments are named `..._<uid marker>_<kind>_YYYYMMDDHHMMSSmmm.ts`. Only
 * the deltas between timestamps matter here, so the timezone the recorder
 * used is irrelevant as long as it's consistent - which it is, since every
 * segment in a match is written by the same recorder.
 *
 * Returns null for playlists and anything unparseable, so callers can
 * filter rather than silently mis-place a track at epoch zero.
 */
function parseSegmentTimeMs(fileName) {
  const match = fileName.match(/_(\d{17})\.ts$/);
  if (!match) return null;
  const s = match[1];
  const parts = [
    s.slice(0, 4), s.slice(4, 6), s.slice(6, 8),
    s.slice(8, 10), s.slice(10, 12), s.slice(12, 14), s.slice(14, 17),
  ].map(Number);
  const ms = Date.UTC(parts[0], parts[1] - 1, parts[2], parts[3], parts[4], parts[5], parts[6]);
  return Number.isFinite(ms) ? ms : null;
}

/** Which player and which track a recorded file belongs to. */
function classifyFile(filePath) {
  const name = filePath.split("/").pop() ?? "";
  const uid = name.match(/__uid_s_(\d+)__uid_e/)?.[1] ?? null;
  const kind = name.includes("_audio") ? "audio" : name.includes("_video") ? "video" : null;
  return {name, uid, kind, isPlaylist: name.endsWith(".m3u8")};
}

/**
 * Segments smaller than this are treated as truncated tails and dropped.
 *
 * Stopping a recording can leave a final fragment holding a few
 * milliseconds of data. Seen on a real match: a 0.04-second trailing
 * audio segment that ffmpeg could not even demux ("Could not find codec
 * parameters ... unspecified frame size"), which aborted the entire
 * render. One unusable scrap must not cost the whole clip, and a fragment
 * this small carries nothing worth keeping.
 */
const MIN_SEGMENT_BYTES = 8 * 1024;

/**
 * Turns a flat list of recorded files into a time-aligned plan.
 *
 * `t0` is the earliest moment any track started; every offset below is
 * relative to it, so the rendered clip begins the instant the first
 * player's stream did rather than at some arbitrary zero.
 *
 * Accepts either bare paths or `{path, sizeBytes}` objects - sizes are
 * what allow truncated fragments to be filtered out, so callers that have
 * them should pass them.
 */
function buildTimeline(files) {
  const segments = [];
  const dropped = [];
  for (const entry of files) {
    const p = typeof entry === "string" ? entry : entry.path;
    const sizeBytes = typeof entry === "string" ? null : entry.sizeBytes;
    const {name, uid, kind, isPlaylist} = classifyFile(p);
    if (isPlaylist || !uid || !kind) continue;
    const startMs = parseSegmentTimeMs(name);
    if (startMs === null) continue;
    if (sizeBytes !== null && sizeBytes < MIN_SEGMENT_BYTES) {
      dropped.push({path: p, sizeBytes});
      continue;
    }
    segments.push({path: p, uid, kind, startMs});
  }

  if (segments.length === 0) return {t0: null, uids: [], segments: [], dropped};

  const t0 = Math.min(...segments.map((s) => s.startMs));
  for (const s of segments) s.offsetMs = s.startMs - t0;
  segments.sort((a, b) => a.offsetMs - b.offsetMs || a.uid.localeCompare(b.uid));

  // Sorted so the layout is stable: player 1 always renders on top,
  // regardless of who happened to start publishing first.
  const uids = [...new Set(segments.map((s) => s.uid))].sort();
  return {t0, uids, segments, dropped};
}

/**
 * Builds the ffmpeg invocation for a stacked vertical render.
 *
 * Each player's video is scaled to fill its half and cropped rather than
 * letterboxed: a tile is 1080x960, wider than tall, while phones publish
 * portrait, so fitting would pillarbox each player into a narrow strip.
 * Cropping keeps the middle of the frame, which is where the pre-match
 * oval guide trains players to put their face.
 *
 * `tpad` prepends black to a video that started late, and `adelay` pushes
 * each audio segment to its own offset. Together those are what keep
 * picture and sound aligned across the muted stretches.
 */
function buildFfmpegArgs(timeline, localDir, outputPath) {
  const {uids, segments} = timeline;
  const inputs = [];
  const filters = [];
  const videoLabels = [];
  const audioLabels = [];
  // Counted separately from `inputs.length`, which advances by two per
  // input because it holds the "-i" flag as well as the path. Using the
  // array length gave every filter an index of 0, 2, 4... and ffmpeg
  // rejected the graph with "Stream specifier ':v' matches no streams".
  let inputIndex = 0;

  for (const uid of uids) {
    const videoSegs = segments.filter((s) => s.uid === uid && s.kind === "video");
    if (videoSegs.length === 0) continue;
    // Video is continuous while a player is publishing (nobody mutes
    // their camera mid-match), so the first segment's offset positions
    // the whole track. A second video segment would indicate a
    // reconnection; renderMatchHighlight logs that case rather than
    // silently mis-timing it.
    const first = videoSegs[0];
    const index = inputIndex++;
    inputs.push("-i", path.join(localDir, first.path.split("/").pop()));
    const pad = (first.offsetMs / 1000).toFixed(3);
    filters.push(
        `[${index}:v]scale=${TILE.width}:${TILE.height}:force_original_aspect_ratio=increase,` +
      `crop=${TILE.width}:${TILE.height},setsar=1,fps=${OUTPUT_FPS},` +
      `tpad=start_duration=${pad}:color=black[v${uid}]`,
    );
    videoLabels.push(`[v${uid}]`);
  }

  for (const seg of segments.filter((s) => s.kind === "audio")) {
    const index = inputIndex++;
    inputs.push("-i", path.join(localDir, seg.path.split("/").pop()));
    const delay = Math.round(seg.offsetMs);
    filters.push(`[${index}:a]adelay=${delay}|${delay}[a${index}]`);
    audioLabels.push(`[a${index}]`);
  }

  if (videoLabels.length === 0) throw new Error("no video track to render");

  // A single player (the opponent never published) still renders, just
  // filling the frame alone rather than stacking.
  if (videoLabels.length === 1) {
    filters.push(`${videoLabels[0]}scale=${CANVAS.width}:${CANVAS.height}:` +
      `force_original_aspect_ratio=increase,crop=${CANVAS.width}:${CANVAS.height}[vout]`);
  } else {
    filters.push(`${videoLabels.join("")}vstack=inputs=${videoLabels.length}[vout]`);
  }

  // normalize=0 because the segments do not overlap - normalising would
  // duck each player's volume by the number of inputs for no reason.
  if (audioLabels.length > 0) {
    filters.push(`${audioLabels.join("")}amix=inputs=${audioLabels.length}:` +
      `normalize=0:dropout_transition=0[aout]`);
  }

  const args = [
    "-y",
    ...inputs,
    "-filter_complex", filters.join(";"),
    "-map", "[vout]",
    ...(audioLabels.length > 0 ? ["-map", "[aout]"] : []),
    "-c:v", "libx264",
    "-preset", "veryfast",
    "-crf", "23",
    "-pix_fmt", "yuv420p",
    "-c:a", "aac",
    "-b:a", "128k",
    // Puts the index at the front so the file starts playing before it has
    // fully downloaded - matters for review in a browser and for upload.
    "-movflags", "+faststart",
    outputPath,
  ];
  return args;
}

function runFfmpeg(binary, args) {
  return new Promise((resolve, reject) => {
    const proc = spawn(binary, args);
    let stderr = "";
    // ffmpeg reports everything on stderr, including normal progress -
    // keep only the tail so a failure message survives without logging
    // megabytes of progress lines.
    proc.stderr.on("data", (d) => {
      stderr = (stderr + d.toString()).slice(-4000);
    });
    proc.on("error", reject);
    proc.on("close", (code) => {
      if (code === 0) resolve(stderr);
      else reject(new Error(`ffmpeg exited ${code}: ${stderr.slice(-1500)}`));
    });
  });
}

/**
 * Renders a match's raw recordings into one vertical clip and stores it
 * alongside the match.
 *
 * Rendered on demand rather than automatically for every match: most
 * matches never become highlights, and rendering each one would burn
 * compute on clips nobody will post.
 */
async function renderMatchHighlight(matchId) {
  const db = getFirestore();
  const bucket = getStorage().bucket();
  const matchRef = db.collection("matches").doc(matchId);
  const snap = await matchRef.get();
  if (!snap.exists) throw new Error("Match not found.");

  const [objects] = await bucket.getFiles({prefix: `match_recordings/${matchId}/`});
  if (objects.length === 0) throw new Error("No recording found for this match.");

  const timeline = buildTimeline(
      objects.map((o) => ({path: o.name, sizeBytes: Number(o.metadata?.size ?? 0)})),
  );
  if (timeline.segments.length === 0) throw new Error("No usable segments in the recording.");

  const warnings = [];
  if (timeline.dropped.length > 0) {
    warnings.push(`skipped ${timeline.dropped.length} truncated segment(s) too small to decode`);
  }
  for (const uid of timeline.uids) {
    const videoCount = timeline.segments.filter((s) => s.uid === uid && s.kind === "video").length;
    if (videoCount > 1) {
      warnings.push(`player ${uid} has ${videoCount} video segments - likely a reconnect; ` +
        `only the first is rendered, so later footage is missing`);
    }
    if (videoCount === 0) warnings.push(`player ${uid} published no video`);
  }

  const workDir = await fs.mkdtemp(path.join(os.tmpdir(), `render-${matchId}-`));
  try {
    // Everything lands in one flat directory so the filenames the
    // playlists reference resolve, and so buildFfmpegArgs can address
    // segments by basename.
    await Promise.all(objects.map((o) =>
      bucket.file(o.name).download({destination: path.join(workDir, o.name.split("/").pop())}),
    ));

    const outputPath = path.join(workDir, "vertical.mp4");
    const ffmpegPath = require("ffmpeg-static");
    const args = buildFfmpegArgs(timeline, workDir, outputPath);
    await runFfmpeg(ffmpegPath, args);

    const destination = `${HIGHLIGHT_PREFIX}/${matchId}/vertical.mp4`;
    await bucket.upload(outputPath, {destination, metadata: {contentType: "video/mp4"}});
    const size = (await fs.stat(outputPath)).size;

    await matchRef.set({
      highlight: {
        path: destination,
        sizeBytes: size,
        renderedAt: FieldValue.serverTimestamp(),
        // Same human gate as the raw recording: rendering something
        // watchable is not the same as approving it for an audience.
        reviewStatus: "pending",
        published: false,
        ...(warnings.length > 0 ? {warnings} : {}),
      },
    }, {merge: true});

    return {rendered: true, path: destination, sizeBytes: size, warnings};
  } finally {
    await fs.rm(workDir, {recursive: true, force: true}).catch(() => {});
  }
}

module.exports = {
  renderMatchHighlight,
  parseSegmentTimeMs,
  classifyFile,
  buildTimeline,
  buildFfmpegArgs,
  CANVAS,
  TILE,
  HIGHLIGHT_PREFIX,
};
