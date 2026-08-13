import { getAdminFirestore } from "./firebaseAdmin";

export interface FeedMatch {
  id: string;
  player1Username: string;
  player2Username: string;
  mode: string;
  voteCount: number;
  createdAtMs: number | null;
}

async function resolveUsernames(db: FirebaseFirestore.Firestore, uids: string[]) {
  const unique = Array.from(new Set(uids));
  const usernames = new Map<string, string>();
  await Promise.all(
    unique.map(async (uid) => {
      const snap = await db.collection("users").doc(uid).get();
      usernames.set(uid, (snap.data()?.username as string | undefined) ?? "Unknown");
    }),
  );
  return usernames;
}

function toFeedMatches(
  docs: FirebaseFirestore.QueryDocumentSnapshot[],
  usernames: Map<string, string>,
): FeedMatch[] {
  return docs.map((doc) => {
    const data = doc.data();
    return {
      id: doc.id,
      player1Username: usernames.get(data.player1Id as string) ?? "Unknown",
      player2Username: usernames.get(data.player2Id as string) ?? "Unknown",
      mode: (data.mode as string | undefined) ?? "exhibition",
      voteCount: (data.voteCount as number | undefined) ?? 0,
      createdAtMs: data.createdAt?.toMillis?.() ?? null,
    };
  });
}

const FEED_LIMIT = 20;

/**
 * Match documents exist from pairing time onward now (see
 * functions/matchmaking.js), so the collection also holds matches that are
 * still being played and ones that were abandoned mid-way. The public feed
 * must show neither: a "pending" match has no result to browse, and an
 * abandoned one (a crash, or a live content-moderation auto-end) is
 * explicitly not content anyone should be pointed at.
 *
 * Both feeds pair this with an orderBy on a different field, which needs a
 * composite index - see firestore.indexes.json.
 */
const COMPLETED = "completed";

/**
 * "Recent" tab (CLAUDE.md's Discovery/feed decision) - most-recent-first,
 * guarantees every match gets visibility during its 24h vote window even
 * with zero votes yet, avoiding the cold-start trap a trending-only feed
 * would have.
 */
export async function getRecentMatches(): Promise<FeedMatch[]> {
  const db = getAdminFirestore();
  const snap = await db
    .collection("matches")
    .where("status", "==", COMPLETED)
    .orderBy("createdAt", "desc")
    .limit(FEED_LIMIT)
    .get();
  const uids = snap.docs.flatMap((d) => [d.data().player1Id, d.data().player2Id]);
  const usernames = await resolveUsernames(db, uids);
  return toFeedMatches(snap.docs, usernames);
}

/**
 * "Trending" tab - sorted by voteCount, a raw count denormalized onto the
 * match doc by the onVoteCast Cloud Function trigger (functions/
 * voteCount.js) whenever a ballot is cast, so this stays a cheap
 * single-field orderBy instead of counting each match's ballots
 * subcollection on every page load. Matches with no votes yet (voteCount
 * field absent) are excluded by Firestore's orderBy semantics - expected,
 * since the Recent tab is what guarantees a brand-new match's visibility.
 */
export async function getTrendingMatches(): Promise<FeedMatch[]> {
  const db = getAdminFirestore();
  const snap = await db
    .collection("matches")
    .where("status", "==", COMPLETED)
    .orderBy("voteCount", "desc")
    .limit(FEED_LIMIT)
    .get();
  const uids = snap.docs.flatMap((d) => [d.data().player1Id, d.data().player2Id]);
  const usernames = await resolveUsernames(db, uids);
  return toFeedMatches(snap.docs, usernames);
}
