"use client";

import Link from "next/link";
import { useAuth } from "@/lib/AuthProvider";

export function SiteHeader() {
  const { user, loading, logOut } = useAuth();

  return (
    <header className="flex items-center justify-between px-6 py-4 border-b border-foreground/10">
      <div className="flex items-center gap-6">
        <Link href="/" className="font-bold">
          The Bully League
        </Link>
        <Link href="/matches" className="text-sm text-foreground/70 hover:text-foreground">
          Matches
        </Link>
      </div>
      {/* SIGN IN IS NO LONGER OFFERED, because nothing on this site needs
          an account any more. Voting was the only thing that did, and it
          has moved entirely into the app.

          A "Sign In" that leads to a form that leads back to an identical
          page is the same defect as a button that answers "Admin only" -
          a control that exists and does nothing reads as broken. The
          /login route and the auth plumbing are deliberately kept, just
          unlinked, so this is one line to restore when something on the
          site genuinely needs a signed-in user.

          Sign OUT is still shown to anyone who has an existing session,
          or they would be stuck signed in with no way out. */}
      {!loading && user && (
        <nav className="text-sm">
          <div className="flex items-center gap-3">
            <span className="text-foreground/60">{user.email}</span>
            <button onClick={() => logOut()} className="text-accent hover:underline">
              Sign Out
            </button>
          </div>
        </nav>
      )}
    </header>
  );
}
