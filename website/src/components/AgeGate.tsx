"use client";

import { useEffect, useState } from "react";

const STORAGE_KEY = "bullyleague_age_confirmed";

// CLAUDE.md's Website age gating decision: NOT full login/age-API
// verification just to watch (would kill the viral sharing loop - someone
// clicking a shared clip shouldn't hit a login wall). Instead, a
// lightweight self-attestation click-through, no login required. Full
// verification (Google Play Age Signals) stays required for account
// creation and voting in the app - this only gates passive anonymous
// viewing on the website, a lower risk profile per that same decision.
export function AgeGate() {
  const [confirmed, setConfirmed] = useState(true); // default true avoids a flash on first paint

  useEffect(() => {
    // localStorage doesn't exist during server rendering, so this can't be
    // read as a lazy useState initializer (would throw during SSR) - a
    // one-time correction on mount is the standard, necessary pattern here.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setConfirmed(localStorage.getItem(STORAGE_KEY) === "true");
  }, []);

  function confirm() {
    localStorage.setItem(STORAGE_KEY, "true");
    setConfirmed(true);
  }

  if (confirmed) return null;

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-ink/95 px-6 backdrop-blur-sm">
      <div className="flex w-full max-w-sm flex-col items-center gap-4 rounded-2xl border border-outline bg-surface p-8 text-center">
        <span className="eyebrow" style={{ color: "var(--live)" }}>Mature content</span>
        <h2 className="display text-2xl">Are you 18 or older?</h2>
        <p className="text-sm text-muted">
          The Bully League is unfiltered comedic roasting — strong and offensive
          language included. It&apos;s not intended for anyone under 18.
        </p>
        <button
          onClick={confirm}
          className="w-full rounded-full py-3 font-semibold text-white"
          style={{ background: "var(--primary)", boxShadow: "0 8px 24px rgba(234,76,109,0.35)" }}
        >
          I&apos;m 18 or older — Continue
        </button>
      </div>
    </div>
  );
}
