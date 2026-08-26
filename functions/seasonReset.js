const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {HttpsError} = require("firebase-functions/v2/https");
const {STARTING_RATING, GOAT_TITLE, computeTitleFromXp} = require("./rating");

/**
 * The season soft reset (CLAUDE.md's Season reset decision).
 *
 * SOFT, NOT HARD: every rating is pulled partway back toward the centre
 * rather than flattened to it. That keeps the skill differential a season
 * of play established while compressing the advantage of having farmed
 * early - a hard reset throws away real information about who is good,
 * and a no-reset ladder eventually calcifies at the top.
 *
 * ADMIN-TRIGGERED, NEVER SCHEDULED. Seasons have no defined length here,
 * and a cron that silently rewrites every player's rating on a timer is
 * the single most destructive thing this codebase could contain. It also
 * demands the season number it is about to create, so running it twice by
 * accident is impossible rather than merely unlikely.
 *
 * IT ARCHIVES BEFORE IT TOUCHES ANYTHING. A reset that destroys the
 * standings it resets is strictly worse than one that keeps them: the
 * final table is the whole record of a season, and it is exactly what a
 * hall of fame, a recap or an argument about who really won will want
 * later. Nothing about the reset needs it to be destructive.
 */

/** How far each rating is dragged toward the centre. 0 changes nothing,
 * 1 is a hard reset. CLAUDE.md suggests half. */
const DEFAULT_PULL = 0.5;
const PULL_LIMITS = {min: 0.05, max: 0.95};

/**
 * A player's rating after the pull.
 *
 * PURE, and worth pinning precisely: this rewrites the number the whole
 * ladder is built on, for everybody at once, and there is no undo beyond
 * the archive.
 */
function pulledRating(rating, pull) {
  const r = Number(rating);
  const base = Number.isFinite(r) ? r : STARTING_RATING;
  const p = Number.isFinite(Number(pull)) &&
    Number(pull) >= PULL_LIMITS.min && Number(pull) <= PULL_LIMITS.max ?
    Number(pull) : DEFAULT_PULL;
  return Math.round(STARTING_RATING + (base - STARTING_RATING) * (1 - p));
}

/**
 * Everything one account's reset changes.
 *
 * PURE, so the whole policy is testable without touching a database.
 *
 * @param {object} user      the account as it stands
 * @param {number} pull      how far toward the centre
 * @return {object} the fields to write
 */
function resetFor(user, pull) {
  const rating = pulledRating(user?.rating, pull);

  // The tier gate reads rankedMatchesPlayed, so zeroing it is what
  // creates the placement period CLAUDE.md describes - everyone has to
  // play a few before a rank means anything again.
  //
  // CAREER TOTAL IS PRESERVED SEPARATELY. Two things depend on knowing
  // somebody has played before: the entitlement carve-out that lets a
  // genuinely new player practise during the window, and any stat that
  // claims to be a career figure. Without this, a reset would hand every
  // existing player the new-player carve-out and quietly suspend the
  // window's ranked-only rule for everyone.
  const career = Number(user?.careerRankedMatches);
  const careerRankedMatches = Number.isFinite(career) ?
    career : (Number(user?.rankedMatchesPlayed) || 0);

  // THE EARNED TITLE IS NEVER RESET. As of the XP ladder (2026-08-25)
  // titles are earned and KEPT - a season reset re-places the hidden Elo
  // for fresh matchmaking but must not knock anyone down the visible
  // ladder, which is the whole promise of the system. XP (career points)
  // is untouched by the reset, so the earned title is preserved by
  // recomputing it from that unchanged XP; a live GOAT keeps GOAT (the
  // proportional pull preserves rating order, so the same five stay on
  // top, and the next syncGoatTier confirms it either way).
  const rankTitle = user?.rankTitle === GOAT_TITLE ?
    GOAT_TITLE : computeTitleFromXp(Number(user?.points) || 0);

  return {
    rating,
    // Zeroed as a per-season stats counter. It no longer gates anything -
    // titles come from XP and the entitlement carve-out reads
    // careerRankedMatches - so this is cosmetic continuity rather than a
    // placement gate.
    rankedMatchesPlayed: 0,
    careerRankedMatches,
    // Written unchanged so the value stays consistent, and the notification
    // pointers are pinned to it so no stray rank-change fires - though with
    // the title preserved there is now nothing to announce in the first
    // place, unlike the old reset that demoted almost everybody at once.
    rankTitle,
    lastNotifiedRankTitle: rankTitle,
    lastSeenRankTitle: rankTitle,
  };
}

/**
 * Archives the standings, then resets every account.
 *
 * @param {object} data.seasonNumber  the season being CLOSED, required
 * @param {number} data.pull          optional override
 * @param {boolean} data.dryRun       report what would change, write nothing
 */
async function runSeasonReset(auth, data, {requireAdmin}) {
  await requireAdmin(auth);
  const {seasonNumber, pull = DEFAULT_PULL, dryRun = false} = data || {};
  if (!Number.isInteger(seasonNumber) || seasonNumber < 1) {
    throw new HttpsError("invalid-argument",
        "seasonNumber is required, and must be the season you are closing.");
  }

  const db = getFirestore();
  const seasonRef = db.collection("seasons").doc(String(seasonNumber));
  if ((await seasonRef.get()).exists) {
    // The archive doubles as the guard: a season that has already been
    // closed cannot be closed again, so a repeated call cannot pull every
    // rating toward the centre a second time.
    throw new HttpsError("already-exists",
        `Season ${seasonNumber} has already been closed.`);
  }

  const users = await db.collection("users").get();
  const standings = users.docs
      .map((d) => ({
        uid: d.id,
        username: d.data().username ?? null,
        rating: d.data().rating ?? STARTING_RATING,
        rankTitle: d.data().rankTitle ?? null,
        wins: d.data().wins ?? 0,
        losses: d.data().losses ?? 0,
        rankedMatchesPlayed: d.data().rankedMatchesPlayed ?? 0,
      }))
      .sort((a, b) => b.rating - a.rating);

  const changes = users.docs.map((d) => ({
    uid: d.id,
    from: d.data().rating ?? STARTING_RATING,
    ...resetFor(d.data(), pull),
  }));

  if (dryRun) {
    return {
      dryRun: true, seasonNumber, pull, accounts: changes.length,
      sample: changes.slice(0, 5).map((c) =>
        ({uid: c.uid, from: c.from, to: c.rating, rankTitle: c.rankTitle})),
    };
  }

  // Archive FIRST. If the write of the standings fails, nothing has been
  // reset and the season can simply be closed again.
  await seasonRef.set({
    seasonNumber,
    pull,
    closedAt: FieldValue.serverTimestamp(),
    accounts: standings.length,
    standings: standings.slice(0, 100),
    champion: standings[0] ?? null,
  });

  let written = 0;
  for (const change of changes) {
    const {uid, from, ...fields} = change;
    await db.collection("users").doc(uid).set(fields, {merge: true});
    written += 1;
  }

  return {
    seasonNumber, pull, accounts: written,
    champion: standings[0]?.username ?? null,
  };
}

module.exports = {
  runSeasonReset,
  pulledRating,
  resetFor,
  DEFAULT_PULL,
  PULL_LIMITS,
};
