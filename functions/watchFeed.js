const {getFirestore, Timestamp} = require("firebase-admin/firestore");
const {HttpsError} = require("firebase-functions/v2/https");
const {getStorage} = require("firebase-admin/storage");
const {voteWindowEndMs} = require("./matchFinalization");

/**
 * The single in-app feed of battles: everything still open for judgement
 * first, then the archive.
 *
 * ONE FEED RATHER THAN TWO TABS. A separate "judge" queue and "watch" feed
 * would show the same clips in the same way, differing only in whether a
 * match's 24-hour window had closed - which is not a distinction worth
 * making a user learn. Worse, a judging queue EMPTIES: you clear it, and
 * the tab is dead until more matches finish. Merging them means the feed
 * flows from "battles that need you" into the archive with no seam and no
 * empty state.
 *
 * ORDERING, in two phases:
 *   1. Open, unjudged by you, ordered by URGENCY - soonest deadline first,
 *      bucketed so the least-judged comes first within each band. Time is
 *      the irreversible constraint: a match closing in twenty minutes
 *      cannot be rescued later, a quiet one with hours left still can.
 *   2. Everything else, ordered by POPULARITY - most votes first. Once the
 *      urgent work is done the value is entertainment, and vote count is
 *      the best proxy available for "the crowd found this one".
 *
 * Matches already at full confidence are NOT excluded from phase 1's pool
 * the way an earlier design had them - a great battle is worth watching
 * whether or not another ballot moves its rating. They simply sort below
 * the ones that still need judgement.
 */

/** How wide an urgency band is. Within the same band the least-judged
 * comes first, so both signals count without either drowning the other. */
const URGENCY_BAND_MS = 2 * 60 * 60 * 1000;

/** Signed URLs are short-lived on purpose. A Firebase download token would
 * mint a PERMANENT public URL, which would let any signed-in user pull an
 * unreviewed clip and post it anywhere - defeating the storage rule that
 * limits renders to signed-in viewers. */
const CLIP_URL_TTL_MS = 6 * 60 * 60 * 1000;

/** How many candidates get a ballot lookup. Bounds the reads one feed
 * load costs while still giving an honest badge count. */
const BALLOT_CHECK_LIMIT = 30;

const PAGE_SIZE = 10;
const SCAN_LIMIT = 60;

/**
 * Sort key for a match still open for voting: urgency band first, then
 * fewest votes within the band.
 *
 * Pure, so the ordering can be tested without Firestore.
 */
function openSortKey(match, nowMs) {
  const remaining = Math.max(0, match.windowEndMs - nowMs);
  return [Math.floor(remaining / URGENCY_BAND_MS), Number(match.voteCount) || 0];
}

/**
 * Orders one page of the feed: everything open and unjudged, then the rest
 * by popularity.
 */
function orderFeed(matches, nowMs) {
  const open = [];
  const archive = [];
  for (const m of matches) {
    (m.canVote ? open : archive).push(m);
  }

  open.sort((a, b) => {
    const [bandA, votesA] = openSortKey(a, nowMs);
    const [bandB, votesB] = openSortKey(b, nowMs);
    return bandA - bandB || votesA - votesB;
  });
  archive.sort((a, b) =>
    (Number(b.voteCount) || 0) - (Number(a.voteCount) || 0));

  return [...open, ...archive];
}

/**
 * The verdict to reveal AFTER a finished clip has played.
 *
 * Only ever populated for matches whose voting has closed. While a window
 * is open the running score stays hidden, because seeing who is ahead
 * before you judge biases the judgement - that is the whole reason the
 * live tally is gated. Once voting closes there is no vote left to bias
 * and the result is simply the payoff for watching.
 *
 * Reports the split rather than rating changes: how the crowd voted is
 * public, how much someone's rating moved is their business.
 */
function verdictFor(match) {
  if (match.voteFinalized !== true) return null;
  const a = Number(match.player1FinalWeight) || 0;
  const b = Number(match.player2FinalWeight) || 0;
  const total = a + b;
  if (total <= 0) return {outcome: "undecided"};
  if (!match.winnerId) {
    // CLAUDE.md's tie rule: neither a win nor a loss, no rating change.
    return {outcome: "tie", player1Share: 0.5, player2Share: 0.5, totalVotes: total};
  }
  return {
    outcome: "decided",
    winnerId: match.winnerId,
    player1Share: a / total,
    player2Share: b / total,
    totalVotes: total,
  };
}

/** A short-lived URL the client can hand straight to a video player. */
async function clipUrl(match) {
  // A published clip already carries a permanent public URL, minted by
  // publishHighlight with a Storage download token. Prefer it: it costs no
  // signing call, and it works even where signing is unavailable.
  const published = match.highlight?.published === true ?
    (match.highlight.publicUrls?.vertical ??
     match.highlight.publicUrls?.landscape) : null;
  if (published) return published;

  const path = match.highlight?.renditions?.vertical?.path ??
    match.highlight?.renditions?.landscape?.path;
  if (!path) return null;
  try {
    const [url] = await getStorage().bucket().file(path).getSignedUrl({
      action: "read",
      expires: Date.now() + CLIP_URL_TTL_MS,
    });
    return url;
  } catch (e) {
    // A missing clip must degrade to metadata, never break the feed.
    console.error(`could not sign ${path}:`, e.message);
    return null;
  }
}

async function getWatchFeed(auth, data) {
  if (!auth) throw new HttpsError("unauthenticated", "Must be signed in.");
  const limit = Math.min(20, Math.max(1, Number(data?.limit) || PAGE_SIZE));
  const db = getFirestore();
  const nowMs = Date.now();

  // Paginated by completion time, walking backwards.
  //
  // A chronological cursor works here for a reason that is easy to miss:
  // a match open for voting is BY DEFINITION one that finished in the last
  // 24 hours, so ordering by completedAt descending already puts every
  // votable battle at the top. Judging work therefore lands on the first
  // page or two on its own, and later pages are pure archive - no need for
  // a second cursor over a different ordering.
  //
  // Scrolling back in time also beats globally sorting the archive by
  // popularity, which would show the same handful of clips forever and
  // never surface anything new. Popularity still orders within a page.
  const cursorMs = Number(data?.cursorMs);
  let query = db.collection("matches")
      .where("status", "==", "completed")
      .orderBy("completedAt", "desc");
  if (Number.isFinite(cursorMs) && cursorMs > 0) {
    query = query.startAfter(Timestamp.fromMillis(cursorMs));
  }
  const snap = await query.limit(SCAN_LIMIT).get();

  const candidates = [];
  // Advanced past EVERY document examined, not just the ones kept. A whole
  // page can be filtered out - matches with no render yet, for instance -
  // and a cursor that only tracked kept items would then never move, so
  // the client would request the same window forever and the feed would
  // stop dead a few clips in.
  let lastScannedMs = 0;
  for (const doc of snap.docs) {
    const match = doc.data();
    lastScannedMs = match.completedAt?.toMillis?.() ?? lastScannedMs;
    // Nothing to watch without a render, and the feed is a watching
    // surface - metadata-only cards are what the old website feed did and
    // they are not worth a scroll.
    if (!match.highlight?.renditions) continue;

    const windowEndMs = voteWindowEndMs(match);
    const isParticipant =
      auth.uid === match.player1Id || auth.uid === match.player2Id;
    const windowOpen = match.voteFinalized !== true && nowMs < windowEndMs;

    candidates.push({
      doc,
      match,
      windowEndMs,
      isParticipant,
      windowOpen,
    });
  }

  // Resolve votability for every candidate, not just the page being
  // returned, so the Judge tab's badge can show a true count of battles
  // waiting on this viewer. A badge that undercounts because it only saw
  // one page would quietly stop being the pull it exists to be.
  const votable = new Map();
  for (const c of candidates.slice(0, BALLOT_CHECK_LIMIT)) {
    // Participants can never vote on their own match, and a ballot already
    // cast cannot be cast again - both make a match archive-like for this
    // viewer even while its window is open.
    if (!c.windowOpen || c.isParticipant) {
      votable.set(c.doc.id, false);
      continue;
    }
    const ballot = await db.collection("votes").doc(c.doc.id)
        .collection("ballots").doc(auth.uid).get();
    votable.set(c.doc.id, !ballot.exists);
  }

  const results = [];
  for (const c of candidates) {
    if (results.length >= limit) break;
    const alreadyVoted = c.windowOpen && !c.isParticipant &&
      votable.get(c.doc.id) === false;

    const [p1, p2] = await Promise.all([
      db.collection("users").doc(c.match.player1Id).get(),
      db.collection("users").doc(c.match.player2Id).get(),
    ]);

    results.push({
      matchId: c.doc.id,
      player1Id: c.match.player1Id,
      player2Id: c.match.player2Id,
      player1Username: p1.data()?.username ?? "Unknown",
      player2Username: p2.data()?.username ?? "Unknown",
      mode: c.match.mode ?? "ranked",
      voteCount: c.match.voteCount ?? 0,
      windowEndMs: c.windowEndMs,
      canVote: c.windowOpen && !c.isParticipant && !alreadyVoted,
      // Distinguishes "you already judged this, it is still being decided"
      // from "this is settled". Without it the client cannot tell the two
      // apart, because both simply have canVote false and no verdict.
      alreadyVoted,
      windowOpen: c.windowOpen,
      isParticipant: c.isParticipant,
      // Null while voting is open - the running score stays hidden until
      // the viewer has judged, or until the result is settled.
      verdict: verdictFor(c.match),
      videoUrl: await clipUrl(c.match),
      captioned: c.match.highlight?.captioned === true,
      reactionCounts: c.match.reactionCounts ?? {},
      reactionTotal: c.match.reactionTotal ?? 0,
    });
  }

  return {
    matches: orderFeed(results, nowMs),
    // Only meaningful on the first page: it counts battles waiting on this
    // viewer overall, not within a window of the archive.
    pendingVotes: [...votable.values()].filter(Boolean).length,
    // Where the next page starts. Null means the collection is exhausted -
    // a short scan cannot be refilled by asking again.
    nextCursorMs: snap.size < SCAN_LIMIT ? null : lastScannedMs,
  };
}

module.exports = {
  getWatchFeed,
  orderFeed,
  openSortKey,
  verdictFor,
  URGENCY_BAND_MS,
  CLIP_URL_TTL_MS,
};
