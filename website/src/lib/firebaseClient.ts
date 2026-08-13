"use client";

import { getApps, initializeApp } from "firebase/app";
import { getAuth } from "firebase/auth";

// Client-side Firebase config - NOT a secret (same treatment as the
// Flutter app's lib/firebase_options.dart, which is committed too). Web
// API keys are public by design; they're scoped by Firebase Auth/Firestore
// security rules and (optionally) HTTP referrer restrictions, not secrecy.
// Registered via `firebase apps:create web` - see CLAUDE.md's Website
// implementation status note for the "shared login" decision this exists
// to support (same Firebase Auth identity as the Flutter app).
const firebaseConfig = {
  apiKey: "AIzaSyA07YDK7gkBPg20MfJZd7brXiST43j68kM",
  authDomain: "the-bully-league.firebaseapp.com",
  projectId: "the-bully-league",
  storageBucket: "the-bully-league.firebasestorage.app",
  messagingSenderId: "283010814552",
  appId: "1:283010814552:web:2b8261bb67ae0bbbf9702d",
  measurementId: "G-GBTL8K0THW",
};

const app = getApps()[0] ?? initializeApp(firebaseConfig);

export const auth = getAuth(app);
