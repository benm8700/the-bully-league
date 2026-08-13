"use client";

import Link from "next/link";
import { useState } from "react";
import type { FeedMatch } from "@/lib/matches";

function MatchCard({ match }: { match: FeedMatch }) {
  return (
    <Link
      href={`/vote/${match.id}`}
      className="flex items-center justify-between rounded-lg border border-foreground/10 px-4 py-3 hover:border-accent transition-colors"
    >
      <div className="flex flex-col">
        <span className="font-medium">
          {match.player1Username} <span className="text-foreground/40">vs</span>{" "}
          {match.player2Username}
        </span>
        <span className="text-xs text-foreground/50 capitalize">{match.mode}</span>
      </div>
      <span className="text-sm text-foreground/70">
        {match.voteCount} {match.voteCount === 1 ? "vote" : "votes"}
      </span>
    </Link>
  );
}

export function MatchFeedTabs({
  recent,
  trending,
}: {
  recent: FeedMatch[];
  trending: FeedMatch[];
}) {
  const [tab, setTab] = useState<"recent" | "trending">("recent");
  const matches = tab === "recent" ? recent : trending;

  return (
    <div className="flex flex-col gap-4">
      <div className="flex gap-2">
        {(["recent", "trending"] as const).map((t) => (
          <button
            key={t}
            onClick={() => setTab(t)}
            className={`px-4 py-1.5 rounded-full text-sm font-medium capitalize transition-colors ${
              tab === t
                ? "bg-accent text-black"
                : "border border-foreground/20 text-foreground/70 hover:border-foreground/40"
            }`}
          >
            {t}
          </button>
        ))}
      </div>
      {matches.length === 0 ? (
        <p className="text-foreground/50">
          {tab === "trending" ? "No votes yet." : "No matches yet."}
        </p>
      ) : (
        <div className="flex flex-col gap-2">
          {matches.map((match) => (
            <MatchCard key={match.id} match={match} />
          ))}
        </div>
      )}
    </div>
  );
}
