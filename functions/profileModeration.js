const {onDocumentWritten} = require("firebase-functions/v2/firestore");
const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {HttpsError} = require("firebase-functions/v2/https");
const {profileTextProblem} = require("./username");

/**
 * Profile text moderation (added 2026-11-09, after a beta tester put a slur
 * in his display name and a child-sex "joke" in his bio - both reached the
 * bio reveal every opponent sees, because profile text was written straight
 * from the client with no check at all).
 *
 * Two layers, same rule (username.js profileTextProblem: hate, the "niger"
 * evasion, anything sexualising children - ordinary swearing stays allowed):
 *   1. checkProfileText - the app asks BEFORE saving, so the player gets a
 *      clear "that isn't allowed" on the field instead of a silent wipe.
 *   2. onUserProfileWritten - the enforcement. Profile fields are still a
 *      plain client write (no new rules to get wrong), so a modified or old
 *      client can save anything; this trigger blanks any field that fails.
 */

/** Profile keys that hold free text a person typed (not URLs/paths). */
function textFieldsOf(profile) {
  if (!profile || typeof profile !== "object") return {};
  const out = {};
  for (const [k, v] of Object.entries(profile)) {
    if (typeof v === "string" && !/url|path/i.test(k)) out[k] = v;
  }
  return out;
}

/** Keys of `fields` whose text is not allowed. Pure, for tests. */
function blockedFields(fields) {
  return Object.entries(fields ?? {})
      .filter(([, v]) => typeof v === "string" && profileTextProblem(v))
      .map(([k]) => k);
}

async function checkProfileText(data, auth) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const fields = data?.fields;
  if (!fields || typeof fields !== "object") {
    throw new HttpsError("invalid-argument", "fields is required.");
  }
  const trimmed = {};
  for (const [k, v] of Object.entries(fields).slice(0, 20)) {
    if (typeof v === "string") trimmed[k] = v.slice(0, 1000);
  }
  return {blocked: blockedFields(trimmed)};
}

const onUserProfileWritten = onDocumentWritten("users/{uid}", async (event) => {
  const after = event.data?.after?.data();
  if (!after) return;
  const before = event.data?.before?.data();
  const now = textFieldsOf(after.profile);
  const was = textFieldsOf(before?.profile);
  // Only look at text that changed - most user-doc writes (points, votes,
  // presence) never touch the profile, and an unchanged field was already
  // checked when it was written.
  const changed = {};
  for (const [k, v] of Object.entries(now)) if (was[k] !== v) changed[k] = v;
  const bad = blockedFields(changed);
  if (bad.length === 0) return;
  const update = {
    profileTextRemovedAt: FieldValue.serverTimestamp(),
    profileTextRemovedFields: bad,
  };
  for (const k of bad) update[`profile.${k}`] = "";
  try {
    await getFirestore().collection("users").doc(event.params.uid).update(update);
    console.log(`profile text removed for ${event.params.uid}: ${bad.join(", ")}`);
  } catch (e) {
    console.error("onUserProfileWritten failed:", e.message);
  }
});

module.exports = {
  checkProfileText,
  onUserProfileWritten,
  blockedFields,
  textFieldsOf,
};
