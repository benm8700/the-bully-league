import 'package:flutter_test/flutter_test.dart';
import 'package:bully_league/core/main_stage_battle.dart';

void main() {
  const cfg = MainStageBattleConfig(turnMs: 30000, interrupts: 0, minHoldMs: 3000);
  MainStageBattleState start() => MainStageBattleState.create(['a', 'b'], config: cfg)
      .reduce(MsEvent.open, by: 'a', atMs: 1000);

  test('yield is refused inside the minimum hold', () {
    final s = start().reduce(MsEvent.yield, by: 'a', atMs: 2500);
    expect(s.floor, 'a');
  });

  test('yield works once the hold has passed', () {
    final s = start().reduce(MsEvent.yield, by: 'a', atMs: 4000);
    expect(s.floor, 'b');
  });

  test('the lock restarts for the new holder', () {
    var s = start().reduce(MsEvent.yield, by: 'a', atMs: 4000);
    s = s.reduce(MsEvent.yield, by: 'b', atMs: 5000);
    expect(s.floor, 'b');
    s = s.reduce(MsEvent.yield, by: 'b', atMs: 7100);
    expect(s.floor, 'a');
  });

  test('0 (Main Stage default) means no lock', () {
    final s = MainStageBattleState.create(['a', 'b'])
        .reduce(MsEvent.open, by: 'a', atMs: 1000)
        .reduce(MsEvent.yield, by: 'a', atMs: 1001);
    expect(s.floor, 'b');
  });

  test('minHoldMs survives the broadcast round-trip', () {
    final s = MainStageBattleState.fromMap(start().toMap());
    expect(s.config.minHoldMs, 3000);
  });
}
