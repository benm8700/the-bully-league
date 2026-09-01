"use client";

import Link from "next/link";
import { useAuth } from "@/lib/AuthProvider";
import { StoreCta } from "@/components/StoreCta";

export function SiteHeader() {
  const { user, loading, logOut } = useAuth();

  return (
    <header className="sticky top-0 z-40 flex items-center justify-between border-b border-outline-soft bg-ink/80 px-6 py-3.5 backdrop-blur">
      <div className="flex items-center gap-6">
        <Link href="/" className="display text-lg leading-none">
          The Bully League
        </Link>
        <nav className="hidden items-center gap-5 sm:flex">
          <Link href="/demo" className="text-sm text-muted transition-colors hover:text-foreground">
            Demo
          </Link>
          <Link href="/matches" className="text-sm text-muted transition-colors hover:text-foreground">
            Matches
          </Link>
        </nav>
      </div>
      <div className="flex items-center gap-4">
        <div className="hidden sm:block">
          <StoreCta variant="inline" />
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
          <nav className="hidden text-sm md:block">
            <div className="flex items-center gap-3">
              <span className="text-muted">{user.email}</span>
              <button onClick={() => logOut()} className="text-primary-soft hover:underline">
                Sign Out
              </button>
            </div>
          </nav>
        )}
      </div>
    </header>
  );
}
