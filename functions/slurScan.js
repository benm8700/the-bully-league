/**
 * Scans a clip's TRANSCRIPT for hate slurs, for the POSTING-side warning only.
 *
 * CRITICAL - THIS NEVER DISQUALIFIES A BATTLE OR BLOCKS A PLAYER'S OWN CLIP.
 * The in-app content policy is deliberately free-speech: slurs and no-holds-
 * barred roasting are ALLOWED, users consent, and there is no real-time speech
 * moderation (see CLAUDE.md). This exists ONLY to warn the founder BEFORE a clip
 * goes to the app's OWN marketing accounts, because TikTok/IG/YouTube ban slurs
 * in THEIR rules and would strike/ban the marketing account - a self-inflicted
 * wound. The founder decides; this just makes the risk impossible to miss.
 *
 * This is DISTINCT from profanity (fuck/shit/etc.), which the app allows and
 * this does NOT flag. The list is only slurs used to demean a protected group -
 * the words that actually get an account struck.
 *
 * The transcript already exists (captions.js transcribes the audio for the
 * caption burn-in), so this costs nothing extra.
 */

// PREFIX slurs: a normalized word STARTING with one of these is a slur, so the
// various endings are all caught (nigg -> nigger/nigga/niggah; fagg -> faggot;
// retard -> retarded). These stems are never the start of an ordinary word.
const PREFIX_SLURS = [
  "nigg", "fagg", "sandnigg", "jiggaboo", "porchmonkey",
  "tarbaby", "wigger", "retard",
];

// WHOLE-WORD slurs: must BE the word (or word+s). Used for short ones that could
// otherwise live inside ordinary words (coon vs raccoon, spic vs ...), matched
// only as a complete transcribed word.
const WORD_SLURS = [
  "fag", "kike", "chink", "spic", "wetback", "beaner", "gook", "coon",
  "raghead", "towelhead", "tranny",
];

const SLUR_STEMS = [...PREFIX_SLURS, ...WORD_SLURS]; // exported for reference

/** Normalizes a single transcribed word: lowercase, letters only, runs of a
 * letter collapsed to two (so "niiigga" -> "niigga" still hits the stem). */
function normalizeWord(w) {
  return String(w || "")
      .toLowerCase()
      .replace(/[^a-z]/g, "")
      .replace(/([a-z])\1{2,}/g, "$1$1");
}

/** Does a normalized word match a slur? Prefix stems catch all endings; short
 * whole-word stems must be the complete word (or +s), so "coon" matches but
 * "raccoon" never does. */
function wordIsSlur(norm) {
  if (!norm) return false;
  for (const stem of PREFIX_SLURS) {
    if (norm.startsWith(stem)) return true;
  }
  for (const stem of WORD_SLURS) {
    if (norm === stem || norm === stem + "s") return true;
  }
  return false;
}

/**
 * Scans an array of transcribed words (strings, or {text} objects) for slurs.
 * Returns {detected, terms} where terms are the DISTINCT normalized slurs found
 * (deduped), newest-first irrelevant. Pure and testable.
 */
function scanWordsForSlurs(words) {
  const found = new Set();
  for (const w of words || []) {
    const text = typeof w === "string" ? w : (w && w.text);
    const norm = normalizeWord(text);
    if (wordIsSlur(norm)) found.add(norm);
  }
  const terms = [...found];
  return {detected: terms.length > 0, terms};
}

module.exports = {scanWordsForSlurs, normalizeWord, wordIsSlur, SLUR_STEMS};
