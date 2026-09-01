"use client";

import { useState } from "react";
import Link from "next/link";
import { PhoneFrame } from "@/components/demo/PhoneFrame";
import { DEMO_SCREENS } from "@/components/demo/screens";
import { StoreCta } from "@/components/StoreCta";

export default function DemoPage() {
  const [i, setI] = useState(0);
  const screen = DEMO_SCREENS[i];
  const go = (n: number) => setI((n + DEMO_SCREENS.length) % DEMO_SCREENS.length);

  return (
    <main className="flex-1 px-5 py-10 sm:py-14">
      <div className="mx-auto flex max-w-3xl flex-col items-center text-center">
        <span className="eyebrow" style={{ color: "var(--primary-soft)" }}>
          Interactive demo
        </span>
        <h1 className="mt-2 text-4xl sm:text-5xl">See it in action</h1>
        <p className="mt-3 max-w-md text-sm text-muted">
          No Android? No problem. Click through the real screens — from the
          first tap to the nightly tournament.
        </p>
      </div>

      {/* screen picker */}
      <div className="mx-auto mt-8 flex max-w-2xl flex-wrap justify-center gap-2">
        {DEMO_SCREENS.map((s, idx) => {
          const on = idx === i;
          return (
            <button
              key={s.id}
              onClick={() => setI(idx)}
              aria-current={on}
              className="rounded-full px-3.5 py-1.5 text-[13px] font-semibold transition-colors"
              style={
                on
                  ? { background: "var(--primary)", color: "#fff" }
                  : { background: "var(--surface-2)", color: "var(--muted)" }
              }
            >
              {s.label}
            </button>
          );
        })}
      </div>

      {/* phone + controls */}
      <div className="mt-8 flex flex-col items-center gap-6">
        <div className="flex items-center gap-3 sm:gap-6">
          <NavArrow dir="prev" onClick={() => go(i - 1)} />
          <PhoneFrame glow>{screen.render()}</PhoneFrame>
          <NavArrow dir="next" onClick={() => go(i + 1)} />
        </div>

        <div className="text-center">
          <p className="display text-lg">{screen.label}</p>
          <p className="mt-1 max-w-xs text-[13px] text-muted">{screen.tagline}</p>
        </div>

        {/* dots */}
        <div className="flex gap-2">
          {DEMO_SCREENS.map((s, idx) => (
            <button
              key={s.id}
              onClick={() => setI(idx)}
              aria-label={`Go to ${s.label}`}
              className="h-2 rounded-full transition-all"
              style={{
                width: idx === i ? 22 : 8,
                background: idx === i ? "var(--primary)" : "var(--outline)",
              }}
            />
          ))}
        </div>
      </div>

      {/* close */}
      <div className="mx-auto mt-12 flex max-w-md flex-col items-center gap-3 text-center">
        <p className="text-sm text-muted">
          Battles happen in the app. This is just the tour.
        </p>
        <StoreCta />
        <Link
          href="/"
          className="text-[13px] font-semibold text-muted underline-offset-4 hover:text-foreground hover:underline"
        >
          Back to home
        </Link>
      </div>
    </main>
  );
}

function NavArrow({ dir, onClick }: { dir: "prev" | "next"; onClick: () => void }) {
  return (
    <button
      onClick={onClick}
      aria-label={dir === "prev" ? "Previous screen" : "Next screen"}
      className="grid h-11 w-11 shrink-0 place-items-center rounded-full border border-outline bg-surface text-foreground transition-colors hover:border-primary hover:text-primary-soft"
    >
      <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" style={{ transform: dir === "next" ? "none" : "scaleX(-1)" }}>
        <path d="M9 6l6 6-6 6" />
      </svg>
    </button>
  );
}
