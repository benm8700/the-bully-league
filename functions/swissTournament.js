/**
 * The Daily Gauntlet - SWISS "most wins" format (2026-09-16 redesign).
 *
 * Replaces single-elimination (climbTournament.js). The developer's goals:
 * everyone keeps playing (nobody is knocked out on one loss), the MOST WINS
 * wins the whole thing, and skill decides it rather than a lucky bracket.
 *
 * WHY SWISS, NOT TRUE ROUND-ROBIN: everyone-plays-everyone is quadratic
 * (N-1 live battles each), and a live ~10-14min video battle means one player
 * fits only ~4-5 battles in the hour - so true round-robin works only for a
 * handful of people. Swiss gets the same "everyone keeps playing, most wins
 * wins, skill not luck" at any field size: each round you're paired with
 * someone on a SIMILAR RECORD you HAVEN'T FACED, and whoever has the most
 * wins when the window ends takes it.
 *
 * NON-ELIMINATION is the core change from the climb: a loss adds to your
 * losses and you go right back to waiting for your next opponent. The
 * tournament runs the whole window; the champion is the top of the standings
 * at the end (most wins, fewest losses, strength of schedule, then who
 * committed earliest).
 *
 * This module is PURE - pairings, results, standings and the champion, with no
 * Firestore, clock or randomness - so the whole format is exercised by
 * test/swissTournament.test.js including randomised simulations (the approach
 * that caught the bracket bye collision before a device ever saw it). Wiring
 * lives in swissPlay.js.
 *
 * An entrant is a plain object:
 *   {uid, wins, losses, opponents:[uid...], status, joinedMs}
 *   status: "waiting" | "in_match" | "done"
 * "done" = out of the pairing pool but still ranked: they dropped, no-showed,
 * or hit the per-player round cap. `joinedMs` (when they SIGNED UP) orders
 * pairing and breaks standings ties - signing up early is a small edge, which
 * is deliberate.
 */

const STATUS = {
  waiting: "waiting",
  inMatch: "in_match",
  done: "done",
};

/** Total games this entrant has settled (each result is one round for both). */
function roundsPlayed(e) {
  return (Number(e.wins) || 0) + (Number(e.losses) || 0);
}

function uidCmp(a, b) {
  return a < b ? -1 : a > b ? 1 : 0;
}

/**
 * Pairing order: best record first (most wins, then fewest losses), then by
 * RATING (closest hidden Elo), then earliest sign-up, then uid. Seeding by
 * rating within a record group is what makes pairing "closest rank" - people
 * of similar skill and the same record meet each other, which is the
 * developer's intent for the format and what makes the roster's "near your
 * rank" study guidance and the projected first matchup honest. `rating` is the
 * hidden Elo (never shown); a missing rating sorts as 0. Used only to ORDER
 * pairing, never the final standings (those are by performance alone).
 */
function byScore(a, b) {
  return (b.wins - a.wins) ||
    (a.losses - b.losses) ||
    ((b.rating || 0) - (a.rating || 0)) ||
    (a.joinedMs - b.joinedMs) ||
    uidCmp(a.uid, b.uid);
}

/**
 * Decide who to pair right now. PURE.
 *
 * Among WAITING entrants who have not hit the round cap, seed by standings and
 * greedily pair each with the nearest-ranked opponent they have NOT already
 * faced (the heart of Swiss - similar records, no rematches). Someone with no
 * unfaced opponent left simply waits this pass.
 *
 * `allowRematch` (the caller sets it near the window's end, when avoiding
 * rematches would otherwise strand people who have already faced everyone
 * near them) relaxes the no-rematch rule so the field keeps battling to the
 * finish rather than stalling. A rematch is a lesser evil than dead air in the
 * last minutes.
 *
 * @param {Array} entrants
 * @param {{allowRematch?: boolean, maxRounds?: number}} opts
 * @return {Array<[string,string]>}
 */
function planPairings(entrants, {allowRematch = false, maxRounds = Infinity} = {}) {
  const avail = entrants
      .filter((e) => e.status === STATUS.waiting && roundsPlayed(e) < maxRounds)
      .sort(byScore);
  const used = new Set();
  const pairs = [];

  for (let i = 0; i < avail.length; i++) {
    const a = avail[i];
    if (used.has(a.uid)) continue;
    const faced = new Set(a.opponents || []);
    let partner = -1;
    let fallback = -1;
    for (let j = i + 1; j < avail.length; j++) {
      const b = avail[j];
      if (used.has(b.uid)) continue;
      if (fallback === -1) fallback = j; // nearest-ranked, even if a rematch
      if (!faced.has(b.uid)) {
        partner = j; // nearest-ranked NON-rematch
        break;
      }
    }
    const pick = partner !== -1 ? partner : (allowRematch ? fallback : -1);
    if (pick !== -1) {
      pairs.push([a.uid, avail[pick].uid]);
      used.add(a.uid);
      used.add(avail[pick].uid);
    }
    // else a waits this pass (no eligible opponent right now)
  }
  return pairs;
}

/** Mark a pair as in a match, so the next planning pass skips them. PURE. */
function markInMatch(entrants, uids) {
  const set = new Set(uids);
  return entrants.map((e) =>
    set.has(e.uid) ? {...e, status: STATUS.inMatch} : e);
}

/** Record that two entrants have now faced each other (both directions). */
function _withOpponent(e, otherUid) {
  const opps = e.opponents || [];
  return opps.includes(otherUid) ? opps : [...opps, otherUid];
}

/**
 * A settled result where BOTH players battled. PURE, non-mutating.
 * Winner +1 win, loser +1 loss; both record having faced each other; both go
 * back to waiting (nobody is eliminated). If either hits the round cap they go
 * `done` instead of waiting.
 */
function applyResult(entrants, {winnerUid, loserUid}, {maxRounds = Infinity} = {}) {
  return entrants.map((e) => {
    if (e.uid === winnerUid) {
      const next = {...e, wins: e.wins + 1,
        opponents: _withOpponent(e, loserUid)};
      next.status = roundsPlayed(next) >= maxRounds ? STATUS.done : STATUS.waiting;
      return next;
    }
    if (e.uid === loserUid) {
      const next = {...e, losses: e.losses + 1,
        opponents: _withOpponent(e, winnerUid)};
      next.status = roundsPlayed(next) >= maxRounds ? STATUS.done : STATUS.waiting;
      return next;
    }
    return e;
  });
}

/**
 * A TIE (draw / zero votes): the crowd could not separate them. Neither a win
 * nor a loss - it counts as a played round (they faced each other) but moves
 * no record, and both return to waiting. PURE.
 *
 * Distinct from single-elim's tie rule (which advanced both a tier): here a
 * draw is simply a no-score game, consistent with "most wins wins".
 */
function applyTie(entrants, {player1Id, player2Id}) {
  return entrants.map((e) => {
    if (e.uid === player1Id || e.uid === player2Id) {
      const other = e.uid === player1Id ? player2Id : player1Id;
      // No win, no loss - so it does not count toward the wins+losses round
      // cap either (ties are rare; the cap is a soft safety bound). Both
      // record the opponent and return to waiting.
      return {...e, opponents: _withOpponent(e, other), status: STATUS.waiting};
    }
    return e;
  });
}

/**
 * A one-sided no-show: the present player is handed the win and returns to
 * waiting; the absent player is DROPPED (status "done") so the sweep stops
 * pairing a ghost into everyone's matches. The dropped player keeps whatever
 * record they had, ranked at the bottom accordingly. PURE.
 */
function applyForfeit(entrants, {winnerUid, loserUid}, {maxRounds = Infinity} = {}) {
  return entrants.map((e) => {
    if (e.uid === winnerUid) {
      const next = {...e, wins: e.wins + 1};
      next.status = roundsPlayed(next) >= maxRounds ? STATUS.done : STATUS.waiting;
      return next;
    }
    if (e.uid === loserUid) {
      return {...e, status: STATUS.done};
    }
    return e;
  });
}

/** A double no-show: neither turned up, so both are dropped. PURE. */
function applyDoubleNoShow(entrants, {player1Id, player2Id}) {
  const set = new Set([player1Id, player2Id]);
  return entrants.map((e) =>
    set.has(e.uid) ? {...e, status: STATUS.done} : e);
}

/** Strength of schedule: total wins of everyone this entrant has faced. Used
 * as a standings tiebreak (beating winners is worth more than beating the
 * winless), the standard Swiss tiebreak. */
function _strengthOfSchedule(entrant, byUid) {
  let s = 0;
  for (const oppUid of entrant.opponents || []) {
    const opp = byUid.get(oppUid);
    if (opp) s += opp.wins;
  }
  return s;
}

/**
 * The full standings, best first. PURE. Sort: most wins, then fewest losses,
 * then strength of schedule, then earliest sign-up, then uid.
 */
function standings(entrants) {
  const byUid = new Map(entrants.map((e) => [e.uid, e]));
  const sos = new Map(entrants.map((e) => [e.uid, _strengthOfSchedule(e, byUid)]));
  return [...entrants].sort((a, b) =>
    (b.wins - a.wins) ||
    (a.losses - b.losses) ||
    (sos.get(b.uid) - sos.get(a.uid)) ||
    (a.joinedMs - b.joinedMs) ||
    uidCmp(a.uid, b.uid));
}

/**
 * Whether the tournament is over and who won. PURE.
 *
 * Unlike single-elim there is no "last survivor" - nobody is eliminated - so
 * the event runs until the window ends (or every entrant is `done`). The
 * champion is then the top of the standings, PROVIDED someone actually won a
 * battle: a field where nobody scored (all 0 wins) crowns nobody, and the
 * caller cancels rather than handing the title to whoever signed up first.
 *
 * @param {Array} entrants
 * @param {{windowEnded: boolean}} flags
 * @return {{done: boolean, winnerUid: string|null}}
 */
function resolveChampion(entrants, {windowEnded}) {
  if (entrants.length === 0) return {done: windowEnded, winnerUid: null};
  const everyoneDone = entrants.every((e) => e.status === STATUS.done);
  if (!windowEnded && !everyoneDone) return {done: false, winnerUid: null};

  const top = standings(entrants)[0];
  if (!top || top.wins <= 0) return {done: true, winnerUid: null};
  return {done: true, winnerUid: top.uid};
}

/**
 * The caller's own live standing for the client. PURE.
 * Returns {wins, losses, status, rank, playerCount} where rank is 1-based over
 * the whole field by the standings order.
 */
function standingFor(entrants, uid) {
  const me = entrants.find((e) => e.uid === uid);
  if (!me) return null;
  const ordered = standings(entrants);
  const rank = ordered.findIndex((e) => e.uid === uid) + 1;
  return {
    wins: me.wins,
    losses: me.losses,
    status: me.status,
    rank,
    playerCount: entrants.length,
  };
}

module.exports = {
  STATUS,
  roundsPlayed,
  byScore,
  planPairings,
  markInMatch,
  applyResult,
  applyTie,
  applyForfeit,
  applyDoubleNoShow,
  standings,
  resolveChampion,
  standingFor,
};
