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

enum MsEvent { open, startTalking, yield, interrupt, endEarly, tick }

enum MsStatus { pending, live, ended }

class MainStageBattleConfig {
  const MainStageBattleConfig({
    this.turnMs = kMainStageTurnMs,
    this.interrupts = kMainStageInterrupts,
    this.shotClockMs = kMainStageShotClockMs,
  });
  final int turnMs;
  final int interrupts;
  final int shotClockMs;
}

class MainStageBattleState {
  MainStageBattleState._(this.players, this.config)
      : remaining = {},
        steals = {};

  /// A fresh battle between two distinct players.
  factory MainStageBattleState.create(
    List<String> players, {
    MainStageBattleConfig config = const MainStageBattleConfig(),
  }) {
    if (players.length != 2 || players[0] == players[1]) {
      throw ArgumentError('createBattle needs two distinct players');
    }
    final s = MainStageBattleState._([players[0], players[1]], config);
    s.remaining[players[0]] = config.turnMs;
    s.remaining[players[1]] = config.turnMs;
    s.steals[players[0]] = config.interrupts;
    s.steals[players[1]] = config.interrupts;
    return s;
  }

  final List<String> players;
  final MainStageBattleConfig config;
  final Map<String, int> remaining; // ms left per player
  final Map<String, int> steals; // interrupt tokens left per player
  String? floor; // who holds the mic
  bool talking = false; // has the floor-holder started talking (shot-clock)
  int? floorTakenMs;
  int? lastMs; // when the floor-holder's clock last settled
  MsStatus status = MsStatus.pending;
  String? endReason;

  String _other(String p) => players[0] == p ? players[1] : players[0];

  MainStageBattleState _clone() {
    final s = MainStageBattleState._(players, config);
    s.remaining.addAll(remaining);
    s.steals.addAll(steals);
    s.floor = floor;
    s.talking = talking;
    s.floorTakenMs = floorTakenMs;
    s.lastMs = lastMs;
    s.status = status;
    s.endReason = endReason;
    return s;
  }

  void _takeFloor(String p, int atMs) {
    floor = p;
    talking = false;
    floorTakenMs = atMs;
    lastMs = atMs;
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
        },
        'remaining': remaining,
        'steals': steals,
        'floor': floor,
        'talking': talking,
        'floorTakenMs': floorTakenMs,
        'lastMs': lastMs,
        'status': status.name,
        'endReason': endReason,
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
        interrupts: (cfg['interrupts'] as num?)?.toInt() ?? kMainStageInterrupts,
        shotClockMs:
            (cfg['shotClockMs'] as num?)?.toInt() ?? kMainStageShotClockMs,
      ),
    );
    (m['remaining'] as Map).forEach((k, v) {
      s.remaining[k as String] = (v as num).toInt();
    });
    (m['steals'] as Map).forEach((k, v) {
      s.steals[k as String] = (v as num).toInt();
    });
    s.floor = m['floor'] as String?;
    s.talking = m['talking'] == true;
    s.floorTakenMs = (m['floorTakenMs'] as num?)?.toInt();
    s.lastMs = (m['lastMs'] as num?)?.toInt();
    s.status = MsStatus.values.byName((m['status'] as String?) ?? 'pending');
    s.endReason = m['endReason'] as String?;
    return s;
  }

  /// The player whose mic is muted right now (the non-holder), or null.
  String? get mutedPlayer =>
      status == MsStatus.live && floor != null ? _other(floor!) : null;

  bool get isOver => status == MsStatus.ended;

  /// Apply one event, returning a NEW state; the input is never mutated.
  MainStageBattleState reduce(MsEvent type, {String? by, required int atMs}) {
    final s = _clone();
    if (s.status == MsStatus.live) s._settle(atMs);
    if (s.status == MsStatus.ended) return s;

    switch (type) {
      case MsEvent.open:
        if (s.status != MsStatus.pending ||
            by == null ||
            !s.players.contains(by)) {
          return s;
        }
        s.status = MsStatus.live;
        s._takeFloor(by, atMs);
        return s;

      case MsEvent.startTalking:
        if (s.floor == by) s.talking = true;
        return s;

      case MsEvent.yield:
        if (by == null || s.floor != by) return s; // only the holder can yield
        final opp = s._other(by);
        if (s.remaining[opp]! > 0) {
          s._takeFloor(opp, atMs);
        } else {
          // Opponent out of time; keep the floor, reset the shot-clock.
          s.talking = false;
          s.floorTakenMs = atMs;
        }
        return s;

      case MsEvent.interrupt:
        if (by == null) return s;
        final opp = s._other(by);
        if (s.floor != opp) return s; // can only cut in on the holder
        if ((s.steals[by] ?? 0) <= 0) return s; // out of steals
        if ((s.remaining[by] ?? 0) <= 0) return s; // no time to take the floor
        s.steals[by] = s.steals[by]! - 1;
        s._takeFloor(by, atMs);
        return s;

      case MsEvent.endEarly:
        // "I'm done" - the floor-holder ends the battle instead of draining a
        // banked clock in dead air. Only valid when the OPPONENT is already out
        // of time (otherwise they still deserve their turn - use yield to pass
        // the floor). This is the "let the last player end before his time is
        // up" escape: nothing is conceded, since the holder's clock would drain
        // to zero and end the battle anyway.
        if (by == null || s.floor != by) return s;
        if (s.remaining[s._other(by)]! > 0) return s;
        s.status = MsStatus.ended;
        s.endReason = 'done';
        s.floor = null;
        return s;

      case MsEvent.tick:
        if (s.floor != null &&
            !s.talking &&
            s.floorTakenMs != null &&
            atMs - s.floorTakenMs! >= s.config.shotClockMs) {
          final opp = s._other(s.floor!);
          if (s.remaining[opp]! > 0) s._takeFloor(opp, atMs);
        }
        if (s.remaining[s.players[0]] == 0 &&
            s.remaining[s.players[1]] == 0) {
          s.status = MsStatus.ended;
          s.endReason = 'time';
          s.floor = null;
        }
        return s;
    }
  }
}
