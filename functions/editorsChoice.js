const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {getStorage} = require("firebase-admin/storage");
const {HttpsError} = require("firebase-functions/v2/https");

const PREVIEW_TTL_MS = 6 * 60 * 60 * 1000; // 6h signed-url lifetime

/**
 * Editor's Choice - the founder's two SEPARATE admin actions on a battle:
 *
 *   PUBLISH  - make the clip's video public/playable (runs the real publish
 *              gate: objection window closed, no participant objection, a render
 *              exists). Useful beyond featuring - a published clip is what the
 *              in-app feed and the website can play.
 *   FEATURE  - put the battle in the Home "Featured" spotlight. A featured card
 *              PLAYS its clip only if the battle is also published; otherwise it
 *              is a names-only spotlight (safe - a spotlight exposes no footage).
 *
 * They are independent (publish without featuring, feature without a clip), but
 * kept consistent: publishing/un-publishing refreshes any existing featured
 * doc's clipUrl, so the two can be done in either order without a stale card.
 */

function clipFromPublicUrls(pub) {
  if (!pub) return null;
  return pub.landscape || pub.vertical || null;
}

/** The current playable clip url for a match, or null if not published. */
function clipUrlForMatch(match) {
  const hl = (match && match.highlight) || {};
  return hl.published === true ? clipFromPublicUrls(hl.publicUrls) : null;
}

/** Add a battle to the Home spotlight (or remove it). Does NOT publish - that is
 * a separate action; the card is a spotlight until the battle is published. */
async function featureBattle(matchId, adminUid, feature) {
  const db = getFirestore();
  const featuredRef = db.collection("featured").doc(matchId);
  if (feature === false) {
    // Un-feature: remove from the spotlight. Keeps the clip published (that is a
    // separate decision) and the performers' badge (being picked happened).
    await featuredRef.delete();
    return {featured: false};
  }

  const snap = await db.collection("matches").doc(matchId).get();
  if (!snap.exists) throw new HttpsError("not-found", "Match not found.");
  const m = snap.data();
  const p1 = m.player1Id;
  const p2 = m.player2Id;
  if (!p1 || !p2) {
    throw new HttpsError("failed-precondition", "That match has no players.");
  }
  const clipUrl = clipUrlForMatch(m);
  const [u1, u2] = await Promise.all([
    db.collection("users").doc(p1).get(),
    db.collection("users").doc(p2).get(),
  ]);
  const nameOf = (s) => (s.data() && s.data().username) || "Unknown";

  await db.runTransaction(async (tx) => {
    const f = await tx.get(featuredRef);
    const firstTime = !f.exists;
    tx.set(featuredRef, {
      matchId,
      player1Id: p1,
      player2Id: p2,
      player1Name: nameOf(u1),
      player2Name: nameOf(u2),
      clipUrl: clipUrl || null,
      pickedBy: adminUid,
      pickedAt: FieldValue.serverTimestamp(),
    }, {merge: true});
    // The permanent ⭐ badge, granted ONCE (first time THIS match is featured).
    if (firstTime) {
      if (u1.exists) {
        tx.update(db.collection("users").doc(p1),
            {editorsChoicePicks: FieldValue.increment(1)});
      }
      if (u2.exists) {
        tx.update(db.collection("users").doc(p2),
            {editorsChoicePicks: FieldValue.increment(1)});
      }
    }
  });
  return {featured: true, clip: !!clipUrl};
}

/** Publish (or un-publish) a battle's clip, reusing the real publish gate, then
 * keep any featured card in sync with the new publish state. */
async function publishBattle(matchId, published) {
  const {publishHighlight, unpublishHighlight} = require("./publishHighlight");
  const result = published === false ?
    await unpublishHighlight(matchId) :
    await publishHighlight(matchId);

  // Refresh a featured card's clipUrl so it reflects the new state - playable
  // once published, spotlight again once taken down. Only if it's featured.
  const db = getFirestore();
  const featuredRef = db.collection("featured").doc(matchId);
  const f = await featuredRef.get();
  if (f.exists) {
    const clipUrl = published === false ?
      null :
      clipFromPublicUrls(result.publicUrls);
    await featuredRef.set({clipUrl: clipUrl || null}, {merge: true});
  }
  return result;
}

/**
 * A short-lived URL so the dashboard can PREVIEW a clip before publishing it -
 * published or not. A published clip already has a permanent public URL; an
 * unpublished render is signed on demand (same approach as the in-app feed's
 * clipUrl). Admin-only, so serving an unreviewed render here is fine.
 */
async function previewClip(matchId, {blurred = false} = {}) {
  const db = getFirestore();
  const snap = await db.collection("matches").doc(matchId).get();
  if (!snap.exists) throw new HttpsError("not-found", "Match not found.");
  const hl = (snap.data() || {}).highlight || {};
  const published = hl.published === true;
  const pub = hl.publicUrls || {};
  // The blurred cut is a post-only, never-published render, so it is always
  // served by a signed URL from its own blurRenditions set.
  const rends = blurred ? (hl.blurRenditions || {}) : (hl.renditions || {});
  // Both renditions, so the dashboard can toggle landscape (side-by-side, the
  // website cut) vs vertical (stacked, the in-app / TikTok cut) with no refetch.
  async function urlFor(name) {
    if (!blurred && published && pub[name]) return pub[name];
    const rend = rends[name];
    if (rend && rend.path) {
      const [url] = await getStorage().bucket().file(rend.path).getSignedUrl({
        action: "read",
        expires: Date.now() + PREVIEW_TTL_MS,
      });
      return url;
    }
    return null;
  }
  const [landscape, vertical] = await Promise.all([
    urlFor("landscape"), urlFor("vertical"),
  ]);
  if (!landscape && !vertical) {
    throw new HttpsError("failed-precondition",
        "No rendered clip to preview yet.");
  }
  return {landscape, vertical};
}

module.exports = {featureBattle, publishBattle, previewClip};
