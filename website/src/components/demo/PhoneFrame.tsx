import type { ReactNode } from "react";

/**
 * A realistic phone device frame that holds one app "screen" at a time.
 * Presentational only (no hooks) so it renders in both the server-rendered
 * homepage hero and the client-side interactive demo.
 *
 * The inner screen is a fixed 9:19.5 aspect box; content that overflows
 * scrolls inside it, exactly like the real app's scrolling Home.
 */
export function PhoneFrame({
  children,
  glow = false,
  className = "",
}: {
  children: ReactNode;
  glow?: boolean;
  className?: string;
}) {
  return (
    <div
      className={`relative mx-auto w-full max-w-[300px] ${className}`}
      style={
        glow
          ? { filter: "drop-shadow(0 30px 60px rgba(234,76,109,0.28))" }
          : { filter: "drop-shadow(0 24px 44px rgba(0,0,0,0.55))" }
      }
    >
      {/* bezel */}
      <div className="rounded-[2.6rem] bg-black p-[3px] ring-1 ring-white/10">
        <div className="rounded-[2.45rem] border border-white/5 bg-black p-2">
          {/* screen */}
          <div className="relative overflow-hidden rounded-[1.9rem] bg-ink">
            <div className="aspect-[9/19.5] w-full overflow-y-auto overflow-x-hidden [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
              {children}
            </div>
            {/* notch / camera pill */}
            <div className="pointer-events-none absolute left-1/2 top-2 h-5 w-24 -translate-x-1/2 rounded-full bg-black" />
          </div>
        </div>
      </div>
    </div>
  );
}

/** The device status bar that sits at the top of every screen. */
export function StatusBar({ time = "6:07" }: { time?: string }) {
  return (
    <div className="flex items-center justify-between px-5 pb-1 pt-2.5 text-[11px] font-semibold text-foreground/85">
      <span className="tabular-nums">{time}</span>
      <div className="flex items-center gap-1.5">
        {/* signal */}
        <svg width="16" height="11" viewBox="0 0 16 11" fill="currentColor" aria-hidden>
          <rect x="0" y="7" width="3" height="4" rx="1" />
          <rect x="4.5" y="5" width="3" height="6" rx="1" />
          <rect x="9" y="2.5" width="3" height="8.5" rx="1" />
          <rect x="13.5" y="0" width="3" height="11" rx="1" opacity="0.4" />
        </svg>
        {/* battery */}
        <svg width="22" height="11" viewBox="0 0 22 11" fill="none" aria-hidden>
          <rect x="0.5" y="0.5" width="18" height="10" rx="2.5" stroke="currentColor" opacity="0.5" />
          <rect x="2" y="2" width="13" height="7" rx="1.5" fill="currentColor" />
          <rect x="20" y="3.5" width="1.5" height="4" rx="0.75" fill="currentColor" opacity="0.5" />
        </svg>
      </div>
    </div>
  );
}
