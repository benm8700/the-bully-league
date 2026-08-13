import { getRecentMatches, getTrendingMatches } from "@/lib/matches";
import { MatchFeedTabs } from "@/components/MatchFeedTabs";

// Same reasoning as the homepage leaderboard: revalidate rather than
// force-dynamic or fully static, so the feed stays close to live without
// re-querying Firestore on every single request.
export const revalidate = 30;

export default async function MatchesPage() {
  const [recent, trending] = await Promise.all([getRecentMatches(), getTrendingMatches()]);

  return (
    <main className="flex-1 px-6 py-12">
      <div className="max-w-2xl mx-auto flex flex-col gap-6">
        <h1 className="text-2xl font-bold">Matches</h1>
        <MatchFeedTabs recent={recent} trending={trending} />
      </div>
    </main>
  );
}
