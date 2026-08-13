"use client";

import { signInWithEmailAndPassword } from "firebase/auth";
import { useRouter } from "next/navigation";
import { useState } from "react";
import { auth } from "@/lib/firebaseClient";

// Login only, no signup here - account creation still happens in the app
// (phone + email + password + age verification, per CLAUDE.md's Core
// Match Flow section). This page exists purely so an existing account can
// sign into the SAME Firebase Auth identity from the website (CLAUDE.md's
// Shared login decision), e.g. to vote on matches later.
export default function LoginPage() {
  const router = useRouter();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setSubmitting(true);
    try {
      await signInWithEmailAndPassword(auth, email, password);
      router.push("/");
    } catch {
      setError("Invalid email or password.");
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <main className="flex-1 flex items-center justify-center px-6 py-20">
      <form onSubmit={handleSubmit} className="w-full max-w-sm flex flex-col gap-4">
        <h1 className="text-2xl font-bold text-center mb-2">Sign In</h1>
        <p className="text-sm text-foreground/60 text-center mb-2">
          Use the same email and password as your Bully League account.
        </p>
        <input
          type="email"
          required
          placeholder="Email"
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          className="rounded-md border border-foreground/20 bg-transparent px-4 py-2 outline-none focus:border-accent"
        />
        <input
          type="password"
          required
          placeholder="Password"
          value={password}
          onChange={(e) => setPassword(e.target.value)}
          className="rounded-md border border-foreground/20 bg-transparent px-4 py-2 outline-none focus:border-accent"
        />
        {error && <p className="text-sm text-red-400">{error}</p>}
        <button
          type="submit"
          disabled={submitting}
          className="rounded-md bg-accent text-black font-medium px-4 py-2 disabled:opacity-50"
        >
          {submitting ? "Signing in..." : "Sign In"}
        </button>
      </form>
    </main>
  );
}
