import { getRecentMatches, getTrendingMatches } from "@/lib/matches";
import { MatchFeedTabs } from "@/components/MatchFeedTabs";
import { StoreCta } from "@/components/StoreCta";

// Same reasoning as the homepage leaderboard: revalidate rather than
// force-dynamic or fully static, so the feed stays close to live without
// re-querying Firestore on every single request.
export const revalidate = 30;

export default async function MatchesPage() {
  const [recent, trending] = await Promise.all([getRecentMatches(), getTrendingMatches()]);

  return (
    <main className="flex-1 px-6 py-12">
      <div className="max-w-2xl mx-auto flex flex-col gap-6">
        <div className="flex flex-wrap items-center justify-between gap-4">
          <div className="flex flex-col">
            <h1 className="text-2xl font-bold">Matches</h1>
            {/* Says plainly where judging happens, so the missing vote
                button reads as a fact about the app rather than as
                something broken. */}
            <p className="text-sm text-foreground/60">
              Watch here. Judging happens in the app.
            </p>
          </div>
          <StoreCta variant="inline" />
        </div>
        <MatchFeedTabs recent={recent} trending={trending} />
      </div>
    </main>
  );
}
