"use client";

import { useAuth } from "@/lib/AuthProvider";
import { functions } from "@/lib/firebaseClient";
import { httpsCallable } from "firebase/functions";
import { useCallback, useEffect, useState } from "react";
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

  const act = useCallback(
    async (payload: Record<string, unknown>, label: string) => {
      if (!user) return;
      setNote(`${label}…`);
      const res = await authed(user, "/api/admin/action", {
        method: "POST",
        body: JSON.stringify(payload),
      });
      const data = await res.json().catch(() => ({}));
      setNote(res.ok ? `${label}: done` : `${label}: ${data.error ?? res.status}`);
      await loadMetrics();
    },
    [user, loadMetrics],
  );

  // Calls a Firebase callable (Editor's Choice feature/publish) as the signed-in
  // admin - the callable enforces requireAdmin and reuses the real publish gate.
  const callFn = useCallback(
    async (name: string, data: Record<string, unknown>, label: string) => {
      if (!user) return;
      setNote(`${label}…`);
      try {
        const res = await httpsCallable(functions, name)(data);
        const d = (res.data ?? {}) as Record<string, unknown>;
        setNote(d.note ? `${label}: done — ${d.note}` : `${label}: done`);
      } catch (e) {
        setNote(`${label}: ${(e as Error).message}`);
      }
      await loadMetrics();
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
          <Link href="/login" className="text-amber-400 underline">Sign in</Link>
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
                onClick={() => act({ type: "setConfigFlag", doc: "tournament", enabled: !metrics.config.tournamentEnabled }, "Tournament flag")}
              />
              <Toggle
                label="Monetization"
                on={metrics.config.monetizationEnabled}
                onClick={() => act({ type: "setConfigFlag", doc: "monetization", enabled: !metrics.config.monetizationEnabled }, "Monetization flag")}
              />
            </div>
          </div>

          <EditorsChoice metrics={metrics} callFn={callFn} />
          <Prizes metrics={metrics} act={act} />
          <Queues metrics={metrics} act={act} />
          <UserSearch user={user!} act={act} />
        </>
      )}
    </Shell>
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

function EditorsChoice({ metrics, callFn }: { metrics: Metrics; callFn: (name: string, data: Record<string, unknown>, label: string) => void }) {
  const items = metrics.recentBattles ?? [];
  const featuredCount = items.filter((b) => b.featured).length;
  const [preview, setPreview] = useState<string | null>(null);
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
                  {b.clipUrl && (
                    <button
                      onClick={() => setPreview(preview === b.id ? null : b.id)}
                      className="rounded border border-zinc-700 px-2 py-1 text-xs text-zinc-200 hover:bg-zinc-800"
                    >
                      {preview === b.id ? "Hide" : "▶ Preview"}
                    </button>
                  )}
                  {b.hasClip ? (
                    <button onClick={() => callFn("publishBattle", { matchId: b.id, published: false }, "Unpublished")} className="rounded border border-green-700/60 px-2 py-1 text-xs text-green-300 hover:bg-green-900/20">
                      Unpublish
                    </button>
                  ) : b.rendered ? (
                    <button onClick={() => callFn("publishBattle", { matchId: b.id, published: true }, "Published")} className="rounded bg-green-600/80 px-2 py-1 text-xs text-white hover:bg-green-600">
                      Publish
                    </button>
                  ) : null}
                  {b.featured ? (
                    <button onClick={() => callFn("featureBattle", { matchId: b.id, feature: false }, "Unfeatured")} className="rounded bg-zinc-700/80 px-2 py-1 text-xs text-white hover:bg-zinc-700">
                      Remove
                    </button>
                  ) : (
                    <button onClick={() => callFn("featureBattle", { matchId: b.id, feature: true }, "Featured")} className="rounded bg-amber-600/80 px-2 py-1 text-xs text-white hover:bg-amber-600">
                      Feature
                    </button>
                  )}
                </div>
              </div>
              {preview === b.id && b.clipUrl && (
                <video
                  src={b.clipUrl}
                  controls
                  autoPlay
                  className="mt-3 w-full max-w-md rounded border border-zinc-800 bg-black"
                />
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

function Queues({ metrics, act }: { metrics: Metrics; act: (p: Record<string, unknown>, l: string) => void }) {
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
                    <button onClick={() => act({ type: b.type, id: it.id, status: "reviewed" }, `${b.title} reviewed`)} className="rounded bg-zinc-800 px-2 py-1 text-zinc-200 hover:bg-zinc-700">Reviewed</button>
                    <button onClick={() => act({ type: b.type, id: it.id, status: "actioned" }, `${b.title} actioned`)} className="rounded bg-amber-600/80 px-2 py-1 text-white hover:bg-amber-600">Actioned</button>
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
                <Btn danger onClick={() => act({ type: "setAccountStatus", uid: u.uid, status: "banned" }, "Ban")}>Ban</Btn>
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
