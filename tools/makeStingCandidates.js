/**
 * Synthesises candidate intro/outro stings so they can be LISTENED to
 * rather than described.
 *
 * These are prototypes for choosing a DIRECTION, not shippable assets -
 * everything here is built from sine tones and filtered noise, so it will
 * sound synthetic next to anything a real sound designer or a licensed
 * library produces. The point is to make the choice concrete and cost
 * nothing to make.
 *
 * Run from the repo root:  node tools/makeStingCandidates.js
 * Output:                  sting_candidates/*.wav (and .mp4 to play anywhere)
 */
const {execFileSync} = require("child_process");
const path = require("path");
const fs = require("fs");

const ffmpeg = require(path.join(__dirname, "..", "functions",
    "node_modules", "ffmpeg-static"));
const outDir = path.join(__dirname, "..", "sting_candidates");
fs.mkdirSync(outDir, {recursive: true});

/** A sine tone with an attack/decay envelope. */
function tone(freq, startSec, durSec, gain = 0.5, decay = true) {
  return {
    src: `sine=frequency=${freq}:duration=${(startSec + durSec).toFixed(3)}`,
    filter: `atrim=start=${startSec.toFixed(3)},asetpts=PTS-STARTPTS,` +
      `afade=t=in:st=0:d=0.008,` +
      (decay ? `afade=t=out:st=${(durSec * 0.25).toFixed(3)}:` +
        `d=${(durSec * 0.75).toFixed(3)},` : "") +
      `adelay=${Math.round(startSec * 1000)}|${Math.round(startSec * 1000)},` +
      `volume=${gain}`,
  };
}

/** A percussive noise burst - the "attack" of a hit. */
function hit(startSec, durSec, hp, lp, gain = 0.5) {
  return {
    src: `anoisesrc=amplitude=0.9:duration=${(startSec + durSec).toFixed(3)}`,
    filter: `atrim=start=${startSec.toFixed(3)},asetpts=PTS-STARTPTS,` +
      `highpass=f=${hp},lowpass=f=${lp},` +
      `afade=t=out:st=0:d=${durSec.toFixed(3)},` +
      `adelay=${Math.round(startSec * 1000)}|${Math.round(startSec * 1000)},` +
      `volume=${gain}`,
  };
}

/** A pitch-falling sub, the "808 drop" shape. */
function subDrop(startSec, durSec, fromHz, toHz, gain = 0.9) {
  // Approximated as a short stack of descending tones, because lavfi's
  // sine generator has no glide.
  const steps = 6;
  const parts = [];
  for (let i = 0; i < steps; i++) {
    const f = fromHz + (toHz - fromHz) * (i / (steps - 1));
    parts.push(tone(Math.round(f), startSec + (durSec / steps) * i,
        durSec / steps + 0.02, gain, false));
  }
  return parts;
}

const CANDIDATES = {
  // A. Fight bell: metallic ring over a low impact.
  "a-fight-bell": [
    hit(0, 0.10, 60, 400, 0.7),
    tone(1046, 0.0, 0.9, 0.30),
    tone(1567, 0.0, 0.9, 0.18),
    tone(2093, 0.0, 0.7, 0.10),
    tone(80, 0.0, 0.5, 0.8),
  ],
  // B. Producer tag: sub drop, then a three-note minor motif.
  "b-producer-tag": [
    ...subDrop(0, 0.35, 180, 45),
    hit(0, 0.05, 2000, 9000, 0.25),
    tone(440, 0.36, 0.14, 0.42), // A
    tone(523, 0.50, 0.14, 0.42), // C
    tone(659, 0.64, 0.42, 0.46), // E
    tone(110, 0.64, 0.5, 0.7),
  ],
  // C. Sports logo: a bright rising stab.
  "c-sports-logo": [
    hit(0, 0.06, 1500, 8000, 0.30),
    tone(392, 0.00, 0.16, 0.40), // G
    tone(523, 0.16, 0.16, 0.44), // C
    tone(784, 0.32, 0.55, 0.50), // G
    tone(196, 0.32, 0.6, 0.55),
    tone(1046, 0.32, 0.5, 0.20),
  ],
  // D. Comedy rimshot: two snare-ish hits and a descending womp.
  "d-comedy-rimshot": [
    hit(0.00, 0.09, 900, 7000, 0.55),
    hit(0.16, 0.09, 900, 7000, 0.55),
    hit(0.32, 0.14, 700, 6000, 0.60),
    ...subDrop(0.34, 0.5, 300, 90, 0.55),
  ],
};

function render(name, parts, gain = 1) {
  const args = ["-y"];
  for (const p of parts) args.push("-f", "lavfi", "-i", p.src);
  const chains = parts.map((p, i) => `[${i}:a]${p.filter}[s${i}]`);
  const labels = parts.map((_, i) => `[s${i}]`).join("");
  chains.push(`${labels}amix=inputs=${parts.length}:normalize=0:` +
    `dropout_transition=0,alimiter=limit=0.95,` +
    `afade=t=out:st=1.15:d=0.15,atrim=0:1.3,volume=${gain}[out]`);
  const wav = path.join(outDir, `${name}.wav`);
  args.push("-filter_complex", chains.join(";"), "-map", "[out]",
      "-ar", "48000", wav);
  execFileSync(ffmpeg, args, {stdio: ["ignore", "ignore", "pipe"]});

  // Also as an mp4 with a black frame, so it plays in anything - a bare
  // .wav can be awkward to preview on Windows without picking an app.
  const mp4 = path.join(outDir, `${name}.mp4`);
  execFileSync(ffmpeg, ["-y",
    "-f", "lavfi", "-i", "color=c=black:s=640x360:d=1.3",
    "-i", wav, "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt",
    "yuv420p", "-c:a", "aac", "-shortest", mp4,
  ], {stdio: ["ignore", "ignore", "pipe"]});
  return {wav, mp4};
}

/** Peak level of a rendered file, in dBFS. */
function peakDb(file) {
  const {spawnSync} = require("child_process");
  const r = spawnSync(ffmpeg, ["-i", file, "-af", "volumedetect",
    "-f", "null", "-"], {encoding: "utf8"});
  const m = String(r.stderr).match(/max_volume: (-?[\d.]+) dB/);
  return m ? Number(m[1]) : null;
}

/** Where every candidate should peak, so they can be judged fairly. */
const TARGET_PEAK_DB = -1.5;

for (const [name, parts] of Object.entries(CANDIDATES)) {
  try {
    // TWO PASSES, because these need to be comparable to be useful.
    // The first attempt used dynaudnorm, whose analysis window is longer
    // than a one-second sting, so it did essentially nothing: the four
    // came out between -6 and -13 dB. That is both too quiet to assess
    // on laptop speakers and an unfair comparison, since the loudest
    // candidate simply sounds the most confident. Measuring the real
    // peak and applying an exact gain is deterministic and cannot
    // silently under-correct.
    const first = render(name, parts);
    const peak = peakDb(first.wav);
    const gain = peak === null ? 1 :
      Math.pow(10, (TARGET_PEAK_DB - peak) / 20);
    const {wav} = render(name, parts, gain);
    console.log(`ok   ${name.padEnd(18)} ${peakDb(wav)} dB peak`);
  } catch (e) {
    console.log(`FAIL ${name}`);
    console.log(String(e.stderr).split("\n").slice(-8).join("\n"));
  }
}
console.log(`\nListen in: ${outDir}`);
