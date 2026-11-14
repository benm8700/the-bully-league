import 'package:flutter_test/flutter_test.dart';
import 'package:bully_league/core/main_stage_battle.dart';

/// Mirrors functions/test/mainStageBattle.test.js - the chess-clock + interrupt
/// rules are a nightmare to verify on two live devices but trivial to pin here,
/// and this Dart port is what actually runs the battle, so it has to match the
/// JS reference exactly.
void main() {
  MainStageBattleState open() => MainStageBattleState.create(['a', 'b'])
      .reduce(MsEvent.open, by: 'a', atMs: 0);

  test('create needs two distinct players', () {
    expect(() => MainStageBattleState.create(['a']), throwsArgumentError);
    expect(() => MainStageBattleState.create(['a', 'a']), throwsArgumentError);
    final s = MainStageBattleState.create(['a', 'b']);
    expect(s.remaining['a'], kMainStageTurnMs);
    expect(s.steals['b'], kMainStageInterrupts);
    expect(s.status, MsStatus.pending);
  });

  test('open starts the battle with the opener on the floor', () {
    final s = open();
    expect(s.status, MsStatus.live);
    expect(s.floor, 'a');
    expect(s.mutedPlayer, 'b'); // the non-holder is muted
    expect(s.talking, false);
  });

  test('startTalking cancels the shot-clock for the holder only', () {
    var s = open();
    s = s.reduce(MsEvent.startTalking, by: 'b', atMs: 100); // not the holder
    expect(s.talking, false);
    s = s.reduce(MsEvent.startTalking, by: 'a', atMs: 100);
    expect(s.talking, true);
  });

  test('a tick deducts only the floor-holder\'s clock', () {
    var s = open();
    s = s.reduce(MsEvent.startTalking, by: 'a', atMs: 0);
    s = s.reduce(MsEvent.tick, atMs: 5000);
    expect(s.remaining['a'], kMainStageTurnMs - 5000);
    expect(s.remaining['b'], kMainStageTurnMs); // opponent untouched
  });

  test('yield is free, passes the floor, and banks unused time', () {
    var s = open();
    s = s.reduce(MsEvent.startTalking, by: 'a', atMs: 0);
    s = s.reduce(MsEvent.yield, by: 'a', atMs: 5000);
    expect(s.floor, 'b');
    expect(s.steals['a'], kMainStageInterrupts); // no token spent on a yield
    expect(s.remaining['a'], kMainStageTurnMs - 5000); // banked for later
    expect(s.remaining['b'], kMainStageTurnMs);
  });

  test('only the holder can yield', () {
    var s = open();
    s = s.reduce(MsEvent.yield, by: 'b', atMs: 1000);
    expect(s.floor, 'a'); // unchanged
  });

  test('interrupt spends a token, takes the floor, starts your own clock', () {
    var s = open(); // a holds
    s = s.reduce(MsEvent.startTalking, by: 'a', atMs: 0);
    s = s.reduce(MsEvent.interrupt, by: 'b', atMs: 4000);
    expect(s.floor, 'b');
    expect(s.steals['b'], kMainStageInterrupts - 1);
    expect(s.remaining['a'], kMainStageTurnMs - 4000); // a billed up to the cut
    expect(s.talking, false); // b must start talking (shot-clock reset)
    // now b's clock runs
    s = s.reduce(MsEvent.tick, atMs: 7000);
    expect(s.remaining['b'], kMainStageTurnMs - 3000);
  });

  test('cannot interrupt while you already hold the floor', () {
    var s = open(); // a holds
    s = s.reduce(MsEvent.interrupt, by: 'a', atMs: 1000);
    expect(s.floor, 'a');
    expect(s.steals['a'], kMainStageInterrupts); // no token spent
  });

  test('out of steals: interrupt is a no-op', () {
    var s = open(); // a holds
    // b spends both steals bouncing the floor back and forth
    s = s.reduce(MsEvent.interrupt, by: 'b', atMs: 1000); // b floor
    s = s.reduce(MsEvent.yield, by: 'b', atMs: 1100); // back to a
    s = s.reduce(MsEvent.interrupt, by: 'b', atMs: 1200); // b floor (2nd token)
    s = s.reduce(MsEvent.yield, by: 'b', atMs: 1300); // back to a
    expect(s.steals['b'], 0);
    final floorBefore = s.floor;
    s = s.reduce(MsEvent.interrupt, by: 'b', atMs: 1400); // no tokens left
    expect(s.floor, floorBefore); // unchanged
  });

  test('shot-clock bounces the floor if the holder never starts talking', () {
    var s = open(); // a holds at t=0, not talking
    s = s.reduce(MsEvent.tick, atMs: kMainStageShotClockMs); // 7s silent
    expect(s.floor, 'b'); // bounced
  });

  test('talking before the shot-clock prevents the bounce', () {
    var s = open();
    s = s.reduce(MsEvent.startTalking, by: 'a', atMs: 1000);
    s = s.reduce(MsEvent.tick, atMs: kMainStageShotClockMs + 1000);
    expect(s.floor, 'a'); // still a's, they're talking
  });

  test('running a clock to zero passes the floor to the banked opponent', () {
    var s = open();
    s = s.reduce(MsEvent.startTalking, by: 'a', atMs: 0);
    s = s.reduce(MsEvent.tick, atMs: kMainStageTurnMs); // a spends all 60s
    expect(s.remaining['a'], 0);
    expect(s.floor, 'b'); // b still has time
    expect(s.status, MsStatus.live);
  });

  test('battle ends when both clocks hit zero', () {
    var s = open();
    s = s.reduce(MsEvent.startTalking, by: 'a', atMs: 0);
    s = s.reduce(MsEvent.tick, atMs: kMainStageTurnMs); // a -> 0, floor to b
    s = s.reduce(MsEvent.startTalking, by: 'b', atMs: kMainStageTurnMs);
    // b burns their 60s too
    s = s.reduce(MsEvent.tick, atMs: kMainStageTurnMs * 2);
    expect(s.remaining['b'], 0);
    expect(s.isOver, true);
    expect(s.endReason, 'time');
    expect(s.floor, isNull);
    expect(s.mutedPlayer, isNull);
  });

  test('events after the battle ends are ignored', () {
    var s = open();
    s = s.reduce(MsEvent.startTalking, by: 'a', atMs: 0);
    s = s.reduce(MsEvent.tick, atMs: kMainStageTurnMs);
    s = s.reduce(MsEvent.startTalking, by: 'b', atMs: kMainStageTurnMs);
    s = s.reduce(MsEvent.tick, atMs: kMainStageTurnMs * 2);
    expect(s.isOver, true);
    final after = s.reduce(MsEvent.interrupt, by: 'a', atMs: kMainStageTurnMs * 3);
    expect(after.isOver, true);
    expect(after.floor, isNull);
  });

  test('toMap/fromMap round-trips through a JSON-like data channel', () {
    var s = open();
    s = s.reduce(MsEvent.startTalking, by: 'a', atMs: 0);
    s = s.reduce(MsEvent.interrupt, by: 'b', atMs: 4000); // b floor, token spent
    s = s.reduce(MsEvent.tick, atMs: 7000);
    // Simulate the num->/dynamic coercion the Agora data channel imposes.
    final wire = <String, dynamic>{
      ...s.toMap(),
      'remaining': {for (final e in s.remaining.entries) e.key: e.value + 0.0},
    };
    final r = MainStageBattleState.fromMap(wire);
    expect(r.floor, s.floor);
    expect(r.talking, s.talking);
    expect(r.status, s.status);
    expect(r.remaining['a'], s.remaining['a']);
    expect(r.remaining['b'], s.remaining['b']);
    expect(r.steals['b'], s.steals['b']);
    expect(r.config.turnMs, s.config.turnMs);
    expect(r.mutedPlayer, s.mutedPlayer);
  });

  test('reduce never mutates the input state', () {
    final s0 = open();
    final before = s0.remaining['a'];
    s0.reduce(MsEvent.startTalking, by: 'a', atMs: 0);
    s0.reduce(MsEvent.tick, atMs: 5000);
    expect(s0.remaining['a'], before); // original untouched
    expect(s0.floor, 'a');
  });

  // --- interrupt grace window (mirrors the JS grace tests) ---
  group('interrupt grace', () {
    MainStageBattleState openGrace(int graceMs) =>
        MainStageBattleState.create(['a', 'b'],
                config: MainStageBattleConfig(graceMs: graceMs))
            .reduce(MsEvent.open, by: 'a', atMs: 0)
            .reduce(MsEvent.startTalking, by: 'a', atMs: 0);

    test('an interrupt commits (spends the token) but waits out the grace', () {
      final s = openGrace(1500).reduce(MsEvent.interrupt, by: 'b', atMs: 3000);
      expect(s.floor, 'a'); // a keeps the floor during the beat
      expect(s.pendingBy, 'b');
      expect(s.steals['b'], kMainStageInterrupts - 1);
      expect(s.mutedPlayer, 'b');
    });

    test('the floor passes once the grace elapses', () {
      var s = openGrace(1500).reduce(MsEvent.interrupt, by: 'b', atMs: 3000);
      s = s.reduce(MsEvent.tick, atMs: 4000); // mid-grace
      expect(s.floor, 'a');
      s = s.reduce(MsEvent.tick, atMs: 4600); // grace up
      expect(s.floor, 'b');
      expect(s.pendingBy, isNull);
      expect(s.remaining['a'], kMainStageTurnMs - 4600); // billed to the cut
    });

    test('yielding during the grace hands straight to the interrupter', () {
      var s = openGrace(1500).reduce(MsEvent.interrupt, by: 'b', atMs: 2000);
      s = s.reduce(MsEvent.yield, by: 'a', atMs: 2500);
      expect(s.floor, 'b');
      expect(s.pendingBy, isNull);
      expect(s.steals['b'], kMainStageInterrupts - 1);
    });

    test('a second interrupt while one is winding up is a no-op', () {
      var s = openGrace(1500).reduce(MsEvent.interrupt, by: 'b', atMs: 1000);
      s = s.reduce(MsEvent.interrupt, by: 'b', atMs: 1200);
      expect(s.pendingBy, 'b');
      expect(s.steals['b'], kMainStageInterrupts - 1); // no double-spend
      expect(s.floor, 'a');
    });

    test('graceMs 0 interrupts instantly (engine default)', () {
      final s = openGrace(0).reduce(MsEvent.interrupt, by: 'b', atMs: 3000);
      expect(s.floor, 'b');
      expect(s.pendingBy, isNull);
    });

    test('pendingBy round-trips through toMap/fromMap', () {
      final s = openGrace(1500).reduce(MsEvent.interrupt, by: 'b', atMs: 3000);
      final r = MainStageBattleState.fromMap(s.toMap());
      expect(r.pendingBy, 'b');
      expect(r.pendingAtMs, 3000);
      expect(r.config.graceMs, 1500);
    });
  });

  group('loadout seeding + extend (regular matches)', () {
    test('per-player steals/extends seed; no seed stays symmetric', () {
      final seeded = MainStageBattleState.create(
        ['a', 'b'],
        config: const MainStageBattleConfig(interrupts: 0),
        stealsByPlayer: {'a': 2, 'b': 0},
        extendsByPlayer: {'a': 1, 'b': 3},
      );
      expect(seeded.steals['a'], 2);
      expect(seeded.steals['b'], 0);
      expect(seeded.extendTokens['a'], 1);
      expect(seeded.extendTokens['b'], 3);
      final finals = MainStageBattleState.create(['a', 'b']);
      expect(finals.steals['a'], kMainStageInterrupts);
      expect(finals.extendTokens['a'], 0);
    });

    test('extend adds 5s to the holder and spends a token', () {
      var s = MainStageBattleState.create(['a', 'b'],
          config: const MainStageBattleConfig(turnMs: 30000),
          extendsByPlayer: {'a': 1});
      s = s.reduce(MsEvent.open, by: 'a', atMs: 0);
      s = s.reduce(MsEvent.extend, by: 'a', atMs: 1000);
      expect(s.remaining['a'], 34000);
      expect(s.extendTokens['a'], 0);
    });

    test('extend defers an incoming interrupt by 5s', () {
      var s = MainStageBattleState.create(['a', 'b'],
          config: const MainStageBattleConfig(graceMs: 2000),
          extendsByPlayer: {'a': 1});
      s = s.reduce(MsEvent.open, by: 'a', atMs: 0);
      s = s.reduce(MsEvent.interrupt, by: 'b', atMs: 1000); // grace to 3000
      s = s.reduce(MsEvent.extend, by: 'a', atMs: 1500); // -> 8000
      expect(s.pendingBy, 'b');
      s = s.reduce(MsEvent.tick, atMs: 3200);
      expect(s.floor, 'a', reason: 'held past the old deadline');
      s = s.reduce(MsEvent.tick, atMs: 8100);
      expect(s.floor, 'b', reason: 'cut-in lands 5s later');
    });

    test('extend/extends round-trip through toMap/fromMap', () {
      final s = MainStageBattleState.create(['a', 'b'],
          extendsByPlayer: {'a': 2, 'b': 1});
      final r = MainStageBattleState.fromMap(s.toMap());
      expect(r.extendTokens['a'], 2);
      expect(r.extendTokens['b'], 1);
    });

    test('instant interrupt steals immediately despite a grace, own pool', () {
      var s = MainStageBattleState.create(['a', 'b'],
          config: const MainStageBattleConfig(graceMs: 2000),
          stealsByPlayer: {'a': 0, 'b': 0},
          instantStealsByPlayer: {'b': 1});
      s = s.reduce(MsEvent.open, by: 'a', atMs: 0);
      s = s.reduce(MsEvent.interrupt, by: 'b', atMs: 1000, instant: true);
      expect(s.floor, 'b', reason: 'no grace, floor taken at once');
      expect(s.pendingBy, isNull);
      expect(s.instantSteals['b'], 0);
    });

    test('instant interrupt with no instant tokens is a no-op', () {
      var s = MainStageBattleState.create(['a', 'b'],
          stealsByPlayer: {'b': 2}, instantStealsByPlayer: {'b': 0});
      s = s.reduce(MsEvent.open, by: 'a', atMs: 0);
      s = s.reduce(MsEvent.interrupt, by: 'b', atMs: 1000, instant: true);
      expect(s.floor, 'a');
      expect(s.steals['b'], 2, reason: 'graced pool not touched by instant');
    });
  });

  group('dead air (three silent passes in a row)', () {
    // Each pass is 1s after the last; talking flags keep the shot clock out.
    MainStageBattleState pass(MainStageBattleState s, int at, bool silent) {
      final by = s.floor!;
      s = s.reduce(MsEvent.startTalking, by: by, atMs: at - 500);
      return s.reduce(MsEvent.yield, by: by, atMs: at, silent: silent);
    }

    test('A silent, B silent, A silent ends the battle', () {
      var s = open();
      s = pass(s, 1000, true); // A
      expect(s.isOver, false);
      s = pass(s, 2000, true); // B
      expect(s.isOver, false);
      expect(s.floor, 'a');
      s = pass(s, 3000, true); // A again
      expect(s.isOver, true);
      expect(s.endReason, 'dead_air');
    });

    test('a pass with speech resets the count', () {
      var s = open();
      s = pass(s, 1000, true);
      s = pass(s, 2000, true);
      s = pass(s, 3000, false); // A says something
      s = pass(s, 4000, true);
      s = pass(s, 5000, true);
      expect(s.isOver, false);
      expect(s.silentPasses, 2);
    });

    test('the count survives the host broadcast', () {
      var s = open();
      s = pass(s, 1000, true);
      s = pass(s, 2000, true);
      final copy = MainStageBattleState.fromMap(s.toMap());
      expect(copy.silentPasses, 2);
    });
  });

  group('rapid rounds (3 rounds x 15s, 2026-11-14)', () {
    const cfg = MainStageBattleConfig(turnMs: 15000, turnCount: 6);
    MainStageBattleState start() =>
        MainStageBattleState.create(['a', 'b'], config: cfg)
            .reduce(MsEvent.open, by: 'a', atMs: 0);

    test('opens on turn 1, round 1, with a fresh 15s clock', () {
      final s = start();
      expect(s.turn, 1);
      expect(s.round, 1);
      expect(s.roundCount, 3);
      expect(s.floor, 'a');
      expect(s.remaining['a'], 15000);
    });

    test('Done passes the mic with a FRESH clock - no carry-over', () {
      var s = start().reduce(MsEvent.yield, by: 'a', atMs: 4000);
      expect(s.floor, 'b');
      expect(s.turn, 2);
      expect(s.remaining['b'], 15000);
      s = s.reduce(MsEvent.yield, by: 'b', atMs: 6000);
      expect(s.floor, 'a');
      expect(s.round, 2);
      expect(s.remaining['a'], 15000, reason: 'unused 11s did not carry');
    });

    test('a turn that runs out of time passes the mic by itself', () {
      final s = start().reduce(MsEvent.tick, atMs: 15000);
      expect(s.floor, 'b');
      expect(s.turn, 2);
      expect(s.remaining['b'], 15000);
    });

    test('the battle ends after the sixth turn, and that turn is the last', () {
      var s = start();
      for (var i = 1; i < 6; i++) {
        s = s.reduce(MsEvent.yield, by: s.floor, atMs: i * 1000);
      }
      expect(s.turn, 6);
      expect(s.isLastTurn, isTrue);
      expect(s.floor, 'b');
      s = s.reduce(MsEvent.yield, by: 'b', atMs: 9000);
      expect(s.isOver, isTrue);
      expect(s.endReason, 'time');
    });

    test('the last turn timing out ends the battle', () {
      var s = start();
      for (var i = 1; i < 6; i++) {
        s = s.reduce(MsEvent.yield, by: s.floor, atMs: i * 1000);
      }
      s = s.reduce(MsEvent.tick, atMs: 5000 + 15000);
      expect(s.isOver, isTrue);
    });

    test('Drop the mic only works on the last turn', () {
      var s = start().reduce(MsEvent.endEarly, by: 'a', atMs: 1000);
      expect(s.isOver, isFalse);
      for (var i = 1; i < 6; i++) {
        s = s.reduce(MsEvent.yield, by: s.floor, atMs: i * 1000);
      }
      s = s.reduce(MsEvent.endEarly, by: s.floor, atMs: 7000);
      expect(s.isOver, isTrue);
      expect(s.endReason, 'done');
    });

    test('no shot clock and no interrupts', () {
      var s = start().reduce(MsEvent.tick, atMs: 9000);
      expect(s.floor, 'a', reason: 'silence is handled by the phone');
      s = s.reduce(MsEvent.interrupt, by: 'b', atMs: 9500);
      expect(s.floor, 'a');
    });

    test('three silent passes still end it as dead air', () {
      var s = start();
      s = s.reduce(MsEvent.yield, by: 'a', atMs: 5000, silent: true);
      s = s.reduce(MsEvent.yield, by: 'b', atMs: 10000, silent: true);
      s = s.reduce(MsEvent.yield, by: 'a', atMs: 15000, silent: true);
      expect(s.isOver, isTrue);
      expect(s.endReason, 'dead_air');
    });

    test('turn and turnCount survive the data-stream round trip', () {
      final s = start().reduce(MsEvent.yield, by: 'a', atMs: 1000);
      final copy = MainStageBattleState.fromMap(s.toMap());
      expect(copy.turn, 2);
      expect(copy.config.turnCount, 6);
      expect(copy.round, 1);
    });
  });
}
