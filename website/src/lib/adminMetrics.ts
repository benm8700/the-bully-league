import { getAdminFirestore } from "./firebaseAdmin";
import { Timestamp } from "firebase-admin/firestore";

// Server-only. The admin command-center numbers. Every query is wrapped so one
// failure (e.g. a missing index on a single metric) returns null for that tile
// instead of blanking the whole dashboard - the admin can still see everything
// else, and a null tile is a visible signal that one query needs attention.

const DAY_MS = 24 * 60 * 60 * 1000;

async function safe<T>(fn: () => Promise<T>): Promise<T | null> {
  try {
    return await fn();
  } catch (e) {
    console.error("admin metric failed:", (e as Error).message);
    return null;
  }
}

type QueueItem = {
  id: string;
  reason?: string;
  category?: string;
  detail?: string;
  reportedUserId?: string;
  createdAt?: number | null;
  diagnostics?: Record<string, unknown> | null;
};

function tsToMs(v: unknown): number | null {
  if (v instanceof Timestamp) return v.toMillis();
  if (typeof v === "number") return v;
  return null;
}

async function recent(
  collection: string,
  statusField = "status",
  pendingValue = "pending",
): Promise<QueueItem[]> {
  const db = getAdminFirestore();
  // No orderBy: these collections may lack createdAt on older docs, and an
  // orderBy would silently drop them. Filter by pending status, cap, sort in JS.
  const snap = await db
    .collection(collection)
    .where(statusField, "==", pendingValue)
    .limit(25)
    .get();
  return snap.docs
    .map((d) => {
      const x = d.data();
      return {
        id: d.id,
        reason: x.reason,
        category: x.category,
        detail: x.detail ?? x.message,
        reportedUserId: x.reportedUserId,
        createdAt: tsToMs(x.createdAt),
        diagnostics: x.diagnostics ?? null,
      } as QueueItem;
    })
    .sort((a, b) => (b.createdAt ?? 0) - (a.createdAt ?? 0));
}

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

// Outstanding non-cash prizes (owed or claimed-but-not-shipped), oldest first
// so the longest-outstanding sits on top. wonAtMs drives the dashboard's
// "won N days ago" age.
async function recentPrizes(): Promise<PrizeItem[]> {
  const db = getAdminFirestore();
  const snap = await db
    .collection("prizeFulfillments")
    .where("status", "in", ["owed", "claimed"])
    .limit(50)
    .get();
  return snap.docs
    .map((d) => {
      const x = d.data();
      return {
        id: d.id,
        prize: x.prize ?? null,
        prizeType: x.prizeType ?? null,
        winnerUid: x.winnerUid ?? null,
        winnerUsername: x.winnerUsername ?? null,
        status: x.status ?? "owed",
        wonAtMs: typeof x.wonAtMs === "number" ? x.wonAtMs : null,
        shipping: x.shipping ?? null,
      } as PrizeItem;
    })
    .sort((a, b) => (a.wonAtMs ?? 0) - (b.wonAtMs ?? 0));
}

type BattleItem = {
  id: string;
  player1Name: string;
  player2Name: string;
  completedAtMs: number | null;
  featured: boolean;
  rendered: boolean; // an edit reel exists in Storage -> the clip CAN be published
  hasClip: boolean; // published -> playable
  // A public, playable URL when the highlight is published (so the dashboard can
  // preview it before featuring). Null when unpublished - previewing an
  // unpublished render needs a signed URL, deliberately not done here to keep
  // the critical metrics route free of extra Admin SDK imports (ESM crashes on
  // Vercel - see firebaseAdmin.ts).
  clipUrl: string | null;
};

const RECORDED_MODES = new Set(["ranked", "tournament", "friend", "elite"]);

// Recent completed battles, so the founder can feature one as Editor's Choice
// straight from the dashboard (no need to know a matchId). orderBy(completedAt)
// is single-field - no composite index - and naturally returns only finished
// matches (pending ones have no completedAt, so the orderBy drops them).
async function recentBattles(): Promise<BattleItem[]> {
  const db = getAdminFirestore();
  const [snap, featuredSnap] = await Promise.all([
    db.collection("matches").orderBy("completedAt", "desc").limit(20).get(),
    db.collection("featured").get(),
  ]);
  const featuredIds = new Set(featuredSnap.docs.map((d) => d.id));
  const rows = snap.docs
    .map((d) => {
      const x = d.data();
      const h = (x.highlight as Record<string, unknown> | undefined) ?? {};
      const pub = (h.publicUrls as Record<string, string> | undefined) ?? {};
      const rends = (h.renditions as Record<string, unknown> | undefined) ?? {};
      const published = h.published === true;
      return {
        id: d.id,
        p1: String(x.player1Id ?? ""),
        p2: String(x.player2Id ?? ""),
        status: x.status,
        mode: x.mode,
        completedAtMs: tsToMs(x.completedAt),
        published,
        rendered: Object.keys(rends).length > 0,
        clipUrl: published ? (pub.landscape ?? pub.vertical ?? null) : null,
      };
    })
    .filter((r) => r.status === "completed" && RECORDED_MODES.has(r.mode));
  const uids = [
    ...new Set(rows.flatMap((r) => [r.p1, r.p2]).filter(Boolean)),
  ];
  const nameByUid = new Map<string, string>();
  if (uids.length) {
    const docs = await db.getAll(
      ...uids.map((u) => db.collection("users").doc(u)),
    );
    docs.forEach((d) =>
      nameByUid.set(d.id, String(d.data()?.username ?? "Unknown")),
    );
  }
  return rows.map((r) => ({
    id: r.id,
    player1Name: nameByUid.get(r.p1) ?? "Unknown",
    player2Name: nameByUid.get(r.p2) ?? "Unknown",
    completedAtMs: r.completedAtMs,
    featured: featuredIds.has(r.id),
    rendered: r.rendered,
    hasClip: r.published,
    clipUrl: r.clipUrl,
  }));
}

type HandledItem = {
  id: string;
  collection: "reports" | "supportRequests" | "banAppeals";
  label: string;
  status: string;
  reviewedAtMs: number | null;
};

// Recently-actioned moderation items, so a click doesn't just vanish - the
// admin can see what they just handled (and undo via the normal flow if needed).
// Ordered by review.at, which ONLY actioned docs have, so no status filter or
// composite index is needed.
async function recentlyHandled(
  collection: "reports" | "supportRequests" | "banAppeals",
): Promise<HandledItem[]> {
  const db = getAdminFirestore();
  const snap = await db
    .collection(collection)
    .orderBy("review.at", "desc")
    .limit(8)
    .get();
  return snap.docs.map((d) => {
    const x = d.data();
    const review = (x.review as Record<string, unknown> | undefined) ?? {};
    return {
      id: d.id,
      collection,
      label: String(x.category ?? x.reason ?? x.detail ?? x.message ?? d.id),
      status: String(x.status ?? "reviewed"),
      reviewedAtMs: tsToMs(review.at),
    } as HandledItem;
  });
}

export type AdminMetrics = Awaited<ReturnType<typeof collectMetrics>>;

export async function collectMetrics() {
  const db = getAdminFirestore();
  const now = Date.now();
  const since = (ms: number) => Timestamp.fromMillis(now - ms);
  const users = db.collection("users");
  const matches = db.collection("matches");

  const count = (q: FirebaseFirestore.Query) =>
    safe(async () => (await q.count().get()).data().count);

  const [
    totalUsers,
    subscribers,
    banned,
    flagged,
    signupsToday,
    signups7d,
    battlesToday,
    battles7d,
    battlesTotal,
    publishedClips,
    votesToday,
    reportsPending,
    supportOpen,
    banAppeals,
    presence,
    tournamentCfg,
    monetizationCfg,
    reports,
    support,
    appeals,
    prizes,
    battlesRecent,
    handledReports,
    handledSupport,
    handledAppeals,
  ] = await Promise.all([
    count(users),
    count(users.where("subscription.active", "==", true)),
    count(users.where("accountStatus", "==", "banned")),
    count(users.where("accountStatus", "==", "flagged")),
    count(users.where("createdAt", ">=", since(DAY_MS))),
    count(users.where("createdAt", ">=", since(7 * DAY_MS))),
    count(matches.where("createdAt", ">=", since(DAY_MS))),
    count(matches.where("createdAt", ">=", since(7 * DAY_MS))),
    count(matches),
    count(matches.where("highlight.published", "==", true)),
    count(
      db
        .collectionGroup("ballots")
        .where("timestamp", ">=", since(DAY_MS)),
    ),
    count(db.collection("reports").where("status", "==", "pending")),
    count(db.collection("supportRequests").where("status", "==", "open")),
    count(db.collection("banAppeals").where("status", "==", "pending")),
    safe(async () => (await db.collection("stats").doc("presence").get()).data()),
    safe(async () =>
      (await db.collection("config").doc("tournament").get()).data(),
    ),
    safe(async () =>
      (await db.collection("config").doc("monetization").get()).data(),
    ),
    safe(() => recent("reports")),
    // Support/bug reports write status "open", NOT "pending" - querying
    // "pending" here silently emptied the whole Support queue (and the stat).
    safe(() => recent("supportRequests", "status", "open")),
    safe(() => recent("banAppeals")),
    safe(() => recentPrizes()),
    safe(() => recentBattles()),
    safe(() => recentlyHandled("reports")),
    safe(() => recentlyHandled("supportRequests")),
    safe(() => recentlyHandled("banAppeals")),
  ]);

  return {
    generatedAt: now,
    users: { total: totalUsers, subscribers, banned, flagged },
    online: {
      total: (presence as Record<string, unknown> | null)?.total ?? null,
      committedTonight:
        (presence as Record<string, unknown> | null)?.committedTonight ?? null,
    },
    signups: { last24h: signupsToday, last7d: signups7d },
    battles: {
      last24h: battlesToday,
      last7d: battles7d,
      total: battlesTotal,
      publishedClips,
    },
    votes: { last24h: votesToday },
    moderation: { reportsPending, supportOpen, banAppeals },
    config: {
      tournamentEnabled:
        (tournamentCfg as Record<string, unknown> | null)?.enabled === true,
      monetizationEnabled:
        (monetizationCfg as Record<string, unknown> | null)?.enabled === true,
    },
    queues: {
      reports: (reports as QueueItem[] | null) ?? [],
      support: (support as QueueItem[] | null) ?? [],
      appeals: (appeals as QueueItem[] | null) ?? [],
    },
    prizes: (prizes as PrizeItem[] | null) ?? [],
    recentBattles: (battlesRecent as BattleItem[] | null) ?? [],
    handled: {
      reports: (handledReports as HandledItem[] | null) ?? [],
      support: (handledSupport as HandledItem[] | null) ?? [],
      appeals: (handledAppeals as HandledItem[] | null) ?? [],
    },
  };
}
