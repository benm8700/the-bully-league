import { getTopRoasters } from "@/lib/leaderboard";

// Revalidate rather than force-dynamic: this page has no per-request input
// (no cookies/params), so Next would otherwise statically render it once
// at build time - which would silently violate CLAUDE.md's "must
// auto-update dynamically... no manual curation needed" homepage
// decision. A short revalidation window keeps it feeling live without
// hitting Firestore on every single request during a traffic spike (see
// CLAUDE.md's Agora cost-planning flag for the same "viral spike vs.
// low/no budget" tension applied to a different service).
export const revalidate = 60;

export default async function Home() {
  const topRoasters = await getTopRoasters();

  return (
    <main className="flex-1 flex flex-col items-center px-6 py-20">
      <div className="max-w-2xl w-full flex flex-col items-center text-center gap-4">
        <h1 className="text-5xl font-bold tracking-tight">The Bully League</h1>
        <p className="text-lg text-foreground/70">
          Live 1-on-1 video roast battles. Random pairing, community-judged, no mercy.
        </p>
      </div>

      <section className="max-w-2xl w-full mt-20">
        <h2 className="text-sm font-semibold uppercase tracking-wider text-foreground/50 mb-4">
          Top 5 Roasters
        </h2>
        {topRoasters.length === 0 ? (
          <p className="text-foreground/50">No roasters yet. Be the first.</p>
        ) : (
          <ol className="flex flex-col gap-2">
            {topRoasters.map((roaster, index) => (
              <li
                key={roaster.id}
                className="flex items-center justify-between rounded-lg border border-foreground/10 px-4 py-3"
              >
                <div className="flex items-center gap-4">
                  <span className="text-accent font-bold w-6 text-right">{index + 1}</span>
                  <div className="flex flex-col">
                    <span className="font-medium">{roaster.username}</span>
                    <span className="text-xs text-foreground/50">{roaster.rankTitle}</span>
                  </div>
                </div>
                <span className="text-sm text-foreground/70 tabular-nums">{roaster.rating}</span>
              </li>
            ))}
          </ol>
        )}
      </section>
    </main>
  );
}
