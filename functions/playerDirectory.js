const {getFirestore} = require("firebase-admin/firestore");
const {HttpsError} = require("firebase-functions/v2/https");

/**
 * Finding other players by name.
 *
 * THIS IS A HARASSMENT SURFACE AND IS BUILT AS ONE. Everything else in
 * the app pairs people randomly, which means nobody can be sought out. A
 * searchable list of names and faces removes exactly that protection, in
 * an app whose premise is insulting strangers - so the safety rules are
 * part of the feature rather than a later hardening pass:
 *
 *   - anyone can REMOVE THEMSELVES from the listing, permanently
 *   - a block hides both people from each other, in both directions
 *   - banned accounts are never listed
 *   - the result carries a name, a face and a rank, and NOTHING else
 *
 * That last one matters most. The profile exists to give an opponent
 * ammo during a match; hometown, job and the volunteered ammo text are
 * fine for someone you have just been paired with and wrong for a
 * stranger who went looking for you. Those fields are deliberately absent
 * here, and adding them later would need this comment re-read first.
 *
 * SERVER-SIDE because none of the above can be enforced by a client
 * query. A direct Firestore query cannot apply someone else's block list
 * and cannot be trusted to honour an opt-out.
 */

/** Results per search. Small on purpose: a directory is for finding
 * someone you already have in mind, not for browsing a userbase. */
const RESULT_LIMIT = 20;

/** Firestore's convention for "everything with this prefix". */
const PREFIX_END = "";

/** Names are matched case-insensitively, so this is what gets stored and
 * queried against. */
function normaliseName(username) {
  return typeof username === "string" ? username.trim().toLowerCase() : "";
}

/**
 * Whether one player may see another in a directory result.
 *
 * Pure, so the whole rule is testable without Firestore.
 *
 * A BLOCK HIDES IN BOTH DIRECTIONS. If it only hid the blocker from the
 * blocked party, the person who did the blocking would still be
 * findable - which is precisely backwards, since they are the one who
 * asked not to be contacted.
 */
function isVisibleTo(candidate, viewer, viewerUid, candidateUid) {
  if (!candidate || candidateUid === viewerUid) return false;
  // Opting out is absolute and needs no justification.
  if (candidate.directoryListed === false) return false;
  // An absent status means a legacy account, which the rest of the
  // codebase treats as active - reading it as non-active would silently
  // hide every pre-existing player.
  if ((candidate.accountStatus ?? "active") !== "active") return false;
  if ((viewer?.blockedUserIds ?? []).includes(candidateUid)) return false;
  if ((candidate.blockedUserIds ?? []).includes(viewerUid)) return false;
  return true;
}

/** What a stranger is allowed to learn. Deliberately minimal. */
function publicCard(uid, user) {
  const photos = user.profile?.photoUrls;
  return {
    uid,
    username: user.username ?? "Unknown",
    // The first photo only. CLAUDE.md requires the first to be a clear
    // face shot, so it is the one that identifies someone - and handing
    // over a whole gallery to a stranger is a different thing entirely.
    photoUrl: Array.isArray(photos) && photos.length > 0 ? photos[0] : null,
    rankTitle: user.rankTitle ?? null,
  };
}

async function searchPlayers(auth, data) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const query = normaliseName(data?.query);
  if (query.length < 2) {
    // Refused rather than returning everyone. A one-character search is
    // browsing the userbase, which is not what this is for.
    return {results: [], reason: "query-too-short"};
  }

  const db = getFirestore();
  const [viewerSnap, monetization, windowConfig] = await Promise.all([
    db.collection("users").doc(auth.uid).get(),
    require("./entitlement").readMonetizationConfig(db),
    db.collection("config").doc("eventWindow").get()
        .then((s) => require("./eventWindow").readEventWindowConfig(s.data()))
        .catch(() => ({enabled: false})),
  ]);
  const viewer = viewerSnap.data() ?? {};

  // Gated from the start rather than opened now and restricted later,
  // which is the most damaging pricing move available. Trial counts as
  // full access, and while enforcement is off everyone reads as trial.
  const {battleEntitlement} = require("./entitlement");
  const state = battleEntitlement({
    user: viewer, mode: "ranked", nowMs: Date.now(),
    windowConfig, config: monetization,
  }).state;
  if (monetization.enabled === true && state === "lapsed") {
    throw new HttpsError("failed-precondition",
        "Searching for players is part of a subscription.",
        {reason: "subscription-required"});
  }

  // Prefix match on the normalised name. Firestore has no substring
  // search, and a full scan filtered in memory would read the entire user
  // collection on every keystroke.
  const snap = await db.collection("users")
      .orderBy("usernameLower")
      .startAt(query)
      .endAt(query + PREFIX_END)
      // Over-fetched because visibility filtering happens after: blocked
      // and opted-out accounts would otherwise eat into the page.
      .limit(RESULT_LIMIT * 3)
      .get();

  const results = [];
  for (const doc of snap.docs) {
    if (results.length >= RESULT_LIMIT) break;
    if (!isVisibleTo(doc.data(), viewer, auth.uid, doc.id)) continue;
    results.push(publicCard(doc.id, doc.data()));
  }
  return {results};
}

module.exports = {
  searchPlayers, isVisibleTo, publicCard, normaliseName, RESULT_LIMIT,
};
