const path = require("path");
const fs = require("fs/promises");
const {spawn} = require("child_process");

/**
 * Burned-in captions for highlight clips (CLAUDE.md's Production quality
 * bar: "captions/subtitles - important for social algorithms and muted
 * autoplay viewing - most social video is watched without sound").
 *
 * SPEAKER ATTRIBUTION IS FREE HERE, which is the nice consequence of
 * recording each player separately. Normally captioning a two-person
 * conversation means speaker diarization, which is error-prone and gets
 * worse exactly when people talk over each other - which in a roast battle
 * is the interesting part. Because every audio file belongs to exactly one
 * player by construction, every transcribed word already knows who said
 * it, with no guessing at all.
 *
 * Each audio segment is transcribed on its own and its word timings are
 * then shifted by that segment's offset in the clip. Segments run about
 * 15 seconds, comfortably inside the synchronous recognizer's limit, so
 * this needs no long-running jobs or intermediate GCS uploads.
 */

/** Speech-to-Text wants uncompressed mono; the recordings are AAC in
 * MPEG-TS. 16 kHz is the documented sweet spot for recognition accuracy -
 * higher sample rates cost bandwidth without improving transcription. */
const STT_SAMPLE_RATE = 16000;

/**
 * Caption styling, tuned for short-form vertical video rather than
 * broadcast subtitling.
 *
 * Cues are deliberately SHORT - a few words at a time, held briefly.
 * Full-sentence subtitles are the wrong shape for this format: they ask
 * the viewer to read while the joke lands. Short bursts track speech
 * closely and keep the eye near the faces.
 */
const STYLE = {
  fontName: "Arial",
  // Sized as a FRACTION of the canvas height rather than in fixed pixels,
  // because the same cues are rendered into both a 1080x1920 vertical clip
  // and a 1920x1080 landscape one. A fixed size legible in the first is
  // absurdly large in the second.
  fontHeightRatio: 0.05,
  outlineRatio: 0.0031,
  shadowRatio: 0.001,
  // Vertically centred, which on a stacked two-player layout puts the
  // text on the seam between the players rather than over either face,
  // and clear of the platform UI that crowds the bottom of the screen.
  alignment: 5,
  // Per-speaker colour so a viewer can tell who is talking without
  // relying on the video alone. ASS colours are &HAABBGGRR (reversed).
  player1Colour: "&H00FFFFFF", // white
  player2Colour: "&H0000E5FF", // amber
};

const MAX_WORDS_PER_CUE = 4;
const MAX_CUE_SECONDS = 2.5;
/** A pause longer than this ends the current cue - it usually means a new
 * thought, and holding stale text across a beat reads as lag. */
const CUE_SPLIT_GAP_SECONDS = 0.6;

function runProcess(binary, args) {
  return new Promise((resolve, reject) => {
    const proc = spawn(binary, args);
    let stderr = "";
    proc.stderr.on("data", (d) => {
      stderr = (stderr + d.toString()).slice(-3000);
    });
    proc.on("error", reject);
    proc.on("close", (code) => code === 0 ? resolve(stderr) :
      reject(new Error(`${path.basename(binary)} exited ${code}: ${stderr.slice(-800)}`)));
  });
}

/** Converts one recorded audio segment into the mono PCM the recognizer
 * expects. */
async function toRecognizerAudio(ffmpegPath, inputPath, outputPath) {
  await runProcess(ffmpegPath, [
    "-y", "-i", inputPath,
    "-vn", "-ac", "1", "-ar", String(STT_SAMPLE_RATE),
    "-c:a", "pcm_s16le", outputPath,
  ]);
}

/** Seconds from a Speech-to-Text duration, which arrives as
 * {seconds, nanos} with either field possibly absent. */
function durationToSeconds(duration) {
  if (!duration) return 0;
  return Number(duration.seconds ?? 0) + Number(duration.nanos ?? 0) / 1e9;
}

/**
 * Groups a flat word stream into short caption cues.
 *
 * Pure and separated from transcription so the grouping rules can be
 * tested directly - they're what decide whether captions feel snappy or
 * laggy, and that's judgement encoded in numbers rather than anything the
 * recognizer returns.
 */
function groupWordsIntoCues(words, options = {}) {
  const maxWords = options.maxWords ?? MAX_WORDS_PER_CUE;
  const maxSeconds = options.maxSeconds ?? MAX_CUE_SECONDS;
  const splitGap = options.splitGap ?? CUE_SPLIT_GAP_SECONDS;

  const cues = [];
  let current = null;

  for (const word of [...words].sort((a, b) => a.start - b.start)) {
    const startsNewCue = !current ||
      current.uid !== word.uid ||
      current.words.length >= maxWords ||
      word.start - current.end > splitGap ||
      word.end - current.start > maxSeconds;

    if (startsNewCue) {
      current = {uid: word.uid, start: word.start, end: word.end, words: [word.text]};
      cues.push(current);
    } else {
      current.words.push(word.text);
      current.end = word.end;
    }
  }

  return cues.map((c) => ({
    uid: c.uid,
    start: c.start,
    // Hold each cue a beat past the last word so it doesn't vanish the
    // instant someone stops speaking.
    end: Math.max(c.end + 0.15, c.start + 0.4),
    text: c.words.join(" "),
  }));
}

/** ASS timestamps are H:MM:SS.cc with centisecond precision. */
function formatAssTime(seconds) {
  const clamped = Math.max(0, seconds);
  const h = Math.floor(clamped / 3600);
  const m = Math.floor((clamped % 3600) / 60);
  const s = Math.floor(clamped % 60);
  const cs = Math.round((clamped - Math.floor(clamped)) * 100);
  // Rounding centiseconds can carry to 100; normalise rather than emit
  // an invalid ".100".
  const carry = cs === 100 ? 1 : 0;
  const shown = cs === 100 ? 0 : cs;
  return `${h}:${String(m).padStart(2, "0")}:${String(s + carry).padStart(2, "0")}` +
    `.${String(shown).padStart(2, "0")}`;
}

/** Commas and braces are structural in ASS dialogue lines, so text
 * carrying them would corrupt the file or be read as override tags. */
function escapeAssText(text) {
  return text.replace(/\\/g, "\\\\").replace(/\{/g, "(").replace(/\}/g, ")").replace(/\n/g, " ");
}

/**
 * Builds a complete ASS subtitle file from cues, scaled to the canvas it
 * will be burned into.
 *
 * Sizes derive from canvas height so one set of cues serves both the
 * vertical and landscape renditions without being re-transcribed or
 * hand-tuned per shape.
 */
/**
 * The burned-in brand mark.
 *
 * WHY IT RIDES ALONG WITH THE CAPTIONS rather than being an ffmpeg
 * `drawtext` filter, which is the obvious answer: drawtext needs a font
 * file, and whether one resolves on the Cloud Functions runtime is not
 * something this project can verify from a Windows dev machine. A missing
 * font fails the whole render, so a cosmetic mark would take the entire
 * clip pipeline down with it. libass is already rendering text
 * successfully here for captions, so reusing it is the proven path.
 *
 * WHY IT MATTERS: CLAUDE.md's monetization decision is "watermark
 * everything" — clips are the growth engine, and an unbranded clip posted
 * to TikTok is free distribution for somebody else's feed. Removing the
 * mark is deliberately NOT sold as a perk, because that would mean charging
 * the most engaged users to strip the branding they are best placed to
 * spread.
 *
 * TOP-LEFT, because the bottom and right of a short-form frame are where
 * TikTok, Reels and Shorts stack their own UI, and the vertical centre is
 * where captions sit on a stacked composite. Semi-transparent and small so
 * it reads as a mark rather than an obstruction.
 */
const WATERMARK = {
  text: "THE BULLY LEAGUE",
  fontHeightRatio: 0.022,
  // &H<alpha><blue><green><red>, so this is white at ~45% transparency.
  colour: "&H4CFFFFFF",
  outlineColour: "&H80000000",
  alignment: 7,
};

/** Far beyond any real clip. An ASS event outstaying the video simply
 * stops rendering, so this avoids threading a duration through purely to
 * end a mark that should be there the whole time. */
const WATERMARK_END = "9:59:59.99";

function buildAssFile(cues, canvas, style = STYLE) {
  const fontSize = Math.round(canvas.height * style.fontHeightRatio);
  const outline = Math.max(2, Math.round(canvas.height * style.outlineRatio));
  const shadow = Math.max(1, Math.round(canvas.height * style.shadowRatio));
  const marginH = Math.round(canvas.width * 0.055);
  const marginV = Math.round(canvas.height * 0.02);
  // Sized as a fraction of canvas height, like the captions, so the mark
  // is proportionate in both the 1920-tall vertical cut and the 1080-tall
  // landscape one rather than absurd in whichever it was not tuned for.
  const wmSize = Math.round(canvas.height * WATERMARK.fontHeightRatio);
  const wmMargin = Math.round(canvas.width * 0.03);

  const header = [
    "[Script Info]",
    "ScriptType: v4.00+",
    `PlayResX: ${canvas.width}`,
    `PlayResY: ${canvas.height}`,
    "WrapStyle: 0",
    "ScaledBorderAndShadow: yes",
    "",
    "[V4+ Styles]",
    "Format: Name, Fontname, Fontsize, PrimaryColour, OutlineColour, BackColour, " +
      "Bold, Italic, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding",
    `Style: P1,${style.fontName},${fontSize},${style.player1Colour},&H00000000,` +
      `&H00000000,-1,0,1,${outline},${shadow},${style.alignment},${marginH},${marginH},${marginV},1`,
    `Style: P2,${style.fontName},${fontSize},${style.player2Colour},&H00000000,` +
      `&H00000000,-1,0,1,${outline},${shadow},${style.alignment},${marginH},${marginH},${marginV},1`,
    `Style: WM,${style.fontName},${wmSize},${WATERMARK.colour},` +
      `${WATERMARK.outlineColour},&H00000000,-1,0,1,${Math.max(1, Math.round(outline / 2))},0,` +
      `${WATERMARK.alignment},${wmMargin},${wmMargin},${wmMargin},1`,
    "",
    "[Events]",
    "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text",
  ];

  const events = cues.map((c) =>
    `Dialogue: 0,${formatAssTime(c.start)},${formatAssTime(c.end)},` +
    `${c.uid === "2" ? "P2" : "P1"},,0,0,0,,${escapeAssText(c.text)}`,
  );

  // Layer 1 so it always draws above a caption that happens to reach it.
  const watermark =
    `Dialogue: 1,0:00:00.00,${WATERMARK_END},WM,,0,0,0,,` +
    escapeAssText(WATERMARK.text);

  return [...header, watermark, ...events].join("\n") + "\n";
}

/**
 * Transcribes every audio segment for a match and returns absolute-timed
 * words, each already attributed to the player who spoke it.
 *
 * Never throws for a segment that fails: one unintelligible or corrupt
 * stretch should cost its own captions, not the whole clip.
 */
async function transcribeSegments(segments, localDir, ffmpegPath, workDir) {
  const speech = require("@google-cloud/speech");
  const client = new speech.SpeechClient();
  const words = [];
  const failures = [];

  for (const seg of segments) {
    const inputPath = path.join(localDir, seg.path.split("/").pop());
    const wavPath = path.join(workDir, `${path.basename(inputPath, ".ts")}.wav`);
    try {
      await toRecognizerAudio(ffmpegPath, inputPath, wavPath);
      const content = await fs.readFile(wavPath);
      const [response] = await client.recognize({
        config: {
          encoding: "LINEAR16",
          sampleRateHertz: STT_SAMPLE_RATE,
          languageCode: "en-US",
          // Word timings are the whole point - without them captions
          // can only be placed per-utterance, which drifts badly.
          enableWordTimeOffsets: true,
          // CLAUDE.md's content policy is explicitly permissive, and
          // these are comedy clips: masking profanity would mangle the
          // captions of the actual jokes.
          profanityFilter: false,
          model: "latest_long",
          useEnhanced: true,
        },
        audio: {content},
      });

      for (const result of response.results ?? []) {
        for (const w of result.alternatives?.[0]?.words ?? []) {
          words.push({
            uid: seg.uid,
            text: w.word,
            // Recogniser timings are relative to this segment; shift them
            // into the clip's timeline.
            start: seg.offsetMs / 1000 + durationToSeconds(w.startTime),
            end: seg.offsetMs / 1000 + durationToSeconds(w.endTime),
          });
        }
      }
    } catch (e) {
      failures.push(`${path.basename(inputPath)}: ${e.message}`);
    } finally {
      await fs.rm(wavPath, {force: true}).catch(() => {});
    }
  }

  return {words, failures};
}

module.exports = {
  transcribeSegments,
  groupWordsIntoCues,
  buildAssFile,
  formatAssTime,
  escapeAssText,
  durationToSeconds,
  STYLE,
  MAX_WORDS_PER_CUE,
  MAX_CUE_SECONDS,
  CUE_SPLIT_GAP_SECONDS,
};
