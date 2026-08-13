import { getAdminFirestore } from "./firebaseAdmin";

export interface TopRoaster {
  id: string;
  username: string;
  rating: number;
  rankTitle: string;
}

/**
 * Live Top 5 ranked roasters for the homepage - see CLAUDE.md's Website
 * homepage decision: "must auto-update dynamically... this is a live query
 * against current ratings, not a static/admin-curated list." Same
 * single-field orderBy(rating desc) query as the app's own
 * LeaderboardScreen (no composite index needed) - no accountStatus filter,
 * matching that existing precedent exactly.
 */
export async function getTopRoasters(): Promise<TopRoaster[]> {
  const snap = await getAdminFirestore()
    .collection("users")
    .orderBy("rating", "desc")
    .limit(5)
    .get();

  return snap.docs.map((doc) => {
    const data = doc.data();
    return {
      id: doc.id,
      username: (data.username as string | undefined) ?? "Unknown",
      rating: (data.rating as number | undefined) ?? 0,
      rankTitle: (data.rankTitle as string | undefined) ?? "Average Joe",
    };
  });
}
