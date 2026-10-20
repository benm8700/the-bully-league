const os = require("os");
const path = require("path");
const fs = require("fs/promises");
const fssync = require("fs");
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

/**
 * The burned-in brand watermark: the home-page logo (the wordmark), overlaid
 * small in the BOTTOM-RIGHT of every clip.
 *
 * An image OVERLAY of the real logo rather than the old ASS "THE BULLY LEAGUE"
 * text, which read as clunky. `overlay` is a core ffmpeg filter and needs no
 * font, so it carries none of the drawtext font-availability worry.
 *
 * BOTTOM-RIGHT (developer's call, 2026-09-22 - "looks better there"). The
 * in-app reaction strip sits full-width along the bottom-left/centre, so the
 * bottom-right is the clearest corner for the mark in the judge feed.
 * Sized as a fraction of canvas WIDTH so it stays proportionate in both the
 * 1080-wide vertical cut and the 1920-wide landscape one. Slightly transparent
 * so it reads as a mark, not an obstruction. Bundled with the function so it
 * ships to the Cloud Functions runtime.
 *
 * THE RIGHT MARGIN IS LARGE ON PURPOSE. The in-app clip player cover-fits the
 * 9:16 clip to a taller phone screen, which crops roughly 9-12% off EACH side
 * - enough to slice the edge off a 3%-inset watermark (the "you can't see the
 * T" report). So the X inset clears that crop band, while the Y inset stays
 * small so it hugs the bottom rather than riding up into frame.
 */
const WATERMARK_LOGO_PATH = path.join(__dirname, "assets", "watermark.png");
const WATERMARK_LOGO_WIDTH_RATIO = 0.17;
// Tightened toward the corner again (developer's call, 2026-10-20 - wants it
// hugging the bottom-right). Still a small inset, not flush: the posted clip -
// the watermark's real job - reads as a clean corner mark, and the inset plus
// the logo PNG's own right-edge padding keeps most of the wordmark inside the
// in-app feed's ~9-12% side-crop. Prioritises the posted/downloaded clip (no
// crop) over the in-app feed look, per the developer.
const WATERMARK_LOGO_MARGIN_X_RATIO = 0.05;
const WATERMARK_LOGO_MARGIN_Y_RATIO = 0.02;
const WATERMARK_LOGO_ALPHA = 0.9;
// Resolved once at load. If the asset ever fails to deploy, this is null and
// renders proceed WITHOUT a watermark rather than failing outright - a missing
// ffmpeg `-i` input would otherwise break every single render.
const WATERMARK_LOGO = fssync.existsSync(WATERMARK_LOGO_PATH) ?
  WATERMARK_LOGO_PATH : null;

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
 * Total seconds an HLS playlist covers, summed from its #EXTINF lines.
 *
 * Pure, and the cheapest correct source of a clip's duration: the
 * playlists are already downloaded, so this needs no probe, no second
 * decode and no extra dependency. Guessing the duration instead would
 * be worse than useless here - it is what decides whether trailing dead
 * air exists at all, and what the bail-out guard measures against.
 */
function sumExtinfSeconds(playlistText) {
  let total = 0;
  for (const line of String(playlistText ?? "").split(/\r?\n/)) {
    const m = line.match(/^#EXTINF:\s*([0-9.]+)/);
    if (!m) continue;
    const n = Number(m[1]);
    if (Number.isFinite(n) && n > 0) total += n;
  }
  return total;
}

/**
 * Maps each segment's basename to its duration (ms) from an HLS playlist's
 * #EXTINF lines. Used to detect GAPS in a player's video track: a gap means
 * the next segment starts later than the previous one ended, so the stream
 * dropped out (disconnect / backgrounded / screen-locked). Returns a Map so a
 * caller can look up a segment it actually has.
 */
function parsePlaylistDurations(playlistText) {
  const out = new Map();
  let pending = null;
  for (const line of String(playlistText ?? "").split(/\r?\n/)) {
    const m = line.match(/^#EXTINF:\s*([0-9.]+)/);
    if (m) {
      const n = Number(m[1]);
      pending = Number.isFinite(n) ? n : null;
      continue;
    }
    const uri = line.trim();
    if (pending != null && uri && !uri.startsWith("#")) {
      out.set(uri.split("/").pop(), Math.round(pending * 1000));
      pending = null;
    }
  }
  return out;
}

// A hole larger than this between two consecutive video segments is treated as
// a real dropout to be filled with black, not segment-boundary jitter.
const VIDEO_GAP_THRESHOLD_MS = 500;

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
    // Agora chunks each player's CONTINUOUS video into several ~30-40s .ts
    // segments (ordinary HLS segmentation), so any match longer than one
    // chunk has multiple video segments even with no reconnect. They are
    // contiguous - each starts exactly when the previous ends, and only the
    // AUDIO playlist carries DISCONTINUITY markers (for the muted turns) -
    // so they are concatenated in chronological order. Rendering only the
    // first segment (the old behaviour) dropped every player's footage after
    // ~30s. `segments` is already sorted by offset, so videoSegs is in order.
    //
    // Each segment is scaled/cropped/fps'd to the tile BEFORE concat so the
    // concat inputs are uniform; tpad then positions the whole track at the
    // first segment's offset, which aligns with the audio (both measured
    // from the same t0).
    // Build the track in order, inserting a black clip wherever the stream
    // dropped out (a GAP). Video was previously assumed contiguous, but a
    // player can lose their camera mid-match (disconnect / backgrounded /
    // screen locked); without filling the hole, everything after it plays
    // early and their picture drifts out of sync - visible as both players
    // appearing to talk at once. `durationMs` comes from the playlist; without
    // it, we fall back to the old contiguous concat. format=yuv420p on both the
    // segments and the black keeps the concat inputs uniform.
    const parts = [];
    for (let i = 0; i < videoSegs.length; i++) {
      const seg = videoSegs[i];
      if (i > 0 && videoSegs[i - 1].durationMs != null) {
        const prev = videoSegs[i - 1];
        const gapMs = seg.offsetMs - (prev.offsetMs + prev.durationMs);
        if (gapMs > VIDEO_GAP_THRESHOLD_MS) {
          const glabel = `[gap${uid}_${i}]`;
          filters.push(
              `color=c=black:s=${tile.width}x${tile.height}:r=${OUTPUT_FPS}:` +
            `d=${(gapMs / 1000).toFixed(3)},format=yuv420p,setsar=1${glabel}`,
          );
          parts.push(glabel);
        }
      }
      const index = inputIndex++;
      inputs.push("-i", path.join(localDir, seg.path.split("/").pop()));
      filters.push(
          `[${index}:v]scale=${tile.width}:${tile.height}:force_original_aspect_ratio=increase,` +
        `crop=${tile.width}:${tile.height},setsar=1,fps=${OUTPUT_FPS},format=yuv420p[vp${uid}_${index}]`,
      );
      parts.push(`[vp${uid}_${index}]`);
    }
    const pad = (videoSegs[0].offsetMs / 1000).toFixed(3);
    if (parts.length === 1) {
      filters.push(`${parts[0]}tpad=start_duration=${pad}:color=black[v${uid}]`);
    } else {
      filters.push(`${parts.join("")}concat=n=${parts.length}:v=1:a=0[vc${uid}]`);
      filters.push(`[vc${uid}]tpad=start_duration=${pad}:color=black[v${uid}]`);
    }
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
  // Dead-air cuts sit BETWEEN the stack and the subtitles, which is the
  // only correct place for them. Trimming after the burn-in would cut
  // through already-painted text; trimming before the stack would need
  // the same plan applied per input, and the two players' tracks start
  // at different offsets, so one plan could not fit both.
  //
  // The cues handed in are ALREADY remapped onto the trimmed timeline
  // by the caller - see remapCues - so the burn-in lands correctly on
  // the shortened video.
  // The brand-logo overlay is the LAST video stage, so the rest of the chain
  // ends at [vbeforelogo] and the overlay produces the final [vout].
  const applyLogo = !!options.logoPath;
  const vLast = applyLogo ? "[vbeforelogo]" : "[vout]";
  const trim = options.trimFilters ?? null;
  const stacked = trim ? "[vstacked]" :
    options.subtitlePath ? "[vpainted]" : vLast;
  if (videoLabels.length === 1) {
    filters.push(`${videoLabels[0]}scale=${canvas.width}:${canvas.height}:` +
      `force_original_aspect_ratio=increase,crop=${canvas.width}:${canvas.height}${stacked}`);
  } else {
    filters.push(
        `${videoLabels.join("")}${rendition.stackFilter}=inputs=${videoLabels.length}${stacked}`,
    );
  }

  // Emitted here rather than later purely for legibility: filter_complex
  // is a graph wired by labels, so ffmpeg does not care about the order
  // of stages in the string - but anybody reading it does, and a graph
  // whose stages run backwards is one nobody can check by eye.
  if (trim) {
    filters.push(`[vstacked]${trim.video}` +
      `${options.subtitlePath ? "[vpainted]" : vLast}`);
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
    filters.push(`[vpainted]subtitles='${escaped}'${vLast}`);
  }

  // Brand watermark: the home-page logo, small and slightly transparent, in
  // the bottom-left of every clip. Overlaid LAST so it sits above captions.
  if (applyLogo) {
    const logoIndex = inputIndex++;
    inputs.push("-i", options.logoPath);
    const logoW = Math.round(canvas.width * WATERMARK_LOGO_WIDTH_RATIO);
    const marginX = Math.round(canvas.width * WATERMARK_LOGO_MARGIN_X_RATIO);
    const marginY = Math.round(canvas.width * WATERMARK_LOGO_MARGIN_Y_RATIO);
    // BOTTOM-RIGHT: x = frame width - logo width - marginX (marginX clears the
    // in-app side-crop); y = frame height - logo height - marginY (hugs the
    // bottom). `W`/`H` are the main frame, `w`/`h` the scaled logo.
    filters.push(`[${logoIndex}:v]scale=${logoW}:-1,format=rgba,` +
      `colorchannelmixer=aa=${WATERMARK_LOGO_ALPHA}[wm]`);
    filters.push(`[vbeforelogo][wm]overlay=W-w-${marginX}:H-h-${marginY}[vout]`);
  }

  // normalize=0 because the segments do not overlap - normalising would
  // duck each player's volume by the number of inputs for no reason.
  if (audioLabels.length > 0) {
    // Audio is cut with the SAME intervals as the video. Anything else
    // desynchronises the clip, which is a worse outcome than not
    // trimming at all - a silent mismatch nobody would spot until
    // watching the finished file.
    const mixOut = trim ? "[amixed]" : "[aout]";
    filters.push(`${audioLabels.join("")}amix=inputs=${audioLabels.length}:` +
      `normalize=0:dropout_transition=0${mixOut}`);
    if (trim) filters.push(`[amixed]${trim.audio}[aout]`);
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

/**
 * FACE-OFF (improv) renders are a DIFFERENT shape, and must be.
 *
 * A roast battle is two players taking turns, one muted at a time, so the
 * stacked composite above works - both faces on screen, their lines
 * interleaved. A Face-Off is the opposite: both comedians perform the SAME
 * prompts SIMULTANEOUSLY and BLIND to each other, so stacking them plays two
 * people talking over each other at once - unwatchable and, worse,
 * unjudgeable. The crowd has to see one whole set, then the other, to decide
 * who was funnier.
 *
 * So a Face-Off clip is SEQUENTIAL: player 1's full set (red gel border),
 * a short black beat, then player 2's full set (blue gel border). The gel
 * colours are the exact ones the vote UI, live tally and judges' table use
 * (House.gelRed / House.gelBlue), so the border tells a judge whose set they
 * are watching and maps straight onto the red/blue winner buttons.
 *
 * Each performer's set is built on its OWN timeline (rebased to that
 * performer's first segment), then the sets are concatenated. That reuses
 * the same adelay/tpad alignment the composite uses - a performer's audio
 * is padded to their video length (apad) so the next set starts cleanly
 * rather than inheriting a within-set a/v mismatch.
 */
const GEL_RED = "0xC4485E";
const GEL_BLUE = "0x5E93A8";
const IMPROV_BORDER_COLORS = [GEL_RED, GEL_BLUE];
/** A black beat between the two sets, so "set one done, set two now" reads
 * without a caption. */
const IMPROV_GAP_SECONDS = 0.75;
/** Border thickness as a fraction of canvas width, so it is proportionate. */
const IMPROV_BORDER_RATIO = 0.012;

/**
 * Splits a flat recording file list into ONE timeline per performer, each
 * rebased to that performer's own first segment (so every set starts at 0).
 *
 * Pure, like buildTimeline, so the whole Face-Off layout can be exercised
 * without ffmpeg or Storage.
 */
function buildImprovTimelines(files) {
  const byUid = new Map();
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
    if (!byUid.has(uid)) byUid.set(uid, []);
    byUid.get(uid).push({path: p, uid, kind, startMs});
  }

  const performers = [];
  for (const uid of [...byUid.keys()].sort()) {
    const segs = byUid.get(uid);
    const t0 = Math.min(...segs.map((s) => s.startMs));
    for (const s of segs) s.offsetMs = s.startMs - t0;
    segs.sort((a, b) => a.offsetMs - b.offsetMs || a.kind.localeCompare(b.kind));
    performers.push({uid, segments: segs});
  }
  return {performers, dropped};
}

/**
 * The total video duration of one performer's set, in ms: where their first
 * video segment starts, plus every segment's length, plus any dropout holes
 * filled with black. Needs per-segment durations (from the playlist); returns
 * null without them, and the caller then skips the audio-length padding.
 */
function improvSetVideoDurationMs(performer) {
  const vids = performer.segments
      .filter((s) => s.kind === "video")
      .sort((a, b) => a.offsetMs - b.offsetMs);
  if (vids.length === 0) return 0;
  if (vids.some((s) => s.durationMs == null)) return null;
  let total = vids[0].offsetMs;
  for (let i = 0; i < vids.length; i++) {
    if (i > 0) {
      const gap = vids[i].offsetMs - (vids[i - 1].offsetMs + vids[i - 1].durationMs);
      if (gap > VIDEO_GAP_THRESHOLD_MS) total += gap;
    }
    total += vids[i].durationMs;
  }
  return total;
}

/**
 * Places each performer's caption cues onto the CONCATENATED Face-Off
 * timeline. Each performer is transcribed on their own rebased timeline, so
 * their cues are 0-based within their set; this shifts set i by the cumulative
 * duration of the earlier sets plus the black beat between each, so P2's
 * captions land over P2's set rather than on top of P1's.
 *
 * Pure, so the offset maths - the whole reason captions were deferred on this
 * cut - can be tested without ffmpeg or transcription.
 *
 * `sets` is in play order: [{durationSec, cues:[{uid,start,end,text}]}].
 */
function mergeImprovCues(sets, gapSeconds) {
  const out = [];
  let offset = 0;
  for (const set of sets) {
    for (const c of set.cues || []) {
      out.push({
        uid: c.uid,
        start: c.start + offset,
        end: c.end + offset,
        text: c.text,
      });
    }
    offset += (Number(set.durationSec) || 0) + gapSeconds;
  }
  return out;
}

/**
 * Builds the ffmpeg invocation for a sequential Face-Off render: each
 * performer's full set, full-frame, in their gel colour, concatenated with a
 * black beat between.
 *
 * Pure (no fs, no spawn) so the filter graph can be asserted in a unit test -
 * the same discipline the composite builder follows, and it matters more here
 * because there is no roast-style footage to eyeball until a real 2-device
 * Face-Off is recorded.
 */
function buildImprovFfmpegArgs(performers, localDir, outputPath, options = {}) {
  const canvas = options.canvas ?? RENDITIONS.vertical.canvas;
  const gapSec = options.gapSeconds ?? IMPROV_GAP_SECONDS;
  const border = Math.max(2, Math.round(canvas.width * IMPROV_BORDER_RATIO));
  const inputs = [];
  const filters = [];
  const concatParts = []; // interleaved [v][a] labels, in play order
  let inputIndex = 0;

  performers.forEach((perf, pi) => {
    const color = IMPROV_BORDER_COLORS[pi % IMPROV_BORDER_COLORS.length];
    const vids = perf.segments
        .filter((s) => s.kind === "video")
        .sort((a, b) => a.offsetMs - b.offsetMs);
    if (vids.length === 0) return;

    // Video: each segment filled to the FULL canvas (not a tile), holes
    // filled with black, concatenated in order, positioned at the set's own
    // first-video offset, then bordered in the performer's gel colour.
    const parts = [];
    for (let i = 0; i < vids.length; i++) {
      const seg = vids[i];
      if (i > 0 && vids[i - 1].durationMs != null) {
        const gapMs = seg.offsetMs - (vids[i - 1].offsetMs + vids[i - 1].durationMs);
        if (gapMs > VIDEO_GAP_THRESHOLD_MS) {
          const glabel = `[igap${pi}_${i}]`;
          filters.push(
              `color=c=black:s=${canvas.width}x${canvas.height}:r=${OUTPUT_FPS}:` +
            `d=${(gapMs / 1000).toFixed(3)},format=yuv420p,setsar=1${glabel}`);
          parts.push(glabel);
        }
      }
      const index = inputIndex++;
      inputs.push("-i", path.join(localDir, seg.path.split("/").pop()));
      filters.push(
          `[${index}:v]scale=${canvas.width}:${canvas.height}:force_original_aspect_ratio=increase,` +
        `crop=${canvas.width}:${canvas.height},setsar=1,fps=${OUTPUT_FPS},format=yuv420p[ivp${pi}_${index}]`);
      parts.push(`[ivp${pi}_${index}]`);
    }
    const pad = (vids[0].offsetMs / 1000).toFixed(3);
    if (parts.length === 1) {
      filters.push(`${parts[0]}tpad=start_duration=${pad}:color=black[ivj${pi}]`);
    } else {
      filters.push(`${parts.join("")}concat=n=${parts.length}:v=1:a=0[ivc${pi}]`);
      filters.push(`[ivc${pi}]tpad=start_duration=${pad}:color=black[ivj${pi}]`);
    }
    // The gel border, drawn INSIDE the frame so it never changes the canvas
    // size (concat needs every segment identical).
    filters.push(`[ivj${pi}]drawbox=x=0:y=0:w=iw:h=ih:color=${color}@1:t=${border}[iv${pi}]`);

    // Audio: each of the performer's audio segments delayed to its own
    // within-set offset, mixed, then PADDED to the video length so the set's
    // audio and video end together - otherwise the next concatenated set
    // would start with the two streams out of step.
    const auds = perf.segments.filter((s) => s.kind === "audio");
    const setDurMs = improvSetVideoDurationMs(perf);
    const setDurSec = setDurMs != null ? (setDurMs / 1000) : null;
    if (auds.length === 0) {
      // A silent set still has to carry an audio stream, or concat (v=1:a=1)
      // cannot line the sets up.
      const d = setDurSec != null ? setDurSec.toFixed(3) : "0.1";
      filters.push(`anullsrc=channel_layout=stereo:sample_rate=44100,` +
        `atrim=duration=${d},asetpts=PTS-STARTPTS[ia${pi}]`);
    } else {
      const aLabels = [];
      for (const seg of auds) {
        const index = inputIndex++;
        inputs.push("-i", path.join(localDir, seg.path.split("/").pop()));
        const delay = Math.round(seg.offsetMs);
        filters.push(`[${index}:a]adelay=${delay}|${delay}[iad${pi}_${index}]`);
        aLabels.push(`[iad${pi}_${index}]`);
      }
      const mix = `[iam${pi}]`;
      filters.push(`${aLabels.join("")}amix=inputs=${aLabels.length}:` +
        `normalize=0:dropout_transition=0${mix}`);
      // aresample+aformat so every set's audio shares one format for concat;
      // apad to the video length when it is known.
      const padTo = setDurSec != null ? `,apad=whole_dur=${setDurSec.toFixed(3)}` : "";
      filters.push(`${mix}aresample=44100,` +
        `aformat=sample_fmts=fltp:channel_layouts=stereo${padTo}[ia${pi}]`);
    }

    concatParts.push(`[iv${pi}]`, `[ia${pi}]`);
    // A black beat between sets (not after the last).
    if (pi < performers.length - 1 && gapSec > 0) {
      filters.push(`color=c=black:s=${canvas.width}x${canvas.height}:r=${OUTPUT_FPS}:` +
        `d=${gapSec},format=yuv420p,setsar=1[ibv${pi}]`);
      filters.push(`anullsrc=channel_layout=stereo:sample_rate=44100,` +
        `atrim=duration=${gapSec},asetpts=PTS-STARTPTS,` +
        `aformat=sample_fmts=fltp:channel_layouts=stereo[iba${pi}]`);
      concatParts.push(`[ibv${pi}]`, `[iba${pi}]`);
    }
  });

  if (concatParts.length === 0) throw new Error("no performer set to render");

  const segCount = concatParts.length / 2;
  // Concat always lands in [ivcat]; the optional subtitles stage and the
  // optional watermark are threaded after it, ending at [vout].
  if (segCount === 1) {
    // Only one performer published anything - rename the single pair rather
    // than concat=n=1, which some ffmpeg builds reject.
    filters.push(`${concatParts[0]}null[ivcat]`);
    filters.push(`${concatParts[1]}anull[aout]`);
  } else {
    filters.push(`${concatParts.join("")}concat=n=${segCount}:v=1:a=1[ivcat][aout]`);
  }

  // Burned-in captions (posting-only), BEFORE the watermark so the logo sits
  // above the text. Cues are already placed on the concatenated timeline by
  // the caller (P2's set offset past P1's set + the black beat).
  let vlabel = "[ivcat]";
  if (options.subtitlePath) {
    const escaped = options.subtitlePath
        .replace(/\\/g, "/").replace(/:/g, "\\:").replace(/'/g, "\\'");
    filters.push(`${vlabel}subtitles='${escaped}'[ivsub]`);
    vlabel = "[ivsub]";
  }

  if (options.logoPath) {
    const logoIndex = inputIndex++;
    inputs.push("-i", options.logoPath);
    const logoW = Math.round(canvas.width * WATERMARK_LOGO_WIDTH_RATIO);
    const marginX = Math.round(canvas.width * WATERMARK_LOGO_MARGIN_X_RATIO);
    const marginY = Math.round(canvas.width * WATERMARK_LOGO_MARGIN_Y_RATIO);
    filters.push(`[${logoIndex}:v]scale=${logoW}:-1,format=rgba,` +
      `colorchannelmixer=aa=${WATERMARK_LOGO_ALPHA}[iwm]`);
    filters.push(`${vlabel}[iwm]overlay=W-w-${marginX}:H-h-${marginY}[vout]`);
  } else {
    filters.push(`${vlabel}null[vout]`);
  }

  return [
    "-y",
    ...inputs,
    "-filter_complex", filters.join(";"),
    "-map", "[vout]",
    "-map", "[aout]",
    "-c:v", "libx264",
    "-preset", "veryfast",
    "-crf", "23",
    "-pix_fmt", "yuv420p",
    "-c:a", "aac",
    "-b:a", "128k",
    "-movflags", "+faststart",
    outputPath,
  ];
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

  // Face-Off is a different shape (sequential, not stacked) - see
  // buildImprovFfmpegArgs. Delegated whole rather than branched inline so the
  // composite path below stays untouched.
  if (snap.data()?.mode === "improv") {
    return renderImprovHighlight(matchId, matchRef, bucket, {captions});
  }

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

    // A player's VIDEO can drop out mid-match (disconnect / app backgrounded /
    // screen locked), leaving a hole between segments. Audio gaps were already
    // handled per-segment, but video gaps were not - the segments were
    // concatenated contiguously, so everything after a hole played early and
    // that player's picture drifted out of sync. Read each video playlist's
    // per-segment durations so buildFfmpegArgs can detect the holes and fill
    // them with black. Best-effort: without durations it falls back to the old
    // contiguous behaviour.
    for (const uid of timeline.uids) {
      const plObj = objects.find((o) => o.name.endsWith(".m3u8") &&
          o.name.includes(`__uid_s_${uid}__uid_e_video`));
      if (!plObj) continue;
      try {
        const text = await fs.readFile(
            path.join(workDir, plObj.name.split("/").pop()), "utf8");
        const durByName = parsePlaylistDurations(text);
        for (const s of timeline.segments) {
          if (s.uid === uid && s.kind === "video") {
            const d = durByName.get(s.path.split("/").pop());
            if (d != null) s.durationMs = d;
          }
        }
      } catch (e) {
        warnings.push(`could not read video playlist for player ${uid}`);
      }
    }

    const ffmpegPath = require("ffmpeg-static");

    // Transcribed ONCE and reused across both renditions. Speech-to-Text
    // bills per audio minute, so transcribing per rendition would double
    // the cost for identical words.
    let cues = [];
    // Kept alongside the cues because dead-air trimming is driven by the
    // word timings rather than by audio analysis - see trimSilence.js.
    let transcript = {words: [], failures: []};
    if (captions) {
      const {transcribeSegments, groupWordsIntoCues} = require("./captions");
      const audioSegs = timeline.segments.filter((s) => s.kind === "audio");
      const {words, failures} = await transcribeSegments(
          audioSegs, workDir, ffmpegPath, workDir,
      );
      transcript = {words, failures};
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

    // DEAD-AIR TRIMMING. Planned once, here, and applied to every
    // rendition, so the two shapes of the same battle are cut
    // identically - a viewer who sees the vertical clip and then the
    // landscape one must not find them different edits.
    //
    // Only possible when captions ran: the plan is built from word
    // timings. An uncaptioned stage-1 render is left untrimmed, which
    // is the right trade - those exist so the judge feed has something
    // to play, and cutting them would mean trusting an audio-level
    // heuristic to decide what footage to destroy.
    let trimFilters = null;
    let trimmedSeconds = 0;
    if (captions && transcript.words.length > 0) {
      const {planKeeps, remapCues, removedSeconds, buildTrimFilters} =
        require("./trimSilence");
      // Duration from the playlists themselves, which are already
      // downloaded - the longest player's track, measured from its own
      // offset into the composite timeline.
      let duration = 0;
      for (const uid of timeline.uids) {
        const seg = timeline.segments.find(
            (x) => x.uid === uid && x.kind === "video");
        if (!seg) continue;
        const playlist = objects.find((o) =>
          o.name.endsWith(".m3u8") && o.name.includes(`__uid_s_${uid}__uid_e`) &&
          o.name.includes("_video"));
        if (!playlist) continue;
        const text = await fs.readFile(
            path.join(workDir, playlist.name.split("/").pop()), "utf8")
            .catch(() => "");
        duration = Math.max(duration,
            seg.offsetMs / 1000 + sumExtinfSeconds(text));
      }

      const keeps = planKeeps(transcript.words,
          {duration, failures: transcript.failures});
      trimFilters = buildTrimFilters(keeps, duration);
      if (trimFilters) {
        trimmedSeconds = removedSeconds(keeps, duration);
        // THE CUES MUST MOVE WITH THE CUTS. Burning captions at their
        // original times onto shortened video drifts them further out
        // of sync with every cut, and a clip whose subtitles lag the
        // mouth looks broken rather than merely unsubtitled.
        cues = remapCues(cues, keeps);
      } else if (duration <= 0) {
        warnings.push("clip duration could not be measured, so dead air " +
          "was left in");
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

      // A captioned render is written to a SEPARATE file rather than
      // overwriting the uncaptioned stage-1 output. Captions are
      // posting-only (CLAUDE.md, 2026-09-22): the judge/Watch feed plays
      // `renditions[name].path`, so burning captions into that same path
      // would leak them into in-app judging. Keeping the captioned cut
      // beside it also means the untrimmed full clip stays available for
      // judging while the posted/download cut is the trimmed, captioned one.
      const outFileName = captions ?
        rendition.fileName.replace(/\.mp4$/, "_captioned.mp4") :
        rendition.fileName;
      const outputPath = path.join(workDir, outFileName);
      await runFfmpeg(ffmpegPath, buildFfmpegArgs(timeline, workDir, outputPath, {
        subtitlePath, rendition, trimFilters, logoPath: WATERMARK_LOGO,
      }));

      const destination = `${HIGHLIGHT_PREFIX}/${matchId}/${outFileName}`;
      await bucket.upload(outputPath, {destination, metadata: {contentType: "video/mp4"}});
      outputs[name] = {
        path: destination,
        sizeBytes: (await fs.stat(outputPath)).size,
        width: rendition.canvas.width,
        height: rendition.canvas.height,
      };
    }

    if (captions) {
      // Record the captioned files ALONGSIDE the uncaptioned renditions,
      // not in place of them. `renditions[name].captionedPath` is deep-
      // merged into each existing rendition, so `.path` (what the judge
      // feed serves) is preserved. reviewStatus/published are deliberately
      // left untouched, so re-captioning never un-publishes an approved clip.
      const renditionMerge = {};
      for (const [name, out] of Object.entries(outputs)) {
        renditionMerge[name] = {
          captionedPath: out.path,
          captionedSizeBytes: out.sizeBytes,
        };
      }
      await matchRef.set({
        highlight: {
          renditions: renditionMerge,
          captioned: cues.length > 0,
          cueCount: cues.length,
          trimmedSeconds: Math.round(trimmedSeconds * 10) / 10,
          captionedRenderedAt: FieldValue.serverTimestamp(),
          ...(warnings.length > 0 ? {captionWarnings: warnings} : {}),
        },
      }, {merge: true});
    } else {
      await matchRef.set({
        highlight: {
          // Keyed by rendition so the website and the social pipeline each
          // pick the shape they need from the same match document.
          renditions: outputs,
          renderedAt: FieldValue.serverTimestamp(),
          captioned: cues.length > 0,
          cueCount: cues.length,
          // Recorded so a short clip is explicable after the fact, and so
          // the thresholds can be tuned against what they actually did
          // rather than against a guess.
          trimmedSeconds: Math.round(trimmedSeconds * 10) / 10,
          // Same human gate as the raw recording: rendering something
          // watchable is not the same as approving it for an audience.
          reviewStatus: "pending",
          published: false,
          ...(warnings.length > 0 ? {warnings} : {}),
        },
      }, {merge: true});
    }

    return {rendered: true, renditions: outputs, cueCount: cues.length, warnings};
  } finally {
    await fs.rm(workDir, {recursive: true, force: true}).catch(() => {});
  }
}

/**
 * Renders a Face-Off (improv) match into one sequential vertical clip: each
 * performer's full set, full-frame, in their gel colour, back to back.
 *
 * Two stages, like the roast path. Stage 1 (captions=false) is the uncaptioned
 * cut the judge feed plays. Stage 2 (captions=true, on request for posting)
 * transcribes each performer separately - free speaker attribution, since
 * improv records per-player - and burns red/blue captions placed onto the
 * concatenated timeline (mergeImprovCues shifts P2's set past P1's + the beat).
 * NO landscape cut: a portrait single-performer sequence has no good 16:9 form.
 */
async function renderImprovHighlight(matchId, matchRef, bucket, {captions = false} = {}) {
  const [objects] = await bucket.getFiles({prefix: `match_recordings/${matchId}/`});
  if (objects.length === 0) throw new Error("No recording found for this match.");

  const {performers, dropped} = buildImprovTimelines(
      objects.map((o) => ({path: o.name, sizeBytes: Number(o.metadata?.size ?? 0)})),
  );
  const withVideo = performers.filter((p) =>
    p.segments.some((s) => s.kind === "video"));
  if (withVideo.length === 0) {
    throw new Error("No usable segments in the recording.");
  }

  const warnings = [];
  if (dropped.length > 0) {
    warnings.push(`skipped ${dropped.length} truncated segment(s) too small to decode`);
  }

  const workDir = await fs.mkdtemp(path.join(os.tmpdir(), `improv-${matchId}-`));
  try {
    await Promise.all(objects.map((o) =>
      bucket.file(o.name).download({destination: path.join(workDir, o.name.split("/").pop())}),
    ));

    // Per-segment video durations, so a mid-set camera dropout is filled with
    // black and each set's audio is padded to the right length. Best-effort:
    // without a readable playlist the set still renders, just without the
    // gap-fill / audio pad.
    for (const perf of performers) {
      const plObj = objects.find((o) => o.name.endsWith(".m3u8") &&
          o.name.includes(`__uid_s_${perf.uid}__uid_e_video`));
      if (!plObj) continue;
      try {
        const text = await fs.readFile(
            path.join(workDir, plObj.name.split("/").pop()), "utf8");
        const durByName = parsePlaylistDurations(text);
        for (const s of perf.segments) {
          if (s.kind === "video") {
            const d = durByName.get(s.path.split("/").pop());
            if (d != null) s.durationMs = d;
          }
        }
      } catch (e) {
        warnings.push(`could not read video playlist for player ${perf.uid}`);
      }
    }

    const ffmpegPath = require("ffmpeg-static");
    const rendition = RENDITIONS.vertical;

    // STAGE 2: the captioned POSTING cut. Written to a SEPARATE file beside
    // the uncaptioned one (captions are posting-only, like the roast path), so
    // the judge feed keeps playing the uncaptioned `.path` while the posted
    // download is the captioned cut.
    if (captions) {
      const {transcribeSegments, groupWordsIntoCues, buildAssFile} =
        require("./captions");
      // Transcribe each performer SEPARATELY on their own rebased timeline, so
      // every word is attributed to the right player and timed within that
      // player's set; mergeImprovCues then offsets P2's set onto the concat.
      const sets = [];
      for (const perf of withVideo) {
        const audioSegs = perf.segments.filter((s) => s.kind === "audio");
        const {words, failures} = await transcribeSegments(
            audioSegs, workDir, ffmpegPath, workDir);
        if (failures.length > 0) {
          warnings.push(
              `${failures.length} audio segment(s) could not be transcribed`);
        }
        const durMs = improvSetVideoDurationMs(perf);
        sets.push({
          durationSec: durMs != null ? durMs / 1000 : 0,
          cues: groupWordsIntoCues(words),
        });
      }
      const merged = mergeImprovCues(sets, IMPROV_GAP_SECONDS);
      if (merged.length === 0) {
        warnings.push("no speech was transcribed, so the clip has no captions");
      }
      const subtitlePath = path.join(workDir, "improv-captions.ass");
      await fs.writeFile(
          subtitlePath, buildAssFile(merged, rendition.canvas), "utf8");

      const capName = rendition.fileName.replace(/\.mp4$/, "_captioned.mp4");
      const capPath = path.join(workDir, capName);
      await runFfmpeg(ffmpegPath, buildImprovFfmpegArgs(withVideo, workDir, capPath, {
        canvas: rendition.canvas,
        logoPath: WATERMARK_LOGO,
        subtitlePath,
      }));
      const capDest = `${HIGHLIGHT_PREFIX}/${matchId}/${capName}`;
      await bucket.upload(capPath, {destination: capDest, metadata: {contentType: "video/mp4"}});

      // Deep-merge the captioned path into the existing vertical rendition so
      // `.path` (what the judge feed serves) is preserved. reviewStatus /
      // published are left untouched, so re-captioning never un-publishes.
      await matchRef.set({
        highlight: {
          renditions: {
            vertical: {
              captionedPath: capDest,
              captionedSizeBytes: (await fs.stat(capPath)).size,
            },
          },
          captioned: merged.length > 0,
          captionedRenderedAt: FieldValue.serverTimestamp(),
          ...(warnings.length > 0 ? {captionWarnings: warnings} : {}),
        },
      }, {merge: true});

      return {rendered: true, captioned: merged.length > 0, warnings};
    }

    // STAGE 1: the uncaptioned cut the judge feed plays.
    const outputPath = path.join(workDir, rendition.fileName);
    await runFfmpeg(ffmpegPath, buildImprovFfmpegArgs(withVideo, workDir, outputPath, {
      canvas: rendition.canvas,
      logoPath: WATERMARK_LOGO,
    }));

    const destination = `${HIGHLIGHT_PREFIX}/${matchId}/${rendition.fileName}`;
    await bucket.upload(outputPath, {destination, metadata: {contentType: "video/mp4"}});
    const out = {
      vertical: {
        path: destination,
        sizeBytes: (await fs.stat(outputPath)).size,
        width: rendition.canvas.width,
        height: rendition.canvas.height,
      },
    };

    await matchRef.set({
      highlight: {
        renditions: out,
        // Marks this as the sequential Face-Off cut, so the client and any
        // later tooling know not to treat it as a top/bottom composite.
        layout: "sequential",
        renderedAt: FieldValue.serverTimestamp(),
        captioned: false,
        reviewStatus: "pending",
        published: false,
        ...(warnings.length > 0 ? {warnings} : {}),
      },
    }, {merge: true});

    return {rendered: true, renditions: out, warnings};
  } finally {
    await fs.rm(workDir, {recursive: true, force: true}).catch(() => {});
  }
}

module.exports = {
  sumExtinfSeconds,
  renderMatchHighlight,
  renderImprovHighlight,
  buildImprovTimelines,
  buildImprovFfmpegArgs,
  improvSetVideoDurationMs,
  mergeImprovCues,
  parseSegmentTimeMs,
  classifyFile,
  buildTimeline,
  buildFfmpegArgs,
  RENDITIONS,
  CANVAS,
  TILE,
  HIGHLIGHT_PREFIX,
};
