/**
 * Cutting dead air out of a highlight clip (CLAUDE.md's Auto-Editing for
 * Highlights: "cut out dead space - silence, hesitation, pauses - so the
 * posted clip is just joke-after-joke").
 *
 * DRIVEN BY THE TRANSCRIPT, NOT BY AUDIO ANALYSIS. Captioning already
 * produces word-level timestamps for the whole clip, and they are already
 * paid for - so the question "was anybody speaking at second 34" is
 * already answered exactly, with speaker attribution, and needs no
 * silencedetect pass and no second decode. It is also a better signal:
 * an audio-level threshold cannot tell speech from a cough, a laugh, or
 * a bump on the desk.
 *
 * THE COMEDY CONSTRAINT, which is why the thresholds are conservative. A
 * pause is a BEAT. In roast content the reaction is frequently funnier
 * than the line, and the moment right after a punch lands is exactly the
 * moment a naive trimmer would delete. So this only removes air that is
 * long enough to be a genuine stall, and it leaves a good part of even
 * those gaps in place. Under-trimming costs a slightly slack clip;
 * over-trimming destroys the timing that made it funny.
 *
 * IT REFUSES TO ACT ON INCOMPLETE INFORMATION, and that guard matters
 * more than the trimming does - see shouldTrim below.
 */

/** Only a gap at least this long is a candidate for cutting. */
const MIN_GAP_SECONDS = 2.5;

/** How much of a cut gap is left in place, so a cut still breathes. */
const KEEP_IN_GAP_SECONDS = 0.6;

/** Speech is padded by this much either side before gaps are measured, so
 * a cut never lands hard against the first or last syllable. */
const SPEECH_PAD_SECONDS = 0.25;

/**
 * If trimming would remove more than this share of the clip, trim NOTHING.
 *
 * The failure this exists for is specific and silent: transcription runs
 * per player, and a failure for ONE of them leaves their speech with no
 * words at all - so their entire turn reads as dead air and would be cut
 * out, deleting half the battle while the render succeeds and looks fine.
 * A clip that is mostly silence by this measure is a clip we do not
 * understand, and the safe move is to leave it alone.
 */
const MAX_REMOVED_SHARE = 0.4;

/**
 * Whether a transcript is trustworthy enough to cut video with.
 *
 * ANY transcription failure disables trimming entirely, deliberately.
 * Captioning degrades gracefully because a missing caption costs a
 * caption; trimming on a partial transcript costs the footage itself, and
 * that is not recoverable from the rendered file.
 */
function shouldTrim(words, failures) {
  if (Array.isArray(failures) && failures.length > 0) return false;
  return Array.isArray(words) && words.length > 0;
}

/**
 * The intervals of the source clip to KEEP.
 *
 * Returns a single full-length interval whenever it is not confident,
 * which is the no-op case: the caller can always concatenate the result
 * without checking whether anything was cut.
 */
function planKeeps(words, {
  duration,
  minGap = MIN_GAP_SECONDS,
  keepInGap = KEEP_IN_GAP_SECONDS,
  pad = SPEECH_PAD_SECONDS,
  maxRemovedShare = MAX_REMOVED_SHARE,
  failures = [],
} = {}) {
  const total = Number(duration);
  if (!Number.isFinite(total) || total <= 0) return [];
  const whole = [{start: 0, end: total}];
  if (!shouldTrim(words, failures)) return whole;

  // Speech spans, padded and merged. Merged first so two words a tenth of
  // a second apart are not treated as a gap worth measuring.
  const spans = [];
  for (const w of [...words].sort((a, b) => a.start - b.start)) {
    const start = Math.max(0, Number(w.start) - pad);
    const end = Math.min(total, Number(w.end) + pad);
    if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start) {
      continue;
    }
    const last = spans[spans.length - 1];
    if (last && start <= last.end) last.end = Math.max(last.end, end);
    else spans.push({start, end});
  }
  if (spans.length === 0) return whole;

  // Every stretch with nobody speaking, including before the first word
  // and after the last.
  const gaps = [];
  let cursor = 0;
  for (const span of spans) {
    if (span.start - cursor >= minGap) gaps.push({start: cursor, end: span.start});
    cursor = span.end;
  }
  if (total - cursor >= minGap) gaps.push({start: cursor, end: total});

  if (gaps.length === 0) return whole;

  // A middle gap keeps keepInGap of the pause, split either side, so the
  // cut still breathes.
  //
  // THE TWO EDGES ARE DIFFERENT, and getting this wrong is invisible in
  // the plan and obvious in the clip. A LEADING gap is cut from zero: the
  // opening second is where a viewer decides whether to keep watching,
  // and there is nothing before it to breathe from. A TRAILING gap is cut
  // all the way to the end for the mirror reason - splitting it leaves a
  // sliver of silence hanging off the end of the clip, which is precisely
  // the dead air this exists to remove and the last thing a viewer sees.
  const cuts = [];
  for (const gap of gaps) {
    const leading = gap.start === 0;
    const trailing = gap.end >= total;
    let cut;
    if (leading && trailing) cut = null; // nobody spoke; handled above
    else if (leading) cut = {start: 0, end: Math.max(0, gap.end - keepInGap)};
    else if (trailing) cut = {start: gap.start + keepInGap, end: total};
    else cut = {start: gap.start + keepInGap / 2, end: gap.end - keepInGap / 2};
    if (cut && cut.end - cut.start > 0.05) cuts.push(cut);
  }
  if (cuts.length === 0) return whole;

  const removed = cuts.reduce((sum, c) => sum + (c.end - c.start), 0);
  if (removed / total > maxRemovedShare) return whole;

  // Invert the cuts into keeps.
  const keeps = [];
  let at = 0;
  for (const cut of cuts) {
    if (cut.start > at) keeps.push({start: at, end: cut.start});
    at = cut.end;
  }
  if (at < total) keeps.push({start: at, end: total});

  return keeps.length > 0 ? keeps : whole;
}

/** Total seconds removed by a keep plan. */
function removedSeconds(keeps, duration) {
  const kept = keeps.reduce((sum, k) => sum + (k.end - k.start), 0);
  return Math.max(0, Number(duration) - kept);
}

/** Whether a plan actually cuts anything. */
function trims(keeps, duration) {
  return removedSeconds(keeps, duration) > 0.05;
}

/**
 * Where a moment in the SOURCE lands on the trimmed timeline.
 *
 * Returns null for a moment inside a cut, which is how a caption whose
 * words were removed is dropped rather than being pinned to the wrong
 * frame. THE CAPTIONS MUST BE REMAPPED THROUGH THE SAME PLAN or they
 * drift further out of sync with every cut - and a clip whose subtitles
 * lag the mouth by three seconds is worse than one with no subtitles at
 * all, because it looks broken rather than plain.
 */
function remapTime(t, keeps) {
  let elapsed = 0;
  for (const keep of keeps) {
    if (t < keep.start) return null;
    if (t <= keep.end) return elapsed + (t - keep.start);
    elapsed += keep.end - keep.start;
  }
  return null;
}

/**
 * Moves caption cues onto the trimmed timeline.
 *
 * A cue whose start survives is kept and its end is clamped into the same
 * kept interval, so a cue can never be stretched across a cut and hang on
 * screen through a jump.
 */
function remapCues(cues, keeps) {
  const out = [];
  for (const cue of cues) {
    const start = remapTime(cue.start, keeps);
    if (start === null) continue;
    let end = remapTime(cue.end, keeps);
    if (end === null || end <= start) {
      // The cue's tail was cut. Hold it for a readable minimum rather than
      // dropping a line somebody actually said.
      end = start + 0.4;
    }
    out.push({...cue, start, end});
  }
  return out;
}

/**
 * The ffmpeg filter fragments that perform the cuts.
 *
 * `select` keeps only frames inside the kept intervals and `setpts`
 * closes the resulting holes; the audio pair does the same. Returns null
 * when nothing is cut, so the caller can leave its filter graph untouched
 * rather than paying for a no-op pass.
 */
function buildTrimFilters(keeps, duration) {
  if (!trims(keeps, duration)) return null;
  const expr = keeps
      .map((k) => `between(t,${k.start.toFixed(3)},${k.end.toFixed(3)})`)
      .join("+");
  return {
    video: `select='${expr}',setpts=N/FRAME_RATE/TB`,
    audio: `aselect='${expr}',asetpts=N/SR/TB`,
  };
}

module.exports = {
  planKeeps,
  remapTime,
  remapCues,
  removedSeconds,
  trims,
  buildTrimFilters,
  shouldTrim,
  MIN_GAP_SECONDS,
  KEEP_IN_GAP_SECONDS,
  MAX_REMOVED_SHARE,
};
