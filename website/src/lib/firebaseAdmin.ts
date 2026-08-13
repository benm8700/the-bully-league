import { cert, getApps, initializeApp } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";

// Server-only - the Admin SDK reads/writes Firestore directly, bypassing
// firestore.rules entirely. This is deliberate: the website's homepage
// needs to show the live Top 5 leaderboard to ANONYMOUS visitors (see
// CLAUDE.md's Website homepage decision), and firestore.rules currently
// requires request.auth != null on every users/{userId} read - loosening
// that for public reads would expose full profile docs (ammoText,
// hometown, etc.) to the internet. Routing through server-side Admin SDK
// code instead matches the same "sensitive access goes through
// server-side code, not relaxed client rules" pattern used everywhere else
// in this project (Cloud Functions for rating/points writes, etc.).
function getAdminApp() {
  const existing = getApps();
  if (existing.length > 0) return existing[0]!;

  const projectId = process.env.FIREBASE_PROJECT_ID;
  const clientEmail = process.env.FIREBASE_CLIENT_EMAIL;
  // Service account keys from the Firebase console JSON have literal
  // "\n" sequences in the private key field, not real newlines - env vars
  // can't hold real newlines cleanly, so this must be unescaped.
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
