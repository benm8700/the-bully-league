import { cert, getApps, initializeApp } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";

// NOTE: we deliberately do NOT import "firebase-admin/auth". Its token
// verification pulls in jwks-rsa -> jose (pure ESM), and require()-ing that on
// Vercel's serverless Node runtime throws ERR_REQUIRE_ESM, which crashed every
// admin route in production. ID tokens are verified via Firebase's REST API
// (verifyIdTokenViaRest) instead, which needs no jose; firebase-admin here is
// used only for Firestore (no ESM-only deps).

// Server-only - the Admin SDK reads/writes Firestore directly, bypassing
// firestore.rules. Deliberate: the public site must show data to anonymous
// visitors without relaxing rules (see CLAUDE.md's Website homepage decision),
// and admin writes must bypass client rules behind the verifyAdmin gate.
function getAdminApp() {
  const existing = getApps();
  if (existing.length > 0) return existing[0]!;

  const projectId = process.env.FIREBASE_PROJECT_ID;
  const clientEmail = process.env.FIREBASE_CLIENT_EMAIL;
  // Service account keys from the Firebase console JSON have literal "\n"
  // sequences in the private key - env vars can't hold real newlines, so unescape.
  const privateKey = process.env.FIREBASE_PRIVATE_KEY?.replace(/\\n/g, "\n");

  if (!projectId || !clientEmail || !privateKey) {
    throw new Error(
      "Missing Firebase Admin credentials - set FIREBASE_PROJECT_ID, " +
        "FIREBASE_CLIENT_EMAIL, and FIREBASE_PRIVATE_KEY in .env.local " +
        "(see .env.local.example).",
    );
  }

  return initializeApp({
    credential: cert({ projectId, clientEmail, privateKey }),
  });
}

export function getAdminFirestore() {
  return getFirestore(getAdminApp());
}

/** Thrown by verifyAdmin; carries the HTTP status a route should return. */
export class AdminAuthError extends Error {
  constructor(
    public status: number,
    message: string,
  ) {
    super(message);
    this.name = "AdminAuthError";
  }
}

// Firebase Web API key - PUBLIC (same value committed in firebaseClient.ts and
// shipped in the app). Used only to call the Identity Toolkit REST endpoint,
// which ties the lookup to this project; it is not a secret.
const FIREBASE_WEB_API_KEY = "AIzaSyA07YDK7gkBPg20MfJZd7brXiST43j68kM";

/**
 * Verify a Firebase ID token WITHOUT firebase-admin/auth (see the note at the
 * top). accounts:lookup returns the account iff the token is a valid, unexpired
 * Firebase ID token for THIS project (the API key scopes it), so it both
 * authenticates and yields the uid. Throws AdminAuthError(401) otherwise.
 */
async function verifyIdTokenViaRest(
  idToken: string,
): Promise<{ uid: string; email?: string }> {
  let res: Response;
  try {
    res = await fetch(
      `https://identitytoolkit.googleapis.com/v1/accounts:lookup?key=${FIREBASE_WEB_API_KEY}`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ idToken }),
      },
    );
  } catch {
    throw new AdminAuthError(401, "Could not verify token");
  }
  if (!res.ok) throw new AdminAuthError(401, "Invalid or expired token");
  const data = (await res.json()) as {
    users?: { localId?: string; email?: string }[];
  };
  const user = data.users?.[0];
  if (!user?.localId) throw new AdminAuthError(401, "Invalid or expired token");
  return { uid: user.localId, email: user.email };
}

/**
 * Checks the signed-in caller's Firebase ID token (Authorization: Bearer) AND
 * that their account carries isAdmin === true (server-only in firestore.rules,
 * set by hand). Returns the caller's uid/email, or throws AdminAuthError 401
 * (not signed in / bad token) or 403 (signed in but not an admin).
 */
export async function verifyAdmin(
  request: Request,
): Promise<{ uid: string; email?: string }> {
  const header = request.headers.get("authorization") ?? "";
  const match = /^Bearer (.+)$/.exec(header);
  if (!match) throw new AdminAuthError(401, "Missing bearer token");

  const caller = await verifyIdTokenViaRest(match[1]!);
  const snap = await getAdminFirestore()
    .collection("users")
    .doc(caller.uid)
    .get();
  if (snap.data()?.isAdmin !== true) {
    throw new AdminAuthError(403, "Admin only");
  }
  return caller;
}

/** Non-throwing variant for the /me gate: who you are + whether you're admin. */
export async function describeCaller(
  request: Request,
): Promise<{ signedIn: boolean; admin: boolean; uid?: string; email?: string }> {
  const header = request.headers.get("authorization") ?? "";
  const match = /^Bearer (.+)$/.exec(header);
  if (!match) return { signedIn: false, admin: false };
  const caller = await verifyIdTokenViaRest(match[1]!);
  const snap = await getAdminFirestore()
    .collection("users")
    .doc(caller.uid)
    .get();
  return {
    signedIn: true,
    admin: snap.data()?.isAdmin === true,
    uid: caller.uid,
    email: caller.email,
  };
}
