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
}
