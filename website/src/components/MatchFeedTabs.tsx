"use client";

import { useState } from "react";
import type { FeedMatch } from "@/lib/matches";

// No longer a link. It used to open a browser voting page, which required
// sign-in - and accounts can only be created in the app, so the visitor
// this feed exists for could never actually vote. The clip plays right
// here instead, and judging lives in the app where the judge already has
// an account.
function MatchCard({ match }: { match: FeedMatch }) {
  return (
    <div
      className="flex flex-col rounded-lg border border-foreground/10 overflow-hidden"
    >
      {match.videoUrl && (
        // preload="metadata" rather than "auto": a feed of twenty cards
        // that each eagerly buffered a clip would be a slow page and a
        // real bandwidth bill, on a project already watching per-match
        // video costs. muted + playsInline so the poster frame shows
        // without the browser blocking it or iOS forcing fullscreen.
        <video
          src={match.videoUrl}
          controls
          muted
          playsInline
          preload="metadata"
          className="w-full max-h-80 bg-black object-contain"
        />
      )}
      <div className="flex items-center justify-between px-4 py-3">
        <div className="flex flex-col">
          <span className="font-medium">
            {match.player1Username} <span className="text-foreground/40">vs</span>{" "}
            {match.player2Username}
          </span>
          <span className="text-xs text-foreground/50 capitalize">
            {match.mode}
            {!match.videoUrl && " · clip not published yet"}
          </span>
        </div>
        <span className="text-sm text-foreground/70">
          {match.voteCount} {match.voteCount === 1 ? "vote" : "votes"}
        </span>
      </div>
    </div>
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
