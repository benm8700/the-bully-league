"use client";

import { httpsCallable } from "firebase/functions";
import { doc, getDoc } from "firebase/firestore";
import Link from "next/link";
import { useParams } from "next/navigation";
import { useEffect, useState } from "react";
import { useAuth } from "@/lib/AuthProvider";
import { db, functions } from "@/lib/firebaseClient";
import { Turnstile } from "@/components/Turnstile";

interface MatchInfo {
  player1Id: string;
  player2Id: string;
  player1Username: string;
  player2Username: string;
}

export default function VotePage() {
  const { matchId } = useParams<{ matchId: string }>();
  const { user, loading: authLoading } = useAuth();

  const [match, setMatch] = useState<MatchInfo | null>(null);
  const [matchError, setMatchError] = useState<string | null>(null);
  const [selected, setSelected] = useState<string | null>(null);
  const [turnstileToken, setTurnstileToken] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [result, setResult] = useState<string | null>(null);

  useEffect(() => {
    if (!user) return;
    (async () => {
      // Client Firestore SDK here (not Admin SDK, unlike the homepage/
      // feed) - this page is only reachable by a signed-in user anyway
      // (voting requires it), and firestore.rules already allows any
      // authenticated read on matches/{id} and users/{id}.
      const matchSnap = await getDoc(doc(db, "matches", matchId));
      if (!matchSnap.exists()) {
        setMatchError("Match not found.");
        return;
      }
      const data = matchSnap.data();
      const [p1Snap, p2Snap] = await Promise.all([
        getDoc(doc(db, "users", data.player1Id)),
        getDoc(doc(db, "users", data.player2Id)),
      ]);
      setMatch({
        player1Id: data.player1Id,
        player2Id: data.player2Id,
        player1Username: p1Snap.data()?.username ?? "Unknown",
        player2Username: p2Snap.data()?.username ?? "Unknown",
      });
    })();
  }, [user, matchId]);

  async function handleVote() {
    if (!selected || !turnstileToken) return;
    setSubmitting(true);
    setResult(null);
    try {
      const castVote = httpsCallable(functions, "castVote");
      await castVote({ matchId, votedForPlayerId: selected, turnstileToken });
      setResult("Vote cast! Thanks for judging.");
    } catch (e) {
      const message = e instanceof Error ? e.message : "Something went wrong.";
      setResult(`Couldn't cast your vote: ${message}`);
    } finally {
      setSubmitting(false);
    }
  }

  if (authLoading) return null;

  if (!user) {
    // Someone arriving from a shared clip has no account and cannot make
    // one here: signup happens in the app, because age verification runs
    // on the store-level Play Age Signals API and has no web equivalent.
    //
    // So this is deliberately a CONVERSION surface, not a dead end. It
    // used to say "Sign in to vote" and link to a login page that offers
    // no way to register - which read as a wall to the exact visitor the
    // shared clip was meant to attract. The clip poses the question; the
    // app is where it gets answered.
    return (
      <main className="flex-1 flex flex-col items-center justify-center gap-4 px-6 py-20 text-center">
        <p className="text-lg font-semibold">Who won this one?</p>
        <p className="text-foreground/70 max-w-md">
          Voting happens in the app, where we can check you&apos;re over 18.
          Grab it, judge this battle, and get matched against a stranger
          yourself.
        </p>
        <Link
          href="/matches"
          className="rounded-full bg-accent px-6 py-3 font-semibold text-background"
        >
          Watch more battles
        </Link>
        <Link href="/login" className="text-foreground/60 text-sm hover:underline">
          Already have an account? Sign in
        </Link>
      </main>
    );
  }

  if (matchError) {
    return (
      <main className="flex-1 flex items-center justify-center px-6 py-20">
        <p className="text-foreground/70">{matchError}</p>
      </main>
    );
  }

  if (!match) {
    return <main className="flex-1 px-6 py-20" />;
  }

  const isParticipant = user.uid === match.player1Id || user.uid === match.player2Id;

  return (
    <main className="flex-1 flex flex-col items-center px-6 py-20 gap-6">
      <h1 className="text-2xl font-bold">Who won?</h1>

      {isParticipant ? (
        <p className="text-foreground/60">You can&apos;t vote on your own match.</p>
      ) : result ? (
        <p className="text-foreground/80">{result}</p>
      ) : (
        <>
          <div className="flex gap-4">
            {[
              { id: match.player1Id, name: match.player1Username },
              { id: match.player2Id, name: match.player2Username },
            ].map((p) => (
              <button
                key={p.id}
                onClick={() => setSelected(p.id)}
                className={`rounded-lg border px-6 py-4 font-medium transition-colors ${
                  selected === p.id
                    ? "border-accent bg-accent/10"
                    : "border-foreground/20 hover:border-foreground/40"
                }`}
              >
                {p.name}
              </button>
            ))}
          </div>

          {selected && <Turnstile onVerify={setTurnstileToken} />}

          <button
            onClick={handleVote}
            disabled={!selected || !turnstileToken || submitting}
            className="rounded-md bg-accent text-black font-medium px-6 py-2 disabled:opacity-40"
          >
            {submitting ? "Casting vote..." : "Cast Vote"}
          </button>
        </>
      )}
    </main>
  );
}
