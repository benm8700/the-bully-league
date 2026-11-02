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
  "nigg", "fagg", "sandnigg", "jiggaboo", "porchmonkey", "tarbaby",
  // Removed at the developer's request (2026-11-02): "wigger", "retard".
];

// WHOLE-WORD slurs: must BE the word (or word+s). Used for short ones that could
// otherwise live inside ordinary words (coon vs raccoon, spic vs ...), matched
// only as a complete transcribed word.
const WORD_SLURS = [
  "fag", "kike", "chink", "spic", "wetback", "beaner", "gook", "coon",
  "raghead", "towelhead",
  // Removed at the developer's request (2026-11-02): "tranny" (note: platforms
  // strike aggressively for it - re-add via the custom list if the heads-up is
  // wanted). "raghead"/"towelhead" were kept in.
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

/** The actual spoken word, cleaned for display: surrounding punctuation
 * stripped, lowercased - so the founder sees exactly what was said
 * ("retarded", "nigga") rather than the matched stem. */
function displayWord(text) {
  return String(text || "")
      .trim()
      .replace(/^[^a-zA-Z]+|[^a-zA-Z]+$/g, "")
      .toLowerCase();
}

/** Does a normalized word match any of the given prefix/whole-word stems?
 * Prefix stems catch all endings; whole-word stems must be the complete word
 * (or +s), so "coon" matches but "raccoon" never does. */
function matchesLists(norm, prefixes, wholeWords) {
  if (!norm) return false;
  for (const stem of prefixes) if (stem && norm.startsWith(stem)) return true;
  for (const stem of wholeWords) {
    if (stem && (norm === stem || norm === stem + "s")) return true;
  }
  return false;
}

/** Built-in match (for tests + default use). */
function wordIsSlur(norm) {
  return matchesLists(norm, PREFIX_SLURS, WORD_SLURS);
}

/**
 * Scans an array of transcribed words (strings, or {text} objects) for slurs.
 *
 * Returns {detected, terms} where terms are the DISTINCT ACTUAL WORDS said
 * (deduped by normalized form), so the founder sees exactly what was spoken.
 *
 * OPTIONS let the founder run their OWN database of flagged words:
 *   - extraWords: additional words to flag (whole-word match, normalized) -
 *     ADDED to the built-in slur list.
 *   - disableBuiltin: true -> use ONLY extraWords (ignore the built-in list).
 * These come from config/moderationWords, read at render time (see
 * highlightRender.js), so the list is editable with no code change.
 *
 * Pure and testable.
 */
function scanWordsForSlurs(words, {extraWords = [], disableBuiltin = false} = {}) {
  const prefixes = disableBuiltin ? [] : PREFIX_SLURS;
  const builtinWords = disableBuiltin ? [] : WORD_SLURS;
  const extra = (Array.isArray(extraWords) ? extraWords : [])
      .map(normalizeWord).filter(Boolean);
  const wholeWords = [...builtinWords, ...extra];

  const found = new Map(); // normalized -> actual spoken word (for display)
  for (const w of words || []) {
    const text = typeof w === "string" ? w : (w && w.text);
    const norm = normalizeWord(text);
    if (!norm) continue;
    if (matchesLists(norm, prefixes, wholeWords) && !found.has(norm)) {
      found.set(norm, displayWord(text) || norm);
    }
  }
  return {detected: found.size > 0, terms: [...found.values()]};
}

module.exports = {
  scanWordsForSlurs, normalizeWord, wordIsSlur, displayWord, SLUR_STEMS,
};
