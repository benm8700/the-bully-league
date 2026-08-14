const crypto = require("crypto");
const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {getStorage} = require("firebase-admin/storage");
const {HttpsError} = require("firebase-functions/v2/https");

/**
 * Publishing and un-publishing highlight clips - the step that turns an
 * approved render into something the website can actually play.
 *
 * This is the enforcement point for CLAUDE.md's human review gate: a
 * render exists as soon as a match is rendered, but it is unreachable by
 * anyone until an admin publishes it here. Nothing in the pipeline
 * publishes on its own.
 *
 * HOW ACCESS IS GRANTED: by setting a Firebase Storage download token on
 * the object, not by copying it or loosening bucket rules. Probed against
 * this bucket to confirm the behaviour: with a token the file fetches
 * unauthenticated (HTTP 200), without one it is refused (HTTP 403).
 *
 * That choice matters for two reasons:
 *   - Un-publishing genuinely REVOKES access. Clearing the token makes
 *     every previously-issued URL start failing, which is what a takedown
 *     has to mean. Copying files to a "public" folder would leave the
 *     copy behind and make revocation a second, forgettable step.
 *   - It works regardless of whether the bucket uses uniform access or
 *     per-object ACLs, so a later change to that setting can't silently
 *     break publishing or, worse, silently expose everything.
 *
 * Storage rules still deny clients any direct read of these paths. The
 * token is the only route in, and it only exists after review.
 */

const HIGHLIGHT_PREFIX = "match_highlights";

/** A published clip is reachable by anyone holding the URL, so the token
 * has to be unguessable rather than derived from the match id. */
function newToken() {
  return crypto.randomUUID();
}

function downloadUrl(bucketName, objectPath, token) {
  return `https://firebasestorage.googleapis.com/v0/b/${bucketName}` +
    `/o/${encodeURIComponent(objectPath)}?alt=media&token=${token}`;
}

/** Rendition name from a stored path, e.g. ".../vertical.mp4" -> "vertical". */
function renditionNameFromPath(objectPath) {
  const file = objectPath.split("/").pop() ?? "";
  return file.replace(/\.mp4$/, "");
}

/**
 * Makes a match's rendered clips publicly playable.
 *
 * Approving and publishing are the same action deliberately: an admin
 * watching a clip and deciding it can go out is one decision, and
 * splitting it into two flags invites a state where something is approved
 * but nobody remembers to publish it.
 */
async function publishHighlight(matchId) {
  const db = getFirestore();
  const bucket = getStorage().bucket();
  const matchRef = db.collection("matches").doc(matchId);
  const snap = await matchRef.get();
  if (!snap.exists) throw new HttpsError("not-found", "Match not found.");

  // A HARD BLOCK, enforced here rather than left to an admin remembering.
  // Two things stop a publication: a participant having objected, and the
  // objection window still being open - so nothing reaches a public
  // audience before both players have had their full chance to opt out.
  // Putting this in the publish path itself is the point; a note in a
  // console is exactly what gets missed at the moment it matters.
  //
  // Collecting the objection BEFORE publishing is also the honest answer to
  // "posting it cost me money": the money is never spent on footage that
  // cannot be used.
  const {publishBlockedReason} = require("./takedown");
  const blocked = publishBlockedReason(snap.data(), Date.now());
  if (blocked === "participant-objected") {
    throw new HttpsError(
        "failed-precondition",
        "A player in this battle has asked for it not to be posted.",
    );
  }
  if (blocked === "objection-window-open") {
    throw new HttpsError(
        "failed-precondition",
        "Voting is still open on this battle, so its players can still opt " +
        "out. It can be published once that window closes.",
    );
  }

  const [objects] = await bucket.getFiles({prefix: `${HIGHLIGHT_PREFIX}/${matchId}/`});
  const videos = objects.filter((o) => o.name.endsWith(".mp4"));
  if (videos.length === 0) {
    throw new HttpsError(
        "failed-precondition",
        "This match has no rendered highlight yet - render it first.",
    );
  }

  const publicUrls = {};
  for (const object of videos) {
    const token = newToken();
    await object.setMetadata({
      contentType: "video/mp4",
      metadata: {firebaseStorageDownloadTokens: token},
    });
    publicUrls[renditionNameFromPath(object.name)] =
      downloadUrl(bucket.name, object.name, token);
  }

  await matchRef.set({
    highlight: {
      published: true,
      reviewStatus: "approved",
      publishedAt: FieldValue.serverTimestamp(),
      publicUrls,
    },
  }, {merge: true});

  // Tell both players their battle is now public.
  //
  // Without this, the safeguards are theoretical: you cannot object to
  // something you do not know exists, and the person most likely to want a
  // takedown is exactly the person who never found out their clip went out.
  // Best-effort - a failed push must never undo a completed publication.
  try {
    const {sendToUsers} = require("./notifications");
    const match = snap.data();
    const players = await Promise.all([
      db.collection("users").doc(match.player1Id).get(),
      db.collection("users").doc(match.player2Id).get(),
    ]);
    await sendToUsers(players.filter((p) => p.exists), {
      title: "Your battle is live",
      body: "One of your roasts just went public. Tap if you'd rather it wasn't.",
      category: "match_found",
      data: {kind: "highlight_published", matchId},
    });
  } catch (e) {
    console.error(`publish notification failed for ${matchId}:`, e.message);
  }

  return {published: true, renditions: Object.keys(publicUrls), publicUrls};
}

/**
 * Takes a published clip down.
 *
 * Clearing the download token is what actually revokes access - every URL
 * already handed out stops working immediately. That's the property a
 * takedown needs: someone who has the link should lose it, not merely be
 * hidden from the feed.
 *
 * Note this is DELIBERATELY different from the CCPA position on account
 * deletion, where an already-published clip is retained. That rule is
 * about a user erasing themselves; this is a moderator removing content,
 * and it has to be able to actually remove it.
 */
async function unpublishHighlight(matchId) {
  const db = getFirestore();
  const bucket = getStorage().bucket();
  const matchRef = db.collection("matches").doc(matchId);
  const snap = await matchRef.get();
  if (!snap.exists) throw new HttpsError("not-found", "Match not found.");

  const [objects] = await bucket.getFiles({prefix: `${HIGHLIGHT_PREFIX}/${matchId}/`});
  for (const object of objects.filter((o) => o.name.endsWith(".mp4"))) {
    await object.setMetadata({metadata: {firebaseStorageDownloadTokens: ""}});
  }

  await matchRef.set({
    highlight: {
      published: false,
      reviewStatus: "unpublished",
      publicUrls: FieldValue.delete(),
      unpublishedAt: FieldValue.serverTimestamp(),
    },
  }, {merge: true});

  return {published: false};
}

module.exports = {
  publishHighlight,
  unpublishHighlight,
  downloadUrl,
  renditionNameFromPath,
  HIGHLIGHT_PREFIX,
};
