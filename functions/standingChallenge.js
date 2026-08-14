/**
 * Standing challenges: a queue entry that outlives the app being closed.
 *
 * THE PROBLEM THIS SOLVES. Live 1v1 pairing needs two people awake and in
 * the app in the same minute. With a small user base spread across
 * timezones that essentially never happens, and the core loop simply does
 * not fire. Sixes and Sevens fixes it by concentrating everyone into one
 * hour; this fixes the other twenty-three, where someone queues, finds
 * nobody, and leaves with nothing.
 *
 * Instead of failing, a wait that finds no live opponent becomes a
 * STANDING challenge. Someone queueing hours later matches it instantly
 * and the standing player gets a push: X wants to battle, battle now?
 *
 * WHAT WAS DELIBERATELY NOT BUILT: scheduling. The original proposal had
 * both players agree a time within the next few hours, and that was
 * rejected because it defers the simultaneity problem rather than removing
 * it - the battle still needs both people live at the same moment, and
 * committing in advance turns "never matched" into "cleared my evening,
 * they didn't show", which is worse for morale. Multi-step flows also
 * compound drop-off: queue, notify, view profile, accept, propose times,
 * confirm, wait, both show up. Scheduling is reserved for tournaments,
 * where an entry fee and a bracket justify the coordination cost.
 */

/** How long a live search runs before the entry becomes standing. Long
 * enough that a busy period still pairs people directly, short enough that
 * nobody watches a spinner wondering if it is broken. */
const STANDING_AFTER_MS = 90 * 1000;

/** How long a standing challenge stays in the pool. Roughly an evening: it
 * has to outlive the app being closed, which is the entire point, but a
 * challenge left from three days ago pairs someone against an opponent who
 * has long since forgotten they queued. */
const STANDING_TTL_MS = 6 * 60 * 60 * 1000;

/** How long the standing player has to accept once matched. They may be
 * asleep, so this is generous next to a live pairing - but bounded,
 * because the other player is waiting on it. */
const ACCEPT_WINDOW_MS = 5 * 60 * 1000;

/**
 * Whether an entry has been waiting long enough to become standing.
 *
 * Pure so the transition can be tested without RTDB or a clock.
 */
function shouldBecomeStanding(entry, nowMs, threshold = STANDING_AFTER_MS) {
  if (!entry || entry.status !== "waiting") return false;
  // ONLY IF THEY CAN ACTUALLY BE WOKEN. A standing challenge works by
  // pushing its owner when someone takes it up; without a registered
  // device there is nobody to push, so the entry would sit in the pool
  // being paired against and never answered.
  //
  // This matters more than it looks. Pairing costs the OTHER player a
  // five-minute wait before the challenge is released, so a pool full of
  // unwakeable entries is worse than an empty one - the app would feel
  // broken rather than quiet. Anything that cannot be notified stays an
  // ordinary wait and is pruned as stale, exactly as before.
  if (entry.canNotify !== true) return false;
  return nowMs - (Number(entry.joinedAt) || 0) >= threshold;
}

/**
 * Whether a queue entry is still usable as a pairing candidate.
 *
 * This replaces a single staleness rule with two, because the two states
 * mean different things. A "waiting" entry implies someone is sitting in
 * front of the app RIGHT NOW, so if its client stopped polling minutes ago
 * that person has gone and pairing against them strands a live player in a
 * match nobody joins. A "standing" entry implies the opposite - the person
 * has deliberately left it behind and expects to be pushed - so it must
 * survive far longer.
 */
function isLive(entry, nowMs, {
  staleMs,
  standingTtlMs = STANDING_TTL_MS,
} = {}) {
  if (!entry) return false;
  const age = nowMs - (Number(entry.joinedAt) || 0);
  if (entry.status === "standing") return age <= standingTtlMs;
  if (entry.status === "waiting") return age <= staleMs;
  // "matched" entries are never pruned - they are how a player who closed
  // the app still finds the match they were paired into.
  return entry.status === "matched";
}

/**
 * Whether a match created against a standing challenge has gone
 * unanswered.
 *
 * Only ever true for a match whose standing player never became ready. A
 * live pairing is not subject to this - both players are already present,
 * and the bio reveal has its own much shorter timer.
 */
function acceptanceExpired(match, nowMs, windowMs = ACCEPT_WINDOW_MS) {
  if (!match) return false;
  if (match.status !== "pending") return false;
  if (match.origin !== "standing") return false;
  const created = match.createdAt?.toMillis?.() ?? 0;
  if (created === 0) return false;
  // Someone accepting is what makes this no longer a pending challenge.
  const ready = Array.isArray(match.readyPlayerIds) ? match.readyPlayerIds : [];
  if (ready.length >= 2) return false;
  return nowMs - created > windowMs;
}

/**
 * Who to blame when a standing challenge expires unanswered.
 *
 * The player who issued the challenge and then failed to show is the one
 * who cost the other person their time, so the challenge is released and
 * the ACTIVE player goes back into the pool rather than being punished for
 * someone else's absence. Nothing is forfeited here - a forfeit is for
 * accepting and then not turning up, which is a promise broken rather than
 * one never made.
 */
function releaseOutcome(match) {
  return {
    requeue: match?.challengerId === match?.player1Id ?
      match?.player2Id : match?.player1Id,
    noShow: match?.challengerId ?? null,
  };
}

module.exports = {
  shouldBecomeStanding,
  isLive,
  acceptanceExpired,
  releaseOutcome,
  STANDING_AFTER_MS,
  STANDING_TTL_MS,
  ACCEPT_WINDOW_MS,
};
