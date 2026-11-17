import 'package:bully_league/core/main_stage_battle.dart';
import 'package:bully_league/core/turn_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const cfg = MainStageBattleConfig(turnMs: 15000, turnCount: 6);
  MainStageBattleState start() => MainStageBattleState.create(
    ['a', 'b'],
    config: cfg,
  ).reduce(MsEvent.open, by: 'a', atMs: 0);

  test('logs only changes, not every tick', () {
    final log = TurnLog();
    var s = start();
    log.record(s, 0);
    s = s.reduce(MsEvent.tick, atMs: 300);
    log.record(s, 300);
    s = s.reduce(MsEvent.tick, atMs: 600);
    log.record(s, 600);
    s = s.reduce(MsEvent.yield, by: 'a', atMs: 4000);
    log.record(s, 4000);
    final r = log.toReport(5000)!;
    final e = r['e'] as List;
    expect(e.length, 2);
    expect((e[0] as Map)['f'], 'a');
    expect((e[1] as Map)['f'], 'b');
    expect((e[1] as Map)['n'], 2);
    expect(((e[1] as Map)['r'] as Map)['b'], 15000);
  });

  test('the report says rapid rounds and carries the format', () {
    final log = TurnLog()..record(start(), 0);
    final r = log.toReport(1000)!;
    expect(r['kind'], 'rounds');
    expect(r['turnMs'], 15000);
    expect(r['turnCount'], 6);
    expect(r['sentAt'], 1000);
    expect(r['players'], ['a', 'b']);
  });

  test('the end is logged as over', () {
    final log = TurnLog();
    var s = start();
    for (var i = 0; i < 6; i++) {
      s = s.reduce(MsEvent.yield, by: s.floor, atMs: 1000 * (i + 1));
      log.record(s, 1000 * (i + 1));
    }
    expect(s.isOver, isTrue);
    final e = log.toReport(9000)!['e'] as List;
    expect((e.last as Map)['o'], 1);
  });

  test('nothing logged -> no report', () {
    expect(TurnLog().toReport(1), isNull);
  });
}
