"use client";

import { useAuth } from "@/lib/AuthProvider";
import { functions } from "@/lib/firebaseClient";
import { httpsCallable } from "firebase/functions";
import { useCallback, useEffect, useRef, useState } from "react";
import type { User } from "firebase/auth";
import Link from "next/link";

// The admin command center. Client page: it sends the signed-in user's Firebase
// ID token to admin-only Route Handlers, which verify the token + isAdmin
// server-side before reading metrics or performing actions. Nothing here is a
// security boundary - the routes are. See src/lib/firebaseAdmin.ts (verifyAdmin).

type Metrics = {
  generatedAt: number;
  users: { total: number | null; subscribers: number | null; banned: number | null; flagged: number | null };
  online: { total: number | null; committedTonight: number | null };
  health: { online: boolean; lastBeatMs: number | null; upSinceMs: number | null };
  signups: { last24h: number | null; last7d: number | null };
  battles: { last24h: number | null; last7d: number | null; total: number | null; publishedClips: number | null };
  votes: { last24h: number | null };
  moderation: { reportsPending: number | null; supportOpen: number | null; banAppeals: number | null };
  config: { tournamentEnabled: boolean; monetizationEnabled: boolean };
  queues: {
    reports: QueueItem[];
    support: QueueItem[];
    appeals: QueueItem[];
  };
  prizes: PrizeItem[];
  recentBattles: BattleItem[];
  handled: { reports: HandledItem[]; support: HandledItem[]; appeals: HandledItem[] };
  postStudio: { candidates: PostClip[]; posted: PostClip[]; dismissed: PostClip[]; morningPick: PostClip | null };
};

type BattleItem = {
  id: string;
  player1Name: string;
  player2Name: string;
  completedAtMs: number | null;
  featured: boolean;
  rendered: boolean;
  hasClip: boolean;
  clipUrl: string | null;
};

type PostClip = {
  id: string;
  player1Name: string;
  player2Name: string;
  completedAtMs: number | null;
  rendered: boolean;
  published: boolean;
  votes: number;
  positiveEmoji: number;
  score: number;
  consent: "ok" | "blur" | "out";
  blurReady: boolean;
  status: "candidate" | "posted" | "dismissed";
  platforms: { tiktok: boolean; instagram: boolean; youtube: boolean } | null;
  actedAtMs: number | null;
};

type HandledItem = {
  id: string;
  collection: string;
  label: string;
  status: string;
  reviewedAtMs: number | null;
};

type PrizeItem = {
  id: string;
  prize: string | null;
  prizeType: string | null;
  winnerUid: string | null;
  winnerUsername: string | null;
  status: string;
  wonAtMs: number | null;
  shipping: { name?: string; address?: string; phone?: string } | null;
};

type QueueItem = {
  id: string;
  reason?: string;
  category?: string;
  detail?: string;
  reportedUserId?: string;
  createdAt?: number | null;
  diagnostics?: Record<string, unknown> | null;
};

type FoundUser = {
  uid: string;
  username: string | null;
  rankTitle: string | null;
  rating: number | null;
  points: number | null;
  pointsBalance: number | null;
  wins: number | null;
  losses: number | null;
  accountStatus: string;
  isAdmin: boolean;
  subscription: { active: boolean; expiresAtMs: number | null; source: string | null };
  createdAtMs: number | null;
};

async function authed(user: User, path: string, init?: RequestInit) {
  const token = await user.getIdToken();
  return fetch(path, {
    ...init,
    // Admin data must never be stale - after an action the UI re-fetches to
    // reflect it, and a cached GET would make the change look like it failed.
    cache: "no-store",
    headers: {
      ...(init?.headers ?? {}),
      Authorization: `Bearer ${token}`,
      ...(init?.body ? { "Content-Type": "application/json" } : {}),
    },
  });
}

const fmt = (n: number | null | undefined) =>
  n === null || n === undefined ? "—" : n.toLocaleString();

export default function AdminPage() {
  const { user, loading } = useAuth();
  const [gate, setGate] = useState<"checking" | "anon" | "notadmin" | "admin">(
    "checking",
  );
  const [metrics, setMetrics] = useState<Metrics | null>(null);
  const [note, setNote] = useState<string>("");
  // Guards against an action firing again while one is in flight (double-clicks
  // when the result isn't instantly visible) - which could double-post/grant.
  // `busy` is the reactive mirror used to grey out the buttons.
  const inFlight = useRef(false);
  const [busy, setBusy] = useState(false);
  const [nowTick, setNowTick] = useState(() => Date.now());

  const loadMetrics = useCallback(async () => {
    if (!user) return;
    const res = await authed(user, "/api/admin/metrics");
    if (res.ok) setMetrics(await res.json());
    else setNote(`Metrics error: ${res.status}`);
  }, [user]);

  useEffect(() => {
    if (loading) return;
    if (!user) {
      setGate("anon");
      return;
    }
    (async () => {
      const res = await authed(user, "/api/admin/me");
      const data = await res.json();
      if (data.admin) {
        setGate("admin");
        loadMetrics();
      } else {
        setGate("notadmin");
      }
    })();
  }, [user, loading, loadMetrics]);

  // Keep the status bar live: tick a clock every second (for the uptime
  // duration) and refresh metrics every 60s (so ONLINE/OFFLINE stays current).
  useEffect(() => {
    const t = setInterval(() => setNowTick(Date.now()), 1000);
    return () => clearInterval(t);
  }, []);
  useEffect(() => {
    if (gate !== "admin") return;
    const t = setInterval(() => loadMetrics(), 60000);
    return () => clearInterval(t);
  }, [gate, loadMetrics]);

  const act = useCallback(
    async (payload: Record<string, unknown>, label: string) => {
      if (!user || inFlight.current) return;
      inFlight.current = true;
      setBusy(true);
      setNote(`${label}…`);
      try {
        const res = await authed(user, "/api/admin/action", {
          method: "POST",
          body: JSON.stringify(payload),
        });
        const data = await res.json().catch(() => ({}));
        setNote(res.ok ? `${label}: done` : `${label}: ${data.error ?? res.status}`);
        await loadMetrics();
      } finally {
        inFlight.current = false;
        setBusy(false);
      }
    },
    [user, loadMetrics],
  );

  // Calls a Firebase callable (Editor's Choice feature/publish) as the signed-in
  // admin - the callable enforces requireAdmin and reuses the real publish gate.
  const callFn = useCallback(
    async (name: string, data: Record<string, unknown>, label: string) => {
      if (!user || inFlight.current) return;
      inFlight.current = true;
      setBusy(true);
      setNote(`${label}…`);
      try {
        const res = await httpsCallable(functions, name)(data);
        const d = (res.data ?? {}) as Record<string, unknown>;
        setNote(d.note ? `${label}: done — ${d.note}` : `${label}: done`);
      } catch (e) {
        setNote(`${label}: ${(e as Error).message}`);
      } finally {
        await loadMetrics();
        inFlight.current = false;
        setBusy(false);
      }
    },
    [user, loadMetrics],
  );

  if (gate === "checking" || loading) {
    return <Shell><p className="text-zinc-400">Checking access…</p></Shell>;
  }
  if (gate === "anon") {
    return (
      <Shell>
        <p className="text-zinc-300">
          Sign in as an admin to view the command center.{" "}
          <Link href="/login?next=/admin" className="text-amber-400 underline">Sign in</Link>
        </p>
      </Shell>
    );
  }
  if (gate === "notadmin") {
    return <Shell><p className="text-zinc-300">This account is not an admin.</p></Shell>;
  }

  return (
    <Shell>
      <div className="mb-6 flex items-center justify-between gap-4">
        <div>
          <h1 className="text-2xl font-bold text-white">Command Center</h1>
          {metrics && (
            <p className="text-xs text-zinc-500">
              Updated {new Date(metrics.generatedAt).toLocaleTimeString()}
            </p>
          )}
        </div>
        <button
          onClick={loadMetrics}
          className="rounded bg-zinc-800 px-3 py-1.5 text-sm text-zinc-200 hover:bg-zinc-700"
        >
          Refresh
        </button>
      </div>

      {metrics && <StatusBar health={metrics.health} now={nowTick} />}

      {note && (
        <div className="mb-4 rounded border border-amber-500/40 bg-amber-500/10 px-3 py-2 text-sm text-amber-200">
          {note}
        </div>
      )}

      {!metrics ? (
        <p className="text-zinc-400">Loading metrics…</p>
      ) : (
        <>
          <Section title="Live">
            <Stat label="Online now" value={fmt(metrics.online.total)} />
            <Stat label="In tonight" value={fmt(metrics.online.committedTonight)} />
            <Stat label="Battles (24h)" value={fmt(metrics.battles.last24h)} />
            <Stat label="Votes (24h)" value={fmt(metrics.votes.last24h)} />
          </Section>

          <Section title="Users">
            <Stat label="Total users" value={fmt(metrics.users.total)} />
            <Stat label="Subscribers" value={fmt(metrics.users.subscribers)} />
            <Stat label="Signups (24h)" value={fmt(metrics.signups.last24h)} />
            <Stat label="Signups (7d)" value={fmt(metrics.signups.last7d)} />
            <Stat label="Banned" value={fmt(metrics.users.banned)} />
            <Stat label="Flagged" value={fmt(metrics.users.flagged)} />
          </Section>

          <Section title="Content">
            <Stat label="Battles (7d)" value={fmt(metrics.battles.last7d)} />
            <Stat label="Battles (all time)" value={fmt(metrics.battles.total)} />
            <Stat label="Published clips" value={fmt(metrics.battles.publishedClips)} />
          </Section>

          <Section title="Moderation queue">
            <Stat label="Reports pending" value={fmt(metrics.moderation.reportsPending)} alert={!!metrics.moderation.reportsPending} />
            <Stat label="Support open" value={fmt(metrics.moderation.supportOpen)} alert={!!metrics.moderation.supportOpen} />
            <Stat label="Ban appeals" value={fmt(metrics.moderation.banAppeals)} alert={!!metrics.moderation.banAppeals} />
          </Section>

          <div className="mb-8">
            <h2 className="mb-2 text-sm font-semibold uppercase tracking-wide text-zinc-400">Switches</h2>
            <div className="flex flex-wrap gap-3">
              <Toggle
                label="Tournament system"
                on={metrics.config.tournamentEnabled}
                onClick={() => { const on = !metrics.config.tournamentEnabled; if (confirm(`Turn the tournament system ${on ? "ON" : "OFF"} for all users?`)) act({ type: "setConfigFlag", doc: "tournament", enabled: on }, "Tournament flag"); }}
              />
              <Toggle
                label="Monetization"
                on={metrics.config.monetizationEnabled}
                onClick={() => { const on = !metrics.config.monetizationEnabled; if (confirm(`Turn monetization ${on ? "ON" : "OFF"} for all users?`)) act({ type: "setConfigFlag", doc: "monetization", enabled: on }, "Monetization flag"); }}
              />
            </div>
          </div>

          <PostStudio metrics={metrics} callFn={callFn} act={act} busy={busy} />
          <EditorsChoice metrics={metrics} callFn={callFn} busy={busy} />
          <Prizes metrics={metrics} act={act} />
          <Queues metrics={metrics} act={act} busy={busy} />
          <UserSearch user={user!} act={act} />
        </>
      )}
    </Shell>
  );
}

function fmtDuration(ms: number): string {
  let s = Math.floor((Number.isFinite(ms) && ms > 0 ? ms : 0) / 1000);
  const d = Math.floor(s / 86400); s -= d * 86400;
  const h = Math.floor(s / 3600); s -= h * 3600;
  const m = Math.floor(s / 60); s -= m * 60;
  if (d > 0) return `${d}d ${h}h ${m}m`;
  if (h > 0) return `${h}h ${m}m`;
  if (m > 0) return `${m}m ${s}s`;
  return `${s}s`;
}

// The big, unmissable backend ONLINE/OFFLINE banner. Driven by the once-a-minute
// presence heartbeat (see functions/presence.js): fresh beat = up, stale = down.
function StatusBar({ health, now }: { health: Metrics["health"]; now: number }) {
  const online = health.online;
  const sinceMs = online ? health.upSinceMs : health.lastBeatMs;
  const dur = sinceMs ? fmtDuration(now - sinceMs) : null;
  return (
    <div className={`mb-6 flex flex-wrap items-center gap-3 rounded-lg border px-4 py-3 ${online ? "border-green-500/60 bg-green-500/15" : "border-red-500/60 bg-red-500/15"}`}>
      <span className={`inline-block h-3.5 w-3.5 rounded-full ${online ? "bg-green-400 animate-pulse" : "bg-red-500"}`} />
      <span className={`text-lg font-extrabold tracking-wide ${online ? "text-green-300" : "text-red-300"}`}>
        {online ? "APP ONLINE" : "APP OFFLINE"}
      </span>
      {dur && (
        <span className="text-sm text-zinc-200">{online ? `up for ${dur}` : `down for ${dur}`}</span>
      )}
      {!online && (
        <span className="ml-auto text-xs text-red-200/80">backend heartbeat is stale — scheduled jobs may be down</span>
      )}
    </div>
  );
}

function Shell({ children }: { children: React.ReactNode }) {
  return (
    <main className="mx-auto min-h-screen max-w-5xl px-4 py-10">{children}</main>
  );
}

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div className="mb-8">
      <h2 className="mb-2 text-sm font-semibold uppercase tracking-wide text-zinc-400">{title}</h2>
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-6">{children}</div>
    </div>
  );
}

function Stat({ label, value, alert }: { label: string; value: string; alert?: boolean }) {
  return (
    <div className={`rounded-lg border px-3 py-3 ${alert ? "border-amber-500/50 bg-amber-500/10" : "border-zinc-800 bg-zinc-900/60"}`}>
      <div className={`text-xl font-bold ${alert ? "text-amber-300" : "text-white"}`}>{value}</div>
      <div className="text-xs text-zinc-500">{label}</div>
    </div>
  );
}

function Toggle({ label, on, onClick }: { label: string; on: boolean; onClick: () => void }) {
  return (
    <button
      onClick={onClick}
      className={`rounded-lg border px-4 py-2 text-sm font-medium ${on ? "border-green-500/50 bg-green-500/15 text-green-300" : "border-zinc-700 bg-zinc-900 text-zinc-400"}`}
    >
      {label}: {on ? "ON" : "OFF"} <span className="ml-1 text-xs opacity-70">(tap to {on ? "disable" : "enable"})</span>
    </button>
  );
}

function prizeAge(wonAtMs: number | null): string {
  if (!wonAtMs) return "date unknown";
  const d = new Date(wonAtMs);
  const days = Math.floor((Date.now() - wonAtMs) / 86400000);
  const ago = days <= 0 ? "today" : days === 1 ? "1 day ago" : `${days} days ago`;
  return `won ${d.toLocaleDateString()} · ${ago}`;
}

// Ready-to-paste captions per platform, with the matchup filled in. Edit after
// pasting - these are a fast start, not a straitjacket. (When real API posting
// lands, these become the auto-filled caption; for now the founder copies one.)
function captionsFor(c: PostClip): { label: string; text: string }[] {
  const vs = `${c.player1Name} vs ${c.player2Name}`;
  return [
    {
      label: "TikTok",
      text:
        `${vs} 😳 Two strangers, 15 seconds each to roast — the crowd picks the winner. Who took it? 👇\n` +
        `🎤 Roast a stranger on The Bully League\n` +
        `#roastbattle #roast #comedy #standupcomedy #fyp #foryou #thebullyleague`,
    },
    {
      label: "Instagram",
      text:
        `${vs} 😳 Two strangers, 15 seconds each — the crowd decides who won. 👇\n` +
        `🎤 The Bully League\n` +
        `#roastbattle #roast #comedy #comedyreels #standup #reels #explorepage #thebullyleague`,
    },
    {
      label: "YouTube",
      text:
        `${vs} — Roast Battle 🎤 | The Bully League\n` +
        `Two strangers get 15 seconds each to roast. The crowd picks the winner.\n` +
        `#Shorts #roastbattle #roast #comedy #standup`,
    },
  ];
}

function PostStudio({ metrics, callFn, act, busy }: { metrics: Metrics; callFn: (name: string, data: Record<string, unknown>, label: string) => void; act: (p: Record<string, unknown>, l: string) => void; busy: boolean }) {
  const ps = metrics.postStudio ?? { candidates: [], posted: [], dismissed: [], morningPick: null };
  const [preview, setPreview] = useState<{ id: string; url: string } | null>(null);
  const [loadingClip, setLoadingClip] = useState<string | null>(null);
  const [plat, setPlat] = useState<Record<string, { tiktok: boolean; instagram: boolean; youtube: boolean }>>({});
  const [showPosted, setShowPosted] = useState(false);
  const [showAside, setShowAside] = useState(false);
  const [capsOpen, setCapsOpen] = useState<string | null>(null);
  const [copied, setCopied] = useState<string | null>(null);

  async function getClipUrl(id: string, blurred: boolean): Promise<string | null> {
    try {
      const res = await httpsCallable(functions, "previewClip")({ matchId: id, blurred });
      const d = (res.data ?? {}) as { landscape?: string | null; vertical?: string | null };
      return d.vertical ?? d.landscape ?? null; // vertical = the TikTok/Reels cut
    } catch {
      return null;
    }
  }
  async function togglePreview(c: PostClip) {
    if (preview?.id === c.id) { setPreview(null); return; }
    setLoadingClip(c.id);
    const url = await getClipUrl(c.id, c.consent === "blur");
    setLoadingClip(null);
    if (url) setPreview({ id: c.id, url });
  }
  async function download(c: PostClip) {
    setLoadingClip(c.id);
    const url = await getClipUrl(c.id, c.consent === "blur");
    setLoadingClip(null);
    if (url) window.open(url, "_blank");
  }
  const platOf = (id: string) => plat[id] ?? { tiktok: false, instagram: false, youtube: false };
  const togglePlat = (id: string, key: "tiktok" | "instagram" | "youtube") =>
    setPlat((s) => ({ ...s, [id]: { ...platOf(id), [key]: !platOf(id)[key] } }));

  const PLATFORMS: { key: "tiktok" | "instagram" | "youtube"; label: string }[] = [
    { key: "tiktok", label: "TikTok" },
    { key: "instagram", label: "IG" },
    { key: "youtube", label: "YT" },
  ];

  // The morning pick is shown in its own section up top, so keep it out of the
  // ranked list below (no double-render).
  const candidatesToShow = ps.candidates.filter((c) => c.id !== ps.morningPick?.id);

  const renderClip = (c: PostClip, rank: number | null) => (
    <div key={c.id} className="rounded-lg border border-zinc-800 bg-zinc-900/60 p-3 text-sm">
      <div className="flex flex-wrap items-center gap-2">
        {rank !== null && (
          <span className="grid h-6 w-6 shrink-0 place-items-center rounded-full bg-zinc-800 text-xs font-bold text-zinc-300">{rank}</span>
        )}
        <span className="font-semibold text-white">{c.player1Name} vs {c.player2Name}</span>
        <span className="rounded bg-zinc-800 px-1.5 py-0.5 text-xs text-zinc-300" title="postability score">★ {c.score}</span>
        <span className="rounded bg-zinc-800/60 px-1.5 py-0.5 text-xs text-zinc-400">👍 {c.votes}</span>
        <span className="rounded bg-orange-500/15 px-1.5 py-0.5 text-xs text-orange-300">🔥 {c.positiveEmoji}</span>
        {c.published ? (
          <span className="rounded bg-green-500/15 px-1.5 py-0.5 text-xs text-green-300">on site</span>
        ) : (
          <span className="rounded bg-sky-500/15 px-1.5 py-0.5 text-xs text-sky-300">reel ready</span>
        )}
        {c.consent === "blur" && (
          <span title="A battler opted to blur their face — post the BLURRED cut" className="rounded bg-amber-500/15 px-1.5 py-0.5 text-xs text-amber-300">👤 face blurred{c.blurReady ? "" : " · prep needed"}</span>
        )}
        {c.consent === "out" && (
          <span title="A battler pulled this clip entirely — don't post it" className="rounded bg-red-500/15 px-1.5 py-0.5 text-xs text-red-300">🚫 pulled</span>
        )}
        <span className="font-mono text-xs text-zinc-600">#{c.id.slice(-6)}</span>
        <div className="ml-auto flex flex-wrap items-center gap-2">
          {c.consent === "blur" && !c.blurReady ? (
            <button disabled={busy} onClick={() => callFn("renderBlurredClip", { matchId: c.id }, "Rendering the blurred cut - give it a minute")} className="rounded bg-amber-600/80 px-2 py-1 text-xs text-white hover:bg-amber-600 disabled:opacity-50">
              Prepare blurred cut
            </button>
          ) : (
            <>
              <button onClick={() => togglePreview(c)} disabled={loadingClip === c.id} className="rounded border border-zinc-700 px-2 py-1 text-xs text-zinc-200 hover:bg-zinc-800 disabled:opacity-50">
                {loadingClip === c.id ? "…" : preview?.id === c.id ? "Hide" : "▶ Preview"}
              </button>
              <button onClick={() => download(c)} disabled={loadingClip === c.id} className="rounded border border-zinc-700 px-2 py-1 text-xs text-zinc-200 hover:bg-zinc-800 disabled:opacity-50">
                ⬇ Clip{c.consent === "blur" ? " (blurred)" : ""}
              </button>
            </>
          )}
          {c.consent === "ok" && !c.published && c.rendered && (
            <button disabled={busy} onClick={() => callFn("publishBattle", { matchId: c.id, published: true }, "Published")} className="rounded bg-green-600/80 px-2 py-1 text-xs text-white hover:bg-green-600 disabled:opacity-50">
              Publish to site
            </button>
          )}
        </div>
      </div>

      <div className="mt-2 flex flex-wrap items-center gap-2">
        <span className="text-xs text-zinc-500">Posted to:</span>
        {PLATFORMS.map((p) => {
          const on = platOf(c.id)[p.key];
          return (
            <button key={p.key} onClick={() => togglePlat(c.id, p.key)} className={`rounded border px-2 py-0.5 text-xs ${on ? "border-pink-500/60 bg-pink-500/15 text-pink-200" : "border-zinc-700 text-zinc-400 hover:bg-zinc-800"}`}>
              {on ? "✓ " : ""}{p.label}
            </button>
          );
        })}
        <button disabled={busy} onClick={() => {
          if (c.consent === "out" && !confirm("A battler PULLED this clip entirely. Posting it is against their wishes. Mark posted anyway?")) return;
          act({ type: "markClipPosted", matchId: c.id, platforms: platOf(c.id) }, "Marked posted");
        }} className="rounded bg-pink-600/80 px-2 py-1 text-xs text-white hover:bg-pink-600 disabled:opacity-50">
          Mark posted
        </button>
        <button disabled={busy} onClick={() => act({ type: "setAsideClip", matchId: c.id }, "Set aside")} className="rounded border border-zinc-700 px-2 py-1 text-xs text-zinc-400 hover:bg-zinc-800 disabled:opacity-50">
          Set aside
        </button>
      </div>

      <div className="mt-2">
        <button onClick={() => setCapsOpen(capsOpen === c.id ? null : c.id)} className="text-xs text-zinc-400 hover:text-zinc-200">
          📋 Captions {capsOpen === c.id ? "▴" : "▾"}
        </button>
        {capsOpen === c.id && (
          <div className="mt-2 space-y-2">
            {captionsFor(c).map((cap) => (
              <div key={cap.label} className="rounded border border-zinc-800 bg-zinc-950/60 p-2">
                <div className="mb-1 flex items-center justify-between">
                  <span className="text-xs font-semibold text-zinc-300">{cap.label}</span>
                  <button onClick={() => { navigator.clipboard?.writeText(cap.text); setCopied(cap.label + c.id); setTimeout(() => setCopied((v) => (v === cap.label + c.id ? null : v)), 1500); }} className="rounded border border-zinc-700 px-2 py-0.5 text-xs text-zinc-200 hover:bg-zinc-800">
                    {copied === cap.label + c.id ? "✓ Copied" : "Copy"}
                  </button>
                </div>
                <pre className="whitespace-pre-wrap break-words font-sans text-xs text-zinc-400">{cap.text}</pre>
              </div>
            ))}
          </div>
        )}
      </div>

      {preview?.id === c.id && (
        <div className="mt-3">
          <video key={preview.url} src={preview.url} controls autoPlay className="block max-h-[70vh] rounded border border-zinc-800 bg-black" />
        </div>
      )}
    </div>
  );

  return (
    <div className="mb-8">
      <h2 className="mb-2 text-sm font-semibold uppercase tracking-wide text-zinc-400">
        Post Studio <span className="text-zinc-500">({ps.candidates.length} to review)</span>
      </h2>
      <p className="mb-3 text-xs text-zinc-600">
        The best finalized clips, ranked by <span className="text-zinc-400">votes + 🔥/🧠 received</span>, best first.
        For each: <span className="text-zinc-400">⬇ download the vertical cut, upload it to your socials, tick where it went, and Mark posted.</span>{" "}
        (True one-click auto-posting to TikTok/IG/YT needs those platform apps connected — once they are, it drops onto this same button.)
        Posted and set-aside clips move to the archives below.
      </p>

      {ps.morningPick && (
        <div className="mb-4 rounded-lg border border-amber-500/40 bg-amber-500/[0.06] p-3">
          <div className="mb-2 flex items-center gap-2">
            <span className="text-sm font-bold text-amber-300">🌅 Last night’s top roast</span>
            <span className="text-xs text-amber-200/70">— the daily one to post</span>
          </div>
          {renderClip(ps.morningPick, null)}
        </div>
      )}

      {candidatesToShow.length === 0 ? (
        <p className="text-xs text-zinc-600">
          {ps.morningPick
            ? "That’s the lot for now — more land here as battles are judged and render."
            : "No clips ready to post yet — they appear here once a battle is judged and its reel has rendered."}
        </p>
      ) : (
        <div className="space-y-2">
          {candidatesToShow.map((c, i) => renderClip(c, i + 1))}
        </div>
      )}

      {/* archives */}
      <div className="mt-4 space-y-2">
        <ArchiveBlock title="Posted" count={ps.posted.length} open={showPosted} onToggle={() => setShowPosted((v) => !v)}>
          {ps.posted.map((c) => (
            <ArchiveRow key={c.id} clip={c} accent="pink" busy={busy} onRestore={() => act({ type: "restoreClip", matchId: c.id }, "Back to queue")} />
          ))}
        </ArchiveBlock>
        <ArchiveBlock title="Set aside" count={ps.dismissed.length} open={showAside} onToggle={() => setShowAside((v) => !v)}>
          {ps.dismissed.map((c) => (
            <ArchiveRow key={c.id} clip={c} accent="zinc" busy={busy} onRestore={() => act({ type: "restoreClip", matchId: c.id }, "Back to queue")} />
          ))}
        </ArchiveBlock>
      </div>
    </div>
  );
}

function ArchiveBlock({ title, count, open, onToggle, children }: { title: string; count: number; open: boolean; onToggle: () => void; children: React.ReactNode }) {
  return (
    <div className="rounded-lg border border-zinc-800 bg-zinc-900/40">
      <button onClick={onToggle} className="flex w-full items-center gap-2 px-3 py-2 text-left text-xs font-semibold uppercase tracking-wide text-zinc-400 hover:text-zinc-200">
        <span>{open ? "▾" : "▸"}</span>
        {title} <span className="text-zinc-600">({count})</span>
      </button>
      {open && (
        <div className="space-y-1.5 px-3 pb-3">
          {count === 0 ? <p className="text-xs text-zinc-600">Nothing here.</p> : children}
        </div>
      )}
    </div>
  );
}

function ArchiveRow({ clip, accent, busy, onRestore }: { clip: PostClip; accent: "pink" | "zinc"; busy: boolean; onRestore: () => void }) {
  const plats = clip.platforms
    ? (["tiktok", "instagram", "youtube"] as const).filter((k) => clip.platforms![k])
    : [];
  return (
    <div className="flex flex-wrap items-center gap-2 rounded border border-zinc-800 bg-black/20 px-2.5 py-1.5 text-xs">
      <span className="font-medium text-zinc-200">{clip.player1Name} vs {clip.player2Name}</span>
      {accent === "pink" && plats.length > 0 && (
        <span className="text-pink-300">{plats.map((p) => (p === "tiktok" ? "TikTok" : p === "instagram" ? "IG" : "YT")).join(" · ")}</span>
      )}
      {accent === "pink" && clip.consent !== "ok" && (
        <span title="A battler changed their mind after this was posted — take it down from your socials" className="rounded bg-red-500/15 px-1.5 py-0.5 text-red-300">🚫 take down from socials</span>
      )}
      <span className="text-zinc-600">{clip.actedAtMs ? new Date(clip.actedAtMs).toLocaleDateString() : ""}</span>
      <button disabled={busy} onClick={onRestore} className="ml-auto rounded border border-zinc-700 px-2 py-0.5 text-zinc-400 hover:bg-zinc-800 disabled:opacity-50">
        Move back
      </button>
    </div>
  );
}

function EditorsChoice({ metrics, callFn, busy }: { metrics: Metrics; callFn: (name: string, data: Record<string, unknown>, label: string) => void; busy: boolean }) {
  const items = metrics.recentBattles ?? [];
  const featuredCount = items.filter((b) => b.featured).length;
  const [preview, setPreview] = useState<{ id: string; urls: { landscape: string | null; vertical: string | null } } | null>(null);
  const [loadingPreview, setLoadingPreview] = useState<string | null>(null);
  const [previewMode, setPreviewMode] = useState<"landscape" | "vertical">("landscape");
  async function openPreview(b: BattleItem) {
    if (preview?.id === b.id) { setPreview(null); return; }
    // previewClip returns BOTH renditions (public URLs when published, signed
    // URLs otherwise), so the landscape/vertical toggle switches with no refetch.
    setLoadingPreview(b.id);
    try {
      const res = await httpsCallable(functions, "previewClip")({ matchId: b.id });
      const d = (res.data ?? {}) as { landscape?: string | null; vertical?: string | null };
      if (d.landscape || d.vertical) {
        setPreview({ id: b.id, urls: { landscape: d.landscape ?? null, vertical: d.vertical ?? null } });
      }
    } catch {
      // preview unavailable - leave it closed
    }
    setLoadingPreview(null);
  }
  return (
    <div className="mb-8">
      <h2 className="mb-2 text-sm font-semibold uppercase tracking-wide text-zinc-400">
        Editor&apos;s Choice <span className="text-zinc-500">({featuredCount} featured)</span>
      </h2>
      <p className="mb-2 text-xs text-zinc-600">
        Two separate actions. <span className="text-green-300">Publish</span> makes
        a clip public/playable (allowed once the ~24h objection window has closed).{" "}
        <span className="text-amber-300">Feature</span> spotlights the battle on
        Home and earns both roasters the ⭐ badge. A featured battle plays its clip
        only if it&apos;s also published — publish in either order, it stays in sync.
      </p>
      {items.length === 0 ? (
        <p className="text-xs text-zinc-600">No recent battles.</p>
      ) : (
        <div className="space-y-2">
          {items.map((b) => (
            <div key={b.id} className={`rounded-lg border p-3 text-sm ${b.featured ? "border-amber-500/50 bg-amber-500/10" : "border-zinc-800 bg-zinc-900/60"}`}>
              <div className="flex flex-wrap items-center gap-2">
                <span className="font-semibold text-white">{b.player1Name} vs {b.player2Name}</span>
                <span className="font-mono text-xs text-zinc-600">#{b.id.slice(-6)}</span>
                {b.featured && <span className="rounded bg-amber-500/15 px-1.5 py-0.5 text-xs text-amber-300">⭐ featured</span>}
                {b.hasClip ? (
                  <span className="rounded bg-green-500/15 px-1.5 py-0.5 text-xs text-green-300">published</span>
                ) : b.rendered ? (
                  <span className="rounded bg-sky-500/15 px-1.5 py-0.5 text-xs text-sky-300">reel ready</span>
                ) : (
                  <span className="rounded bg-zinc-700/40 px-1.5 py-0.5 text-xs text-zinc-500">no reel yet</span>
                )}
                <span className="text-xs text-zinc-500">
                  {b.completedAtMs ? new Date(b.completedAtMs).toLocaleString() : ""}
                </span>
                <div className="ml-auto flex flex-wrap gap-2">
                  {(b.rendered || b.clipUrl) && (
                    <button
                      onClick={() => openPreview(b)}
                      disabled={loadingPreview === b.id}
                      className="rounded border border-zinc-700 px-2 py-1 text-xs text-zinc-200 hover:bg-zinc-800 disabled:opacity-50"
                    >
                      {loadingPreview === b.id ? "…" : preview?.id === b.id ? "Hide" : "▶ Preview"}
                    </button>
                  )}
                  {b.hasClip ? (
                    <button disabled={busy} onClick={() => { if (confirm("Unpublish this clip? It stops playing everywhere it's public (the website feed, any shared link) and both players are notified it came down.")) callFn("publishBattle", { matchId: b.id, published: false }, "Unpublished"); }} className="rounded border border-green-700/60 px-2 py-1 text-xs text-green-300 hover:bg-green-900/20 disabled:opacity-50">
                      Unpublish
                    </button>
                  ) : b.rendered ? (
                    <button disabled={busy} onClick={() => callFn("publishBattle", { matchId: b.id, published: true }, "Published")} className="rounded bg-green-600/80 px-2 py-1 text-xs text-white hover:bg-green-600 disabled:opacity-50">
                      Publish
                    </button>
                  ) : null}
                  {b.featured ? (
                    <button disabled={busy} onClick={() => callFn("featureBattle", { matchId: b.id, feature: false }, "Unfeatured")} className="rounded bg-zinc-700/80 px-2 py-1 text-xs text-white hover:bg-zinc-700 disabled:opacity-50">
                      Remove
                    </button>
                  ) : (
                    <button disabled={busy} onClick={() => callFn("featureBattle", { matchId: b.id, feature: true }, "Featured")} className="rounded bg-amber-600/80 px-2 py-1 text-xs text-white hover:bg-amber-600 disabled:opacity-50">
                      Feature
                    </button>
                  )}
                </div>
              </div>
              {preview?.id === b.id && (
                <div className="mt-3">
                  <div className="mb-2 inline-flex overflow-hidden rounded border border-zinc-700 text-xs">
                    <button
                      disabled={!preview.urls.landscape}
                      onClick={() => setPreviewMode("landscape")}
                      className={`px-2.5 py-1 ${previewMode === "landscape" ? "bg-zinc-200 text-black" : "text-zinc-300 hover:bg-zinc-800"} disabled:opacity-40`}
                    >
                      Landscape <span className="text-[10px] opacity-70">(website)</span>
                    </button>
                    <button
                      disabled={!preview.urls.vertical}
                      onClick={() => setPreviewMode("vertical")}
                      className={`px-2.5 py-1 ${previewMode === "vertical" ? "bg-zinc-200 text-black" : "text-zinc-300 hover:bg-zinc-800"} disabled:opacity-40`}
                    >
                      Vertical <span className="text-[10px] opacity-70">(in-app)</span>
                    </button>
                  </div>
                  {(() => {
                    const url = preview.urls[previewMode] ?? preview.urls.landscape ?? preview.urls.vertical;
                    return url ? (
                      <video
                        key={url}
                        src={url}
                        controls
                        autoPlay
                        className={previewMode === "vertical"
                          ? "block max-h-[70vh] rounded border border-zinc-800 bg-black"
                          : "w-full max-w-md rounded border border-zinc-800 bg-black"}
                      />
                    ) : null;
                  })()}
                </div>
              )}
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

function Prizes({ metrics, act }: { metrics: Metrics; act: (p: Record<string, unknown>, l: string) => void }) {
  const items = metrics.prizes ?? [];
  return (
    <div className="mb-8">
      <h2 className="mb-2 text-sm font-semibold uppercase tracking-wide text-zinc-400">
        Prizes to fulfill <span className="text-zinc-500">({items.length})</span>
      </h2>
      {items.length === 0 ? (
        <p className="text-xs text-zinc-600">No prizes outstanding.</p>
      ) : (
        <div className="space-y-2">
          {items.map((p) => {
            const stale = p.wonAtMs != null && Date.now() - p.wonAtMs > 7 * 86400000;
            return (
              <div key={p.id} className={`rounded-lg border p-3 text-sm ${stale ? "border-amber-500/50 bg-amber-500/10" : "border-zinc-800 bg-zinc-900/60"}`}>
                <div className="flex flex-wrap items-center gap-2">
                  <span className="font-semibold text-white">{p.prize ?? "(prize)"}</span>
                  <span className="text-xs text-zinc-500">→ {p.winnerUsername ?? p.winnerUid}</span>
                  <span className={`rounded px-1.5 py-0.5 text-xs ${p.status === "claimed" ? "bg-green-500/15 text-green-300" : "bg-zinc-700/40 text-zinc-400"}`}>{p.status}</span>
                  {p.prizeType === "cash" && <span className="rounded bg-amber-500/15 px-1.5 py-0.5 text-xs text-amber-300">CASH — handle manually</span>}
                </div>
                <div className={`mt-1 text-xs ${stale ? "text-amber-300" : "text-zinc-500"}`}>{prizeAge(p.wonAtMs)}</div>
                {p.shipping ? (
                  <div className="mt-2 rounded border border-zinc-800 bg-black/30 p-2 text-xs text-zinc-300">
                    <div className="font-medium text-zinc-200">Ship to:</div>
                    <div>{p.shipping.name}</div>
                    <div className="whitespace-pre-wrap">{p.shipping.address}</div>
                    {p.shipping.phone && <div>{p.shipping.phone}</div>}
                  </div>
                ) : (
                  <div className="mt-1 text-xs text-zinc-600">Waiting on the winner to submit shipping details…</div>
                )}
                <div className="mt-2">
                  <button onClick={() => act({ type: "markPrizeFulfilled", id: p.id }, "Prize fulfilled")} className="rounded bg-amber-600/80 px-2 py-1 text-xs text-white hover:bg-amber-600">
                    Mark fulfilled
                  </button>
                </div>
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}

// Compact diagnostics pills on a support/bug item - which build + OS it was
// filed on, so a terse report is triageable.
function Diag({ d }: { d: Record<string, unknown> }) {
  const ver = d.appVersion
    ? `v${String(d.appVersion)}${d.buildNumber ? `+${String(d.buildNumber)}` : ""}`
    : null;
  const os = [d.platform, d.osVersion].filter(Boolean).map(String).join(" ");
  const parts = [ver, os].filter((p): p is string => !!p);
  if (parts.length === 0) return null;
  return (
    <div className="mt-1 flex flex-wrap gap-1">
      {parts.map((p) => (
        <span key={p} className="rounded bg-zinc-800 px-1.5 py-0.5 text-[10px] text-zinc-400">{p}</span>
      ))}
    </div>
  );
}

function Queues({ metrics, act, busy }: { metrics: Metrics; act: (p: Record<string, unknown>, l: string) => void; busy: boolean }) {
  const blocks: { title: string; items: QueueItem[]; type: string; handled: HandledItem[] }[] = [
    { title: "Reports", items: metrics.queues.reports, type: "reviewReport", handled: metrics.handled.reports },
    { title: "Support", items: metrics.queues.support, type: "resolveSupport", handled: metrics.handled.support },
    { title: "Ban appeals", items: metrics.queues.appeals, type: "resolveAppeal", handled: metrics.handled.appeals },
  ];
  return (
    <div className="mb-8 grid gap-4 lg:grid-cols-3">
      {blocks.map((b) => (
        <div key={b.title} className="rounded-lg border border-zinc-800 bg-zinc-900/60 p-3">
          <h3 className="mb-2 text-sm font-semibold text-white">{b.title} <span className="text-zinc-500">({b.items.length})</span></h3>
          {b.items.length === 0 ? (
            <p className="text-xs text-zinc-600">Nothing pending.</p>
          ) : (
            <ul className="space-y-2">
              {b.items.map((it) => (
                <li key={it.id} className="rounded border border-zinc-800 bg-black/30 p-2 text-xs text-zinc-300">
                  <div className="font-medium text-zinc-200">{it.category === "bug_report" ? "🐞 Bug report" : (it.category ?? it.reason ?? "item")}</div>
                  {it.detail && <div className="mt-0.5 line-clamp-4 text-zinc-500 whitespace-pre-wrap">{it.detail}</div>}
                  {it.diagnostics && <Diag d={it.diagnostics} />}
                  {it.createdAt && <div className="mt-1 text-[10px] text-zinc-600">{new Date(it.createdAt).toLocaleString()}</div>}
                  <div className="mt-2 flex gap-2">
                    <button disabled={busy} onClick={() => act({ type: b.type, id: it.id, status: "reviewed" }, `${b.title} reviewed`)} className="rounded bg-zinc-800 px-2 py-1 text-zinc-200 hover:bg-zinc-700 disabled:opacity-50">Reviewed</button>
                    <button disabled={busy} onClick={() => act({ type: b.type, id: it.id, status: "actioned" }, `${b.title} actioned`)} className="rounded bg-amber-600/80 px-2 py-1 text-white hover:bg-amber-600 disabled:opacity-50">Actioned</button>
                  </div>
                </li>
              ))}
            </ul>
          )}
          {b.handled.length > 0 && (
            <div className="mt-3 border-t border-zinc-800 pt-2">
              <div className="mb-1 text-[10px] uppercase tracking-wide text-zinc-600">Recently handled</div>
              <ul className="space-y-1">
                {b.handled.map((h) => (
                  <li key={h.id} className="flex items-center gap-2 text-[11px] text-zinc-500">
                    <span className={`rounded px-1 py-0.5 ${h.status === "actioned" ? "bg-amber-500/15 text-amber-300" : "bg-zinc-700/40 text-zinc-400"}`}>{h.status}</span>
                    <span className="truncate">{h.label}</span>
                    {h.reviewedAtMs && <span className="ml-auto whitespace-nowrap text-zinc-600">{new Date(h.reviewedAtMs).toLocaleDateString()}</span>}
                  </li>
                ))}
              </ul>
            </div>
          )}
        </div>
      ))}
    </div>
  );
}

function UserSearch({ user, act }: { user: User; act: (p: Record<string, unknown>, l: string) => void }) {
  const [q, setQ] = useState("");
  const [results, setResults] = useState<FoundUser[]>([]);
  const [searching, setSearching] = useState(false);

  const run = useCallback(async () => {
    if (q.trim().length < 2) return;
    setSearching(true);
    try {
      const res = await authed(user, `/api/admin/users?q=${encodeURIComponent(q.trim())}`);
      const data = await res.json();
      setResults(data.results ?? []);
    } finally {
      setSearching(false);
    }
  }, [q, user]);

  return (
    <div className="mb-10">
      <h2 className="mb-2 text-sm font-semibold uppercase tracking-wide text-zinc-400">Players</h2>
      <div className="flex gap-2">
        <input
          value={q}
          onChange={(e) => setQ(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && run()}
          placeholder="Search username or paste a uid…"
          className="flex-1 rounded border border-zinc-700 bg-zinc-900 px-3 py-2 text-sm text-white placeholder:text-zinc-600"
        />
        <button onClick={run} className="rounded bg-zinc-800 px-4 py-2 text-sm text-zinc-200 hover:bg-zinc-700">
          {searching ? "…" : "Search"}
        </button>
      </div>
      <div className="mt-3 space-y-2">
        {results.map((u) => (
          <div key={u.uid} className="rounded-lg border border-zinc-800 bg-zinc-900/60 p-3 text-sm">
            <div className="flex flex-wrap items-center gap-2">
              <span className="font-semibold text-white">{u.username ?? "(no name)"}</span>
              <span className="text-xs text-zinc-500">{u.rankTitle ?? ""} · {u.wins ?? 0}-{u.losses ?? 0}</span>
              <StatusPill status={u.accountStatus} />
              {u.subscription.active && <span className="rounded bg-green-500/15 px-1.5 py-0.5 text-xs text-green-300">sub</span>}
              {u.isAdmin && <span className="rounded bg-amber-500/15 px-1.5 py-0.5 text-xs text-amber-300">admin</span>}
            </div>
            <div className="mt-1 font-mono text-[10px] text-zinc-600">{u.uid}</div>
            <div className="mt-2 flex flex-wrap gap-2 text-xs">
              {u.accountStatus === "banned" ? (
                <Btn onClick={() => act({ type: "setAccountStatus", uid: u.uid, status: "active" }, "Unban")}>Unban</Btn>
              ) : (
                <Btn danger onClick={() => { if (confirm(`Ban ${u.username ?? u.uid}? They'll be blocked from the app immediately.`)) act({ type: "setAccountStatus", uid: u.uid, status: "banned" }, "Ban"); }}>Ban</Btn>
              )}
              <Btn onClick={() => act({ type: "setAccountStatus", uid: u.uid, status: "flagged" }, "Flag")}>Flag</Btn>
              <Btn onClick={() => act({ type: "compAccess", uid: u.uid, days: 30 }, "Comp 30d")}>Comp 30d</Btn>
              <Btn onClick={() => act({ type: "compAccess", uid: u.uid, days: 0 }, "Comp open")}>Comp open</Btn>
              <Btn onClick={() => act({ type: "revokeAccess", uid: u.uid }, "Revoke")}>Revoke sub</Btn>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

function StatusPill({ status }: { status: string }) {
  const c = status === "banned" ? "bg-red-500/15 text-red-300" : status === "flagged" ? "bg-amber-500/15 text-amber-300" : "bg-zinc-700/40 text-zinc-400";
  return <span className={`rounded px-1.5 py-0.5 text-xs ${c}`}>{status}</span>;
}

function Btn({ children, onClick, danger }: { children: React.ReactNode; onClick: () => void; danger?: boolean }) {
  return (
    <button onClick={onClick} className={`rounded px-2 py-1 ${danger ? "bg-red-600/80 text-white hover:bg-red-600" : "bg-zinc-800 text-zinc-200 hover:bg-zinc-700"}`}>
      {children}
    </button>
  );
}
