import Link from "next/link";
import { getTopRoasters } from "@/lib/leaderboard";
import { StoreCta } from "@/components/StoreCta";
import { PhoneFrame } from "@/components/demo/PhoneFrame";
import { ScreenBattle, ScreenSixes } from "@/components/demo/screens";

// Revalidate rather than force-dynamic: this page has no per-request input
// (no cookies/params), so Next would otherwise statically render it once at
// build time - which would silently violate CLAUDE.md's "must auto-update
// dynamically... no manual curation needed" homepage decision. A short
// revalidation window keeps the leaderboard live without hitting Firestore
// on every request during a traffic spike.
export const revalidate = 60;

export default async function Home() {
  const topRoasters = await getTopRoasters();

  return (
    <main className="flex-1">
      <Hero />
      <HowItWorks />
      <SixesAndSevens />
      <Rules />
      <Leaderboard roasters={topRoasters} />
    </main>
  );
}

/* ---------------------------------------------------------------- Hero */
function Hero() {
  return (
    <section className="relative overflow-hidden border-b border-outline-soft">
      <div className="mx-auto grid max-w-6xl items-center gap-10 px-6 py-16 sm:py-24 lg:grid-cols-[1.05fr_0.95fr]">
        <div className="text-center lg:text-left">
          <span className="eyebrow inline-block" style={{ color: "var(--primary-soft)" }}>
            18+ · Live comedy, no mercy
          </span>
          <h1 className="mt-4 text-[clamp(2.6rem,7vw,4.6rem)] leading-[0.98]">
            Get matched.
            <br />
            Get <span style={{ color: "var(--primary)" }}>roasted.</span>
            <br />
            Get even.
          </h1>
          <p className="mx-auto mt-5 max-w-xl text-[15px] leading-relaxed text-muted lg:mx-0">
            The Bully League drops you into a live, timed 1-on-1 roast battle
            with a total stranger. Three rounds. Fifteen seconds a turn. The
            crowd votes the winner — and you climb the ranks or eat the loss.
          </p>
          <div className="mt-8 flex flex-col items-center gap-3 sm:flex-row lg:items-start lg:justify-start">
            <StoreCta />
            <Link
              href="/demo"
              className="inline-flex items-center justify-center gap-2 rounded-full border border-outline px-6 py-3 text-base font-semibold text-foreground transition-colors hover:border-primary hover:text-primary-soft"
            >
              Try the live demo
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M5 12h14M13 6l6 6-6 6" /></svg>
            </Link>
          </div>
          <p className="mt-4 text-xs text-muted lg:pl-1">
            Free to watch and judge. Battles happen in the app.
          </p>
        </div>

        <div className="relative">
          <div
            className="absolute -inset-6 -z-10 rounded-full opacity-70 blur-3xl"
            style={{ background: "radial-gradient(circle, rgba(234,76,109,0.25), transparent 65%)" }}
          />
          <PhoneFrame glow>
            <ScreenBattle />
          </PhoneFrame>
        </div>
      </div>
    </section>
  );
}

/* -------------------------------------------------------- How it works */
function HowItWorks() {
  const steps = [
    ["Get paired", "Tap once and you're matched 1-on-1 with a random stranger who's online right now."],
    ["Study the target", "Watch their 60-second intro and read their card. That's your ammo — use it."],
    ["Battle live", "Three rounds, ~15 seconds a turn. Your turn, your mic; theirs is muted. Then you swap."],
    ["Crowd decides", "The battle goes to the community. Judges have 24 hours to vote. Win, and your rank climbs."],
  ];
  return (
    <section className="mx-auto max-w-6xl px-6 py-20">
      <SectionHead
        eyebrow="How it works"
        title="A real battle, not a group chat"
        sub="Structure, a live opponent, and a verdict that isn't just your friends."
      />
      <ol className="mt-12 grid gap-5 sm:grid-cols-2 lg:grid-cols-4">
        {steps.map(([title, body], n) => (
          <li key={title} className="relative rounded-2xl border border-outline-soft bg-surface p-6">
            <span className="display block text-3xl" style={{ color: "var(--primary)" }}>
              {String(n + 1).padStart(2, "0")}
            </span>
            <h3 className="mt-3 text-lg font-semibold">{title}</h3>
            <p className="mt-2 text-[13px] leading-relaxed text-muted">{body}</p>
          </li>
        ))}
      </ol>
    </section>
  );
}

/* ------------------------------------------------------ Sixes & Sevens */
function SixesAndSevens() {
  return (
    <section className="border-y border-outline-soft" style={{ background: "linear-gradient(180deg, rgba(232,184,75,0.05), transparent)" }}>
      <div className="mx-auto grid max-w-6xl items-center gap-12 px-6 py-20 lg:grid-cols-[0.9fr_1.1fr]">
        <div className="order-2 lg:order-1">
          <PhoneFrame>
            <ScreenSixes />
          </PhoneFrame>
        </div>
        <div className="order-1 lg:order-2">
          <span className="eyebrow inline-block" style={{ color: "var(--reward)" }}>
            The main event
          </span>
          <h2 className="mt-3 text-4xl sm:text-5xl">Sixes and Sevens</h2>
          <p className="mt-4 text-[15px] leading-relaxed text-muted">
            Every night, 6–7pm Pacific, the whole app battles at once. It&apos;s
            the nightly tournament — and the busiest hour of the day, so it&apos;s
            the fastest place to find a fight. Points count double while the
            lights are on.
          </p>
          <div className="mt-6 space-y-3">
            {[
              ["Join anytime in the hour", "No bracket to be late for. Drop in and you start at zero wins."],
              ["Win to climb", "Beat someone on your win-count and you move up a tier."],
              ["Lose once, you're out", "Single elimination. Last comic standing takes the night."],
            ].map(([t, b]) => (
              <div key={t} className="flex gap-3">
                <span className="mt-1 grid h-5 w-5 shrink-0 place-items-center rounded-full" style={{ background: "rgba(232,184,75,0.18)", color: "var(--reward)" }}>
                  <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round"><path d="M20 6 9 17l-5-5" /></svg>
                </span>
                <p className="text-sm leading-snug text-foreground/85">
                  <span className="font-semibold text-foreground">{t}.</span>{" "}
                  <span className="text-muted">{b}</span>
                </p>
              </div>
            ))}
          </div>
          <div className="mt-7">
            <Link
              href="/demo"
              className="inline-flex items-center gap-2 rounded-full px-6 py-3 text-base font-bold text-black"
              style={{ background: "linear-gradient(180deg, #f4d27a, #e8b84b 60%, #cf9a2e)" }}
            >
              Watch the climb
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round"><path d="M5 12h14M13 6l6 6-6 6" /></svg>
            </Link>
          </div>
        </div>
      </div>
    </section>
  );
}

/* -------------------------------------------------------------- Rules */
function Rules() {
  return (
    <section className="mx-auto max-w-6xl px-6 py-20">
      <SectionHead
        eyebrow="The one rule"
        title="Bring the heat. Not the hate."
        sub="This is a comedy platform with a free-speech spine — but comedy is the whole point."
      />
      <div className="mt-10 grid gap-5 md:grid-cols-2">
        <RuleCard
          tone="yes"
          title="This flies"
          items={[
            "Brutal, personal, no-holds-barred roasts",
            "Offensive jokes and savage wordplay",
            "Punching at your opponent — that's the game",
            "Losing with your dignity in pieces",
          ]}
        />
        <RuleCard
          tone="no"
          title="This doesn't"
          items={[
            "Hate or bigotry meant to demean, not amuse",
            "Sustained harassment beyond the battle",
            "Nudity or explicit content (auto-detected)",
            "Anything targeting someone under 18 — it's an 18+ app",
          ]}
        />
      </div>
      <p className="mx-auto mt-8 max-w-2xl text-center text-[13px] text-muted">
        Every battle is recorded and consented to up front. See something over
        the line? Flag it — reports are actioned within 24 hours.
      </p>
    </section>
  );
}

function RuleCard({ tone, title, items }: { tone: "yes" | "no"; title: string; items: string[] }) {
  const color = tone === "yes" ? "var(--winner)" : "var(--live)";
  return (
    <div className="rounded-2xl border border-outline-soft bg-surface p-7">
      <div className="flex items-center gap-2.5">
        <span className="grid h-7 w-7 place-items-center rounded-full" style={{ background: `color-mix(in srgb, ${color} 18%, transparent)`, color }}>
          {tone === "yes" ? (
            <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round"><path d="M20 6 9 17l-5-5" /></svg>
          ) : (
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round"><path d="M6 6l12 12M18 6 6 18" /></svg>
          )}
        </span>
        <h3 className="display text-xl">{title}</h3>
      </div>
      <ul className="mt-4 space-y-2.5">
        {items.map((it) => (
          <li key={it} className="flex gap-2.5 text-sm text-foreground/85">
            <span className="mt-2 h-1.5 w-1.5 shrink-0 rounded-full" style={{ background: color }} />
            {it}
          </li>
        ))}
      </ul>
    </div>
  );
}

/* -------------------------------------------------------- Leaderboard */
function Leaderboard({ roasters }: { roasters: { id: string; username: string; rating: number; rankTitle: string }[] }) {
  return (
    <section className="border-t border-outline-soft bg-surface/40">
      <div className="mx-auto max-w-3xl px-6 py-20">
        <SectionHead
          eyebrow="Live standings"
          title="Top 5 roasters"
          sub="The best in the League right now. It updates itself."
        />
        <div className="mt-10">
          {roasters.length === 0 ? (
            <p className="text-center text-muted">No roasters yet. Be the first.</p>
          ) : (
            <ol className="space-y-2.5">
              {roasters.map((r, index) => {
                const goat = index === 0;
                return (
                  <li
                    key={r.id}
                    className="flex items-center gap-4 rounded-2xl border px-5 py-4"
                    style={{
                      borderColor: goat ? "rgba(232,184,75,0.4)" : "var(--outline-soft)",
                      background: goat ? "linear-gradient(100deg, rgba(232,184,75,0.10), transparent)" : "var(--surface)",
                    }}
                  >
                    <span
                      className="display grid h-9 w-9 shrink-0 place-items-center rounded-full text-lg"
                      style={{
                        color: goat ? "#000" : "var(--foreground)",
                        background: goat ? "var(--reward)" : "var(--surface-3)",
                      }}
                    >
                      {index + 1}
                    </span>
                    <div className="flex min-w-0 flex-1 flex-col">
                      <span className="truncate font-semibold">
                        {r.username}
                        {goat && <span className="ml-1.5" aria-label="GOAT" title="GOAT">🐐</span>}
                      </span>
                      <span className="text-xs text-muted">{r.rankTitle}</span>
                    </div>
                    <span className="tabular-nums text-sm text-foreground/70">{r.rating}</span>
                  </li>
                );
              })}
            </ol>
          )}
        </div>
        <div className="mt-10 flex flex-col items-center gap-4 text-center">
          <StoreCta />
        </div>
      </div>
    </section>
  );
}

/* ---------------------------------------------------------- shared bits */
function SectionHead({ eyebrow, title, sub }: { eyebrow: string; title: string; sub: string }) {
  return (
    <div className="mx-auto max-w-2xl text-center">
      <span className="eyebrow inline-block text-muted">{eyebrow}</span>
      <h2 className="mt-2 text-4xl sm:text-[2.75rem]">{title}</h2>
      <p className="mt-3 text-[15px] leading-relaxed text-muted">{sub}</p>
    </div>
  );
}
