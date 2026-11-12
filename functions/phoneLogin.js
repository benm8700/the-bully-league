const {getAuth} = require("firebase-admin/auth");
const {getFirestore} = require("firebase-admin/firestore");
const {HttpsError} = require("firebase-functions/v2/https");
const {normalizeE164} = require("./phoneSignup");

/**
 * "Log in with your phone number" for accounts that are really email +
 * password (sign-up links a phone to every account).
 *
 * The obvious version - "give me the email for this number" - would let anyone
 * turn a phone number into an email address. So the PASSWORD is checked here
 * first (Identity Toolkit's own signInWithPassword, with the app's public web
 * key), and the email comes back only to someone who already knows it. The
 * client then signs in normally with that email + password.
 *
 * Every failure reads the same ("Wrong phone number or password."), so this
 * can't be used to probe which numbers have accounts.
 */
const API_KEY = "AIzaSyD-yeC1osuXpfwXWNZPnLEOq7yLviM7J0c"; // public client key
const WRONG = "Wrong phone number or password.";

async function resolvePhoneLogin(data) {
  const phone = normalizeE164(typeof data?.phone === "string" ? data.phone : "");
  const password = typeof data?.password === "string" ? data.password : "";
  if (!phone || !password) throw new HttpsError("invalid-argument", WRONG);

  let email = null;
  try {
    email = (await getAuth().getUserByPhoneNumber(phone)).email ?? null;
  } catch (_) {
    // Not the Auth phone (older accounts) - fall back to the user doc field.
  }
  if (!email) {
    const found = await getFirestore().collection("users")
        .where("phoneNumber", "==", phone).limit(1).get();
    if (!found.empty) {
      try {
        email = (await getAuth().getUser(found.docs[0].id)).email ?? null;
      } catch (_) {
        email = null;
      }
    }
  }
  if (!email) throw new HttpsError("permission-denied", WRONG);

  const res = await fetch(
      "https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword" +
      `?key=${API_KEY}`,
      {
        method: "POST",
        headers: {"Content-Type": "application/json"},
        body: JSON.stringify({email, password, returnSecureToken: false}),
      });
  if (!res.ok) {
    const body = await res.json().catch(() => ({}));
    const msg = String(body?.error?.message ?? "");
    if (msg.startsWith("TOO_MANY_ATTEMPTS")) {
      throw new HttpsError("resource-exhausted",
          "Too many attempts. Wait a few minutes and try again.");
    }
    if (msg.startsWith("USER_DISABLED")) {
      throw new HttpsError("permission-denied",
          "This account has been disabled.");
    }
    throw new HttpsError("permission-denied", WRONG);
  }
  return {email};
}

module.exports = {resolvePhoneLogin};
