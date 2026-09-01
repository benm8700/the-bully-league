import type { ReactNode } from "react";
import { ScreenShell, Gel, LaughMeter, NavBar, FauxVideo } from "./bits";

/* Faithful, on-brand mockups of the app's key screens. Static (no backend)
   and built in the Comedy Night theme rather than using real screenshots,
   so they stay clean and consistent with the site. */

function AppBar({ title = "The Bully League" }: { title?: string }) {
  return (
    <div className="flex items-center justify-between pb-3 pt-3">
      <span className="display text-[19px] leading-none">{title}</span>
      <div className="flex gap-3 text-muted">
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round">
          <path d="M18 8a6 6 0 0 0-12 0c0 7-3 9-3 9h18s-3-2-3-9M13.7 21a2 2 0 0 1-3.4 0" />
        </svg>
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round">
          <circle cx="12" cy="12" r="9" />
          <path d="M9.5 9.5a2.5 2.5 0 1 1 3.5 2.3c-.7.3-1 .8-1 1.7M12 17h.01" />
        </svg>
      </div>
    </div>
  );
}

// -- 1. HOME ---------------------------------------------------------------
export function ScreenHome() {
  return (
    <ScreenShell>
      <AppBar />

      {/* Collectible rank card */}
      <div
        className="rounded-2xl p-[1.5px]"
        style={{ background: "linear-gradient(135deg, var(--primary), var(--secondary) 55%, var(--reward))" }}
      >
        <div className="rounded-[calc(1rem-1px)] bg-surface px-4 py-4">
          <div className="eyebrow text-muted">Your rank</div>
          <div className="mt-1 flex items-end justify-between">
            <span className="display text-[26px]">Average Joe</span>
            <span className="rounded-md bg-white/5 px-2 py-1 text-[11px] font-semibold text-foreground/80">
              2–3 <span className="text-muted">W–L</span>
            </span>
          </div>
          <div className="mt-3">
            <LaughMeter pct={28} />
            <p className="mt-2 text-[11px] leading-snug text-muted">
              Open Micer is a long way off. Go win something.
            </p>
          </div>
        </div>
      </div>

      {/* Sixes and Sevens */}
      <div
        className="mt-3 rounded-2xl border p-4"
        style={{ borderColor: "rgba(232,184,75,0.35)", background: "linear-gradient(160deg, rgba(232,184,75,0.10), rgba(255,255,255,0.02))" }}
      >
        <div className="flex items-center gap-1.5">
          <span className="eyebrow" style={{ color: "var(--reward)" }}>Sixes and Sevens</span>
        </div>
        <p className="mt-1.5 text-[13px] font-semibold leading-snug">
          The nightly tournament — win prestige &amp; prizes
        </p>
        <div className="mt-1 flex items-center gap-2 text-[11px] text-muted">
          <span>6pm–7pm Pacific</span>
          <span
            className="rounded-full px-2 py-0.5 text-[10px] font-bold"
            style={{ background: "rgba(232,184,75,0.16)", color: "var(--reward)" }}
          >
            ⚡ 2x points during the hour
          </span>
        </div>
        <button
          className="mt-3 w-full rounded-xl py-2 text-[13px] font-bold text-black"
          style={{ background: "linear-gradient(180deg, #f4d27a, #e8b84b 60%, #cf9a2e)" }}
        >
          Tonight&apos;s Tournament
        </button>
        <div className="mt-2 flex items-center justify-between rounded-xl bg-white/[0.03] px-3 py-2">
          <span className="text-[11px] text-muted">I&apos;m in tonight</span>
          <span className="relative h-5 w-9 rounded-full" style={{ background: "var(--reward)" }}>
            <span className="absolute right-0.5 top-0.5 h-4 w-4 rounded-full bg-white" />
          </span>
        </div>
      </div>

      {/* Primary CTA */}
      <button
        className="mt-3 w-full rounded-2xl py-3.5 text-[15px] font-bold text-white"
        style={{ background: "var(--primary)", boxShadow: "0 8px 24px rgba(234,76,109,0.35)" }}
      >
        Roast a Stranger
      </button>

      {/* Daily quests */}
      <div className="mt-4">
        <div className="eyebrow text-muted">Today&apos;s quests</div>
        <div className="mt-2 space-y-1.5">
          {[
            ["Judge a battle", "0/1"],
            ["Play 2 battles", "0/2"],
            ["Win a battle", "0/1"],
          ].map(([label, prog]) => (
            <div key={label} className="flex items-center gap-2.5 rounded-xl bg-surface px-3 py-2.5">
              <span className="grid h-4 w-4 place-items-center rounded-full border border-outline text-muted" />
              <span className="flex-1 text-[12px]">{label}</span>
              <span className="text-[11px] font-semibold text-muted tabular-nums">{prog}</span>
            </div>
          ))}
        </div>
      </div>

      <div className="h-3" />
      <NavBar active="battle" />
    </ScreenShell>
  );
}

// -- 2. PRE-MATCH CHECK ----------------------------------------------------
export function ScreenPreMatch() {
  return (
    <ScreenShell>
      <div className="pb-2 pt-3">
        <span className="display text-[19px]">Pre-match check</span>
        <p className="text-[11px] text-muted">Look good before you go live.</p>
      </div>

      <FauxVideo hue="neutral" className="aspect-[3/4] w-full rounded-2xl">
        {/* face-framing oval */}
        <div className="absolute inset-0 grid place-items-center">
          <div
            className="h-[72%] w-[58%] rounded-[50%] border-2 border-dashed"
            style={{ borderColor: "rgba(255,111,144,0.75)" }}
          />
        </div>
        <span className="absolute left-3 top-3 rounded-full bg-black/50 px-2 py-1 text-[10px] font-semibold text-foreground/90">
          Front camera
        </span>
      </FauxVideo>

      {/* mic level */}
      <div className="mt-3">
        <div className="flex items-center justify-between text-[11px] text-muted">
          <span>Mic level</span>
          <span style={{ color: "var(--winner)" }}>Sounds good</span>
        </div>
        <div className="mt-1.5 flex h-6 items-end gap-1">
          {[3, 6, 4, 9, 12, 7, 14, 10, 5, 8, 11, 6, 3, 7, 4].map((h, i) => (
            <div
              key={i}
              className="flex-1 rounded-sm"
              style={{ height: `${h * 1.5}px`, background: i < 10 ? "var(--winner)" : "var(--outline)" }}
            />
          ))}
        </div>
      </div>

      {/* tips */}
      <ul className="mt-3 space-y-1.5">
        {["Make sure you're in a well-lit area", "Hold your device steady", "Keep your face inside the outline"].map((t) => (
          <li key={t} className="flex items-center gap-2 text-[12px] text-foreground/80">
            <span className="grid h-4 w-4 place-items-center rounded-full" style={{ background: "rgba(79,201,138,0.15)", color: "var(--winner)" }}>
              <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round"><path d="M20 6 9 17l-5-5" /></svg>
            </span>
            {t}
          </li>
        ))}
      </ul>

      <button className="mt-4 w-full rounded-2xl py-3.5 text-[15px] font-bold text-white" style={{ background: "var(--primary)", boxShadow: "0 8px 24px rgba(234,76,109,0.35)" }}>
        I&apos;m Ready
      </button>
      <div className="h-4" />
    </ScreenShell>
  );
}

// -- 3. OPPONENT / BIO REVEAL ---------------------------------------------
export function ScreenOpponent() {
  return (
    <ScreenShell>
      <div className="flex items-center justify-between pb-2 pt-3">
        <span className="display text-[19px]">Your opponent</span>
        <span className="rounded-full px-2.5 py-1 text-[11px] font-bold" style={{ background: "rgba(255,59,71,0.14)", color: "var(--live)" }}>
          Starts in 60s
        </span>
      </div>

      <div className="flex items-center gap-3 rounded-2xl bg-surface px-4 py-3">
        <Gel initial="R" color="var(--gel-b)" size={46} />
        <div>
          <div className="text-[15px] font-bold">RoastdePapi</div>
          <div className="text-[11px] text-muted">Door Guy · 41–29</div>
        </div>
      </div>

      <p className="mt-3 text-[13px] font-semibold" style={{ color: "var(--primary-soft)" }}>
        Here&apos;s your ammo. Use it.
      </p>

      {/* their intro video */}
      <FauxVideo hue="b" className="mt-2 aspect-[3/4] w-full rounded-2xl">
        <div className="absolute inset-0 grid place-items-center">
          <span className="grid h-12 w-12 place-items-center rounded-full bg-white/12 backdrop-blur">
            <svg width="20" height="20" viewBox="0 0 24 24" fill="currentColor" className="ml-0.5 text-white"><path d="M8 5v14l11-7z" /></svg>
          </span>
        </div>
        <span className="absolute bottom-3 left-3 rounded-full bg-black/50 px-2 py-1 text-[10px] font-semibold text-foreground/90">
          Their intro · 0:60
        </span>
      </FauxVideo>

      <div className="mt-3 grid grid-cols-2 gap-2">
        {[
          ["Profession", "Substitute teacher"],
          ["Hometown", "Fresno, CA"],
          ["Fun fact", "Still on his learner's permit"],
          ["Pets", "One very judgmental cat"],
        ].map(([k, v]) => (
          <div key={k} className="rounded-xl bg-surface px-3 py-2">
            <div className="text-[9px] uppercase tracking-wide text-muted">{k}</div>
            <div className="text-[11px] leading-tight">{v}</div>
          </div>
        ))}
      </div>

      <button className="mt-4 w-full rounded-2xl py-3.5 text-[15px] font-bold text-white" style={{ background: "var(--primary)", boxShadow: "0 8px 24px rgba(234,76,109,0.35)" }}>
        I&apos;m Ready
      </button>
      <div className="h-4" />
    </ScreenShell>
  );
}

// -- 4. THE BATTLE ---------------------------------------------------------
export function ScreenBattle() {
  return (
    <div className="relative flex min-h-full flex-col">
      {/* opponent full-frame */}
      <FauxVideo hue="b" className="absolute inset-0 h-full w-full" />

      {/* top overlay: round + timer */}
      <div className="relative z-10 flex items-center justify-between px-4 pb-2 pt-9">
        <span className="rounded-full bg-black/45 px-3 py-1 text-[11px] font-bold text-foreground/90 backdrop-blur">
          Round 1 of 3
        </span>
        <span className="flex items-center gap-1.5 rounded-full bg-black/45 px-3 py-1 text-[13px] font-bold tabular-nums backdrop-blur" style={{ color: "var(--live)" }}>
          <span className="h-1.5 w-1.5 rounded-full" style={{ background: "var(--live)" }} />
          0:12
        </span>
      </div>

      {/* warmup banner variant - self-start so it clears the PiP on the right */}
      <div className="relative z-10 ml-4 mt-1.5 inline-flex max-w-[62%] items-center gap-1.5 self-start rounded-lg bg-black/50 px-2.5 py-1.5 text-[10px] font-semibold text-foreground/80 backdrop-blur">
        <span className="h-1.5 w-1.5 shrink-0 rounded-full" style={{ background: "var(--reward)" }} />
        Warmup · both mics open
      </div>

      {/* opponent name + muted tag */}
      <div className="relative z-10 mt-auto flex items-center gap-2 px-4">
        <Gel initial="R" color="var(--gel-b)" size={30} />
        <span className="text-[12px] font-semibold drop-shadow">RoastdePapi</span>
        <span className="ml-auto flex items-center gap-1 rounded-full bg-black/50 px-2 py-1 text-[10px] text-muted">
          <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><path d="M3 3l18 18M9 9v3a3 3 0 0 0 4.5 2.6M12 4a3 3 0 0 1 3 3v2" /></svg>
          muted on your turn
        </span>
      </div>

      {/* your PiP */}
      <div className="absolute right-3 top-16 z-10 h-28 w-20 overflow-hidden rounded-xl ring-1 ring-white/25">
        <FauxVideo hue="a" className="h-full w-full">
          <span className="absolute bottom-1 left-1 rounded bg-black/55 px-1.5 py-0.5 text-[8px] font-semibold">You</span>
        </FauxVideo>
      </div>

      {/* end turn */}
      <div className="relative z-10 px-4 pb-5 pt-3">
        <button className="w-full rounded-2xl py-3.5 text-[15px] font-bold text-white" style={{ background: "var(--primary)", boxShadow: "0 8px 24px rgba(234,76,109,0.4)" }}>
          End My Turn
        </button>
      </div>
    </div>
  );
}

// -- 5. VOTE / JUDGE -------------------------------------------------------
export function ScreenVote() {
  return (
    <ScreenShell>
      <div className="pb-2 pt-3">
        <span className="display text-[19px]">Judge the battle</span>
        <p className="text-[11px] text-muted">The crowd decides. Judging earns points.</p>
      </div>

      {/* clip player: two contestants split */}
      <div className="relative overflow-hidden rounded-2xl">
        <div className="grid aspect-[4/3] grid-cols-2">
          <FauxVideo hue="a" className="h-full w-full">
            <span className="absolute bottom-2 left-2 rounded bg-black/55 px-1.5 py-0.5 text-[9px] font-semibold" style={{ color: "var(--gel-a)" }}>MicDropMandy</span>
          </FauxVideo>
          <FauxVideo hue="b" className="h-full w-full">
            <span className="absolute bottom-2 right-2 rounded bg-black/55 px-1.5 py-0.5 text-[9px] font-semibold" style={{ color: "var(--gel-b)" }}>RoastdePapi</span>
          </FauxVideo>
        </div>
        <div className="absolute left-1/2 top-1/2 -translate-x-1/2 -translate-y-1/2">
          <span className="display grid h-9 w-9 place-items-center rounded-full bg-black/60 text-[13px] backdrop-blur">VS</span>
        </div>
        <div className="absolute left-1/2 top-2 flex -translate-x-1/2 items-center gap-1 rounded-full bg-black/60 px-2.5 py-1 text-[10px] font-semibold backdrop-blur">
          <span className="h-1.5 w-1.5 rounded-full" style={{ background: "var(--live)" }} /> 0:41 left · watch it all
        </div>
      </div>

      <p className="mt-4 text-center text-[15px] font-bold">Who won?</p>
      <div className="mt-2 space-y-2">
        {[
          ["MicDropMandy", "var(--gel-a)", "M"],
          ["RoastdePapi", "var(--gel-b)", "R"],
        ].map(([name, color, ini]) => (
          <button
            key={name}
            className="flex w-full items-center gap-3 rounded-2xl border bg-surface px-3 py-3 text-left"
            style={{ borderColor: `color-mix(in srgb, ${color} 45%, transparent)` }}
          >
            <Gel initial={ini} color={color} size={34} />
            <span className="text-[13px] font-semibold">{name}</span>
            <span className="ml-auto grid h-5 w-5 place-items-center rounded-full border border-outline" />
          </button>
        ))}
      </div>
      <p className="mt-3 text-center text-[10.5px] text-muted">
        Tallies stay hidden until you vote — no following the crowd.
      </p>
      <div className="h-3" />
      <NavBar active="judge" />
    </ScreenShell>
  );
}

// -- 6. SIXES AND SEVENS — THE CLIMB --------------------------------------
export function ScreenSixes() {
  const ladder = [
    ["Champion", "1 left"],
    ["3 wins", "2 left"],
    ["2 wins", "4 left"],
    ["1 win", "7 left"],
    ["0 wins", "12 in"],
  ];
  return (
    <ScreenShell>
      <div className="flex items-center justify-between pb-2 pt-3">
        <span className="display text-[19px]" style={{ color: "var(--reward)" }}>Sixes and Sevens</span>
        <span className="flex items-center gap-1 rounded-full px-2.5 py-1 text-[10px] font-bold" style={{ background: "rgba(255,59,71,0.14)", color: "var(--live)" }}>
          <span className="h-1.5 w-1.5 rounded-full" style={{ background: "var(--live)" }} /> LIVE
        </span>
      </div>

      {/* your standing */}
      <div className="rounded-2xl border p-4" style={{ borderColor: "rgba(232,184,75,0.3)", background: "linear-gradient(160deg, rgba(232,184,75,0.10), transparent)" }}>
        <div className="eyebrow text-muted">You&apos;re in the climb</div>
        <div className="mt-1 flex items-baseline gap-2">
          <span className="display text-[30px]" style={{ color: "var(--reward)" }}>2</span>
          <span className="text-[13px] text-foreground/80">wins in</span>
        </div>
        <div className="mt-3 flex items-center gap-2 text-[12px] text-foreground/80">
          <span className="relative flex h-2.5 w-2.5">
            <span className="absolute inline-flex h-full w-full animate-ping rounded-full opacity-70" style={{ background: "var(--reward)" }} />
            <span className="relative inline-flex h-2.5 w-2.5 rounded-full" style={{ background: "var(--reward)" }} />
          </span>
          Finding your next opponent — 4 climbers left
        </div>
        <p className="mt-2 text-[11px] leading-snug text-muted">
          Win to climb. Lose once and you&apos;re out.
        </p>
      </div>

      {/* ladder */}
      <div className="mt-3 space-y-1.5">
        {ladder.map(([tier, count], i) => {
          const mine = tier === "2 wins";
          return (
            <div
              key={tier}
              className="flex items-center gap-2 rounded-lg px-3 py-2"
              style={{
                background: mine ? "rgba(232,184,75,0.14)" : "var(--surface)",
                border: mine ? "1px solid rgba(232,184,75,0.4)" : "1px solid transparent",
              }}
            >
              <span className="w-4 text-[11px] font-bold tabular-nums text-muted">{ladder.length - i}</span>
              <span className="text-[12px] font-semibold">{tier}</span>
              {mine && <span className="rounded px-1.5 py-0.5 text-[9px] font-bold text-black" style={{ background: "var(--reward)" }}>YOU</span>}
              <span className="ml-auto text-[11px] text-muted">{count}</span>
            </div>
          );
        })}
      </div>

      {/* live now */}
      <div className="mt-4">
        <div className="eyebrow text-muted">Live now — watch &amp; vote</div>
        <div className="mt-2 space-y-1.5">
          {[
            ["MicDropMandy", "vs", "SickBurnSam"],
            ["LaughTrackLuis", "vs", "PunniferLopez"],
          ].map(([a, , b]) => (
            <div key={a} className="flex items-center gap-2 rounded-xl bg-surface px-3 py-2.5">
              <span className="h-1.5 w-1.5 rounded-full" style={{ background: "var(--live)" }} />
              <span className="text-[11px] font-semibold" style={{ color: "var(--gel-a)" }}>{a}</span>
              <span className="text-[10px] text-muted">vs</span>
              <span className="text-[11px] font-semibold" style={{ color: "var(--gel-b)" }}>{b}</span>
              <span className="ml-auto rounded-full px-2 py-0.5 text-[9px] font-bold" style={{ background: "rgba(234,76,109,0.16)", color: "var(--primary-soft)" }}>Watch</span>
            </div>
          ))}
        </div>
      </div>

      <div className="h-3" />
      <NavBar active="mybattles" />
    </ScreenShell>
  );
}

export type DemoScreen = {
  id: string;
  label: string;
  tagline: string;
  render: () => ReactNode;
};

export const DEMO_SCREENS: DemoScreen[] = [
  { id: "home", label: "Home", tagline: "Your rank, your quests, and one button to start.", render: () => <ScreenHome /> },
  { id: "prematch", label: "Pre-match", tagline: "Camera and mic check before you go live.", render: () => <ScreenPreMatch /> },
  { id: "opponent", label: "Opponent", tagline: "Study your opponent. Load up on ammo.", render: () => <ScreenOpponent /> },
  { id: "battle", label: "Battle", tagline: "Three rounds. One mic at a time. No mercy.", render: () => <ScreenBattle /> },
  { id: "vote", label: "Vote", tagline: "The crowd judges every battle.", render: () => <ScreenVote /> },
  { id: "sixes", label: "Sixes & Sevens", tagline: "The nightly tournament climb.", render: () => <ScreenSixes /> },
];
