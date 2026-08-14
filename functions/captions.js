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
  fontSize: 96,
  outline: 6,
  shadow: 2,
  // Vertically centred, which on a stacked two-player layout puts the
  // text on the seam between the players rather than over either face,
  // and clear of the platform UI that crowds the bottom of the screen.
  alignment: 5,
  marginV: 40,
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

/** Builds a complete ASS subtitle file from cues. */
function buildAssFile(cues, canvas, style = STYLE) {
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
    `Style: P1,${style.fontName},${style.fontSize},${style.player1Colour},&H00000000,` +
      `&H00000000,-1,0,1,${style.outline},${style.shadow},${style.alignment},60,60,${style.marginV},1`,
    `Style: P2,${style.fontName},${style.fontSize},${style.player2Colour},&H00000000,` +
      `&H00000000,-1,0,1,${style.outline},${style.shadow},${style.alignment},60,60,${style.marginV},1`,
    "",
    "[Events]",
    "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text",
  ];

  const events = cues.map((c) =>
    `Dialogue: 0,${formatAssTime(c.start)},${formatAssTime(c.end)},` +
    `${c.uid === "2" ? "P2" : "P1"},,0,0,0,,${escapeAssText(c.text)}`,
  );

  return [...header, ...events].join("\n") + "\n";
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
