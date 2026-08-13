"use client";

import Link from "next/link";
import { useAuth } from "@/lib/AuthProvider";

export function SiteHeader() {
  const { user, loading, logOut } = useAuth();

  return (
    <header className="flex items-center justify-between px-6 py-4 border-b border-foreground/10">
      <Link href="/" className="font-bold">
        The Bully League
      </Link>
      {!loading && (
        <nav className="text-sm">
          {user ? (
            <div className="flex items-center gap-3">
              <span className="text-foreground/60">{user.email}</span>
              <button onClick={() => logOut()} className="text-accent hover:underline">
                Sign Out
              </button>
            </div>
          ) : (
            <Link href="/login" className="text-accent hover:underline">
              Sign In
            </Link>
          )}
        </nav>
      )}
    </header>
  );
}
