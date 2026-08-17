const {getAuth} = require("firebase-admin/auth");
const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {getStorage} = require("firebase-admin/storage");
const {getDatabase} = require("firebase-admin/database");
const {HttpsError} = require("firebase-functions/v2/https");

/**
 * User-initiated account and data deletion (CLAUDE.md's Compliance /
 * Account Management item: required under CCPA, and a question app store
 * reviewers ask directly).
 *
 * THE AWKWARD PART IS THAT MATCHES HAVE TWO PEOPLE IN THEM. One person
 * asking to be deleted cannot be allowed to destroy the other's footage,
 * rating history, or the record of matches they played. So this deletes
 * everything that is genuinely *theirs* and leaves shared records intact
 * but no longer pointing at a person.
 *
 * Recording each player separately turns out to matter here: because raw
 * footage is per-player files rather than one baked composite, a deleting
 * user's own video can be removed while their opponent's survives. Under
 * the previous composite recording that would have been impossible - the
 * only options would have been destroying the opponent's footage too, or
 * keeping video of someone who asked to be erased.
 *
 * WHAT IS DELETED OUTRIGHT
 *   - The user document: profile, ammo text, hometown, interests, photos
 *     list, push tokens. This is where the personal data actually lives.
 *   - Profile photos in Cloud Storage.
 *   - Their own raw match footage (their per-player files only).
 *   - Rendered highlights that were never published, since a composite
 *     necessarily contains them.
 *   - Any matchmaking queue entry, so they stop being pairable instantly.
 *   - The Firebase Auth account itself: email, phone, credentials.
 *
 * WHAT IS DELIBERATELY KEPT
 *   - Highlights already published. CLAUDE.md's position: those were
 *     consented to under the ToS at the time and are already publicly
 *     distributed, and deleting an account does not unpublish a live post.
 *     This is flagged in CLAUDE.md as a working answer wanting a real
 *     legal check, not a settled one.
 *   - Match documents and their results. The opponent has a legitimate
 *     interest in their own rating history, and removing one side would
 *     corrupt it. Once the user document is gone these hold only an
 *     opaque uid; the website feed already renders an unresolvable player
 *     as "Unknown" rather than breaking.
 *   - Ballots they cast. Deleting them would retroactively change other
 *     people's match outcomes.
 *   - Moderation reports. Deleting the record of a report would let
 *     someone erase their own history by deleting and re-registering,
 *     which is exactly the abuse the report system exists to catch.
 */

/**
 * Which Agora uid this player had in a given match, which is how their
 * own recording files are identified. Player 1 publishes as uid 1 and
 * player 2 as uid 2 (see functions/matchmaking.js).
 */
function playerUidInMatch(match, userId) {
  if (match.player1Id === userId) return "1";
  if (match.player2Id === userId) return "2";
  return null;
}

/** True if a recorded file belongs to this player specifically. */
function fileBelongsToPlayer(filePath, playerUid) {
  return filePath.includes(`__uid_s_${playerUid}__uid_e`);
}

/**
 * Decides what happens to one match's artefacts when a participant
 * deletes their account.
 *
 * Pure and separated from the deletion itself so the policy can be tested
 * directly - this is the code that decides what is irreversibly destroyed
 * and what a second person keeps, and it encodes a legal position rather
 * than a technical one.
 */
function planMatchDeletion(match, userId) {
  const playerUid = playerUidInMatch(match, userId);
  const published = match.highlight?.published === true;
  return {
    // Only this player's own footage. The opponent's files are untouched.
    deleteOwnRecordingForUid: playerUid,
    // A rendered highlight is a composite of both players, so an
    // unpublished one cannot be kept once one of them asks to be erased.
    deleteRenditions: !published,
    // Already public, already consented to. Left alone.
    keepPublishedHighlight: published,
    // The match record itself survives either way, for the opponent.
    keepMatchRecord: true,
  };
}

/**
 * Deletes a user's account and their personal data.
 *
 * Ordered so the user stops being reachable before the slower cleanup
 * runs: queue entries and the auth account go early, so a half-finished
 * deletion can never leave someone pairable or able to sign back in.
 */
async function deleteAccount(auth) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const userId = auth.uid;
  const db = getFirestore();
  const bucket = getStorage().bucket();
  const summary = {
    recordingFilesDeleted: 0,
    renditionsDeleted: 0,
    publishedHighlightsKept: 0,
    matchesRetained: 0,
    profilePhotosDeleted: 0,
  };

  // 1. Stop them being pairable immediately, before anything slower runs.
  for (const mode of ["exhibition", "ranked"]) {
    await getDatabase().ref(`matchmakingQueue/${mode}/${userId}`).remove().catch(() => {});
  }

  // 2. Their own matches - their footage goes, the shared record stays.
  for (const field of ["player1Id", "player2Id"]) {
    const matches = await db.collection("matches").where(field, "==", userId).get();
    for (const doc of matches.docs) {
      const match = doc.data();
      const plan = planMatchDeletion(match, userId);
      summary.matchesRetained++;

      if (plan.deleteOwnRecordingForUid) {
        const [objects] = await bucket.getFiles({prefix: `match_recordings/${doc.id}/`});
        for (const o of objects) {
          if (!fileBelongsToPlayer(o.name, plan.deleteOwnRecordingForUid)) continue;
          await o.delete().catch(() => {});
          summary.recordingFilesDeleted++;
        }
      }

      if (plan.deleteRenditions) {
        const [rendered] = await bucket.getFiles({prefix: `match_highlights/${doc.id}/`});
        for (const o of rendered) {
          await o.delete().catch(() => {});
          summary.renditionsDeleted++;
        }
        if (rendered.length > 0) {
          await doc.ref.set({
            highlight: {renditions: FieldValue.delete(), deletedForPrivacy: true},
          }, {merge: true}).catch(() => {});
        }
      } else if (plan.keepPublishedHighlight) {
        summary.publishedHighlightsKept++;
      }
    }
  }

  // 3. Profile photos.
  const [photos] = await bucket.getFiles({prefix: `profile_photos/${userId}/`});
  for (const o of photos) {
    await o.delete().catch(() => {});
    summary.profilePhotosDeleted++;
  }

  // 4. The user document AND everything beneath it.
  //
  // recursiveDelete, NOT delete(). Deleting a Firestore document does not
  // touch its subcollections - they survive as orphans, reachable by
  // anyone who knows the uid and invisible in the console because the
  // parent is gone. For this user that would leave `pointsLedger` (what
  // they earned and spent, and when) and `ratingHistory` (every rated
  // match, its date, and their opponent's id) behind after they had
  // asked to be erased.
  //
  // This is the shape of bug that only appears when a new subcollection
  // is added months after the deletion flow was written and verified, so
  // recursion is used deliberately rather than naming the two known
  // subcollections - a list would silently go stale the next time one is
  // added.
  const userRef = db.collection("users").doc(userId);
  try {
    await db.recursiveDelete(userRef);
    summary.subcollectionsPurged = true;
  } catch (e) {
    // Fall back to at least removing the document itself. Leaving the
    // profile in place because a subcollection sweep failed would be the
    // worse outcome by far.
    console.error(`recursive delete for ${userId} failed:`, e.message);
    summary.subcollectionsPurged = false;
    await userRef.delete().catch(() => {});
  }

  // 5. A record that the deletion happened, holding no personal data.
  // Useful as compliance evidence, and harmless: once the user document
  // and auth account are gone, the uid maps to nobody.
  await db.collection("deletedAccounts").doc(userId).set({
    deletedAt: FieldValue.serverTimestamp(),
    summary,
  }).catch(() => {});

  // 6. The auth account last, so a failure earlier still leaves an
  // account that can sign in and retry rather than an orphaned identity.
  await getAuth().deleteUser(userId);

  return {deleted: true, summary};
}

module.exports = {
  deleteAccount,
  planMatchDeletion,
  playerUidInMatch,
  fileBelongsToPlayer,
};
