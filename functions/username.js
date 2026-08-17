const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {HttpsError} = require("firebase-functions/v2/https");

/**
 * Usernames: validity, a slur filter, uniqueness, and a change cooldown.
 *
 * WHY THIS IS FILTERED AT ALL, in an app whose whole content policy is
 * that offensive material is allowed. A username is a different object
 * from a roast, in three ways that all point the same direction:
 *
 *   - it is PERMANENT, where a roast is fifteen seconds;
 *   - it is UNAVOIDABLE - it renders on the leaderboard, in the feed,
 *     on the public website, next to someone else's face;
 *   - and it is read by people who never opted into any of this. The two
 *     players consented to the format. A visitor who clicked a shared
 *     clip did not.
 *
 * That is the same reasoning that put an allowlist on reactions rather
 * than a text box, and it is why app stores review persistent public
 * identifiers even in otherwise permissive apps. So the filter targets
 * HATE and IMPERSONATION specifically, not profanity: "DamnGood" is a
 * fine name here and is meant to stay one.
 *
 * Everything below the callables is PURE, so the whole policy can be
 * tested without Firestore or a clock.
 */

/** Bounds. Short enough to fit a leaderboard row, long enough to be a
 * name rather than a handle fragment. */
const MIN_LENGTH = 3;
const MAX_LENGTH = 20;

/** CLAUDE.md's username-change decision leaves the interval at 30-60
 * days. 30 is the friendlier end of the range and still far longer than
 * the memory of a bad match, which is what the cooldown is really for.
 * Overridable via config/usernamePolicy. */
const DEFAULT_COOLDOWN_DAYS = 30;
const DAY_MS = 24 * 60 * 60 * 1000;

/**
 * Characters that get typed in place of letters to slip a word past a
 * filter. Mapped before matching, so "n1gg3r" and "nigger" are the same
 * string by the time the list is consulted.
 */
const CONFUSABLES = {
  "0": "o", "1": "i", "3": "e", "4": "a", "5": "s", "7": "t", "8": "b",
  "@": "a", "$": "s", "!": "i", "|": "i", "+": "t", "*": "", "'": "",
  "`": "", "\"": "", ".": "", "_": "", "-": "", " ": "",
};

/**
 * Hate terms matched as SUBSTRINGS of the normalised name.
 *
 * Every entry here is long enough, and odd enough, that it does not
 * appear inside an innocent word - which is the whole reason the short
 * ones live in the token list below instead. Getting this wrong in the
 * permissive direction lets a slur onto a leaderboard; getting it wrong
 * in the strict direction tells someone their real name is unacceptable,
 * which is its own small cruelty. Hence the split.
 */
const HATE_SUBSTRINGS = [
  "nigger", "nigga", "niglet", "jigaboo", "porchmonkey",
  "wetback", "beaner", "towelhead", "raghead", "sandnigger", "camelj0ckey",
  "chinaman", "slanteye", "gook", "kike", "heeb",
  "faggot", "fagot", "tranny", "shemale", "ladyboy",
  "retard", "mongoloid", "halfbreed", "mudslime",
  "hitler", "nazi", "whitepower", "whitepride", "heilhitler", "kkk",
  "gaschamber", "lynchthe",
  "childporn", "childrape", "pedophile", "cumslut", "blowjob",
];

/**
 * Terms matched only as WHOLE TOKENS - split on separators and on
 * capitalisation, so "Ben_Admin" and "BenAdmin" both surface "admin".
 *
 * These are short enough to sit inside ordinary words: substring-matching
 * "spic" would reject "Despicable", "coon" would reject "Raccoon",
 * "admin" would reject "Badminton", and "cock" would reject an entire
 * aviary. The token rule catches the name that IS the word without
 * touching the name that merely contains it.
 */
const BLOCKED_TOKENS = [
  "fag", "fags", "spic", "chink", "coon", "paki", "abo", "dyke", "kaffir",
  "cunt", "rape", "rapist", "slut", "whore", "cock", "dick", "nigg",
  // Impersonation of the platform or its staff. Cheap to prevent now,
  // and a name like "Support" in a report queue or a DM is a phishing
  // primitive rather than a joke.
  "admin", "administrator", "mod", "mods", "moderator", "staff", "support",
  "official", "help", "helpdesk", "root", "system", "team",
  "thebullyleague", "bullyleague", "bullyleagueofficial",
];

/**
 * Names that would otherwise trip the substring list for innocent
 * reasons. Checked against the whole normalised name, not a fragment.
 *
 * Currently empty of real entries and that is fine - it exists so the
 * first false positive reported in the beta is a one-line fix rather
 * than an argument about the matcher.
 */
const ALLOWLIST = new Set([]);

/**
 * Everything that is not a letter or a digit, after confusable mapping.
 * Runs of three or more identical characters collapse to two.
 *
 * COLLAPSING TO TWO RATHER THAN ONE IS DELIBERATE. Collapsing to one
 * defeats padding ("niiiice"), but it also turns "Nigeria" into a string
 * containing "niger", so a Nigerian flag in a username would be refused
 * as a slur. Collapsing to two kills the padding trick and leaves real
 * words - including real place names - intact.
 */
function normalizeForMatch(raw) {
  const lowered = String(raw ?? "").toLowerCase();
  let mapped = "";
  for (const ch of lowered) {
    const sub = Object.prototype.hasOwnProperty.call(CONFUSABLES, ch) ?
      CONFUSABLES[ch] : ch;
    mapped += sub;
  }
  const lettersOnly = mapped.replace(/[^a-z0-9]/g, "");
  return lettersOnly.replace(/(.)\1{2,}/g, "$1$1");
}

/**
 * The name split into words: on separators, on digit/letter boundaries,
 * and on capitalisation, then confusable-mapped individually.
 */
function tokensOf(raw) {
  const s = String(raw ?? "");
  const parts = s
      .replace(/([a-z])([A-Z])/g, "$1 $2")
      .split(/[^A-Za-z0-9]+/)
      .flatMap((p) => p.split(/(?<=[A-Za-z])(?=[0-9])|(?<=[0-9])(?=[A-Za-z])/))
      .filter(Boolean);
  return parts.map((p) => normalizeForMatch(p)).filter(Boolean);
}

/**
 * Shape rules, applied before the content check so the message a user
 * gets is about the actual problem.
 */
function shapeProblem(name) {
  if (typeof name !== "string" || name.length === 0) {
    return "Pick a username.";
  }
  if (name !== name.trim()) {
    return "Usernames can't start or end with a space.";
  }
  if (name.length < MIN_LENGTH) {
    return `Usernames need at least ${MIN_LENGTH} characters.`;
  }
  if (name.length > MAX_LENGTH) {
    return `Usernames can be at most ${MAX_LENGTH} characters.`;
  }
  if (!/^[A-Za-z0-9._-]+$/.test(name)) {
    return "Use letters, numbers, and . _ - only.";
  }
  if (!/^[A-Za-z0-9]/.test(name) || !/[A-Za-z0-9]$/.test(name)) {
    return "Start and end with a letter or number.";
  }
  if (/[._-]{2,}/.test(name)) {
    return "No two punctuation marks in a row.";
  }
  // A name of nothing but punctuation-adjacent digits is unreadable on a
  // leaderboard and is usually a throwaway.
  if (!/[A-Za-z]/.test(name)) {
    return "Include at least one letter.";
  }
  return null;
}

/**
 * The content check. Returns a reason string, or null if the name is
 * acceptable.
 *
 * @param {string} name        the name as typed
 * @param {string[]} extra     additional blocked substrings from config
 * @return {?string}
 */
function contentProblem(name, extra = []) {
  const normalized = normalizeForMatch(name);
  if (ALLOWLIST.has(normalized)) return null;

  const substrings = [...HATE_SUBSTRINGS, ...extra]
      .map((t) => normalizeForMatch(t))
      .filter(Boolean);
  for (const term of substrings) {
    if (normalized.includes(term)) {
      return "That username isn't available. Try another.";
    }
  }

  const blocked = new Set(BLOCKED_TOKENS.map((t) => normalizeForMatch(t)));
  for (const token of tokensOf(name)) {
    if (blocked.has(token)) {
      return "That username isn't available. Try another.";
    }
  }
  // Also catch the case where the whole name IS a blocked token but the
  // tokeniser split it oddly (e.g. "a.d.m.i.n").
  if (blocked.has(normalized)) {
    return "That username isn't available. Try another.";
  }
  return null;
}

/**
 * The message deliberately does NOT say which rule was hit or quote the
 * matched term back. Naming the term teaches an evader exactly what to
 * change, and "isn't available" is also true - the name is unavailable
 * to them either way.
 */
function usernameProblem(name, extra = []) {
  return shapeProblem(name) ?? contentProblem(name, extra);
}

/** The uniqueness key. Case-insensitive, so "TheGoat" and "thegoat"
 * cannot both exist - on a leaderboard those are the same person to
 * every reader.
 *
 * KNOWN GAP, accepted for V1: this does not defend against homoglyphs
 * ("PIayer" with a capital i against "Player"). Closing that properly
 * means claiming a second, aggressively-normalised key, which also
 * blocks legitimately distinct names like "Mark" and "M4rk". Not worth
 * the collateral until someone actually does it. */
function usernameKey(name) {
  return String(name ?? "").trim().toLowerCase();
}

/**
 * Reads config/usernamePolicy, bounds-checked per field - same rule the
 * match settings, the event window and the monetization config use, and
 * for the same reason: it is hand-edited in the console against a live
 * app with nothing validating it in between.
 */
async function readUsernamePolicy(db = getFirestore()) {
  try {
    const snap = await db.collection("config").doc("usernamePolicy").get();
    const raw = snap.exists ? snap.data() : {};
    const days = Number(raw?.changeCooldownDays);
    const extra = Array.isArray(raw?.extraBlocked) ?
      raw.extraBlocked.filter((t) => typeof t === "string") : [];
    return {
      changeCooldownDays: Number.isFinite(days) && days >= 0 && days <= 365 ?
        days : DEFAULT_COOLDOWN_DAYS,
      extraBlocked: extra,
    };
  } catch (e) {
    console.error("could not read config/usernamePolicy:", e.message);
    return {changeCooldownDays: DEFAULT_COOLDOWN_DAYS, extraBlocked: []};
  }
}

/**
 * When this account may next change its name.
 *
 * The cooldown starts at the first CHANGE, not at signup: someone who
 * typos their name during onboarding should be able to fix it, and the
 * behaviour the cooldown guards against - cycling names to shake off
 * recognition after a bad match - needs at least one change to begin.
 *
 * @return {?number} epoch millis, or null if a change is allowed now
 */
function cooldownUntilMs(user, cooldownDays) {
  const last = user?.usernameChangedAt;
  const lastMs = typeof last?.toMillis === "function" ? last.toMillis() :
    (typeof last === "number" && last > 0 ? last : null);
  if (lastMs === null) return null;
  const until = lastMs + cooldownDays * DAY_MS;
  return until;
}

/** "in 12 days" / "tomorrow" - a date is less useful than a wait. */
function waitPhrase(untilMs, nowMs) {
  const days = Math.ceil((untilMs - nowMs) / DAY_MS);
  if (days <= 1) return "tomorrow";
  return `in ${days} days`;
}

/**
 * Is this name usable by this account right now? Shape, content and
 * availability, with no side effects.
 */
async function checkUsername(data, auth) {
  const db = getFirestore();
  const name = typeof data?.username === "string" ? data.username.trim() : "";
  const policy = await readUsernamePolicy(db);

  const problem = usernameProblem(name, policy.extraBlocked);
  if (problem) return {available: false, reason: problem};

  const key = usernameKey(name);
  const claim = await db.collection("usernames").doc(key).get();
  // Your own name reads as available, so re-submitting it (a retry, or a
  // change of capitalisation) is never refused as "taken by you".
  if (claim.exists && claim.data()?.uid !== auth?.uid) {
    return {available: false, reason: "That username is taken."};
  }
  return {available: true, reason: null};
}

/**
 * Claim a username for the signed-in account.
 *
 * The claim and the user document move together in ONE transaction. The
 * claim collection is the only thing making uniqueness real - two people
 * submitting the same name in the same second is exactly the case a
 * read-then-write would let through, and the loser would only find out
 * when someone else's name appeared on their profile.
 */
async function setUsername(data, auth) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const db = getFirestore();
  const nowMs = Date.now();
  const name = typeof data?.username === "string" ? data.username.trim() : "";
  const policy = await readUsernamePolicy(db);

  const problem = usernameProblem(name, policy.extraBlocked);
  if (problem) throw new HttpsError("invalid-argument", problem);

  const key = usernameKey(name);
  const userRef = db.collection("users").doc(auth.uid);
  const claimRef = db.collection("usernames").doc(key);

  return db.runTransaction(async (tx) => {
    const [userSnap, claimSnap] = await Promise.all([
      tx.get(userRef), tx.get(claimRef),
    ]);
    const user = userSnap.data() ?? {};

    if (claimSnap.exists && claimSnap.data()?.uid !== auth.uid) {
      throw new HttpsError("already-exists", "That username is taken.");
    }

    const current = user.username ?? null;
    const isFirst = !current;
    const unchanged = usernameKey(current) === key;

    // Re-submitting the same name (a retry, or fixing capitalisation)
    // must not spend the cooldown. Only a real change does.
    if (!isFirst && !unchanged) {
      const until = cooldownUntilMs(user, policy.changeCooldownDays);
      if (until !== null && nowMs < until) {
        throw new HttpsError(
            "failed-precondition",
            `You can change your username again ${waitPhrase(until, nowMs)}.`,
        );
      }
    }

    tx.set(claimRef, {uid: auth.uid, username: name, claimedAt: nowMs});

    // The old claim is released so the name returns to the pool. Held
    // claims would make every abandoned name permanently unusable, which
    // in a small userbase is how a namespace dies.
    if (current && !unchanged) {
      tx.delete(db.collection("usernames").doc(usernameKey(current)));
    }

    const update = {
      username: name,
      // Lowercased copy for the directory's prefix query - Firestore has
      // no case-insensitive search.
      usernameLower: key,
    };
    // Only a genuine change starts the clock, per cooldownUntilMs.
    if (!isFirst && !unchanged) {
      update.usernameChangedAt = FieldValue.serverTimestamp();
    }
    tx.set(userRef, update, {merge: true});

    return {
      username: name,
      // A first set is not a "change" - nothing was replaced, and the
      // cooldown it would otherwise imply has not started.
      changed: !isFirst && !unchanged,
      nextChangeAllowedAtMs: isFirst || unchanged ?
        null : nowMs + policy.changeCooldownDays * DAY_MS,
    };
  });
}

/** What the profile screen needs to render the change control honestly. */
async function getUsernameState(auth) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const db = getFirestore();
  const [userSnap, policy] = await Promise.all([
    db.collection("users").doc(auth.uid).get(),
    readUsernamePolicy(db),
  ]);
  const user = userSnap.data() ?? {};
  const nowMs = Date.now();
  const until = cooldownUntilMs(user, policy.changeCooldownDays);
  const locked = until !== null && nowMs < until;
  return {
    username: user.username ?? null,
    canChange: !locked,
    nextChangeAllowedAtMs: locked ? until : null,
    message: locked ?
      `You can change your username again ${waitPhrase(until, nowMs)}.` : null,
    cooldownDays: policy.changeCooldownDays,
  };
}

module.exports = {
  checkUsername,
  setUsername,
  getUsernameState,
  // Exported for tests.
  MIN_LENGTH,
  MAX_LENGTH,
  DEFAULT_COOLDOWN_DAYS,
  normalizeForMatch,
  tokensOf,
  shapeProblem,
  contentProblem,
  usernameProblem,
  usernameKey,
  cooldownUntilMs,
  waitPhrase,
  readUsernamePolicy,
};
