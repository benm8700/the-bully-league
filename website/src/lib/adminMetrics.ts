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

type MatchRow = {
  id: string;
  p1: string;
  p2: string;
  completedAtMs: number | null;
  published: boolean;
  rendered: boolean;
  clipUrl: string | null;
  featName1?: string; // fallback names from the featured doc if the match is gone
  featName2?: string;
};

function rowFromMatch(id: string, x: Record<string, unknown>): MatchRow {
  const h = (x.highlight as Record<string, unknown> | undefined) ?? {};
  const pub = (h.publicUrls as Record<string, string> | undefined) ?? {};
  const rends = (h.renditions as Record<string, unknown> | undefined) ?? {};
  const published = h.published === true;
  return {
    id,
    p1: String(x.player1Id ?? ""),
    p2: String(x.player2Id ?? ""),
    completedAtMs: tsToMs(x.completedAt),
    published,
    rendered: Object.keys(rends).length > 0,
    clipUrl: published ? (pub.landscape ?? pub.vertical ?? null) : null,
  };
}

// Battles the founder can act on in the Editor's Choice panel: the 20 most
// recent completed battles, PLUS every currently-featured battle (even if it's
// aged out of the recent window, or its match was deleted) so a featured battle
// can always be un-featured. orderBy(completedAt) is single-field (no composite
// index) and drops pending matches (they have no completedAt).
async function recentBattles(): Promise<BattleItem[]> {
  const db = getAdminFirestore();
  const [snap, featuredSnap] = await Promise.all([
    db.collection("matches").orderBy("completedAt", "desc").limit(20).get(),
    db.collection("featured").get(),
  ]);
  const featuredIds = new Set(featuredSnap.docs.map((d) => d.id));
  const featById = new Map(featuredSnap.docs.map((d) => [d.id, d.data()]));

  const recentRows = snap.docs
    .filter(
      (d) =>
        d.data().status === "completed" && RECORDED_MODES.has(d.data().mode),
    )
    .map((d) => rowFromMatch(d.id, d.data()));
  const recentIds = new Set(recentRows.map((r) => r.id));

  const missing = [...featuredIds].filter((id) => !recentIds.has(id));
  const extraRows: MatchRow[] = [];
  if (missing.length) {
    const mdocs = await db.getAll(
      ...missing.map((id) => db.collection("matches").doc(id)),
    );
    for (const md of mdocs) {
      const feat =
        (featById.get(md.id) as Record<string, unknown> | undefined) ?? {};
      if (md.exists) {
        const r = rowFromMatch(md.id, md.data() as Record<string, unknown>);
        r.featName1 = String(feat.player1Name ?? "");
        r.featName2 = String(feat.player2Name ?? "");
        extraRows.push(r);
      } else {
        // Match deleted but still featured - keep it removable.
        extraRows.push({
          id: md.id,
          p1: "",
          p2: "",
          completedAtMs: null,
          published: false,
          rendered: false,
          clipUrl: (feat.clipUrl as string | undefined) ?? null,
          featName1: String(feat.player1Name ?? "Unknown"),
          featName2: String(feat.player2Name ?? "Unknown"),
        });
      }
    }
  }

  const rows = [...extraRows, ...recentRows]; // featured-first, so always visible
  const uids = [...new Set(rows.flatMap((r) => [r.p1, r.p2]).filter(Boolean))];
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
    player1Name: (r.p1 && nameByUid.get(r.p1)) || r.featName1 || "Unknown",
    player2Name: (r.p2 && nameByUid.get(r.p2)) || r.featName2 || "Unknown",
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

// ---- Post Studio: rank the best finalized clips for the founder to post ----

export type PostClip = {
  id: string;
  player1Name: string;
  player2Name: string;
  completedAtMs: number | null;
  rendered: boolean;
  published: boolean;
  votes: number;
  positiveEmoji: number; // 🔥 fire + 🧠 clever received this match
  score: number;
  // Marketing-use consent across BOTH battlers: both said yes / still needed /
  // at least one declined. Gates whether it's safe to post as official promo.
  consent: "both" | "needs" | "declined";
  status: "candidate" | "posted" | "dismissed";
  platforms: { tiktok: boolean; instagram: boolean; youtube: boolean } | null;
  actedAtMs: number | null; // posted/dismissed timestamp, for archive ordering
};

const POSITIVE_EMOJI = new Set(["fire", "clever"]);

// Sum the positive emoji (🔥/🧠) a match's two roasters received, across all
// ballots. Bounded to the handful of top candidates, so the per-match ballot
// read is cheap; wrapped in safe() by the caller so a miss just scores 0.
async function positiveEmojiForMatch(matchId: string): Promise<number> {
  const db = getAdminFirestore();
  const snap = await db
    .collection("votes")
    .doc(matchId)
    .collection("ballots")
    .get();
  let n = 0;
  for (const d of snap.docs) {
    const er = (d.data().emojiRatings as Record<string, string> | undefined) ?? {};
    for (const k of Object.values(er)) if (POSITIVE_EMOJI.has(k)) n++;
  }
  return n;
}

// Candidates = finalized, rendered, recorded-mode battles not yet posted or set
// aside, ranked best-first (votes + positive emoji). Posted/dismissed are the
// two archives, read by their explicit status so they never clutter the queue.
async function postStudioClips(): Promise<{
  candidates: PostClip[];
  posted: PostClip[];
  dismissed: PostClip[];
}> {
  const db = getAdminFirestore();
  const [recentSnap, postedSnap, dismissedSnap] = await Promise.all([
    db.collection("matches").orderBy("completedAt", "desc").limit(60).get(),
    db.collection("matches").where("postStudio.status", "==", "posted").limit(40).get(),
    db.collection("matches").where("postStudio.status", "==", "dismissed").limit(40).get(),
  ]);

  const candDocs = recentSnap.docs.filter((d) => {
    const x = d.data();
    const ps = (x.postStudio as Record<string, unknown> | undefined) ?? {};
    const h = (x.highlight as Record<string, unknown> | undefined) ?? {};
    const rends = (h.renditions as Record<string, unknown> | undefined) ?? {};
    return (
      x.status === "completed" &&
      RECORDED_MODES.has(String(x.mode)) &&
      x.voteFinalized === true &&
      Object.keys(rends).length > 0 &&
      ps.status !== "posted" &&
      ps.status !== "dismissed"
    );
  });
  // Rank by raw popularity first to pick which to spend ballot-reads on, cap 20.
  candDocs.sort(
    (a, b) => (Number(b.data().voteCount) || 0) - (Number(a.data().voteCount) || 0),
  );
  const topCand = candDocs.slice(0, 20);
  const emojiCounts = await Promise.all(
    topCand.map((d) => safe(() => positiveEmojiForMatch(d.id)).then((v) => v ?? 0)),
  );

  const all = [
    ...topCand.map((d) => d),
    ...postedSnap.docs,
    ...dismissedSnap.docs,
  ];
  const uids = [
    ...new Set(
      all
        .flatMap((d) => [String(d.data().player1Id ?? ""), String(d.data().player2Id ?? "")])
        .filter(Boolean),
    ),
  ];
  const nameByUid = new Map<string, string>();
  if (uids.length) {
    const udocs = await db.getAll(...uids.map((u) => db.collection("users").doc(u)));
    udocs.forEach((d) => nameByUid.set(d.id, String(d.data()?.username ?? "Unknown")));
  }

  function build(
    d: FirebaseFirestore.QueryDocumentSnapshot,
    positiveEmoji: number,
    status: "candidate" | "posted" | "dismissed",
  ): PostClip {
    const x = d.data();
    const h = (x.highlight as Record<string, unknown> | undefined) ?? {};
    const rends = (h.renditions as Record<string, unknown> | undefined) ?? {};
    const ps = (x.postStudio as Record<string, unknown> | undefined) ?? {};
    const plat = (ps.platforms as Record<string, boolean> | undefined) ?? null;
    const votes = Number(x.voteCount) || 0;
    const mc =
      (x.marketingConsent as Record<string, { consent?: boolean }> | undefined) ?? {};
    const c1 = mc[String(x.player1Id ?? "")]?.consent;
    const c2 = mc[String(x.player2Id ?? "")]?.consent;
    const consent: "both" | "needs" | "declined" =
      c1 === false || c2 === false
        ? "declined"
        : c1 === true && c2 === true
          ? "both"
          : "needs";
    return {
      id: d.id,
      player1Name: nameByUid.get(String(x.player1Id ?? "")) ?? "Unknown",
      player2Name: nameByUid.get(String(x.player2Id ?? "")) ?? "Unknown",
      completedAtMs: tsToMs(x.completedAt),
      rendered: Object.keys(rends).length > 0,
      published: h.published === true,
      votes,
      positiveEmoji,
      score: votes + positiveEmoji * 2,
      consent,
      status,
      platforms: plat
        ? { tiktok: !!plat.tiktok, instagram: !!plat.instagram, youtube: !!plat.youtube }
        : null,
      actedAtMs: tsToMs(ps.postedAt) ?? tsToMs(ps.dismissedAt),
    };
  }

  const candidates = topCand
    .map((d, i) => build(d, emojiCounts[i], "candidate"))
    .sort((a, b) => b.score - a.score);
  const posted = postedSnap.docs
    .map((d) => build(d, 0, "posted"))
    .sort((a, b) => (b.actedAtMs ?? 0) - (a.actedAtMs ?? 0));
  const dismissed = dismissedSnap.docs
    .map((d) => build(d, 0, "dismissed"))
    .sort((a, b) => (b.actedAtMs ?? 0) - (a.actedAtMs ?? 0));
  return { candidates, posted, dismissed };
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
    postStudioData,
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
    safe(() => postStudioClips()),
  ]);

  return {
    generatedAt: now,
    users: { total: totalUsers, subscribers, banned, flagged },
    online: {
      total: (presence as Record<string, unknown> | null)?.total ?? null,
      committedTonight:
        (presence as Record<string, unknown> | null)?.committedTonight ?? null,
    },
    // Backend health from the once-a-minute presence heartbeat: a fresh beat
    // means the scheduled jobs (and Firestore + the functions runtime) are
    // alive; a stale one means the backend is down. upSinceMs = continuous
    // uptime start.
    health: (() => {
      const p = presence as Record<string, unknown> | null;
      const lastBeatMs = Number(p?.heartbeatMs) || null;
      const upSinceMs = Number(p?.upSinceMs) || null;
      const online = lastBeatMs != null && now - lastBeatMs < 4 * 60 * 1000;
      return { online, lastBeatMs, upSinceMs };
    })(),
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
    postStudio: (postStudioData as {
      candidates: PostClip[];
      posted: PostClip[];
      dismissed: PostClip[];
    } | null) ?? { candidates: [], posted: [], dismissed: [] },
  };
}
