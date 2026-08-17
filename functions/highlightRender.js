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

/**
 * The two shapes a match is rendered into, from one recording.
 *
 * This is the payoff of recording each player separately: the same source
 * serves both without re-recording, and a third shape could be added later
 * without touching any footage.
 *
 * VERTICAL is for TikTok/Reels/Shorts, stacked, because side-by-side in a
 * 9:16 frame gives each player a 540x1920 sliver.
 *
 * LANDSCAPE is for the website, side-by-side, where that arrangement is
 * genuinely good - two portrait sources sit naturally next to each other
 * in a 16:9 frame, and it crops each player less than the vertical stack
 * does (about 37% of height rather than 50%).
 */
const RENDITIONS = {
  vertical: {
    canvas: {width: 1080, height: 1920},
    tile: {width: 1080, height: 960},
    stackFilter: "vstack",
    fileName: "vertical.mp4",
  },
  landscape: {
    canvas: {width: 1920, height: 1080},
    tile: {width: 960, height: 1080},
    stackFilter: "hstack",
    fileName: "landscape.mp4",
  },
};

/** Kept for callers and tests that just want the vertical shape. */
const CANVAS = RENDITIONS.vertical.canvas;
const TILE = RENDITIONS.vertical.tile;
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
function buildFfmpegArgs(timeline, localDir, outputPath, options = {}) {
  const rendition = options.rendition ?? RENDITIONS.vertical;
  const canvas = rendition.canvas;
  const tile = rendition.tile;
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
        `[${index}:v]scale=${tile.width}:${tile.height}:force_original_aspect_ratio=increase,` +
      `crop=${tile.width}:${tile.height},setsar=1,fps=${OUTPUT_FPS},` +
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
  // Captions are burned on AFTER stacking, so one subtitle track spans the
  // whole frame rather than being scaled differently inside each tile.
  const stacked = options.subtitlePath ? "[vstacked]" : "[vout]";
  if (videoLabels.length === 1) {
    filters.push(`${videoLabels[0]}scale=${canvas.width}:${canvas.height}:` +
      `force_original_aspect_ratio=increase,crop=${canvas.width}:${canvas.height}${stacked}`);
  } else {
    filters.push(
        `${videoLabels.join("")}${rendition.stackFilter}=inputs=${videoLabels.length}${stacked}`,
    );
  }

  if (options.subtitlePath) {
    // ffmpeg parses the filter graph as a string, so a Windows path's
    // backslashes and drive colon would be read as escapes and option
    // separators. Normalising to forward slashes and escaping the colon
    // is what makes the same code work locally and on Cloud Functions.
    const escaped = options.subtitlePath
        .replace(/\\/g, "/")
        .replace(/:/g, "\\:")
        .replace(/'/g, "\\'");
    filters.push(`[vstacked]subtitles='${escaped}'[vout]`);
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
async function renderMatchHighlight(matchId, {captions = true} = {}) {
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

    const ffmpegPath = require("ffmpeg-static");

    // Transcribed ONCE and reused across both renditions. Speech-to-Text
    // bills per audio minute, so transcribing per rendition would double
    // the cost for identical words.
    let cues = [];
    if (captions) {
      const {transcribeSegments, groupWordsIntoCues} = require("./captions");
      const audioSegs = timeline.segments.filter((s) => s.kind === "audio");
      const {words, failures} = await transcribeSegments(
          audioSegs, workDir, ffmpegPath, workDir,
      );
      if (failures.length > 0) {
        warnings.push(`${failures.length} audio segment(s) could not be transcribed`);
      }
      cues = groupWordsIntoCues(words);
      if (cues.length === 0) {
        // Rendering without captions beats failing the whole clip - a
        // match with no intelligible speech is unusual but not an error.
        warnings.push("no speech was transcribed, so the clips have no captions");
      }
    }

    const {buildAssFile} = require("./captions");
    const outputs = {};

    for (const [name, rendition] of Object.entries(RENDITIONS)) {
      // Captions are burned in rather than shipped as a sidecar track:
      // TikTok, Reels and Shorts don't render an external subtitle file,
      // and most short-form video is watched muted (see CLAUDE.md's
      // Production quality bar), so the text has to be part of the
      // picture. A separate subtitle file per rendition because the font
      // scales to each canvas.
      // ALWAYS written, even with no cues, because the same file carries
      // the burned-in watermark - and CLAUDE.md's decision is that every
      // clip is watermarked, including the uncaptioned stage-1 renders
      // that make up the large majority. `captioned` below stays keyed to
      // real cues rather than to this file existing, or every clip would
      // claim captions it does not have.
      const subtitlePath = path.join(workDir, `captions-${name}.ass`);
      await fs.writeFile(subtitlePath, buildAssFile(cues, rendition.canvas), "utf8");

      const outputPath = path.join(workDir, rendition.fileName);
      await runFfmpeg(ffmpegPath, buildFfmpegArgs(timeline, workDir, outputPath, {
        subtitlePath, rendition,
      }));

      const destination = `${HIGHLIGHT_PREFIX}/${matchId}/${rendition.fileName}`;
      await bucket.upload(outputPath, {destination, metadata: {contentType: "video/mp4"}});
      outputs[name] = {
        path: destination,
        sizeBytes: (await fs.stat(outputPath)).size,
        width: rendition.canvas.width,
        height: rendition.canvas.height,
      };
    }

    await matchRef.set({
      highlight: {
        // Keyed by rendition so the website and the social pipeline each
        // pick the shape they need from the same match document.
        renditions: outputs,
        renderedAt: FieldValue.serverTimestamp(),
        captioned: cues.length > 0,
        cueCount: cues.length,
        // Same human gate as the raw recording: rendering something
        // watchable is not the same as approving it for an audience.
        reviewStatus: "pending",
        published: false,
        ...(warnings.length > 0 ? {warnings} : {}),
      },
    }, {merge: true});

    return {rendered: true, renditions: outputs, cueCount: cues.length, warnings};
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
  RENDITIONS,
  CANVAS,
  TILE,
  HIGHLIGHT_PREFIX,
};
