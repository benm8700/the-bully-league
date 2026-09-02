/**
 * The nightly "climb" tournament: rolling single-elimination where the bracket
 * builds itself as people arrive (CLAUDE.md's Sixes and Sevens format,
 * 2026-08-31).
 *
 * WHY THIS INSTEAD OF A FIXED BRACKET. A pre-seeded bracket has to lock at one
 * exact minute (6:15), which strands anyone who is a little late and needs a
 * critical mass present all at once - fatal for a thin/variable pool. The
 * climb removes the lock: you can JOIN ANY TIME, you enter at 0 wins, and you
 * advance only by beating someone with the SAME number of wins. Lose once and
 * you are out (single elimination), but you can still watch/vote/gift.
 *
 * THE ANTI-CHEESE IS STRUCTURAL, not a bolted-on rule. Because you are only
 * ever paired with an equally-proven opponent, a latecomer cannot leapfrog to
 * the final off one match - they must climb 0 -> 1 -> 2 -> ... beating a winner
 * at every step. And the later they join, the fewer fresh same-tier opponents
 * exist to climb through, so "join at 6:58 and win it all" is impossible by
 * construction rather than by a punishing cutoff.
 *
 * This module is PURE - it decides pairings, applies results, and names the
 * champion, with no Firestore, clock, or randomness - so the whole format is
 * exercised by test/climbTournament.test.js (including randomised simulations,
 * the same approach that caught the bracket bye collision before a device
 * ever saw it). Wiring lives elsewhere.
 *
 * A climber is a plain object:
 *   {uid, wins, status, joinedMs}
 *   status: "waiting" | "in_match" | "eliminated"
 * `wins` is the climber's current tier (rounds won). `joinedMs` orders pairing
 * and breaks champion ties; uid is the final deterministic tiebreak.
 */

const STATUS = {
  waiting: "waiting",
  inMatch: "in_match",
  eliminated: "eliminated",
};

/** Active = still in the running (not knocked out). */
function isActive(c) {
  return c.status !== STATUS.eliminated;
}

/**
 * Deterministic order within a pairing group: longest-waiting first (lowest
 * joinedMs), uid as the final tiebreak so two climbers who joined in the same
 * millisecond still order stably.
 */
function byWaiting(a, b) {
  if (a.joinedMs !== b.joinedMs) return a.joinedMs - b.joinedMs;
  return a.uid < b.uid ? -1 : a.uid > b.uid ? 1 : 0;
}

/**
 * Decide who to pair right now. PURE.
 *
 * Always makes SAME-WIN-COUNT pairs (the heart of the format). When
 * `forceResolve` is set - the caller passes it once the field can no longer
 * produce same-count pairs on its own (joins closed and the top players are
 * stranded at different tiers, or the window is ending) - it additionally
 * force-pairs the leftover waiters TOP-DOWN, so the event converges on a
 * champion instead of stalling forever waiting for a challenger who will never
 * arrive. Force-pairing the highest-win players first keeps the final between
 * the two best survivors.
 *
 * "Pair unbattled-first" falls out for free: unbattled newcomers are exactly
 * the 0-win bucket, and every bucket is paired in the same pass, so newcomers
 * are never starved behind the high-tier players.
 *
 * @param {Array} climbers
 * @param {{forceResolve?: boolean}} opts
 * @return {Array<[string,string]>} pairings as [uidA, uidB]
 */
function planPairings(climbers, {forceResolve = false} = {}) {
  const waiting = climbers.filter((c) => c.status === STATUS.waiting);
  const pairings = [];
  const used = new Set();

  // 1. Same-win-count pairs.
  const buckets = new Map();
  for (const c of waiting) {
    if (!buckets.has(c.wins)) buckets.set(c.wins, []);
    buckets.get(c.wins).push(c);
  }
  for (const group of buckets.values()) {
    group.sort(byWaiting);
    for (let i = 0; i + 1 < group.length; i += 2) {
      pairings.push([group[i].uid, group[i + 1].uid]);
      used.add(group[i].uid);
      used.add(group[i + 1].uid);
    }
  }

  if (!forceResolve) return pairings;

  // 2. Resolution: force-pair the stranded waiters, highest wins first, so the
  // last players standing are funnelled to one champion. Ties in wins keep the
  // longest-waiting order.
  const leftover = waiting
      .filter((c) => !used.has(c.uid))
      .sort((a, b) => (b.wins - a.wins) || byWaiting(a, b));
  for (let i = 0; i + 1 < leftover.length; i += 2) {
    pairings.push([leftover[i].uid, leftover[i + 1].uid]);
  }
  return pairings;
}

/**
 * Apply a settled match. PURE - returns a NEW array, never mutates.
 * Winner climbs a tier and goes back to waiting; loser is eliminated. Both
 * must currently be in the match (guards against a stale/double apply).
 */
function applyResult(climbers, {winnerUid, loserUid}) {
  return climbers.map((c) => {
    if (c.uid === winnerUid) {
      return {...c, wins: c.wins + 1, status: STATUS.waiting};
    }
    if (c.uid === loserUid) {
      return {...c, status: STATUS.eliminated};
    }
    return c;
  });
}

/**
 * A TIE (equal or zero votes): the crowd could not separate them, so BOTH
 * climbers advance a tier and return to waiting - neither is eliminated
 * (the developer's call, 2026-09-01). PURE, non-mutating.
 *
 * This is deliberately NOT single-elimination for that one match: nobody is
 * knocked out. The tournament still always crowns a champion because
 * resolveChampion picks the highest-win active climber at the window's end.
 * Distinct from a DOUBLE NO-SHOW (both eliminated), which the sweep handles -
 * a tie means both showed up and battled to a draw.
 */
function applyTie(climbers, {player1Id, player2Id}) {
  return climbers.map((c) =>
    (c.uid === player1Id || c.uid === player2Id) ?
      {...c, wins: c.wins + 1, status: STATUS.waiting} : c);
}

/** Mark a pair as in a match (so the next planning pass skips them). PURE. */
function markInMatch(climbers, uids) {
  const set = new Set(uids);
  return climbers.map((c) =>
    set.has(c.uid) ? {...c, status: STATUS.inMatch} : c);
}

/**
 * Whether the tournament is over and who won. PURE.
 *
 * A champion is crowned when the field has resolved to a single survivor with
 * no one left to beat (joins closed), or when the window ends - in which case
 * the highest-win active climber takes it (earliest to reach that tier wins a
 * tie, then uid). Returns {done, winnerUid}.
 *
 * @param {Array} climbers
 * @param {{joinsClosed: boolean, windowEnded: boolean}} flags
 */
function resolveChampion(climbers, {joinsClosed, windowEnded}) {
  const active = climbers.filter(isActive);
  // Nobody in the running. This is NOT "done" while the window is still open -
  // a freshly-created climb has zero climbers and must wait for joins, not
  // complete itself instantly. Only once the window has ended is an empty
  // field over (and then with no winner - the caller cancels rather than
  // crowns).
  if (active.length === 0) return {done: windowEnded, winnerUid: null};

  // One survivor and nobody else can enter to challenge them -> champion.
  if (active.length === 1 && joinsClosed) {
    return {done: true, winnerUid: active[0].uid};
  }

  if (windowEnded) {
    const best = [...active].sort(
        (a, b) => (b.wins - a.wins) || byWaiting(a, b))[0];
    return {done: true, winnerUid: best.uid};
  }

  return {done: false, winnerUid: null};
}

/**
 * A convenience read for the client: the caller's own live standing.
 * PURE. Returns {wins, status, rank, activeCount} where rank is 1-based among
 * active climbers by wins (ties share the higher rank), so someone can be told
 * "you are 2 wins in, 3 climbers left".
 */
function standingFor(climbers, uid) {
  const me = climbers.find((c) => c.uid === uid);
  if (!me) return null;
  const active = climbers.filter(isActive);
  const ahead = active.filter((c) => c.wins > me.wins).length;
  return {
    wins: me.wins,
    status: me.status,
    rank: isActive(me) ? ahead + 1 : null,
    activeCount: active.length,
  };
}

/**
 * Decide what the sweep should do with a climb match that is still `pending`.
 * PURE (no Firestore/clock beyond the passed nowMs), so it is unit-tested.
 *
 * THE BUG THIS REPLACES: the old sweep forfeited any pending climb match older
 * than a fixed timeout and read `arrivedAt` to pick the winner - but climb
 * matches never populate `arrivedAt`, so both read as no-shows and BOTH were
 * eliminated. Worse, a real battle stays `pending` for its ENTIRE duration
 * (bio-reveal study, warmup, rounds), only flipping to `completed` at the very
 * end via completeMatch - so a legitimate battle that ran past the timeout was
 * force-abandoned mid-fight. Found on the first 2-device dry run (2026-09-01).
 *
 * THE SIGNAL THAT FIXES IT: `readyPlayerIds`. Once BOTH players have readied in
 * the bio reveal, the battle has started; heartbeats stop at that point (the
 * battle is peer-to-peer), so presence cannot be judged during it - only a long
 * crash-safety window abandons a both-ready match, and then as a no-contest
 * since there is no winner to record. Before both ready, it is still the bio
 * reveal, judged by presence exactly like ordinary matches (opponentUnresponsive
 * in matchmaking.js): two present players are never forfeited, a genuine
 * one-sided no-show hands the win to whoever showed up, and a double no-show
 * eliminates both.
 *
 * `match` fields used: player1Id, player2Id, readyPlayerIds, lastSeenAt,
 * arrivedAt, createdMs (a number - the caller resolves the Firestore Timestamp).
 * Returns {action:"wait"} or {action:"forfeit", winnerUid} (winnerUid null = a
 * no-contest, nobody advances).
 */
function climbForfeitDecision(match, nowMs, opts) {
  const {matchTimeoutMs, battleAbandonMs, presenceStaleMs} = opts;
  const createdMs = Number(match.createdMs);
  if (!Number.isFinite(createdMs) || createdMs <= 0) return {action: "wait"};

  const p1 = match.player1Id;
  const p2 = match.player2Id;
  const ready = match.readyPlayerIds || [];
  const seen = match.lastSeenAt || {};
  const arrived = match.arrivedAt || {};

  const readied = (u) => ready.includes(u);
  const fresh = (u) => {
    const t = Number(seen[u]);
    return Number.isFinite(t) && t > 0 && nowMs - t <= presenceStaleMs;
  };
  // Arrival is a bonus signal only (the bracket flow sets it; the climb does
  // not). It never overrides absence, so it is folded into "present" as a
  // recent-arrival heartbeat rather than an "ever here" flag.
  const arrivedFresh = (u) => {
    const t = Number(arrived[u]);
    return Number.isFinite(t) && t > 0 && nowMs - t <= presenceStaleMs;
  };
  // PRESENT NOW - committed (readied) or heartbeating. Used both to protect
  // two present players and to attribute a one-sided no-show. Deliberately
  // "now", not "ever": a player who showed up and then walked away must not
  // still count as present against an opponent who is here and waiting.
  const present = (u) => readied(u) || fresh(u) || arrivedFresh(u);

  // 1. Both committed -> the battle started. Do NOT forfeit at the no-show
  // timeout; a battle legitimately runs well past it. Abandon only after a
  // long crash-safety window, and then as a no-contest.
  if (readied(p1) && readied(p2)) {
    if (nowMs < createdMs + battleAbandonMs) return {action: "wait"};
    return {action: "forfeit", winnerUid: null};
  }

  // 2. Pre-battle. Two players still actively present are mid bio-reveal -
  // never forfeit two present players.
  if (present(p1) && present(p2)) return {action: "wait"};

  // 3. Not both present. Give the no-show timeout before acting, so a brief
  // network blip or a slow arrival is not punished.
  if (nowMs < createdMs + matchTimeoutMs) return {action: "wait"};

  // 4. Whoever is present advances over an absent opponent; if neither is
  // present, nobody advances.
  if (present(p1) && !present(p2)) return {action: "forfeit", winnerUid: p1};
  if (present(p2) && !present(p1)) return {action: "forfeit", winnerUid: p2};
  return {action: "forfeit", winnerUid: null};
}

module.exports = {
  STATUS,
  isActive,
  byWaiting,
  planPairings,
  applyResult,
  applyTie,
  markInMatch,
  resolveChampion,
  standingFor,
  climbForfeitDecision,
};
