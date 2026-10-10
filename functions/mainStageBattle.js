/**
 * Main Stage battle format - the pure state machine (chess clock + interrupts).
 *
 * The weekly finals use a different battle format from everyday ranked (see the
 * Tournament model decision record in CLAUDE.md):
 *  - Two "chess clocks": each player has a fixed talk budget (default 60s) that
 *    ticks ONLY while they hold the floor. Unused time BANKS for later.
 *  - Yielding is FREE - stop and the floor passes to your opponent, no cost.
 *  - 2 INTERRUPTS ("steals") each: cut in while the opponent holds the floor.
 *    An interrupt spends a token AND starts your own clock (you pay with your
 *    time), and you hold the floor until you yield, run out, or get stolen back.
 *  - A short SHOT-CLOCK: hold the floor without starting to talk for too long
 *    and it bounces to your opponent, so nobody can stall in a standoff.
 *  - The battle ends when both clocks hit zero.
 *
 * This is PURE and deterministic: a reducer over events that each carry an
 * absolute `atMs`, so the whole thing is exercised with plain `node` - no Agora,
 * no real clock, no Firestore. The live wiring (mic mute/unmute on floor change,
 * broadcasting, the real timer) sits on top and drives this with real events.
 * Modelling it this way is deliberate: the mute/floor rules are exactly the kind
 * of thing that is a nightmare to verify live but trivial to pin down here.
 */

const DEFAULTS = {
  turnMs: 60 * 1000, // each player's total talk budget
  interrupts: 2, // "steals" each
  shotClockMs: 7 * 1000, // start talking within this of taking the floor
  // Grace window before an interrupt actually takes the floor, so the person
  // being cut into gets a beat to LAND their line rather than being gagged
  // mid-punchline. 0 = instant (the pure-engine default, and what the existing
  // tests assert). The PRODUCT stamps a real grace (see mainStagePlay +
  // resolveGraceMs); it is kept out of the engine default so the steal mechanic
  // can still be tested in isolation.
  graceMs: 0,
};

// Product default + bounds for the interrupt grace. Lives here (pure, testable)
// but is NOT the engine DEFAULTS value - the engine stays instant so the raw
// steal rules test cleanly; the battle-creating callable applies this.
const GRACE_DEFAULT_MS = 1500;
const GRACE_MAX_MS = 10 * 1000;

/**
 * Resolve a (console-tunable) interrupt grace to a safe value. Anything
 * non-finite or out of [0, GRACE_MAX_MS] falls back to the product default -
 * this config is hand-edited in the Firebase console with no validation layer,
 * exactly like the match-settings timings.
 */
function resolveGraceMs(raw) {
  const n = Number(raw);
  if (!Number.isFinite(n) || n < 0 || n > GRACE_MAX_MS) return GRACE_DEFAULT_MS;
  return Math.trunc(n);
}

/** A fresh battle between two distinct players. */
function createBattle(players, config = {}) {
  const [a, b] = players;
  if (!a || !b || a === b) {
    throw new Error("createBattle needs two distinct players");
  }
  const cfg = {...DEFAULTS, ...config};
  return {
    players: [a, b],
    config: cfg,
    remaining: {[a]: cfg.turnMs, [b]: cfg.turnMs},
    steals: {[a]: cfg.interrupts, [b]: cfg.interrupts},
    floor: null, // who holds the mic
    talking: false, // has the floor-holder started talking (shot-clock)
    floorTakenMs: null,
    lastMs: null, // when the floor-holder's clock last settled
    pendingBy: null, // an interrupt committed, in its grace window (who cut in)
    pendingAtMs: null, // when that interrupt was fired
    status: "pending", // pending -> live -> ended
    endReason: null,
  };
}

function other(state, p) {
  return state.players[0] === p ? state.players[1] : state.players[0];
}

function cloneState(state) {
  return {...state, remaining: {...state.remaining}, steals: {...state.steals}};
}

/**
 * Give the floor to `p` at `atMs`, resetting the shot-clock/talking. Any floor
 * change cancels/consumes a pending interrupt - the universal rule that keeps
 * the pending state from surviving a floor it no longer describes.
 */
function takeFloor(s, p, atMs) {
  s.floor = p;
  s.talking = false;
  s.floorTakenMs = atMs;
  s.lastMs = atMs;
  s.pendingBy = null;
  s.pendingAtMs = null;
}

/**
 * Deduct the time the floor-holder has spent since `lastMs`, and if they run
 * out, pass the floor to the opponent (who may still have banked time) or end
 * the battle when both are spent. Only touches the floor-holder's clock - that
 * is the whole point of a chess clock.
 */
function settle(s, atMs) {
  if (s.status !== "live" || s.floor == null || s.lastMs == null) return;
  const elapsed = Math.max(0, atMs - s.lastMs);
  s.remaining[s.floor] = Math.max(0, s.remaining[s.floor] - elapsed);
  s.lastMs = atMs;
  if (s.remaining[s.floor] === 0) {
    const opp = other(s, s.floor);
    if (s.remaining[opp] > 0) {
      takeFloor(s, opp, atMs); // out of time -> opponent gets the mic
    } else {
      s.status = "ended";
      s.endReason = "time";
      s.floor = null;
    }
  }
}

/**
 * Apply one event. Events: {type, by, atMs}.
 *   open         - start the battle, `by` opens with the floor
 *   startTalking - the floor-holder began speaking (cancels the shot-clock)
 *   yield        - the floor-holder passes the mic (free, no steal)
 *   interrupt    - `by` steals the floor from the opponent (costs a token)
 *   endEarly     - the floor-holder ends the battle when the opponent is out of
 *                  time (skips draining a banked clock in dead air)
 *   tick         - time passes; evaluates the shot-clock and the end condition
 * Returns a new state; the input is never mutated.
 */
function reduce(state, ev) {
  const s = cloneState(state);
  if (s.status === "live") settle(s, ev.atMs);
  if (s.status === "ended") return s;

  // Resolve a pending interrupt. The interrupter already spent a token and gave
  // the holder a grace window to finish their line; once it elapses the floor
  // passes to them. If the floor already moved on its own (the holder ran out
  // or yielded - takeFloor clears pending) this never fires. Runs before the
  // event so a `tick` (fired every ~300ms live) is what lands the hand-off.
  if (s.pendingBy != null && s.status === "live") {
    const target = other(s, s.pendingBy);
    if (s.floor !== target) {
      s.pendingBy = null; // floor already left the person being cut into
      s.pendingAtMs = null;
    } else if (ev.atMs - s.pendingAtMs >= s.config.graceMs) {
      if (s.remaining[s.pendingBy] > 0) {
        takeFloor(s, s.pendingBy, ev.atMs); // grace elapsed -> cut in (clears pending)
      } else {
        s.pendingBy = null;
        s.pendingAtMs = null;
      }
    }
  }

  switch (ev.type) {
    case "open":
      if (s.status !== "pending" || !s.players.includes(ev.by)) return s;
      s.status = "live";
      takeFloor(s, ev.by, ev.atMs);
      return s;

    case "startTalking":
      if (s.floor === ev.by) s.talking = true;
      return s;

    case "yield": {
      if (s.floor !== ev.by) return s; // only the holder can yield
      const opp = other(s, ev.by);
      if (s.remaining[opp] > 0) takeFloor(s, opp, ev.atMs);
      else {
        // Opponent is out of time; keep the floor but reset the shot-clock.
        s.talking = false;
        s.floorTakenMs = ev.atMs;
      }
      return s;
    }

    case "interrupt": {
      const opp = other(s, ev.by);
      if (s.floor !== opp) return s; // can only cut in on the holder
      if (s.steals[ev.by] <= 0) return s; // out of steals
      if (s.remaining[ev.by] <= 0) return s; // no time to take the floor with
      if (s.pendingBy != null) return s; // an interrupt is already winding up
      s.steals[ev.by] -= 1; // the token is spent the instant you commit
      if (s.config.graceMs > 0) {
        // Commit, but let the holder land their line - the floor passes when
        // the grace elapses (resolved above on the next tick). The UI flashes
        // the holder's clock + buzzes them so the beat has teeth.
        s.pendingBy = ev.by;
        s.pendingAtMs = ev.atMs;
      } else {
        takeFloor(s, ev.by, ev.atMs); // graceMs 0 -> instant steal
      }
      return s;
    }

    case "endEarly": {
      // "I'm done" - the floor-holder ends the battle instead of draining a
      // banked clock in dead air. Only valid when the OPPONENT is already out
      // of time (otherwise they still deserve their turn - yield passes the
      // floor instead). Nothing is conceded: the holder's clock would drain to
      // zero and end the battle anyway, so this just skips the dead air.
      if (s.floor !== ev.by) return s;
      if (s.remaining[other(s, ev.by)] > 0) return s;
      s.status = "ended";
      s.endReason = "done";
      s.floor = null;
      return s;
    }

    case "tick": {
      if (s.floor != null && !s.talking && s.floorTakenMs != null &&
          ev.atMs - s.floorTakenMs >= s.config.shotClockMs) {
        const opp = other(s, s.floor);
        if (s.remaining[opp] > 0) takeFloor(s, opp, ev.atMs);
      }
      if (s.remaining[s.players[0]] === 0 && s.remaining[s.players[1]] === 0) {
        s.status = "ended";
        s.endReason = "time";
        s.floor = null;
      }
      return s;
    }

    default:
      return s;
  }
}

/** The player whose mic is muted right now (the non-holder), or null. */
function mutedPlayer(s) {
  return s.status === "live" && s.floor != null ? other(s, s.floor) : null;
}

function isOver(s) {
  return s.status === "ended";
}

module.exports = {
  createBattle,
  reduce,
  settle,
  mutedPlayer,
  isOver,
  resolveGraceMs,
  DEFAULTS,
  GRACE_DEFAULT_MS,
  GRACE_MAX_MS,
};
