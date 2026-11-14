/// Main Stage battle format - the chess-clock + interrupts state machine, in
/// Dart. A faithful port of functions/mainStageBattle.js that MUST stay in step
/// with it (the JS copy is the tested reference; this is what runs live,
/// host-driven and broadcast over the Agora data stream - the same peer-to-peer
/// model the normal match turn-sync uses). See the tournament decision record's
/// "Main Stage battle format" section.
///
///  - Two chess clocks: each player has a talk budget ([turnMs], default 60s)
///    that ticks ONLY while they hold the floor; unused time banks.
///  - Yielding is FREE: stop and the floor passes to the opponent.
///  - 2 interrupts ("steals") each: cut in while the opponent holds the floor.
///    An interrupt spends a token AND starts your own clock.
///  - A short shot-clock: hold the floor without talking too long and it
///    bounces to the opponent, so nobody can stall in a standoff.
///  - The battle ends when both clocks hit zero.
///
/// Deterministic: a reducer over events carrying an absolute `atMs`, so it is
/// exercised with plain Dart - no Agora, no real clock. [reduce] never mutates
/// its input; it clones and mutates the clone, like the JS.
library;

const int kMainStageTurnMs = 60 * 1000;
const int kMainStageInterrupts = 2;
const int kMainStageShotClockMs = 7 * 1000;

/// Grace window before an interrupt takes the floor, so the person being cut
/// into gets a beat to land their line. 0 = instant (the pure-engine default,
/// mirroring the JS DEFAULTS, which the existing tests assert). The real battle
/// runs the server-stamped value (product default 1.5s, console-tunable); the
/// service layer falls back to [kMainStageGraceDefaultMs] if the stamp is
/// missing.
const int kMainStageGraceMs = 0;
const int kMainStageGraceDefaultMs = 1500;

/// How much the "+5 Seconds" loadout ability adds to the actor's clock (regular
/// matches only; the finals never fire [MsEvent.extend]). Mirrors
/// mainStageBattle.js's EXTEND_MS.
const int kMainStageExtendMs = 5 * 1000;

/// Silent passes in a row that end a battle as dead air (see
/// [MainStageBattleState.silentPasses]).
const int kDeadAirSilences = 3;

enum MsEvent { open, startTalking, yield, interrupt, extend, endEarly, tick }

enum MsStatus { pending, live, ended }

class MainStageBattleConfig {
  const MainStageBattleConfig({
    this.turnMs = kMainStageTurnMs,
    this.interrupts = kMainStageInterrupts,
    this.shotClockMs = kMainStageShotClockMs,
    this.graceMs = kMainStageGraceMs,
    this.minHoldMs = 0,
    this.turnCount = 0,
  });

  /// RAPID ROUNDS (2026-11-14, regular/friend battles): when > 0 the battle
  /// is this many alternating TURNS (3 rounds = 6), each a fresh [turnMs]
  /// clock. Unused time never carries over; a turn ends on a yield ("Done" /
  /// silence) or when its clock runs out, and the battle ends after the last
  /// turn. No shot clock (the holder's phone handles silence). 0 = the Main
  /// Stage chess clock (banked time, interrupts, shot clock).
  final int turnCount;
  bool get isRounds => turnCount > 0;
  final int turnMs;
  final int interrupts;
  final int shotClockMs;
  final int graceMs;

  /// Regular/friend battles: once you take the floor, Yield is refused for
  /// this long, so two players can't ping-pong the mic and drain both clocks
  /// without saying anything. 0 (the default, and the Main Stage) = off.
  final int minHoldMs;
}

class MainStageBattleState {
  MainStageBattleState._(this.players, this.config)
    : remaining = {},
      steals = {},
      instantSteals = {},
      extendTokens = {};

  /// A fresh battle between two distinct players.
  ///
  /// [stealsByPlayer]/[extendsByPlayer] let a REGULAR match seed per-player
  /// interrupt/extend tokens from the paid loadout. Omitted (the finals), both
  /// players get the symmetric [config.interrupts] steals and zero extends, so
  /// Main Stage is unaffected. Mirrors mainStageBattle.js's `seed` argument.
  factory MainStageBattleState.create(
    List<String> players, {
    MainStageBattleConfig config = const MainStageBattleConfig(),
    Map<String, int>? stealsByPlayer,
    Map<String, int>? instantStealsByPlayer,
    Map<String, int>? extendsByPlayer,
  }) {
    if (players.length != 2 || players[0] == players[1]) {
      throw ArgumentError('createBattle needs two distinct players');
    }
    final s = MainStageBattleState._([players[0], players[1]], config);
    for (final p in players) {
      s.remaining[p] = config.turnMs;
      s.steals[p] = (stealsByPlayer?[p] ?? config.interrupts).clamp(0, 1 << 20);
      s.instantSteals[p] = (instantStealsByPlayer?[p] ?? 0).clamp(0, 1 << 20);
      s.extendTokens[p] = (extendsByPlayer?[p] ?? 0).clamp(0, 1 << 20);
    }
    return s;
  }

  final List<String> players;
  final MainStageBattleConfig config;
  final Map<String, int> remaining; // ms left per player
  final Map<String, int> steals; // graced interrupt tokens left per player
  final Map<String, int> instantSteals; // no-grace interrupt tokens per player
  final Map<String, int> extendTokens; // +5s tokens left per player
  String? floor; // who holds the mic
  bool talking = false; // has the floor-holder started talking (shot-clock)
  int? floorTakenMs;
  int? lastMs; // when the floor-holder's clock last settled
  String? pendingBy; // an interrupt committed, in its grace window (who cut in)
  int? pendingAtMs; // when that interrupt was fired
  MsStatus status = MsStatus.pending;
  String? endReason;

  /// Passes in a row by a holder who never said a word (regular battles'
  /// silence auto-pass). Any pass with speech, or an interrupt, resets it;
  /// [kDeadAirSilences] in a row ends the battle as dead air.
  int silentPasses = 0;

  /// Rapid rounds: how many turns have started (1-based; 0 before open).
  int turn = 0;

  /// The round the current turn belongs to (1, 1, 2, 2, 3, 3).
  int get round => turn <= 0 ? 0 : (turn + 1) ~/ 2;
  int get roundCount => config.turnCount ~/ 2;

  /// Rapid rounds: this is the battle's final turn (the closer).
  bool get isLastTurn => config.isRounds && turn >= config.turnCount;

  String _other(String p) => players[0] == p ? players[1] : players[0];

  MainStageBattleState _clone() {
    final s = MainStageBattleState._(players, config);
    s.remaining.addAll(remaining);
    s.steals.addAll(steals);
    s.instantSteals.addAll(instantSteals);
    s.extendTokens.addAll(extendTokens);
    s.floor = floor;
    s.talking = talking;
    s.floorTakenMs = floorTakenMs;
    s.lastMs = lastMs;
    s.pendingBy = pendingBy;
    s.pendingAtMs = pendingAtMs;
    s.status = status;
    s.endReason = endReason;
    s.silentPasses = silentPasses;
    s.turn = turn;
    return s;
  }

  /// Rapid rounds: hand [p] the next turn with a fresh clock, or end the
  /// battle if every turn has been taken.
  void _nextTurn(String p, int atMs) {
    if (turn >= config.turnCount) {
      status = MsStatus.ended;
      endReason = 'time';
      floor = null;
      return;
    }
    turn++;
    remaining[p] = config.turnMs;
    _takeFloor(p, atMs);
  }

  // Any floor change cancels/consumes a pending interrupt - the universal rule
  // that keeps the pending state from surviving a floor it no longer describes.
  void _takeFloor(String p, int atMs) {
    floor = p;
    talking = false;
    floorTakenMs = atMs;
    lastMs = atMs;
    pendingBy = null;
    pendingAtMs = null;
  }

  void _settle(int atMs) {
    if (status != MsStatus.live || floor == null || lastMs == null) return;
    final f = floor!;
    final elapsed = (atMs - lastMs!) < 0 ? 0 : atMs - lastMs!;
    final left = remaining[f]! - elapsed;
    remaining[f] = left < 0 ? 0 : left;
    lastMs = atMs;
    if (remaining[f] == 0) {
      final opp = _other(f);
      if (config.isRounds) {
        _nextTurn(opp, atMs); // turn over: their go (or the battle ends)
        return;
      }
      if (remaining[opp]! > 0) {
        _takeFloor(opp, atMs);
      } else {
        status = MsStatus.ended;
        endReason = 'time';
        floor = null;
      }
    }
  }

  /// Serialize for broadcasting the authoritative state host -> guest over the
  /// Agora data stream (sendMatchMessage takes a Map). Config is included so a
  /// guest that somehow created its state with different timings still renders
  /// the host's truth.
  Map<String, dynamic> toMap() => {
    'players': players,
    'config': {
      'turnMs': config.turnMs,
      'interrupts': config.interrupts,
      'shotClockMs': config.shotClockMs,
      'graceMs': config.graceMs,
      'minHoldMs': config.minHoldMs,
      'turnCount': config.turnCount,
    },
    'remaining': remaining,
    'steals': steals,
    'instantSteals': instantSteals,
    'extends': extendTokens,
    'floor': floor,
    'talking': talking,
    'floorTakenMs': floorTakenMs,
    'lastMs': lastMs,
    'pendingBy': pendingBy,
    'pendingAtMs': pendingAtMs,
    'status': status.name,
    'endReason': endReason,
    'silentPasses': silentPasses,
    'turn': turn,
  };

  /// Rebuild a state a host broadcast. Tolerant of the JSON round-trip
  /// (num->int, dynamic maps) the data channel imposes.
  static MainStageBattleState fromMap(Map<String, dynamic> m) {
    final players = (m['players'] as List).cast<String>();
    final cfg = (m['config'] as Map?) ?? const {};
    final s = MainStageBattleState._(
      [players[0], players[1]],
      MainStageBattleConfig(
        turnMs: (cfg['turnMs'] as num?)?.toInt() ?? kMainStageTurnMs,
        interrupts:
            (cfg['interrupts'] as num?)?.toInt() ?? kMainStageInterrupts,
        shotClockMs:
            (cfg['shotClockMs'] as num?)?.toInt() ?? kMainStageShotClockMs,
        graceMs: (cfg['graceMs'] as num?)?.toInt() ?? kMainStageGraceMs,
        minHoldMs: (cfg['minHoldMs'] as num?)?.toInt() ?? 0,
        turnCount: (cfg['turnCount'] as num?)?.toInt() ?? 0,
      ),
    );
    (m['remaining'] as Map).forEach((k, v) {
      s.remaining[k as String] = (v as num).toInt();
    });
    (m['steals'] as Map).forEach((k, v) {
      s.steals[k as String] = (v as num).toInt();
    });
    (m['instantSteals'] as Map?)?.forEach((k, v) {
      s.instantSteals[k as String] = (v as num).toInt();
    });
    (m['extends'] as Map?)?.forEach((k, v) {
      s.extendTokens[k as String] = (v as num).toInt();
    });
    s.floor = m['floor'] as String?;
    s.talking = m['talking'] == true;
    s.floorTakenMs = (m['floorTakenMs'] as num?)?.toInt();
    s.lastMs = (m['lastMs'] as num?)?.toInt();
    s.pendingBy = m['pendingBy'] as String?;
    s.pendingAtMs = (m['pendingAtMs'] as num?)?.toInt();
    s.status = MsStatus.values.byName((m['status'] as String?) ?? 'pending');
    s.endReason = m['endReason'] as String?;
    s.silentPasses = (m['silentPasses'] as num?)?.toInt() ?? 0;
    s.turn = (m['turn'] as num?)?.toInt() ?? 0;
    return s;
  }

  /// The player whose mic is muted right now (the non-holder), or null.
  String? get mutedPlayer =>
      status == MsStatus.live && floor != null ? _other(floor!) : null;

  bool get isOver => status == MsStatus.ended;

  /// Apply one event, returning a NEW state; the input is never mutated.
  /// [instant] (only meaningful for [MsEvent.interrupt]) uses the no-grace
  /// instant-interrupt token pool instead of the graced one.
  MainStageBattleState reduce(
    MsEvent type, {
    String? by,
    required int atMs,
    bool instant = false,
    bool silent = false,
  }) {
    final s = _clone();
    if (s.status == MsStatus.live) s._settle(atMs);
    if (s.status == MsStatus.ended) return s;

    // Resolve a pending interrupt: once the grace elapses the interrupter takes
    // the floor. If the floor already moved on its own (_takeFloor clears
    // pending) this never fires. Runs before the event so a live `tick` lands
    // the hand-off. Mirrors mainStageBattle.js.
    if (s.pendingBy != null && s.status == MsStatus.live) {
      final target = s._other(s.pendingBy!);
      if (s.floor != target) {
        s.pendingBy = null;
        s.pendingAtMs = null;
      } else if (atMs - s.pendingAtMs! >= s.config.graceMs) {
        if ((s.remaining[s.pendingBy] ?? 0) > 0) {
          s._takeFloor(s.pendingBy!, atMs); // cut in (clears pending)
        } else {
          s.pendingBy = null;
          s.pendingAtMs = null;
        }
      }
    }

    switch (type) {
      case MsEvent.open:
        if (s.status != MsStatus.pending ||
            by == null ||
            !s.players.contains(by)) {
          return s;
        }
        s.status = MsStatus.live;
        if (s.config.isRounds) {
          s._nextTurn(by, atMs);
        } else {
          s._takeFloor(by, atMs);
        }
        return s;

      case MsEvent.startTalking:
        if (s.floor == by) s.talking = true;
        return s;

      case MsEvent.yield:
        if (by == null || s.floor != by) return s; // only the holder can yield
        if (s.config.minHoldMs > 0 &&
            s.floorTakenMs != null &&
            atMs - s.floorTakenMs! < s.config.minHoldMs) {
          return s; // too soon - hold the floor a beat first
        }
        // DEAD AIR (2026-11-12, developer's rule): A silent, B silent, A
        // silent again = the battle ends. Any pass with speech resets it.
        if (silent) {
          s.silentPasses++;
          if (s.silentPasses >= kDeadAirSilences) {
            s.status = MsStatus.ended;
            s.endReason = 'dead_air';
            s.floor = null;
            return s;
          }
        } else {
          s.silentPasses = 0;
        }
        final opp = s._other(by);
        if (s.config.isRounds) {
          s._nextTurn(opp, atMs); // "Done": their turn, or the battle ends
          return s;
        }
        if (s.remaining[opp]! > 0) {
          s._takeFloor(opp, atMs);
        } else {
          // Opponent out of time; keep the floor, reset the shot-clock.
          s.talking = false;
          s.floorTakenMs = atMs;
        }
        return s;

      case MsEvent.interrupt:
        // Rapid rounds have no interrupts (turns are fixed).
        if (by == null || s.config.isRounds) return s;
        final opp = s._other(by);
        if (s.floor != opp) return s; // can only cut in on the holder
        if ((s.remaining[by] ?? 0) <= 0) return s; // no time to take the floor
        if (s.pendingBy != null) return s; // an interrupt is already winding up
        s.silentPasses = 0; // someone wanted the mic - not dead air
        if (instant) {
          // The "Instant Interrupt" ability: no grace, separate token pool.
          if ((s.instantSteals[by] ?? 0) <= 0) return s;
          s.instantSteals[by] = s.instantSteals[by]! - 1;
          s._takeFloor(by, atMs);
          return s;
        }
        if ((s.steals[by] ?? 0) <= 0) return s; // out of graced steals
        s.steals[by] = s.steals[by]! - 1; // token spent the instant you commit
        if (s.config.graceMs > 0) {
          // Commit, but let the holder land their line - the floor passes when
          // the grace elapses. The UI flashes + buzzes the holder meanwhile.
          s.pendingBy = by;
          s.pendingAtMs = atMs;
        } else {
          s._takeFloor(by, atMs); // graceMs 0 -> instant steal
        }
        return s;

      case MsEvent.extend:
        // "+5 Seconds" loadout ability (regular matches). The floor-holder adds
        // kMainStageExtendMs to their own clock; if a steal is winding up
        // against them, the cut-in is deferred by the same amount, so they get
        // the five seconds BEFORE the opponent takes over. Mirrors
        // mainStageBattle.js.
        if (by == null || s.floor != by) return s;
        if ((s.extendTokens[by] ?? 0) <= 0) return s;
        s.extendTokens[by] = s.extendTokens[by]! - 1;
        s.remaining[by] = (s.remaining[by] ?? 0) + kMainStageExtendMs;
        if (s.pendingBy != null && s.pendingBy == s._other(by)) {
          s.pendingAtMs = (s.pendingAtMs ?? atMs) + kMainStageExtendMs;
        }
        return s;

      case MsEvent.endEarly:
        // "I'm done" - the floor-holder ends the battle instead of draining a
        // banked clock in dead air. Only valid when the OPPONENT is already out
        // of time (otherwise they still deserve their turn - use yield to pass
        // the floor). This is the "let the last player end before his time is
        // up" escape: nothing is conceded, since the holder's clock would drain
        // to zero and end the battle anyway.
        if (by == null || s.floor != by) return s;
        if (s.config.isRounds
            ? !s.isLastTurn
            : s.remaining[s._other(by)]! > 0) {
          return s;
        }
        s.status = MsStatus.ended;
        s.endReason = 'done';
        s.floor = null;
        return s;

      case MsEvent.tick:
        if (s.config.isRounds) return s; // turn time-outs settle above
        if (s.floor != null &&
            !s.talking &&
            s.floorTakenMs != null &&
            atMs - s.floorTakenMs! >= s.config.shotClockMs) {
          final opp = s._other(s.floor!);
          if (s.remaining[opp]! > 0) s._takeFloor(opp, atMs);
        }
        if (s.remaining[s.players[0]] == 0 && s.remaining[s.players[1]] == 0) {
          s.status = MsStatus.ended;
          s.endReason = 'time';
          s.floor = null;
        }
        return s;
    }
  }
}
