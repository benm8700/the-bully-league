import type { ReactNode } from "react";
import { StatusBar } from "./PhoneFrame";

/* Small shared pieces used across the screen mockups. Presentational only. */

export function ScreenShell({
  children,
  time,
  pad = true,
}: {
  children: ReactNode;
  time?: string;
  pad?: boolean;
}) {
  return (
    <div className="flex min-h-full flex-col bg-ink text-foreground">
      <StatusBar time={time} />
      <div className={`flex-1 ${pad ? "px-4" : ""}`}>{children}</div>
    </div>
  );
}

/** A round avatar with a coloured ring — a player "gel". */
export function Gel({
  initial,
  color,
  size = 40,
}: {
  initial: string;
  color: string;
  size?: number;
}) {
  return (
    <div
      className="grid shrink-0 place-items-center rounded-full font-semibold text-black"
      style={{
        width: size,
        height: size,
        background: `linear-gradient(140deg, ${color}, ${color}bb)`,
        boxShadow: `0 0 0 2px rgba(255,255,255,0.08), 0 4px 12px ${color}55`,
        fontSize: size * 0.42,
      }}
    >
      {initial}
    </div>
  );
}

/** The rank "laugh meter" — a filled gradient bar (pink → gold). */
export function LaughMeter({ pct }: { pct: number }) {
  return (
    <div className="h-2.5 w-full overflow-hidden rounded-full bg-white/8">
      <div
        className="h-full rounded-full"
        style={{
          width: `${pct}%`,
          background: "linear-gradient(90deg, var(--primary), var(--reward))",
          boxShadow: "0 0 12px rgba(234,76,109,0.5)",
        }}
      />
    </div>
  );
}

export type TabId = "battle" | "judge" | "mybattles" | "ranks" | "profile";

const TABS: { id: TabId; label: string; icon: ReactNode }[] = [
  {
    id: "battle",
    label: "Battle",
    icon: (
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round">
        <rect x="9" y="3" width="6" height="11" rx="3" />
        <path d="M6 11a6 6 0 0 0 12 0M12 17v4M9 21h6" />
      </svg>
    ),
  },
  {
    id: "judge",
    label: "Judge",
    icon: (
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
        <path d="M12 3v18M5 21h14M7 8l5-3 5 3M4.5 8h5l-2.5 5a2.5 2.5 0 0 1-5 0zM14.5 8h5l-2.5 5a2.5 2.5 0 0 1-5 0z" />
      </svg>
    ),
  },
  {
    id: "mybattles",
    label: "My Battles",
    icon: (
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round">
        <rect x="3" y="6" width="13" height="14" rx="2" />
        <path d="M8 3h11a2 2 0 0 1 2 2v12" opacity="0.5" />
      </svg>
    ),
  },
  {
    id: "ranks",
    label: "Ranks",
    icon: (
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round">
        <path d="M5 21V11M12 21V4M19 21v-7" />
      </svg>
    ),
  },
  {
    id: "profile",
    label: "Profile",
    icon: (
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round">
        <circle cx="12" cy="8" r="3.5" />
        <path d="M5 20a7 7 0 0 1 14 0" />
      </svg>
    ),
  },
];

export function NavBar({ active }: { active: TabId }) {
  return (
    <div className="mt-auto flex items-stretch justify-between border-t border-outline-soft bg-surface px-1.5 pb-2 pt-2">
      {TABS.map((t) => {
        const on = t.id === active;
        return (
          <div
            key={t.id}
            className="flex flex-1 flex-col items-center gap-1"
            style={{ color: on ? "var(--primary)" : "var(--muted)" }}
          >
            <div className="h-[18px] w-[18px]">{t.icon}</div>
            <span className="text-[8.5px] font-bold leading-none">{t.label}</span>
          </div>
        );
      })}
    </div>
  );
}

/** A soft "video feed" backdrop for camera/battle mockups. */
export function FauxVideo({
  hue = "a",
  children,
  className = "",
}: {
  hue?: "a" | "b" | "neutral";
  children?: ReactNode;
  className?: string;
}) {
  const bg =
    hue === "a"
      ? "radial-gradient(80% 70% at 30% 25%, #3a1622, #17121a 70%, #0d0d0f)"
      : hue === "b"
        ? "radial-gradient(80% 70% at 70% 30%, #241640, #16121f 70%, #0d0d0f)"
        : "radial-gradient(80% 70% at 50% 30%, #22222a, #141419 70%, #0d0d0f)";
  return (
    <div className={`relative overflow-hidden ${className}`} style={{ background: bg }}>
      {/* a faint head-and-shoulders silhouette so it reads as "a person on
          camera" rather than an empty black rectangle */}
      <div
        className="absolute left-1/2 top-[26%] h-[16%] w-[26%] -translate-x-1/2 rounded-full opacity-[0.22]"
        style={{ background: "radial-gradient(circle at 50% 40%, #fff, transparent 70%)" }}
      />
      <div
        className="absolute left-1/2 top-[44%] h-[56%] w-[58%] -translate-x-1/2 rounded-[45%_45%_0_0] opacity-[0.16]"
        style={{ background: "radial-gradient(120% 100% at 50% 0%, #fff, transparent 65%)" }}
      />
      {children}
    </div>
  );
}
