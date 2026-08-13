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
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-background/95 backdrop-blur-sm px-6">
      <div className="max-w-sm w-full flex flex-col items-center text-center gap-4 rounded-lg border border-foreground/10 p-8">
        <h2 className="text-xl font-bold">Mature Content</h2>
        <p className="text-sm text-foreground/70">
          The Bully League features unfiltered comedic roasting, including strong and offensive
          language. It&apos;s not intended for people under 18.
        </p>
        <button
          onClick={confirm}
          className="w-full rounded-md bg-accent text-black font-medium px-4 py-2"
        >
          I&apos;m 18 or older — Continue
        </button>
      </div>
    </div>
  );
}
