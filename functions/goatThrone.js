const {getFirestore} = require("firebase-admin/firestore");
const {GOAT_POOL_SIZE, GOAT_ELIGIBLE_MIN_XP} = require("./rating");

/**
 * GOAT "defend your throne" watch - Option 1 of the title-fight design
 * (CLAUDE.md). GOAT is ALREADY losable passively: it is the top-5 by hidden
 * rating among XP-eligible players, so an up-and-comer who out-rates the lowest
 * GOAT bumps them out (syncGoatTier). What was missing is the DRAMA before it
 * happens - a GOAT gets no warning that their throne is under threat, and the
 * challenger closing in gets no hype. This job adds exactly that, a warning
 * layer; it does NOT change how GOAT is actually won or lost.
 *
 * The "you took / lost the throne" MOMENT is already carried by the rank-change
 * popups (GOAT up: "...defend it in a title fight"; GOAT displaced: "you've
 * been bested"). This is only the lead-up.
 */

/**
 * How close, in hidden rating, a challenger must be to the lowest GOAT for the
 * throne to count as "under threat". A placeholder like the other tuning
 * numbers; the rating gap is NEVER surfaced - only the FACT of a threat is.
 */
const THRONE_MARGIN_RATING = 75;

/** How many recipients a single warning fans out to (two: the GOAT + the
 * challenger). Here for symmetry with the other push jobs' blast-radius note. */

/**
 * PURE. Given players (each {uid, name, rating, points}), decide whether a GOAT
 * throne is under threat and name the two players involved.
 *
 * Mirrors syncGoatTier EXACTLY so the watch never warns about a bump that
 * cannot happen: the GOAT pool is the top `poolSize` XP-eligible players, and a
 * challenger can only take the throne if THEY are XP-eligible too. A threat
 * exists only when the pool is FULL (an open slot would let a challenger JOIN
 * rather than displace anyone) and the top eligible non-GOAT is within `margin`
 * of the lowest GOAT.
 */
function throneThreat(players, {poolSize, minXp, margin}) {
  const eligible = (players || [])
      .filter((p) => (Number(p.points) || 0) >= minXp)
      .slice()
      .sort((a, b) => (Number(b.rating) || 0) - (Number(a.rating) || 0));
  if (eligible.length <= poolSize) return {underThreat: false};
  const lowestGoat = eligible[poolSize - 1];
  const challenger = eligible[poolSize];
  const gap = (Number(lowestGoat.rating) || 0) - (Number(challenger.rating) || 0);
  if (gap < 0 || gap > margin) return {underThreat: false};
  return {underThreat: true, goat: lowestGoat, challenger, gap};
}

/** Identifies a specific (defender, challenger) confrontation, so a warning
 * fires once per NEW pairing rather than every sweep while it persists. */
function pairKey(goatUid, challengerUid) {
  return `${goatUid}|${challengerUid}`;
}

/**
 * Find the current throne threat, publish it to stats/goatThrone (which drives
 * the in-app banner for the two players), and push a one-time warning to each
 * side when the pairing is new. Best-effort - a failed push never throws.
 */
async function sweepGoatThrone(nowMs = Date.now()) {
  const db = getFirestore();
  const {sendToUsers} = require("./notifications");

  // The same read syncGoatTier uses: a generous top-N by rating, XP-filtered
  // in memory (Firestore can't range-filter one field and orderBy another
  // without a composite index).
  const snap = await db.collection("users")
      .orderBy("rating", "desc").limit(50).get();
  const players = snap.docs.map((d) => ({
    uid: d.id,
    name: d.data().username || "A challenger",
    rating: Number(d.data().rating) || 0,
    points: Number(d.data().points) || 0,
  }));

  const t = throneThreat(players, {
    poolSize: GOAT_POOL_SIZE,
    minXp: GOAT_ELIGIBLE_MIN_XP,
    margin: THRONE_MARGIN_RATING,
  });

  const ref = db.collection("stats").doc("goatThrone");
  const prev = (await ref.get()).data() || {};

  if (!t.underThreat) {
    // Clear the banner, but PRESERVE notifiedPair so a pairing that dips below
    // the margin and climbs back doesn't re-push the same warning.
    await ref.set({
      underThreat: false,
      notifiedPair: prev.notifiedPair ?? null,
      updatedAtMs: nowMs,
    }, {merge: true});
    return {underThreat: false};
  }

  const key = pairKey(t.goat.uid, t.challenger.uid);
  const isNew = key !== prev.notifiedPair;

  // Always refresh the state doc (drives the in-app banner), claiming the
  // pairing BEFORE sending - missing a warning costs one quiet evening,
  // duplicating one is how an app earns an OS-level mute.
  await ref.set({
    underThreat: true,
    goatUid: t.goat.uid,
    goatName: t.goat.name,
    challengerUid: t.challenger.uid,
    challengerName: t.challenger.name,
    notifiedPair: key,
    updatedAtMs: nowMs,
  }, {merge: true});

  if (!isNew) return {underThreat: true, pushed: false};

  // Warn both sides. Reuses the rank_change category, so anyone who muted rank
  // changes stays muted. sendToUsers honours that preference itself.
  try {
    await sendToUsers([t.goat.uid], {
      title: "Your throne is under threat",
      body: `${t.challenger.name} is closing in. Defend it in the Daily Gauntlet.`,
      category: "rank_change",
      data: {type: "goat_throne", role: "defender"},
    });
  } catch (e) {
    console.error("goatThrone defender push:", e.message);
  }
  try {
    await sendToUsers([t.challenger.uid], {
      title: "A GOAT throne is in reach",
      body: `You're closing in on ${t.goat.name}. Win in the Daily Gauntlet ` +
        "and it could be yours.",
      category: "rank_change",
      data: {type: "goat_throne", role: "challenger"},
    });
  } catch (e) {
    console.error("goatThrone challenger push:", e.message);
  }

  return {underThreat: true, pushed: true,
    goatUid: t.goat.uid, challengerUid: t.challenger.uid};
}

module.exports = {throneThreat, pairKey, sweepGoatThrone, THRONE_MARGIN_RATING};
