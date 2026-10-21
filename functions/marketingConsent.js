const {getFirestore} = require("firebase-admin/firestore");
const {HttpsError} = require("firebase-functions/v2/https");

/**
 * A battler's MARKETING-USE preference for one specific battle of theirs.
 *
 * Three modes (default is "in" when absent):
 *   - "in"   : fine to feature as-is (the default - everyone okays promo use in
 *              the recording-consent acknowledgement before they play).
 *   - "blur" : keep the clip alive for their opponent, but BLUR their own panel
 *              in any posted version (face hidden, audio kept). The easy opt-out.
 *   - "out"  : remove entirely - not postable at all. The full withdrawal.
 *
 * Separate from recording consent (recording + in-app judging) and the
 * takedown/objection window. Stored at match.marketingConsent.{uid}={mode,at};
 * match docs are write:false for clients, so this callable is the only writer.
 */
const VALID_MODES = new Set(["in", "blur", "out"]);

async function setMatchMarketingConsent(auth, data) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const matchId = data && data.matchId;
  if (!matchId || typeof matchId !== "string") {
    throw new HttpsError("invalid-argument", "matchId required.");
  }
  const mode = data && data.mode;
  if (!VALID_MODES.has(mode)) {
    throw new HttpsError("invalid-argument", "mode must be in | blur | out.");
  }
  const db = getFirestore();
  const ref = db.collection("matches").doc(matchId);
  const snap = await ref.get();
  if (!snap.exists) throw new HttpsError("not-found", "Match not found.");
  const m = snap.data();
  if (auth.uid !== m.player1Id && auth.uid !== m.player2Id) {
    throw new HttpsError(
        "permission-denied", "Only the two battlers can set this.");
  }
  await ref.set({
    marketingConsent: {[auth.uid]: {mode, at: Date.now()}},
  }, {merge: true});
  const after = (await ref.get()).data();
  return {marketingConsent: after.marketingConsent || {}};
}

/**
 * The render/panel uids ("1" / "2") to blur for a match, from its consent.
 *
 * player1Id is always Agora uid 1 and player2Id is Agora uid 2 (fixed at
 * pairing, and what the recording segments are tagged with), so a blurred
 * player maps straight to their panel. Only "blur" players are returned - "out"
 * is handled by not posting the clip at all.
 */
function blurPanelUidsFor(match) {
  const mc = (match && match.marketingConsent) || {};
  const out = [];
  if (mc[match.player1Id] && mc[match.player1Id].mode === "blur") out.push("1");
  if (mc[match.player2Id] && mc[match.player2Id].mode === "blur") out.push("2");
  return out;
}

/** The clip-level status from both players' modes: "out" (don't post) wins,
 * then "blur" (post the blurred cut), else "ok". */
function clipConsentStatus(match) {
  const mc = (match && match.marketingConsent) || {};
  const m1 = mc[match.player1Id] && mc[match.player1Id].mode;
  const m2 = mc[match.player2Id] && mc[match.player2Id].mode;
  if (m1 === "out" || m2 === "out") return "out";
  if (m1 === "blur" || m2 === "blur") return "blur";
  return "ok";
}

module.exports = {setMatchMarketingConsent, blurPanelUidsFor, clipConsentStatus};
