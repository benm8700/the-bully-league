const {getFirestore} = require("firebase-admin/firestore");
const {HttpsError} = require("firebase-functions/v2/https");

/**
 * A battler's MARKETING-USE consent for one specific battle of theirs.
 *
 * This is deliberately SEPARATE from the two consents that already exist:
 *   - in-app RECORDING consent (covers recording the match + showing it in the
 *     in-app feed / judging), given before every match; and
 *   - the OBJECTION window (the opt-out before a clip is published to OUR
 *     surfaces - the website feed / downloads).
 *
 * This third one is the explicit "yes, you may use THIS clip in The Bully
 * League's OWN promos / official socials (TikTok, IG, YouTube)". The
 * official-posting strategy (see CLAUDE.md) requires marketing-use consent from
 * BOTH battlers before a clip goes out as the company's advertising - because a
 * person being cast in someone's ad is a materially different ask from playing
 * a judged match. The Post Studio surfaces this as the ✅/⚠️/❌ flag per clip.
 *
 * Stored per match per player at match.marketingConsent.{uid} = {consent, at}.
 * true = yes, false = declined, absent = not answered yet. Match docs are
 * server-write-only (firestore.rules), so this callable is the only writer;
 * clients read the field straight off the match doc they can already see.
 */
async function setMatchMarketingConsent(auth, data) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const matchId = data && data.matchId;
  if (!matchId || typeof matchId !== "string") {
    throw new HttpsError("invalid-argument", "matchId required.");
  }
  const consent = data.consent === true; // anything but an explicit yes = no
  const db = getFirestore();
  const ref = db.collection("matches").doc(matchId);
  const snap = await ref.get();
  if (!snap.exists) throw new HttpsError("not-found", "Match not found.");
  const m = snap.data();
  // Only the two people IN the clip may speak to its marketing use - nobody
  // else's consent is theirs to give.
  if (auth.uid !== m.player1Id && auth.uid !== m.player2Id) {
    throw new HttpsError(
        "permission-denied", "Only the two battlers can set this.");
  }
  // Deep-merge so setting one player's answer never wipes the other's.
  await ref.set({
    marketingConsent: {[auth.uid]: {consent, at: Date.now()}},
  }, {merge: true});
  const after = (await ref.get()).data();
  return {marketingConsent: after.marketingConsent || {}};
}

module.exports = {setMatchMarketingConsent};
